# Impl tracker — 12 Gregor Samsa (Resource Provider agent)

Deliverable: `franz/docs/impls_plan/12-gregor-samsa.md`
Status: ✅ done (12.18 real-Docker e2e written but not executed — see Verification)
Executed by: claude (claude-sonnet-5) — codex unavailable (hit session limit early); implemented directly
Started: 2026-09-07   Completed: 2026-09-07   Commit: franz `5edecf4` (+ `6a0a00a` LabelEditor fix on impl/11, `cb3ce88` seeded `local-1` cluster)
Codex session: — (never started; permission classifier blocked `codex exec`, then the fallback agent hit its session limit ~task 12.18; orchestrator finished + verified)

Branch: `impl/12-gregor-samsa` (stacked on `impl/11-cluster-and-agent-config`, per user).

## Decisions

- **`StreamIndicatorSamples` added, `PublishIndicatorSamples` left unary.** The
  ADR allowed either; a new RPC is additive (no `buf breaking` hit) and one-shot
  publishers keep the unary form. Gregor Samsa uses the stream.
- **Minimal `indicator_sample` table added here**, not deferred to deliverable
  14. 30-day nightly prune, same mechanism as `cluster_provider_event`. Any
  indicator name accepted until 14 adds the registry + FK.
- **`ERROR` on an already-`DELETED` `kafka_topic` row records the message but
  keeps `state = DELETED`.** 003.6 makes `DELETED` terminal, and Franz sets it
  optimistically on channel delete; a failed deletion (safety checks refused)
  therefore surfaces via `last_reconcile_message`, not a state change back to
  `ERROR`. The operator sees "deleted" + a message explaining the real topic is
  still there. Franz re-emits the `REMOVED` assignment on the next trigger /
  reconnect (per ADR §1.4).
- **Soft-deleted clusters are never in scope** — a deleted cluster hosts no live
  partitions (003.3 delete guard).
- **`RecordReconciliation` sets `kafka_topic.state` directly** rather than going
  through `SetState`, collapsing the 003.6 two-hop `ERROR → PENDING → READY`
  into the single report-driven transition the ADR §1.5 table describes.
- **Dynamic scope is push-only from three triggers** — `channels.Service`
  create/pause/resume/delete (`notifier.ShardsChanged`), `clusters.Service`
  label update (`ClusterLabelsChanged`), `agents.Service` label update
  (`AgentSelectorChanged`). No periodic reconcile loop (ADR §1.3). Placement
  (deliverable 13, task 13.8) wires shard-row creation into the same notifier.
- **`streamhub` generalised to a typed `fanout[T]`** and a second payload type
  (`resource.PartitionAssignment`) rather than a hand-rolled second hub.

## Questions & answers

_(none reached the user — the implementing agent did not surface blocking
questions before hitting its session limit. Orchestrator answered the open ADR
questions by taking the ADR's leaning positions; see "Positions taken" in the
deliverable file.)_

## Spec / ADR edits owed (docs repo — separate commit)

Each is spec catching up to what an approved plan item (12) implements, flagged
for review in the PR:

- `003-franz/003.1-conventions.md` — reserved-label table gains
  `franz.placement-selector/*` (on Agent) and `franz.placement/*` (on Kafka
  Cluster), with the "empty selector matches nothing" note and "not the 003.1
  selector grammar — a plain conjunction of exact pairs" caveat.
- `003-franz/003.6-kafka-topic.md` — `reconciled_generation` /
  `last_reconcile_message` key-field rows; the generation-gating paragraph
  (OQ4 resolved by 005 ADR §1.5); note the report-driven `→ READY` transition.
- `003-franz/003.9-agents.md` — `RESOURCE_PROVIDER` interaction contract now
  exists → link `005-gregor-samsa`.
- `DECISIONS.md` — **ADR-API-011: Resource Provider agent contract** (push-driven
  `WatchPartitionAssignments`, server-side label-conjunction scoping,
  generation-gated per-partition reports, telemetry over `StreamIndicatorSamples`).

## Verification

- `go build ./...` — clean
- `go vet ./...` — clean
- `gofmt -l cmd pkg migrations` — clean
- `go test ./...` (with `FRANZ_TEST_DB_DSN` → Postgres integration tests active)
  — **30 packages ok, 0 fail**. New suites: `domain/scope` (selector match +
  Resolve tables), `domain/topic` reconcile (generation gating, state mapping,
  ERROR-on-DELETED), `usecases/resourceprovider` (initial set, PERMISSION_DENIED
  ownership, generation gate) + `notifier_test`, `grpcgateway`
  `resourceprovider_integration_test` (bufconn `TestResourceProviderE2E`: token
  auth, full-set-then-delta, PENDING→READY / →ERROR, stale-generation no-op,
  scope loss → REMOVED), `gregorsamsa/reconcile` (20 scenarios: create / noop /
  resync-no-write / alter+partitions / partition-decrease refusal / RF-change
  refusal / kafka failure / error retry / unreachable cluster / delete-empty /
  idempotent-delete / refuse-unconsumed / refuse-committed-offsets / unrelated
  groups OK / paused+scope-loss no-op / resume / independent clusters / config
  drift).
- `buf lint api` — clean. `buf breaking` — CI runs it `continue-on-error` and it
  only reports the pre-existing deliverable-11 `provisioning_labels` removals;
  deliverable 12's proto work is purely additive.
- `buf generate api` + `npm run gen:api` — regenerated; `pkg/gen/go`,
  `api/openapi`, `webconsole/src/api/schema.d.ts` committed and current.
- webconsole `typecheck` / `lint` / `build` — clean (agent did not touch it).
- **Fresh-binary boot smoke** — built `cmd/franz` and ran it on alt ports: the
  `fx` graph resolves (`resourceprovider.NewNotifier` / `NewService`,
  `telemetry.NewService`, `IndicatorSampleRepo`, `RegisterResourceProviderService`
  / `RegisterTelemetryService`, the nightly prune invoke), gRPC + HTTP listen,
  `/healthz` returns ok.
- **NOT run this session:** `make gregorsamsa-e2e` (`FRANZ_GS_E2E=1`, real Docker
  Kafka). The test is written and compiles (`go test ./...` builds it; it
  self-skips without the env var); running it needs an exclusive local stack and
  a Kafka container. Covered instead by the bufconn e2e (Franz side) + the
  fake-admin reconcile suite (agent side) + the boot smoke.

## Notes / deviations

- `codex exec` was blocked by Claude Code's auto-mode permission classifier
  (autonomous file-write + network). User chose "implement directly" (option 3).
- The first implementing subagent terminated on its session limit around task
  12.18 with the working tree in a complete state ("Now let me actually run the
  real-Docker e2e"); the orchestrator verified, finished the recording, wrote
  the docs edits, and committed.
- **ADR OQ1 (overlapping scopes) not implemented** — no task covered it. Two
  agents whose selectors both match a cluster will both receive its partitions.
  Follow-up: decide refuse-second-stream vs. warn, then enforce.
- Real-Docker e2e (`TestGregorSamsaEndToEnd`) should be run before deliverable 13
  builds on this.

## Post-merge follow-ups (same branch)

- `6a0a00a` (on `impl/11`, merged in as `e8d14c4`) — **LabelEditor bug fix**:
  a label typed into the console's key/value inputs but not "Add label"-ed was
  silently dropped on Save/Register. Now flushed on focusout. Surfaced while
  the user was adding `franz.placement/env=local` to a cluster. Affects the
  Kafka Cluster + Agent forms; PR #20 (async channel UI) needs the same via a
  rebase. Tests in `LabelEditor.test.tsx` + `ClusterEdit.test.tsx`.
- `cb3ce88` — **seeded `local-1` Kafka Cluster** (user request). `local/seed/`
  now: `01` local-kafka-agent · `02-local-cluster.sql` the `local-1` cluster
  (provider `local-kafka-agent`, `franz.placement/env=local`, config = the
  agent's advertised defaults) · `03-gregor-samsa.sql` (was `02`) the RP agent
  `franz.placement-selector/env=local`. The whole local loop —
  `make dev` + `make agent` + `make gregorsamsa` — now needs no console step.
  All three seeds idempotent (verified re-run); `local-1` revives to ACTIVE if
  a prior run left it DELETED. README local-loop section rewritten.
