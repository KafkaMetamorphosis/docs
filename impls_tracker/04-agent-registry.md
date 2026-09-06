# Impl tracker — 04 Agent registry

Deliverable: `franz/docs/impls_plan/04-agent-registry.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex unavailable (usage limit resets 2026-09-28)
Started: 2026-09-06   Completed: 2026-09-06   Commit: c694abb (franz, impl/04-agent-registry)
Codex session: — (out of quota)

## Decisions

- **`pkg/shared/token`** — bearer-token primitive: `Generate()` →
  (`frnat_` + base64url(32 random bytes), sha256-hex hash); `Hash(plaintext)`
  for the eventual verify path. Franz stores only the hash (003.9). No token
  verification is wired yet — deliverable 05 (agent interaction) consumes it.
- **Token lives on the domain entity as `TokenHash`** (never rendered to proto).
  `agent.New` takes the hash; `RotateToken` swaps it. The usecase mints the
  plaintext and returns it once via `in.CreatedAt`/`RotateToken`.
- **`type` filter pushed to SQL** (unlike the Kafka Cluster label selector which
  is Go-side) — `ListAgentsRequest` exposes only a `type` filter, no selector, so
  pagination is exact (`LIMIT n+1`).
- **Same slice shape as deliverable 03** — `Mutate` port method
  (`SELECT … FOR UPDATE` in one txn), `frn.Codec` in the handler, in-process
  gateway registration via `grpcgateway.RegisterAgentService`.

## Questions & answers

_(none blocking — autonomous run; assumptions below.)_

## Assumptions (need a yes/no later)

1. **`type` is mutable** via `UpdateAgent` (003.9 OQ2; deliverable note said
   "treat as mutable for now").
2. **Pause/Resume idempotent**; **GetAgent returns a soft-deleted agent**
   (state=DELETED), not NOT_FOUND — mirrors Kafka Cluster.
3. **Token format** `frnat_` + 32 random bytes base64url; sha256-hex stored. No
   TTL, no scopes (interaction ADR territory).
4. **ListAgents = type filter only** (proto has no selector); `page.total_size`
   = 0.
5. **Delete while a cluster names the agent** → allowed; the
   `cluster_provider_agent` string is left dangling (003.9 OQ3, per 003.3).
6. **RotateAgentToken on a DELETED agent** → FAILED_PRECONDITION.
7. Endpoint namespace kept at `/v1/kafka/agents` (003.9 OQ1 — accepted open).

## Verification

Run from `franz/`:

- `go build` / `go vet` / `gofmt -l` / `go test ./...` — ✅ clean/pass
  (domain type+status machine; `token` pkg; `agents.Service` with in-memory repo:
  token mint + hash-stored-not-plaintext, rotate invalidates old, lifecycle,
  masked update, type filter + pagination; handler tests: token in response, FRN
  prefix, error→status, mask forwarding, rotate).
- `buf lint api` — ✅ pass (no `.proto` change).
- **Postgres integration** (`FRANZ_TEST_DB_DSN` set) — ✅ pass:
  `TestAgentRepoLifecycle` (create/get/rotate/soft-delete/name-not-reusable),
  `TestAgentRepoListTypeFilter` (+ paginated), and
  `TestAgentDeleteLeavesClusterProviderStringDangling` (04.5), plus the 02/03
  suites.
- **REST end-to-end** against real Postgres — ✅ create → one-time
  `frnat_…` token + FRN, `?type=AGENT_TYPE_CLUSTER_PROVIDER` filter,
  `:rotateToken` → new token, `PATCH … update_mask=type`, `:pause` → 200,
  `AGENT_TYPE_UNSPECIFIED` create → 400, delete → 200.

## Notes / deviations

- Codex out of quota → Claude implemented the whole deliverable.
- New shared package `pkg/shared/token`. No new external Go dependencies.
- `agent` table has a `token_hash text NOT NULL` column not spelled out in
  003.12's table list — implied by 003.9 ("Franz stores only its hash").
