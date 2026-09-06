# Impl tracker — 03 Kafka Cluster

Deliverable: `franz/docs/impls_plan/03-kafka-cluster.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex unavailable (usage limit resets 2026-09-28)
Started: 2026-09-06   Completed: 2026-09-06   Commit: d1fde0a (franz, impl/03-kafka-cluster)
Codex session: — (out of quota)

## Decisions

- **`Mutate` port method instead of leaking `pgx.Tx`** — `ClusterRepository.Mutate(realmID, name, func(*Cluster) error)` runs
  `BEGIN → SELECT … FOR UPDATE → mutate → UPDATE … RETURNING → COMMIT` internally.
  Keeps `SELECT … FOR UPDATE` (003.12) without a transaction type in the port.
  Update / Delete / Pause / Resume all go through it.
- **Selector filtering is Go-side** (003.12 OQ2 says start Go-side). The repo
  streams rows `ORDER BY name` with a hard `LIMIT 5000` scan cap, applies
  `selector.Match` in Go, and stops at `page.Limit + 1` matches to compute the
  next-page cursor.
- **`ClusterTopicGuard` port + `stub.NoTopicGuard`** — the delete guard (03.6)
  needs a live-topic count, but `kafka_topic` does not exist until deliverable
  09. A no-op guard returning 0 is wired now; 09 swaps in a postgres-backed count.
- **`fieldmask.CanonicalPaths`** added so the handler can `switch` on proto field
  names (resolving JSON-name aliases) to build the typed `UpdateClusterInput`
  (nil pointer = leave unchanged). `update_mask` added to the immutable set.
- **FRN rendering** — the handler holds a `frn.Codec` and renders
  `KafkaCluster.frn` with the configured prefix (ADR-API-007); the DB stores the
  prefix-less path.
- **Service registration** — `grpcgateway.RegisterKafkaClusterService(server,
  svc, codec)` mounts the impl on both the gRPC server and the in-process REST
  gateway. Called from `newServer` before `Start`.

## Questions & answers

_(none blocking — assumptions listed below were made autonomously per the user's
"assume, note, resolve later" instruction while AFK.)_

## Assumptions (need a yes/no later)

1. **Pause/Resume idempotent** — Pause on PAUSED (Resume on ACTIVE) returns 200,
   not FAILED_PRECONDITION.
2. **GetKafkaCluster returns a soft-deleted cluster** (state=DELETED) rather than
   NOT_FOUND. Only mutating ops fail on DELETED.
3. **`page.total_size` = 0** on List (best-effort; 003.1 permits). Not computed
   under Go-side selector filtering.
4. **List scan cap 5000 rows/page.** A realm with >5000 non-deleted clusters
   could miss later-page rows. Fine pre-scale.
5. **`ListClusterProviderEvents` → Unimplemented** (deliverable 05 owns it).

## Verification

Run from `franz/`:

- `go build ./...`, `go vet ./...`, `gofmt -l` — ✅ clean
- `go test ./...` — ✅ pass (domain state machine, `clusters.Service` with an
  in-memory repo: lifecycle, delete-blocked-by-topics, masked update, selector +
  pagination + cross-query-token rejection + soft-delete visibility; handler
  tests: FRN prefix rendering, error→status, mask forwarding, empty/immutable
  mask rejection).
- `buf lint api` — ✅ pass (no `.proto` change this deliverable).
- **Postgres integration** (`docker compose up -d postgres`,
  `FRANZ_TEST_DB_DSN` set) — ✅ pass: `TestClusterRepoLifecycle`,
  `TestClusterRepoListSelectorAndPagination`, `TestClusterRepoMutateSerialises`
  (8 concurrent `Mutate` → no lost updates), plus the deliverable-02 suite.
- **REST end-to-end** against real Postgres — ✅ create (FRN
  `frn:default:kafka-cluster:east-1`, state ACTIVE), get, `?selector=env=prod`,
  `:pause` (state + `updated_at`), duplicate create → 409, empty
  `connection_strings` → 400 with `google.rpc.BadRequest`, delete → 200.

## Notes / deviations

- Codex out of quota → Claude implemented the whole deliverable.
- No new Go dependencies.
- New package `pkg/franz/adapters/out/stub` for later-deliverable placeholders.
