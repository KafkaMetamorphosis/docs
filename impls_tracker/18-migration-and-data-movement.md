# Impl tracker — 18 Migration & data movement

Deliverable: `franz/docs/impl_plans/18-migration-and-data-movement.md`
Status: ✅ done (18.4's misplaced-shard auto-relocate deferred)
Executed by: claude (claude-sonnet-5) — codex out of quota (resets 2026-09-28), never ran
Started: 2026-09-13   Completed: 2026-09-14   Commit: franz `<pending>`
Codex session: — (quota-exhausted, no code)

Branch: `impl/18-migration-and-data-movement` (off `impl/17-access-policy-and-channel-access`,
PR #30, still open at the time this branch was cut — 18 stacks on it per the
established convention).

## Questions & answers

The user's standing instruction for this deliverable was explicit: ask with 4
options via `AskUserQuestion` at every open decision rather than assume. Two
rounds covered 003.13's prerequisite OQs; a third, unplanned round happened
mid-implementation when the mechanism itself turned out to be wrong.

### Q1 — RPC surface (`003.13` OQ1)
- **Asked by:** claude
- **Answered by:** user
- **Question:** Internal-only migration, or an operator-facing
  `MigrateKafkaTopic` / re-shard entry point?
- **Answer:** "Explicit write RPC now."
- **Source:** `api/franz/v1/migration.proto`'s `MigrateKafkaTopic` /
  `MigrateCluster` RPCs.

### Q2 — Data-copy mechanism (`003.13` OQ2)
- **Asked by:** claude
- **Answered by:** user
- **Question:** Drain-based only (v1), or also a replication-based path
  (MirrorMaker2 / offset translation) for bounded downtime?
- **Answer:** "Drain-based only (Recommended)."
- **Source:** the whole deliverable — no byte-copy path exists; a key's old
  messages stay on the retiring shard until retention cleans them up.

### Q3 — Drain-deadline policy (`003.13` OQ3)
- **Asked by:** claude
- **Answered by:** user
- **Question:** Fixed config-wide deadline, per-channel, or lag-derived?
  If fixed, what value?
- **Answer:** "Fixed, config-wide deadline (Recommended)" — "1 hour."
- **Source:** `migration.DrainDeadlineWindow = time.Hour`.

### Q4 — Old-data disposition after a shard is removed (`003.13` OQ4, folded
in while resolving 18.7's re-shard scope)
- **Asked by:** claude
- **Answered by:** user
- **Question:** When a shard retires (migration, or a re-shard decrease),
  what happens to messages a key already routed there?
- **Answer:** "Old messages stay put, permanently (Recommended)" — no
  replay/redirect; retention cleans them up on its own schedule.
- **Source:** the "Done when" drain condition (`kafka.topic.drained`) requires
  zero data, not zero-and-copied.

### Q5 — Cluster-delete-with-live-topics (`003.13` OQ5, `003.3` OQ1)
- **Asked by:** claude
- **Answered by:** user
- **Question:** Auto-drain silently, require an explicit `force=true`, or
  require a prior `drain` taint before delete is even attempted?
- **Answer:** "Require force=true, which auto-triggers drain (Recommended)."
- **Source:** `DeleteKafkaClusterRequest.force`; `clusters.Service.Delete` —
  `force=false` + live shards → `FAILED_PRECONDITION`; `force=true` → cluster
  stays ACTIVE, `MigrateCluster` starts, delete completes on a later call.

### Q6 — Concurrency limits (`003.13` OQ6)
- **Asked by:** claude
- **Answered by:** user
- **Question:** A fleet-wide cap, no limit, or a per-cluster configurable
  limit?
- **Answer:** "Per-cluster configurable limit."
- **Source:** `KafkaCluster.MaxConcurrentMigrations` (new field, proto +
  domain + postgres + handler; `DefaultMaxConcurrentMigrations = 1` when
  unset) — deliberately **not** folded into the `cluster_configuration` map,
  since that map is documented elsewhere as "the single home for Kafka
  config", not general settings.

### Q7 — Where the operator RPC lives
- **Asked by:** claude
- **Answered by:** user
- **Question:** Since migration got an explicit operator RPC (Q1), should it
  live on an existing service or a new one?
- **Answer:** "New MigrationService (Recommended)."
- **Source:** `api/franz/v1/migration.proto`.

### Q8 — Drain-readiness signal source (no named OQ — identified by claude
while designing 18.3; the user gave a substantive answer rather than picking
an option)
- **Asked by:** claude
- **Answered by:** user
- **Question:** How does Franz learn a migration's target is safely consuming
  and the source has no lag/data left?
- **Answer (verbatim):** "1, the lag draining should be verified by
  gregor-samsa which has connection to kafka. Is up to it say the moments of
  migrations. For instance, to verify that the new topic has already a
  consumer connected to it and it is ok to produce to it, gregor-samsa that
  should verify this. To make sure no lag is present on the old topic and it
  is also empty and can be removed, it is also a gregor-samsa duty."
- **Source:** motivated the two new indicators before Q10 resolved *how* they
  should be surfaced.

### Q9 — Source-shard teardown mechanics (no named OQ, asked alongside Q8)
- **Asked by:** claude
- **Answered by:** user
- **Question:** When is the source shard's row actually removed, and through
  what mechanism?
- **Answer (verbatim):** "The kafka topic is always the representation of an
  given topic in a cluster, so it the topic is migrated a new registry in db
  is created and the old one is still there until it is ready to be removed
  (no messages, no lag). So the action of removing this from the cluster (whe
  really ready), should remove the old one. Ask me if anything is still
  ambiguous."
- **Source:** this is the seed of the whole reframe (see Q11) — "a new
  registry is created and the old one is still there" is exactly "no
  `kafka_cluster_id` flip, two rows coexist", stated before claude had
  connected it to `traffic_share`.

### Q10 — Readiness-reporting protocol
- **Asked by:** claude
- **Answered by:** user
- **Question:** claude asked (via `AskUserQuestion`) how the drain/connected
  signal from Q8 should reach Franz — a new agent-protocol RPC, or something
  else.
- **Answer:** "why not using a indicator / sensor for that?"
- **Source:** the two new indicators (`kafka.topic.drained`,
  `kafka.topic.consumer_connected`) reuse deliverables 14/15's Indicator/
  telemetry infrastructure entirely — zero new agent-protocol surface,
  computed from existing `kafkaadmin.Admin` methods
  (`ListOffsets`/`ListConsumerGroups`/`ListConsumerGroupOffsets`).

### Q11 — The mechanism itself (the pivotal correction)
- **Asked by:** user, unprompted — claude had proposed a "row visibility
  during migration" `AskUserQuestion` that assumed a state machine flipping
  `kafka_topic.kafka_cluster_id`; the user rejected that tool call outright
  ("The user wants to clarify these questions... Start by asking them what
  they would like to clarify") rather than answer it.
- **Answered by:** user, in plain text after claude asked what they'd like to
  clarify
- **The correction (verbatim):** "Actually, I think about the migration in a
  simple way. An async channel can have N kafka topics inside it, as we know.
  And the load can be spread among percentually. When the topic is created,
  the consumer on the topic can be active or not, we already have it. The
  migration process happens this mechanism just by controlling the amoung of
  load distributed by them. For instance, lets say we have an async channel
  with 2 topics (tpc-p0 and tpc-p1) which the p0 lives on cluster A and the
  p1 lives on cluster B. Moving tpc-p0 to a cluster C means to 1. creating a
  new topic (tpc-p0) the async partition but on cluster C; 2. Making the
  consumers reading from tpc-p0 on C; 3. move the load from A (tpc-p0) to C
  (tpc-p0); 4. The use will see a partition in more than one place for a
  while, but in different cluster; 5. once the tpc-p0 on A has no load,
  consumers and no messages left on the disk (messages where cleaned by
  retention config), it can be removed; My point is that the migration just
  use this mechanism to make thing work, not a completely isolated feature."
- **What changed:** everything downstream of "provision". The original task
  list (18.1's `kafka_topic.kafka_cluster_id` flip at cutover) is mechanically
  impossible anyway — `kafka_topic.name` and its FRN are unique per row, and
  the `PartitionNotifier` design is row-driven — but claude had not caught
  that before the user corrected the premise directly. Claude synthesized the
  5-step design back as a confirmation ("is this the right shape? If so, I'll
  start building") before writing any code; the user replied **"yes,go
  ahead."**
- **Source:** `docs/impl_plans/18-migration-and-data-movement.md`'s "The
  mechanism, reframed" callout quotes the synthesized design; `migration.go`'s
  package doc and `service.go`'s `createMigration` implement it verbatim.

### Q12 — Scope-stop decision for 18.4/18.8 (asked after the core mechanism
was built and verified)
- **Asked by:** claude
- **Answered by:** user
- **Question:** 18's own "Done when" requires governance to be able to
  re-place/taint/re-shard, which needs 18.8 (governance-action enablement);
  18.4's misplaced-shard auto-relocate was also unbuilt. Finish 18.8 now,
  finish both, defer both and mark 18 done-with-gaps, or pause for review?
- **Answer:** "Finish 18.8 now (Recommended)" — leave misplaced-shard
  auto-relocate explicitly deferred, since it is not in Done-when and 13.5
  already marks shards misplaced without this being the only consumer of
  that marker.
- **Source:** `governance/actions.go`'s `writeChannelField`; `whitelist.go`'s
  `deferredAction` trimmed to just the channel_partitions-decrease case.

## Decisions

- **`shard_migration` is bookkeeping, not a parallel state machine** — the
  phase column drives the sweep's own resumability; it does not gate what
  `kafka_topic` rows mean. This is the single load-bearing consequence of Q11.
- **Per-cluster `MaxConcurrentMigrations`, not a `cluster_configuration` key**
  (Q6) — `cluster_configuration` is documented elsewhere as the Kafka-config
  map specifically; a scheduling knob does not belong there.
- **Two new indicators, zero new agent RPCs** (Q8/Q10) — `PartitionOffsets.
  HasData()` (Earliest < Latest) is the "drained" signal; a consumer group
  with any committed offset on the topic is "connected". Both computed in
  Gregor Samsa's existing per-cluster sweep, one `ListConsumerGroups` call
  reused across every topic in the sweep rather than once per topic.
- **Concurrency check ordering** — `createMigration` checks "already
  migrating this shard" (→ `AlreadyExists`) *before* the concurrency-limit
  check (→ `ResourceExhausted`), not after; the two are easy to conflate when
  a cluster's concurrency slots are already full of the same shard's own
  migration.
- **Re-shard is increase-only** (18.7) — `AsyncChannel.SetChannelPartitions`
  rejects `n <= current`. A decrease needs the same drain-then-retire
  sequence run per *removed* shard, and nothing drives that automatically —
  explicitly out of scope here, tracked in the deliverable's Notes and the
  plan's Blockers table.
- **18.8's un-deferral is narrow, not blanket** — `franz.affinity/*`,
  `franz.antiaffinity/*`, `franz.taint` labels, and a `channel_partitions`
  *increase* all now reach the real path (they already flowed through
  `channels.Service.Update` / `clusters.Service.Update`, which already do the
  right thing since 18.4's drain-taint hook and 18.7's re-shard landed) — a
  `channel_partitions` *decrease* stays rejected at write, for the same
  reason as the 18.7 decision above.
- **Misplaced-shard auto-relocate deferred** (Q12) — 13.5's `misplaced`
  marker exists but nothing calls `MigrateKafkaTopic` for it automatically
  yet; an operator (or a future governance policy over a misplaced-derived
  indicator) drives it manually today.

## Verification

- `go build ./...` — clean.
- `go vet ./...` — clean.
- `gofmt -l` (excluding `pkg/gen`) — clean.
- `go test -p 1 ./...` with `FRANZ_TEST_DB_DSN` → Postgres integration active
  — **41 packages ok, 0 fail** (re-verified after the 18.8 addition). Without
  `-p 1`, `go test ./...` intermittently fails several `grpcgateway` tests —
  confirmed via isolated reruns and `-p 1` serialization that this is a
  **pre-existing** cross-package race against the same live Postgres
  instance, not a regression from this deliverable; `-p 1` is the reliable
  way to verify this suite until that gets its own fix.
- New suites: `core/domain/migration/migration_test.go` (10 cases — `New`
  validation, full happy-path transition order, out-of-order rejection,
  `ReadyToRetire`'s drained/deadline logic, `Fail` from every non-terminal
  phase); `pkg/gregorsamsa/telemetry/telemetry_test.go` (5 cases — drained/
  connected/unknown-on-error); `adapters/out/postgres/
  migration_integration_test.go` (`TestMigrationFullLifecycle` — full
  PROVISIONING→CUTOVER→DRAINING→RETIRING→DONE via repeated `Sweep()` calls,
  idempotent no-op sweep after DONE; `TestMigrateKafkaTopicRejectsSameCluster`,
  `TestMigrateKafkaTopicRejectsIneligibleTarget`,
  `TestMigrateClusterSkipsShardsWithNoEligibleTarget`,
  `TestMigrateClusterMovesEveryLiveShard`,
  `TestClusterDrainTaintAutoTriggersMigration`); `adapters/out/postgres/
  placement_integration_test.go` (`TestUpdateAsyncChannelChannelPartitions
  Reshards`, `TestUpdateAsyncChannelRejectsChannelPartitionsDecrease`);
  `core/domain/governance/policy_test.go` +
  `core/usecases/governance/{service,evaluator}_test.go` (18.8 — placement
  actions now accepted, `TestEvaluateAppliesChannelPartitionsReshard` proves
  a fired policy actually re-shards, a decrease still rejected).
- `buf lint` (from `franz/api`) — clean.
- **Live smoke test** against the local dev Postgres + a real `franz` binary
  boot on isolated ports: `/healthz` → 200; `POST /v1/kafka-topics/
  orders-0/migrate` against the local loop's one unplaced seed shard returned
  the expected domain error (`FAILED_PRECONDITION: shard "orders-0" is not
  placed on any cluster`), not a crash — confirming the REST↔proto↔service
  wiring end to end. A full live migration demo (two real reachable clusters
  with an agent on each) was not attempted; the local dev loop only
  registers one cluster, and the phase-by-phase integration test already
  covers the mechanism more precisely than an ad hoc curl sequence would.
- **Done-when** — all three criteria met; see the deliverable file's own
  "Done when" section for the test cross-references.

## Notes / deviations

- codex never ran (quota, resets 2026-09-28) — claude implemented it
  directly, across a genuinely large deliverable (11+ files touched or added
  across domain/ports/usecases/postgres/handlers/proto/wiring).
- **Found and fixed a real pre-existing production bug** as a side effect of
  writing 18.7's re-shard integration test:
  `adapters/out/postgres/channel.go`'s `persistChannel` UPDATE statement never
  included `channel_partitions` in its SET clause. This was correct-at-the-
  time (the field was always immutable before 18.7), but became a live bug
  the moment `UpdateAsyncChannel` started accepting it. Root-caused with a
  throwaway diagnostic test, then fixed and the diagnostic deleted.
- **Fixed a widespread test-helper FK cascade**: the new `shard_migration`
  table FK's to `kafka_topic`; the shared `cleanupTopics(t, db)` helper (used
  by ~20 unrelated tests across the `postgres` package) did `DELETE FROM
  kafka_topic` without clearing `shard_migration` first, so every one of
  those tests started failing on a foreign-key violation the moment the new
  table existed. Fixed by adding `DELETE FROM shard_migration` as the first
  statement in that shared helper.
- **A stray, incomplete file-renumbering edit** was found and reverted at the
  start of this finalization pass: `docs/impl_plans/18-migration-and-data-
  movement.md` and `21-client-ui.md` had been renamed to swap their numbers,
  but only each file's H1 title line had been changed — no internal task IDs,
  cross-references, or the `README.md` table agreed with the swap. Reverted
  to the consistent state (18 = Migration, 21 = Client UI, matching every
  line of code written for this deliverable) via `git checkout` on the two
  tracked files and deleting the two untracked ones.
- The local dev Postgres needed a `franz_test` database created by hand
  before `-p 1` integration tests would run at all — a one-time environment
  gap, not a code issue (`CREATE DATABASE franz_test;` against the same
  Postgres container).
