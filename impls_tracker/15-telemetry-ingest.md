# Impl tracker — 15 Telemetry ingest

Deliverable: `franz/docs/impls_plan/15-telemetry-ingest.md`
Status: ✅ done
Executed by: codex → claude (architect agent, claude-opus-5; orchestration claude-sonnet-5) — codex out of quota (resets 2026-09-28)
Started: 2026-09-13   Completed: 2026-09-13   Commit: franz `bb19115`
Codex session: — (quota-exhausted, no code)

Branch: `impl/15-telemetry-ingest` (off `main`, deliverable 14 merged as `19b3d73`).

## Decisions

- **Batch validation is atomic — one bad sample rejects the whole batch.**
  `PublishIndicatorSamplesResponse` carries only an accepted count, so a
  partial-accept has no way to tell the agent which rows landed; failing the
  whole call is the only response shape that is honest about what happened.
  Indicators are resolved once per distinct name in a batch (not once per
  row) so a 1000-sample sweep against a handful of indicators does not turn
  into a thousand repository round trips.
- **Ingest → eval hook is synchronous, in-process** (`003.14` OQ4, resolved
  for the simple option — matches 14's decision to leave the evaluator
  in-process rather than queued). A failed `RecordSample` or a failed
  `Evaluate` is logged and does **not** fail the ingest call — the sample is
  already durable, and the next sample re-triggers both.
- **Out-of-order handling lives in `IndicatorRepository.RecordSample`'s
  `advanced` return**, not in the service: a sample older than the stored
  `last_sample_at` is appended to history but does not become current and does
  not call `Evaluate`. This was already the contract 14 defined for
  `RecordSample`; 15 is the first caller.
- **New categorical unit family (`string` / `enum`).** `005` ADR §2.1 needs
  `kafka.topic.state` (enum) and `kafka.cluster.controller_id` (string) as
  indicators, and the four families 14 shipped (numeric / duration / boolean /
  byte-size) have no honest way to represent a label. Any non-empty string
  parses; two values in the family compare lexicographically, so `EQUAL` /
  `NOT_EQUAL` policies mean what an operator expects and the ordering
  operators stay total instead of undefined. Deliberately **not** a fallback:
  an unrecognised unit string still parses numerically, so a typo'd unit
  surfaces as an unparseable value rather than silently becoming a string
  comparison. `core/domain/indicator/value.go`.
- **`custom` on an observed consumer group is derived by Franz on write, never
  accepted from the agent.** Two agents observing the same group must not be
  able to disagree about whether it is conventional; deriving it from
  `client_frn` (or `owner` when no FRN resolved) plus `kafka_topic` against the
  `<client>.<topic>` shape keeps that a Franz-side fact. A sighting Franz
  cannot attribute to any client is treated as custom — there is no
  convention to hold an unattributed sighting to.
- **`indicator_sample.indicator` gets a composite FK to `indicator (realm_id,
  name)`, `ON DELETE CASCADE`**, added via an idempotent `DO` block (the table
  predates the registry in file order) that first deletes any orphan rows a
  pre-registry database accumulated. Cascade rather than restrict: a sample's
  value is only interpretable through its indicator's `unit`, so history
  without the registration is not recoverable data — and `RESTRICT` would make
  `DeleteIndicator` fail for every indicator that has ever been sampled (all
  of them), with a constraint violation instead of `003.8`'s explained
  `FAILED_PRECONDITION`.
- **`observed_consumer_group`'s `kafka_topic_id` / `async_channel_id` (as
  `003.14` sketches them) are plain text, not foreign keys** — same reasoning
  as `indicator_sample.resource_frn`: an agent reports what it saw on the
  substrate, including groups on topics Franz does not manage, and an
  observation Franz cannot resolve to a row is still evidence worth keeping.
  `client_frn` is likewise unconstrained; the `Client` entity itself lands
  with 16.
- **`ObservedConsumerGroupRepository.ListCurrent` pages by a `(group_name,
  kafka_topic)` keyset, not `(observed_at, id)`.** The current view is a *set*
  (`DISTINCT ON` per group/topic) that re-sorts as new sightings arrive, unlike
  every other Franz time series; only a keyset on the identity columns avoids
  skipping or repeating rows across pages under concurrent ingest.
- **`ListObservedConsumerGroups` / `ListConsumerGroupObservations` stay
  unimplemented as RPCs.** They are declared on `ClientService`
  (`client.proto`), which nothing registers yet (deliverable 16). This
  deliverable ships the table, `ReportConsumerGroups`, and the full
  repository (`ListCurrent`/`ListObservations`/`PruneOlderThan`) behind them,
  so 16 only has to write the two thin handlers.

## Questions & answers

_(none reached the user — no blocking questions; the OQ4 sync-vs-queue call
was made per the deliverable's own "start synchronous" note, and the other
decisions above followed directly from `003.14` / `005` §2.1 / the precedent
14 set.)_

## Verification

- `go build ./...` — clean
- `go vet ./...` — clean
- `gofmt -l cmd pkg migrations` — clean
- `go test ./...` with `FRANZ_TEST_DB_DSN` → Postgres integration active —
  **37 packages ok, 0 fail**. New/extended suites: `domain/consumergroup`
  (`TestIsCustom` — 9 sub-cases, `TestNewObservation*`), `domain/indicator`
  (`TestCategoricalValues`, `TestUnitFamily`, `TestCompareRejectsMixedFamilies`
  extended for the new family), `usecases/telemetry` (`service_test.go` —
  `TestIngestRejectsUnregisteredIndicator`,
  `TestIngestRejectsWholeBatchOnOneBadSample`,
  `TestIngestRejectsEntityMismatch`, `TestIngestRejectsUnparseableValue`,
  `TestIngestAcceptsEnumValues`, `TestIngestFiresEvalOncePerAdvancingSample`,
  `TestIngestStoresOutOfOrderSampleWithoutEvaluating`,
  `TestIngestSurvivesEvaluationFailure`, `TestIngestSurvivesRecordSampleFailure`,
  `TestIngestPropagatesAppendFailure`, `TestIngestAttributesToAuthenticatedAgent`,
  `TestIngestBatchBounds`, `TestIngestConsumerGroups*`), `adapters/out/postgres`
  (`telemetry_integration_test.go` — `TestIndicatorSampleRequiresRegisteredIndicator`,
  `TestDeleteIndicatorCascadesToItsSamples`,
  `TestObservedConsumerGroupCurrentAndHistory`,
  `TestObservedConsumerGroupPaginates`, `TestObservedConsumerGroupPrune`),
  `adapters/in/grpcgateway` (`telemetry_integration_test.go` —
  `TestPublishIndicatorSamplesRequiresRegistration`,
  `TestPublishIndicatorSamplesValidation`,
  `TestStreamIndicatorSamplesSharesTheIngestPath`,
  `TestIngestMaintainsCurrentValueAndHealth`,
  `TestPublishAcceptsCategoricalIndicator`, `TestReportConsumerGroupsE2E`,
  `TestTelemetryServiceAcceptsEveryAgentType`).
- `buf lint` (from `franz/api`) — clean. **No proto change** —
  `telemetry.proto` / `governance.proto` were already complete for this
  deliverable's scope.
- `buf generate api` + `npm --prefix webconsole run gen:api` — no diff.
- webconsole `typecheck` / `build` — clean (`schema.d.ts` unchanged; this
  deliverable has no console surface).
- **Done when** — all four: (1) unregistered-indicator sample rejected,
  registering it unblocks (`TestIngestRejectsUnregisteredIndicator`); (2)
  `STALE` health after `staleness_threshold` with no sample — derivation is
  14's, exercised again here against a live pipeline
  (`TestIngestMaintainsCurrentValueAndHealth`); (3) a current-value-changing
  sample calls the evaluator, an out-of-order one does not
  (`TestIngestFiresEvalOncePerAdvancingSample` /
  `TestIngestStoresOutOfOrderSampleWithoutEvaluating`); (4) the prune job
  keeps only 30 days (`TestObservedConsumerGroupPrune`, plus 12's existing
  `indicator_sample` prune test).

## Notes / deviations

- codex never ran (quota, resets 2026-09-28). One architect-agent session was
  interrupted mid-task by the user's machine sleeping (not a session-limit or
  quota failure) right before its final "update the plan doc" step; the
  implementation itself was already complete and untouched by the
  interruption. The orchestrator verified (build/vet/fmt/full test suite) and
  finished the documentation/commit steps.
- `cmd/franz/main.go`'s `fx.Invoke(func(in.GovernanceEvaluator){})` force-build
  placeholder — added in 14 because nothing consumed the evaluator yet — is
  removed now that `telemetry.NewService` takes it as a real dependency; fx's
  lazy graph no longer needs forcing.
