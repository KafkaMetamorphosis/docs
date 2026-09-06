# Impl tracker — 07 local-kafka-docker-agent

Deliverable: `franz/docs/impls_plan/07-local-kafka-docker-agent.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex unavailable (usage limit resets 2026-09-28)
Started: 2026-09-06   Completed: 2026-09-06   Commit: f942ebb (franz, impl/07-local-kafka-docker-agent)
Codex session: — (probe returned "You've hit your usage limit")

## Decisions

All three were **asked**:

### Q1 — Go Kafka client
- **Asked by:** claude   **Answered by:** user
- **Answer:** **`github.com/twmb/franz-go`** (pure Go, no CGO, admin + metadata).
  Also the standing choice for future Go Kafka code. Readiness probe = a broker
  `Metadata` request; `DEGRADED` when it errors or returns no live brokers.

### Q2 — 07.9 test strategy
- **Answer:** **Fake Docker for logic + local-only real smoke.** Reconcile /
  recipe logic is unit-tested against an in-memory fake Docker driver (runs in
  CI). A real-Docker end-to-end (`make agent-e2e`) pulls `apache/kafka`, brings a
  broker up, connects a franz-go client, creates a topic, then deletes — it
  self-skips without `FRANZ_AGENT_E2E=1`; **not** in CI.

### Q3 — local dev
- **Answer:** **`make agent TOKEN=…`** — a standalone target run after
  registering an agent in the console. `make dev` is unchanged.

### Implementation choices (not asked)

- **`assign` leaf package** — `Assignment` / `Change` moved out of the root
  `localkafka` package to break a `recipe → localkafka → docker → recipe` cycle.
- **Stream debounce** — the server sends one message per assignment (full set on
  open, then deltas). The watcher accumulates into a `desired` map and reconciles
  ~500 ms after the last message; a `REMOVED` entry is passed to the reconciler
  (so it tears the container down) then dropped from the map.
- **Status dedup** — the reconciler tracks `lastPhase` per cluster and only
  reports on a transition. An agent restart re-reports once.
- **Fresh-broker probe retry** — `Reconciler.ProbeAttempts/ProbeDelay`
  (default 12 × 5 s) so a normal KRaft boot goes `PROVISIONING → READY` with no
  transient `DEGRADED`. Tunable for tests.
- **Recreate keeps the volume**; only `REMOVED` and orphan-with-assignment drop
  it. Orphan-without-assignment removes the container, keeps the volume.
- **`CLUSTER_ID`** is fixed in the recipe env; the image formats storage on first
  boot and the data volume persists it across recreates.

## Questions & answers

_(the three decisions above; no mid-build blockers)_

## Verification

From `franz/`:

- `go build ./...`, `go vet ./...`, `gofmt -l` — ✅ clean
- `go test -count=1 ./...` (with `FRANZ_TEST_DB_DSN`) — ✅ pass. New suites:
  `recipe` (render, version→hash, allow-list + warnings, error paths),
  `reconcile` (create→READY, idempotent re-sync, recreate-keeps-volume, pause,
  removed, orphan, DEGRADED, probe-retry, bad-assignment→ERROR — all against the
  in-memory Docker fake), `stream` (debounce, REMOVED pruned after sync).
- `buf lint` — n/a (no `.proto` change).
- **Real Docker** (`make agent-e2e`, `FRANZ_AGENT_E2E=1`) — ✅ pass (~9 s with the
  image cached): register agent → agent starts → register cluster
  (`franz.provisioning/deployment-type=local-docker`) → container up → provider
  status `PROVISIONING → READY` → a `kadm` client connects at `localhost:19092`
  and creates `e2e-topic` → delete cluster → container + volume gone.

## Notes / deviations

- Codex out of quota → Claude implemented the whole deliverable.
- Agents are "deliberately simple" (002-monorepo-structure) — plain packages
  under `pkg/localkafka/`, no hexagonal layering, no `fx`.
- New deps: `github.com/twmb/franz-go` (+ `pkg/kadm` for the e2e),
  `github.com/docker/docker` (Engine API SDK) and its transitive tree.
- No CI change — the fake-driver tests run in the existing `go` job; the
  real-Docker e2e is local-only by decision.
- `Makefile` gains `agent` and `agent-e2e`; `webconsole/README` documents the
  "register agent → `make agent TOKEN=…` → register cluster" path to a live
  broker.
