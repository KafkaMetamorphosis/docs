# Impl tracker — 14 Governance (Indicator registry + non-placement actions)

Deliverable: `franz/docs/impl_plans/14-governance.md`
Status: ✅ done
Executed by: codex → claude (architect agent, claude-opus-5; orchestration claude-sonnet-5) — codex out of quota (resets 2026-09-28); two agent sessions hit their own session limits, a third + the orchestrator finished
Started: 2026-09-07   Completed: 2026-09-10   Commit: franz `92fee49`
Codex session: — (quota-exhausted, no code)

Branch: `impl/14-governance` (off `main`).

Plan note: deliverables 14 ↔ 15 were **swapped** this session (plan commit
`3766677`). The **Indicator registry** moved from telemetry into governance to
break their mutual dependency — `003.8` already lists Indicator CRUD on
`GovernanceService`, and `CreatePolicy` must reject an unregistered indicator.
Governance ships first, self-contained (registry + policy engine + a bare
in-process evaluation entry point); deliverable 15 (telemetry) feeds samples and
calls the entry point.

## Decisions

- **003.8 OQ1 — per-action cap encoding.** An **optional third positional
  `Action.args` entry**: `"max=<ceiling>"` on `INCREASE_FIELD_BY`,
  `"min=<floor>"` on `DECREASE_FIELD_BY`. It bounds the **resulting field
  value**, not the per-fire delta (a bound on the field is a bound on the fleet
  regardless of firing rate; a per-fire delta bounds nothing over time). At
  apply time it **clamps** rather than fails — a policy that has driven a field
  to its ceiling settles into a no-op, which is the intended steady state.
  **Required** on `INCREASE_FIELD_BY partitions` (irreversible under `003.6`),
  optional elsewhere. Uses the existing `repeated string args` — no proto
  change. `core/domain/governance/cap.go`.
- **STALE when never sampled.** An `Indicator` with no `last_sample_at` derives
  `health = STALE`, so a policy on a brand-new indicator does not act until real
  data arrives.
- **Placement actions rejected at write, not accepted-and-queued.** `003.8`
  whitelists `franz.affinity/*` / `franz.antiaffinity/*` label edits on a
  channel, `franz.taint` on a cluster, and `channel_partitions` changes, but
  says they "queue work that does not execute" until the migration flow
  (`003.13`) lands. The plan Notes say reject; followed the plan —
  `CreatePolicy` / `UpdatePolicy` returns `FAILED_PRECONDITION` rather than
  silently no-op'ing at evaluation time. Revisit when 16/18 land.
- **`ListIndicatorSamples` implemented here** though nominally a deliverable-15
  task (15.2) — it is a `GovernanceService` RPC and leaving a registered handler
  unimplemented is worse; it reads the deliverable-12 `indicator_sample` table.
- **`policy_action` carries no FK to `policy`** — audit rows outlive the policy
  (`003.8` "Auditability"); a `policy_name` column keeps a deleted policy's
  history queryable. Nightly 30-day prune like every other Franz time series.
- **The `Entity` proto↔domain mapping pair moved to `grpcgateway/governance.go`**
  (it owns both directions); `telemetry.go` shares the read half.
- **Evaluator provided to fx but unconsumed** (`fx.Invoke(func(in.GovernanceEvaluator){})`)
  — deliverable 15's ingest path is the only caller; `NoopEvaluator` is exported
  for tests.

## Questions & answers

_(none reached the user — the architect agents hit no blocking questions; the
OQ1 decision was made per the deliverable brief's "your call, document it".)_

## Verification

- `go build ./...` — clean
- `go vet ./...` — clean
- `gofmt -l cmd pkg migrations` — clean
- `go test ./...` with `FRANZ_TEST_DB_DSN` → Postgres integration active —
  **35 packages ok, 0 fail**. New suites: `domain/governance` (`TestValidateAgainstWhitelist`
  — 21 sub-cases across all three entities; `TestRequireCapOnPartitionIncrease`),
  `domain/indicator` (`TestNewIndicator*`, staleness / health), `usecases/governance`
  (`evaluator_test`, `service_test` — unknown-indicator rejection, deny-on-STALE,
  conflict order, dry-run no-mutation, DeleteIndicator-with-policy guard),
  `adapters/out/postgres` (`TestGovernanceEndToEndOnAChannel` / `...OnACluster`,
  `TestDryRunAgainstARealStoreMutatesNothing`, `TestIndicatorRepo*`,
  `TestPolicyRepo*`, `TestPolicyActionRepoAppendListPrune`,
  `TestIndicatorSampleRepoListAndLatestPerResource`), `adapters/in/grpcgateway`
  (`TestGovernance*` — CRUD forwards + renders, mask handling, error → status
  mapping).
- `buf lint` (from `franz/api`) — clean. **No proto change** —
  `governance.proto` was already complete.
- `buf generate api` + `npm --prefix webconsole run gen:api` from a clean tree —
  no diff (confirms no codegen owed).
- webconsole `typecheck` / `build` — clean (`schema.d.ts` unchanged).
- **Done when** — all four: (1) `CreateIndicator` + unknown-indicator
  `CreatePolicy` rejection; (2) out-of-whitelist action rejected at write;
  (3) evaluate with a limit-crossing value → `PolicyAction`, STALE skipped
  (`TestGovernanceEndToEnd*`); (4) equal-weight policies deterministic by name.

## Spec / ADR edits owed (docs repo)

- **`003.8` OQ1** — record the cap encoding resolution (see Decisions).
- **`003.8` §"Cross-entity behavior / Migration flow"** — note that until the
  migration flow lands, placement actions (`franz.affinity/*` etc.,
  `channel_partitions`) are **rejected at `CreatePolicy`**, not accepted-and-queued.
- **`003.8` OQ5** (`topic_configuration` / `cluster_configuration` key set) —
  this deliverable validates `topic_configuration.<key>` against the real Kafka
  topic-config key set (`core/domain/topic/kafkaconfig.go`); no curated
  exclusion list. Worth folding into the spec or leaving OQ5 open explicitly.
- **`DECISIONS.md`** — a governance-contract ADR is arguably owed (like
  ADR-API-011 for the Resource Provider); the reactive-only / write-whitelist /
  no-anti-thrash / cap model is spread across `003.8` today.

## Notes / deviations

- codex never ran (quota, resets 2026-09-28). Two architect-agent sessions built
  it across their own limits; the orchestrator verified + finalised.
- 14 ↔ 15 swap: plan files renamed, `Depends on` + cross-refs updated in
  `README.md`, `16-client.md`, `02-domain-foundations.md`, `12-gregor-samsa.md`
  (plan commit `3766677`, pushed to `main`).
