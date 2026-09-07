# Impl tracker — 13 Placement & selection

Deliverable: `franz/docs/impls_plan/13-placement.md`
Status: ✅ done
Executed by: codex → claude (claude-sonnet-5) — codex hit its usage limit (resets 2026-09-28) before writing any code; Claude implemented via the architect agent, orchestrator verified + finalised
Started: 2026-09-07   Completed: 2026-09-07   Commit: franz `<sha>`
Codex session: — (quota-exhausted on first invocation, no code produced)

Branch: `impl/13-placement` (off `main` — 11/19/12 merged).

Naming note (user, 2026-09-07): prose / doc comments / `slog` / this tracker call
a "shard" an **"async-channel shard"** to keep it distinct from a Kafka
partition. Existing identifiers unchanged.

## Decisions

- **`topic.Materialize` now drops the seed keys.** Its doc comment already said
  `partitions` / `replication-factor` are not part of the config merge, but the
  code copied the whole cluster map — so `materialized_configuration` carried
  `partitions: "6"` etc., which Gregor Samsa would try to apply as Kafka
  *topic-config*. Added `topic.ConfigKeyPartitions` / `ConfigKeyReplicationFactor`,
  excluded from the cluster layer, plus `SeedPartitions` / `SeedReplicationFactor`.
  Behaviour change for deliverable 12's agent, in the direction 003.6 specifies.
  Closes **003.6 OQ1**: keys `partitions` / `replication-factor`, default `1`/`1`
  when absent/unparseable, excluded from the merge, no channel-level hint.
- **Rows only exist for placed async-channel shards** (ADR-API-009 + the task
  list), *not* the `PENDING`/`NULL`-cluster row that 003.7 still describes.
  `topic.New`'s `partitions>=1` precondition therefore always holds.
- **Cluster create / pause / resume / delete run a placement pass**, not just
  `Update` — a channel materialises on cluster registration rather than up to a
  sweep interval later; also makes the integration tests deterministic.
- **Channel `Update` skips a no-op pass via `placement.RulesChanged`** (reserved
  keys only); **cluster `Update` re-places on any label edit** (affinity matches
  free-form cluster labels — no reserved-key shortcut on that side).
- **The misplaced marker does not bump `generation`** and is pushed to agents
  only when it flips, not per sweep.
- **Removing `franz.affinity/selector` marks every placed shard misplaced**
  (no selector ⇒ no candidates ⇒ every cluster fails affinity). Any `kafka_topic`
  row seeded outside placement gets marked on the first pass over its channel.
- **`no-creation` does not misplace an already-placed shard; only `drain` does.**
- **A cluster with malformed reserved labels fails closed** — not a candidate,
  not a valid host (write-path validation should make this unreachable).
- **Unknown `franz.affinity/*` keys are NOT rejected** — 003.1 says the reserved
  set is open, so `franz.affinity/shardsize` (typo) is silently ignored. Possible
  spec tightening.
- New repo methods: `TopicRepository.PlaceChannelShards` (channel + shard rows
  `FOR UPDATE`, one txn); `AsyncChannelRepository.ListActive(realmID)` +
  `ListUnderplaced()` (cross-realm sweep work list); `RealmRepository.GetByID`
  used to resolve the realm for the FRN in the sweep.
- `placement.Service` provided to fx both concretely (the sweep needs it for
  `Sweep`) and behind `out.ShardPlacer`.
- Round-robin remainder → earlier (higher-weight, then lower-named) clusters,
  `chosen[index % k]`. `shard-size` may exceed `channel_partitions`; capped at
  `|candidates|`. Closes **003.7 OQ1**.
- Retry sweep: `FRANZ_PLACEMENT__SWEEP_INTERVAL`, default `30s`, `0` disables;
  event triggers run in addition. Closes **003.7 OQ5**.

## Questions & answers

_(none — codex produced no questions before quota-out; the architect agent hit no
blocking questions. Both 003.7 OQs were answerable from ADR-API-009/010/011.)_

## Verification

- `go build ./...` — OK
- `go vet ./...` — OK
- `gofmt -l cmd pkg migrations` — empty
- `go test ./...` with `FRANZ_TEST_DB_DSN` — **32 packages ok**, 0 fail (stream
  test re-run 3×). New suites: `domain/placement` (Select + determinism +
  reversed-input + label validation + `CanHost` no-creation/drain asymmetry),
  `usecases/placement` (fakes), `adapters/out/postgres/placement_integration_test`
  (7 tests: materialise-on-registration, no-selector→0-rows, misplaced-no-move,
  taints, sweep, deterministic-across-runs, labels-validated-on-write),
  `adapters/in/grpcgateway/placement_integration_test` (bufconn — placement
  reaches a connected agent as `SET`).
- `buf lint` (from `franz/api`) — exit 0. Proto change is additive
  (`KafkaTopic.misplaced = 14`, `misplaced_reason = 15`).
- `buf generate api` + `npm --prefix webconsole run gen:api` — idempotent;
  `pkg/gen/go`, `api/openapi`, `webconsole/src/api/schema.d.ts` verified to match
  the proto (regen from a clean tree of the branch produces no diff).
- webconsole `typecheck` / `lint` / `test` (7 files, 21) / `build` — all pass.
- **Done when** — all three met:
  1. `TestPlacementIsDeterministicAcrossRuns` + `TestSelectIsDeterministic`
     (identical and reversed inputs → identical assignment).
  2. `TestPlacementMaterialisesOnClusterRegistration` (0 rows → register a
     matching cluster → exactly `channel_partitions` rows, `partitions` /
     `replication_factor` seeded).
  3. `TestPlacementMarksMisplacedAndMovesNothing` (`misplaced = true`,
     `kafka_cluster` unchanged even with a second eligible cluster present).

## Spec / ADR edits — DONE (2026-09-07, docs `main`)

All applied in one pass (`003.1` / `003.6` / `003.7` / `003.9` / `DECISIONS.md`).

1. **`003.7`** — three passages say an unplaceable shard gets a `PENDING` /
   `kafka_cluster = NULL` **row** (lines ~22–24, the "Selection algorithm" tail
   ~66–70, the first Invariant ~101–102) + the "Kafka Topic (003.6)" cross-entity
   bullet ~118–120. All contradict **ADR-API-009** (a row exists only once
   placed; `GetAsyncChannel` reports "M of N placed" by counting rows). Reword.
2. **`003.7` OQ1** — resolved (round-robin remainder to earlier clusters;
   `shard-size` may exceed `channel_partitions`). Fold into the body, close OQ.
3. **`003.7` OQ5** — resolved (configurable 30s default + event triggers). Close.
4. **`003.7` "Re-placement"** — state that removing `franz.affinity/selector`
   marks every placed shard misplaced, and the marker auto-clears when the
   cluster satisfies the rules again.
5. **`003.7` "Taints"** — explicit line that `no-creation` does NOT misplace an
   already-placed shard (only `drain` does) — the single most load-bearing
   asymmetry in the code.
6. **`003.6` OQ1** — resolved (see Decisions). Close, and note the two seed keys
   are excluded from the "Config merge".
7. **`003.6` KafkaTopic field table** — add `misplaced` / `misplaced_reason`.
8. **`DECISIONS.md` ADR-API-009** — note placement also owns the misplaced marker
   and strips the two seed keys from the merge.

## Notes / deviations

- codex never ran (quota); the whole deliverable is Claude's.
- The webconsole has no Kafka Topic view yet, so `misplaced` is API-only for now.
- `013.7` OQ2 (`PreviewPlacement` RPC) — still out of scope, unaddressed.
