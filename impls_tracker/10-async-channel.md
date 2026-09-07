# Impl tracker — 10 Async Channel + access-policy document

Deliverable: `franz/docs/impls_plan/10-async-channel.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex out of quota (usage limit resets 2026-09-28)
Started: 2026-09-06   Completed: 2026-09-06
Codex session: — (probe returned "You've hit your usage limit")

## Decisions

### Q1 — when are shard `kafka_topic` rows created?
- **Asked by:** claude   **Answered by:** user
- **Answer:** **not at `CreateAsyncChannel`.** The channel-create is a single
  `async_channel` row; `channel_partitions` is the declared count. **Placement**
  (deliverable 11) materialises the shard rows when it can assign a cluster,
  seeding `partitions` / `replication_factor` / `materialized_configuration` from
  that cluster's `cluster_configuration`. A channel with no eligible cluster has
  **0 shards**. Spec amended: `003.4` + new **ADR-API-009** (docs `6687748`).
  Deliverable-10 plan reworded (10.3, 10.9, "Done when"); deliverable-11 plan
  11.3/11.4/11.6 now own shard-row creation.

### Q2 — access-policy statement cap
- **Asked by:** claude   **Answered by:** user
- **Answer:** **no cap yet** — 003.5's "statement count is capped" invariant is
  deferred to its OQ2. `Policy.Validate` checks only per-statement
  well-formedness.

### Implementation choices (not asked)
- **No proto change** — `AsyncChannelService` + `AccessPolicy` shapes already
  generated.
- `access_policy` types live in their own `pkg/franz/core/domain/accesspolicy`
  package (deliverable 15's engine extends them).
- `ListChannelClients` handler returns `codes.Unimplemented` (deliverable 15).
- Delete / Pause / Resume cascade to shards via a channel-repo `MutateWithShards`
  (channel + its shards `FOR UPDATE` in one txn) — a no-op until placement
  creates shards, but written now.

## Questions & answers

_(the two decisions above)_

## Verification

- `go build ./...`, `go vet ./...`, `gofmt -l` — clean
- `go test ./...` (with `FRANZ_TEST_DB_DSN`) — 26 packages pass. New suites:
  `domain/accesspolicy` (validation table, no-cap), `domain/channel` (New,
  state machine, immutability, SetAccessPolicy), `adapters/in/grpcgateway`
  (create forwards + renders, mask rejection, SetAccessPolicy, ListChannelClients
  → Unimplemented, error mapping), `adapters/out/postgres` (create writes 1 row
  0 shards, pause/resume/delete cascade to test-inserted shards, SetAccessPolicy
  round-trip + malformed-statement rejection, selector list).
- `buf lint` — clean (no proto change).
- Done-when — all four met (create: 1 channel row + 0 shards;
  channel_partitions/type/access_policy not maskable; delete/pause cascade;
  SetAccessPolicy validates + stores verbatim).
- Live REST smoke — POST /v1/async-channels (0 shards), :pause cascade, mask
  rejection (400), PUT .../access-policy validation (400), GET .../clients (501).

## Notes / deviations

- codex out of quota → claude implemented the whole deliverable.
- **ADR-API-009** — shard `kafka_topic` rows are created by placement
  (deliverable 11), not at `CreateAsyncChannel`. Amended 003.4, added the ADR,
  reworded deliverable 10 (10.3/10.9/Done-when) and deliverable 11 (11.3/11.4/
  11.6 own shard creation). Docs `6687748`.
- `persistTopicTx` extracted in `postgres/topic.go`, shared by `MutateChannelShards`
  and the channel repo's `MutateWithShards`.
