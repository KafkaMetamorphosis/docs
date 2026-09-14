# Impl tracker — 17 Access-policy engine & channel-access views

Deliverable: `franz/docs/impl_plans/17-access-policy-and-channel-access.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex out of quota (resets 2026-09-28), never ran
Started: 2026-09-13   Completed: 2026-09-13   Commit: franz `26d2867`
Codex session: — (quota-exhausted, no code)

Branch: `impl/17-access-policy-and-channel-access` (off `main`, deliverable 16
merged as `2f4ffa3`).

## Questions & answers

The user explicitly asked that every open decision in 17 and 18 be resolved by
asking, not assuming, with 4 options per question. Two `AskUserQuestion` rounds
covered 17 (an earlier round for 18's prerequisite decisions was interrupted —
18 has not started).

### Q1 — `matched_by` on a multi-statement match (`003.5` OQ4)
- **Asked by:** claude (identified while scoping 17)
- **Answered by:** user
- **Question:** When several statements match a `(client, action)` and at
  least one is ALLOW (no DENY), what should `ChannelClientAccess.matched_by`
  report — the single deciding statement, every matching statement, or the
  deciding statement with all ALLOWs listed on a grant?
- **Answer:** "The deciding statement, but list all ALLOWs on an allow" — on
  DENY, report just the deciding DENY (though moot: a denied permission is
  never in `Effective`, so nothing is ever rendered for it); on ALLOW, list
  every matching ALLOW statement.
- **Source:** `core/domain/accesspolicy/evaluate.go`'s `decide`/`describeAllow`.

### Q2 — Selector-match cost bound (`003.5` OQ3)
- **Asked by:** claude
- **Answered by:** user
- **Question:** `ListChannelClients` evaluates every statement against every
  Client in the realm — does this deliverable need a bound on that cost, or
  is a plain in-memory pass over one page fine?
- **Answer:** "No special bound — evaluate in Go per page", matching
  `ClusterRepo.List`'s existing 003.1-selector pattern.
- **Source:** both views fetch one underlying page and filter in Go; a
  sparse-match page can come back with fewer rows than requested.

### Q3 — Statement cap (`003.5` OQ2)
- **Asked by:** claude
- **Answered by:** user
- **Question:** The statement cap was left unresolved in deliverable 10 ("no
  cap yet") — should 17 resolve it?
- **Answer:** "Keep deferring — still no cap." Nothing in 17's task list needs
  one.

### Q4 — SDK enforcement scope (`003.5` OQ1)
- **Asked by:** claude
- **Answered by:** user
- **Question:** SDK enforcement point isn't in 17's task list at all — should
  that stay out of scope?
- **Answer:** "Yes, out of scope for 17" — confirmed, not built here.

### Q5 — `client_frn` glob matching representation
- **Asked by:** claude (identified while designing `Evaluator`, not from a
  named `003.5` OQ — the spec's worked example writes a prefixed pattern,
  which conflicts with how every FRN is otherwise stored)
- **Answered by:** user
- **Question:** Franz stores every FRN prefix-less internally; should a
  wildcard `client_frn` pattern be matched against the prefix-less stored
  form, the API-rendered (prefixed) form, or normalize either input?
- **Answer:** "The prefix-less stored form" — matches `resource_frn`,
  `indicator_sample`, `policy_action`, every other FRN comparison in the
  schema.
- **Source:** `Evaluator.Evaluate`'s doc comment;
  `TestClientFRNGlobMatchesThePrefixLessForm`.

### Q6 — Row inclusion for both views
- **Asked by:** claude
- **Answered by:** user
- **Question:** Should the views include every client/channel in the realm
  (effective possibly empty) or only ones with ≥1 effective permission?
- **Answer:** "Only rows with ≥1 effective permission" — matches 003.10's own
  framing of the reverse view.

## Decisions

- Everything above; no further undocumented judgment calls were made — this
  deliverable was built entirely from resolved questions plus the spec's own
  worked example and invariants.

## Verification

- `go build ./...` — clean
- `go vet ./...` — clean
- `gofmt -l cmd pkg migrations` — clean
- `go test ./...` with `FRANZ_TEST_DB_DSN` → Postgres integration active —
  **40 packages ok, 0 fail**. New suites: `domain/accesspolicy`
  (`evaluate_test.go` — `TestWorkedExample` (003.5's own example verbatim),
  `TestEmptyPolicyDeniesEveryone`, `TestReadAndWriteAreIndependent`,
  `TestLabelSelectorPrincipalMatches`,
  `TestPrincipalWithBothCriteriaMatchesOnEither`,
  `TestClientFRNGlobMatchesThePrefixLessForm`,
  `TestDenyWinsRegardlessOfDocumentOrder`,
  `TestMatchedByReportsAllAllowsOnGrant`,
  `TestMatchedByEmptyOnZeroTrustDenial`,
  `TestClientFRNThatResolvesToNoClientStillEvaluates`, `TestBroadMatrix` — 5
  sub-cases), `adapters/in/grpcgateway`
  (`TestListChannelClientsRendersFRNAndForwardsPage`,
  `TestListChannelClientsErrorMapping`,
  `TestListClientChannelAccessForwardsPageAndMapping`,
  `TestListClientChannelAccessErrorMapping`), `adapters/out/postgres`
  (`accesspolicy_integration_test.go` —
  `TestAccessPolicyForwardAndReverseViewsAgree`,
  `TestAccessPolicyChangeIsReflectedInBothViews`,
  `TestListChannelClientsPaginates`).
- `buf lint` (from `franz/api`) — clean. **No proto change** —
  `async_channel.proto` / `client.proto` were already complete.
- `git status --porcelain | grep -E '\.proto$|gen/go|openapi|schema.d.ts'` —
  empty, confirming no codegen drift.
- **Live end-to-end check** against the local dev Postgres + a real `franz`
  binary boot (`local/seed/06-access-policy-demo.sql`'s `billing-events`
  channel): `GET /v1/async-channels/billing-events/clients` returned billing
  (READ+WRITE) and payments-consumer (READ only); `GET
  /v1/clients/billing/channel-access` and `.../payments-consumer/channel-access`
  agreed exactly with the forward view. First attempt showed stale/missing
  seed data (empty labels, a 404 for payments-consumer) because the
  integration test suite had just run against the *same* local Postgres
  instance and its `cleanup*` helpers wiped the seeded rows — re-seeding
  (`for f in local/seed/*.sql; do psql < $f; done`) before the live check
  produced the correct result shown above. Not a code defect; noted here so a
  future session doesn't mistake the same collision for a regression.
- **Done when** — both: (1) the `003.5` worked example and the broad matrix
  pass as unit tests; (2) `ListChannelClients` / `ListClientChannelAccess`
  return consistent grants for every `(client, channel)` pair in an
  integration fixture (`TestAccessPolicyForwardAndReverseViewsAgree`).

## Notes / deviations

- codex never ran (quota, resets 2026-09-28) — claude implemented it directly.
- `channels.NewService` gained a 4th parameter (`out.ClientRepository`) and
  `clients.NewService` a 3rd (`out.AsyncChannelRepository`). Both are wired
  for free by fx's reflection-based DI in `cmd/franz/main.go` — no call-site
  change there, only the function signatures fx introspects. Every other call
  site (postgres/grpcgateway integration tests) needed an explicit extra
  argument; all updated (nil where the test doesn't exercise the new view).
- Verified the fx wiring actually resolves at runtime, not just compiles: built
  and booted the real `franz` binary against local Postgres
  (`FRANZ_DB__AUTO_MIGRATE=true`), confirmed `/healthz` returns 200, killed
  the process. No leftover process.
- `docs/impl_plans/21-client-ui.md` updated (un-deferred the "Channel access"
  panel, added 17 to Depends-on) — the only downstream doc this deliverable's
  completion changes.
