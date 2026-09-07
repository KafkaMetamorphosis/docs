# Impl tracker — 09 Kafka Topic (read model)

Deliverable: `franz/docs/impls_plan/09-kafka-topic.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex out of quota (usage limit resets 2026-09-28)
Started: 2026-09-06   Completed: 2026-09-06
Commit (franz, impl/09-kafka-topic): see the deliverable's Landed cells
Codex session: — (probe returned "You've hit your usage limit")

## Decisions

### Q1 — async_channel table / FK (chicken-and-egg with deliverable 10)
- **Asked by:** claude   **Answered by:** user
- **Answer:** 09 creates a **minimal `async_channel` stub** (id, realm_id, name,
  frn, timestamps, `UNIQUE(realm_id,name)`, `UNIQUE(frn)`) in `V1__init.sql` — just
  enough for a real `kafka_topic.async_channel_id` FK and name→id resolution for
  the `ListKafkaTopics` channel filter. Deliverable 10 extends the same table
  with the channel columns (labels, access_policy, channel_partitions, type,
  state); its task 10.1 is restated "extend" not "create".

### Q2 — traffic_share unit/values
- **Asked by:** claude   **Answered by:** user
- **Answer:** fixed `unit = "percent"`. Each shard whose `consumption = ENABLED`
  gets `100.0 / enabled-count` (exact double); `DISABLED` shards get `0`.
  `SetConsumption` recomputes the split across the channel's shards.

### Implementation choices (not asked)
- `materialized_configuration` is an **internal column only** — not surfaced on
  `KafkaTopic` in the proto (003.6 is `ready`; no proto change). It is stored,
  frozen at create/desired-state-change, and read by the agent path later.
- No proto change — `KafkaTopicService` + gateway are already generated.
- The **state machine is modelled, not driven** — 09 has no channel propagation
  (deliverable 10) and no agent reporting (interaction ADR). `SetConsumption` is
  the only mutation and it never touches `state`.
- `partitions` increase-only + immutability of `name`/`async_channel`/
  `kafka_cluster` are enforced in the **domain** (`IncreasePartitions`,
  no setters for the immutable fields), ready for governance (13) / re-shard (16)
  — no RPC exercises them in 09.

## Questions & answers

_(the two decisions above)_

## Verification

- `go build ./...`, `go vet ./...`, `gofmt -l` — ✅ clean
- `go test ./...` (with `FRANZ_TEST_DB_DSN`) — ✅ 24 packages pass. New suites:
  `domain/topic` (state machine, `SetConsumption`, `IncreasePartitions`,
  `Rematerialize`, `EqualSharePercent`), `usecases/topics` (rebalance,
  all-disabled, bad value, deleted), `adapters/in/grpcgateway` (Get renders
  joined names + FRN, SetConsumption forwarding, error mapping, list filters),
  `adapters/out/postgres` (materialised-config frozen across a cluster edit,
  4-shard drain → re-normalise → restore, list filters + pagination + soft-delete
  hidden, `CountLiveTopics` blocks `DeleteKafkaCluster`, partition-decrease rolls
  the txn back).
- `buf lint` — n/a (no proto change; `KafkaTopicService` was already generated).
- Done-when checks — ✅ all three (drain→0 + siblings re-sum, cluster-config edit
  leaves materialised config untouched, cluster delete with a live topic →
  `FAILED_PRECONDITION`).
- Live REST smoke — ✅ `GET /v1/kafka/topics/{name}`, `?async_channel=` filter,
  `POST …:setConsumption` (drain a shard, siblings re-split 50/50).

## Notes / deviations

- codex out of quota → claude implemented the whole deliverable.
- **Deliverable 10 plan updated in this pass**: `10-async-channel.md` task 10.1
  is now "**extend** `async_channel`" (09 created the id/realm/name/frn stub for
  the FK).
- Shared integration-test cleanups (`cleanupClusters`, the grpcgateway
  clusterprovider e2e) now also `DELETE FROM kafka_topic` / `async_channel` —
  the new FK from `kafka_topic` to `kafka_cluster` otherwise blocks those deletes
  when a topic-suite test leaves rows.
