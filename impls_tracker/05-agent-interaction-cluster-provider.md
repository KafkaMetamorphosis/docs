# Impl tracker — 05 Agent interaction (Cluster Provider)

Deliverable: `franz/docs/impls_plan/05-agent-interaction-cluster-provider.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex unavailable (usage limit resets 2026-09-28)
Started: 2026-09-06   Completed: 2026-09-06   Commit: c07373b (franz, impl/05-agent-interaction-cluster-provider)
Codex session: — (probe 01a0774b returned "You've hit your usage limit")

## Decisions

- **05.1 was already done by deliverable 04** — `pkg/shared/token`
  (`Generate`/`Hash`), `CreateAgentResponse.token`, `RotateAgentToken`,
  `agent.token_hash`. Prefix `frnat_`, SHA-256 (not the ADR's illustrative
  `frz_agt_` / argon2). Nothing re-done here.
- **05.3 proto was already written** in the earlier proto pass and is buf-lint
  clean. This deliverable is the Franz-side Go implementation only.
- **`provider` domain is a leaf package** — it must not import `cluster`
  (`cluster.Cluster` carries `*provider.Status`, which would cycle). The
  `*cluster.Cluster → provider.Assignment` mapping lives as `cluster.ToAssignment()`
  in the `cluster` package (which already imports `provider`).
- **Assignment fan-out is publish-on-mutate** — `clusters.Service` gained an
  `out.AssignmentPublisher` port and calls it after every Create/Update/Pause/
  Resume/Delete. On a provider-agent *change* it also publishes `CHANGE_REMOVED`
  to the previous owner. `streamhub.Hub` implements the port (in-memory).
- **`streamhub` drops a lagging subscriber** (buffer 64) by closing its channel;
  the handler returns `ABORTED` and the agent reconnects + full-resyncs
  (level-triggered per ADR §6).
- **Agent-auth interceptor is method-prefixed** to `/franz.v1.ClusterProviderService/`.
  Everything else keeps the allow-all realm interceptor (02.10). The provider
  usecase scopes by `agent.RealmID` from the authenticated agent, not
  `realm.FromContext`.
- **`Mutate`-style ownership + `SELECT … FOR UPDATE` not needed for status
  reports** — `ReportClusterStatus` is an append; it only reads the cluster for
  the ownership check.
- **Event history cursor** is an opaque `base64("<unixnano>|<uuid>")` (ordering
  is `occurred_at DESC, id DESC`, not by name), wrapped by `pagetoken` for the
  query-binding check.
- **Nightly prune** is a plain goroutine + 24h ticker in `cmd/franz`
  (`startProviderEventPrune`), 30-day window. Not distributed-lock-guarded — one
  Franz instance assumed.
- **`pkg/internal/dbtest.Lock`** — a Postgres session advisory lock on a pinned
  pool connection, taken by every DB integration test, so the `postgres` package
  tests and the new bufconn e2e (different package, run concurrently by
  `go test ./...`) do not clobber each other's fixtures.

## Questions & answers

_(none blocking — autonomous run per the user's "assume, note, resolve later"
instruction. Assumptions are listed in the deliverable file's "What landed"
section and mirrored below.)_

## Assumptions (need a yes/no later)

1. Initial assignment set **includes DELETED clusters as `CHANGE_REMOVED`**
   (re-sent every reconnect; idempotent for the agent).
2. Lagging subscriber → stream ends `ABORTED`; agent reconnects.
3. `ListClusterProviderEvents.page.total_size` = 0.
4. `cluster_provider_event` retention 30 days (ADR OQ6 — shares 003.14 default).
5. `agent` / `kafka_cluster` blanket-DELETE in tests now also clears the child
   `cluster_provider_event` rows (FK).

## Verification

Run from `franz/`:

- `go build ./...`, `go vet ./...`, `gofmt -l` — ✅ clean
- `go test -count=1 ./...` — ✅ pass (with `FRANZ_TEST_DB_DSN` + docker Postgres):
  - `provider` usecase: initial assignments (own clusters only, paused → PAUSED,
    provisioning-label filter), ownership `PERMISSION_DENIED`, phase validation,
    event append, `ListEvents`.
  - `streamhub`: delivery, multi-subscriber, unsubscribe, lagging-drop.
  - `clusters` usecase: assignment published SET/PAUSED/REMOVED on lifecycle;
    reassign → REMOVED to old agent + SET to new.
  - `postgres` `TestProviderEventRepo`: append, `LatestStatus` projection,
    newest-first pagination with cursor, prune.
  - **`TestClusterProviderE2E`** (bufconn, real Postgres, both interceptors):
    Bearer-token auth, stream full-set on open, `franz.provisioning/*` edit →
    `CHANGE_SET` delta, `ReportClusterStatus` → `provider_status` on
    `GetKafkaCluster`, `ListClusterProviderEvents` history, non-owner report →
    `PERMISSION_DENIED`, `RotateAgentToken` invalidates the old token
    (`UNAUTHENTICATED`), missing token → `UNAUTHENTICATED`.
- `buf lint api` — ✅ pass (no `.proto` change).
- REST gateway wiring sanity-checked (`/healthz`, `provider_status` rendered on
  `GetKafkaCluster`, `/v1/kafka/clusters/{name}/provider-events` → 200).

## Notes / deviations

- Codex out of quota → Claude implemented the whole deliverable.
- No new external Go dependencies (bufconn ships with `google.golang.org/grpc`).
- New packages: `core/domain/provider`, `core/usecases/provider`,
  `adapters/streamhub`, `pkg/internal/dbtest`.
- `clusters.NewService` and `grpcgateway.RegisterKafkaClusterService` signatures
  changed (extra deps); all call sites + tests updated.
- 003.12 (docs) gains the `cluster_provider_event` table row.
