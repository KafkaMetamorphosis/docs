# Impl tracker — 20 Governance UI

Deliverable: `franz/docs/impl_plans/20-governance-ui.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — no codex involvement this deliverable
Started: 2026-09-14   Completed: 2026-09-14   Commit: franz `5f04893`

Branch: `impl/20-governance-ui` (off `impl/18-migration-and-data-movement`,
franz PR #31, per the established stacked-PR convention — 20 doesn't depend on
18 functionally, but the chain stays linear). This deliverable is franz PR #32.

## Context

The plan file (`20-governance-ui.md`) was already fully drafted — routes,
editable-field rules, panel layout, and a 12-task breakdown — from an earlier
session (2026-09-13, alongside 15/19's scoping). Nothing in this deliverable's
own scope required an `AskUserQuestion` round: the design doc's decisions were
already resolved, and the two corrections found below are factual (a wire
contract the plan predates, and a real value-format bug) rather than product
tradeoffs.

## Decisions

- **`Indicator` has no `current_value`/`current_resource_frn` field on the
  wire.** The plan's 20.3/20.5 described a "current value" line; the actual
  `Indicator` proto message (governance.proto) carries only `name`, `unit`,
  `applies_to`, `source_agents`, `health`, `last_sample_at`. `health` is
  derived server-side from `last_sample_at` and never stored as a raw value.
  `IndicatorDetail` renders health + last-sample-at as the two real fields;
  the top row of its recent-samples table (`ListIndicatorSamples`, no
  resourceFrn filter) is the closest thing to "current value" that exists,
  and is presented as exactly that — a sample, not a summary field.
- **`DryRunPolicyRequest` has no resource FRN or hypothetical-value input.**
  The plan's 20.9 described "an inline form (resource FRN + a hypothetical
  value)". The actual RPC takes a full definition
  (`indicator`/`matcher`/`limit`/`actions`) and evaluates it server-side
  against **the latest real sample per matched resource**, returning
  `{resource_frn, indicator_value, would_trigger}` per match — no action list
  in the response either (`DryRunPolicyResponseMatch` doesn't carry one).
  `PolicyDetail`'s Dry-run panel is therefore a single button that dry-runs
  the policy's own saved definition; there is no separate input form to build.
- **`SET_STATUS`'s value is a plain state name** (`"PAUSED"`), not the
  proto-prefixed enum string (`"CHANNEL_STATE_PAUSED"`) — found live, not in
  review. `governance/whitelist.go`'s `isGovernableStatus` checks against
  `channel.State`/`cluster.State`'s bare constants
  (`"ACTIVE"`/`"PAUSED"`/`"DELETED"`, shared between the two domains), not
  against any proto enum. A hand-typed `"CHANNEL_STATE_PAUSED"` in a live
  `CreatePolicy` smoke test came back `INVALID_ARGUMENT` with exactly this
  message. Fixed by rendering a real `<select>` of the three bare names for a
  `SET_STATUS` action's argument in `ActionEditor`, instead of a free-text
  input — this closes the mistake at the form level, not just in a doc note.
- **`ActionEditor` extracted as a shared component** (not duplicated between
  `PolicyRegister` and `PolicyEdit`) — both pages need identical kind-
  dependent arg rendering, the arithmetic cap, and the per-row violation
  list; a shared component with a `violations` prop (from
  `api/violations.ts`'s `violationsByActionIndex`, keyed off the
  `actions[N]...` field-path convention `governance/whitelist.go`'s
  `validateAction` uses) was the natural seam.
- **Indicator picker in `PolicyRegister` disables once picked** (with a
  "Change" button to re-enable) rather than leaving it a normal live select —
  matches the plan's own 20.8 wording and pre-empts a user changing it
  mid-form and silently reinterpreting the limit value's unit before the
  first save even happens (the backend enforces true immutability after
  create; this is pure form ergonomics on top of that).
- **No pagination**, consistent with every other list page in the console —
  restated in the plan's own Notes, not a new decision.

## Verification

- `npm run typecheck` — clean.
- `npm run lint` — clean (0 warnings; moved `violationsByActionIndex` out of
  `ActionEditor.tsx` into its own `api/violations.ts` to avoid a
  `react-refresh/only-export-components` warning from mixing a component
  export with a plain function export in one file).
- `npm run build` — clean, 114 modules, no proto/schema.d.ts drift (this
  deliverable makes no backend or proto change).
- `npx vitest run` — **13 test files, 35 tests, all green** (6 new files, 18
  new cases): `IndicatorList` (row rendering, empty state),
  `IndicatorRegister` (create body shape incl. source agents, field-violation
  rendering), `IndicatorEdit` (partial-mask PATCH, applies-to shown
  read-only), `PolicyList` (row rendering incl. "every resource" and operator
  symbols, empty state), `PolicyRegister` (full create body shape incl.
  actions with a cap, empty-actions client-side guard, inline
  whitelist-violation rendering scoped to `.field-error` so it's
  distinguishable from the generic top-of-page `ErrorBanner` listing the same
  violation), `PolicyEdit` (partial-mask PATCH, indicator shown read-only,
  removing the policy's only action still saves a valid empty-actions patch).
- **Live smoke test** against a real `franz` binary on isolated ports, backed
  by the local dev Postgres: `POST /v1/governance/indicators`,
  `POST /v1/governance/policies`, `POST /v1/governance/policies:dryRun`,
  `GET /v1/governance/policies/{name}/actions` all round-tripped correctly on
  the second attempt — the first attempt surfaced the `SET_STATUS` bug above,
  fixed, then reverified clean. Test rows deleted from the local Postgres
  afterward; no leftover `franz-test20*` processes (verified via `pgrep`).
- **Done when** — both: (1) full indicator lifecycle (register → list → open
  → edit → delete-blocked-while-referenced) verified via the live smoke test
  plus `IndicatorDetail`'s `referencedByPolicy` guard; (2) full policy
  lifecycle (register → list → dry-run "not applied" → audit trail) verified
  the same way plus `e2e/governance.spec.ts`.

## CI caught a test bug the live smoke test didn't

`e2e/governance.spec.ts` asserted a freshly-registered Indicator's health as
"No samples yet" — wrong. `indicator/registry.go`'s `Health()` is explicit in
its own doc comment: "An indicator that has never been sampled is STALE, not
HEALTHY... treating no data as healthy would let a policy fire off a stale
reading the moment one arrived late." My earlier live curl smoke test had
actually shown `"health":"INDICATOR_HEALTH_STALE"` for a brand-new indicator
in its raw JSON output, but the significance didn't register until the
`console-e2e` CI job on PR #32 failed on exactly this assertion. Fixed in
`2cfa417` (one line + a comment quoting the domain doc). `IndicatorList`'s
own `healthLabel("No samples yet")` fallback for the `UNSPECIFIED` enum value
is now understood to be effectively dead code for this field in practice —
harmless to keep as a defensive default, not removed.

## Notes / deviations

- No codex involvement — implemented directly, following the session's
  established pattern for the increasingly large deliverables (14 onward).
- No backend, proto, or `schema.d.ts` change — the entire deliverable is
  console code against the `GovernanceService` REST surface deliverable 14
  already shipped in full.
- Branch stacks on `impl/18-migration-and-data-movement` per the standing
  stacked-PR convention, even though 20 has no functional dependency on 18 —
  keeping the chain linear avoids a merge-order puzzle later, at the cost of
  20's PR technically carrying 18's diff until 18 merges first.

## Landed on main — 2026-09-16, franz `98f255a`

**The stacked PRs merging did not put 20, 21 or 22 on `main`.** The
merge-order puzzle the note above hoped to avoid is exactly what happened.
PRs #32 (20→18), #33 (21→20) and #34 (22→21) each merged into their stack
*parent*, all within the same two seconds as PR #30 merged
`impl/17-access-policy-and-channel-access` → `main`. Those merges travelled
*down* the chain and never propagated back up to `impl/17` before it landed,
so `main` received 17 and 18 only. All three PRs read MERGED while none of
their console work existed on `main` — `impl/22-migration-ui` sat 8 commits
ahead of it for two days.

This surfaced as "the Client and Indicator screens have disappeared" the
moment a checkout moved to `main`: `webconsole/src/pages/` there had no
`clients/` or `governance/` directory at all, and `App.tsx` carried none of
their 12 routes. Nothing had regressed — the screens were never on `main`.

Resolved by merging `origin/main` into `impl/22-migration-ui`
(merge commit franz `98f255a`, **no conflicts** — the CHANGELOG entries from
both sides sat in different hunks and auto-merged), verifying the combined
state, then fast-forwarding `main` to it. Fast-forward rather than a second
merge commit: `98f255a` already integrates both sides, so `--no-ff` would only
have added an empty commit.

`main` now contains 17, 18, 20, 21, 22 and the two indicator fixes (franz
PRs #36, #37) together for the first time. Deliverables 21 and 22 have no
tracker file of their own; this section is the landing record for all three.

**Convention change:** this landing was done straight to `main`, no PR — per
the user's decision at the time. Deliverables 01–22 all used the stacked-PR
flow (`impl/NN-slug` → previous), which is what produced this trap. Any future
multi-deliverable chain should either merge bottom-up to `main` one PR at a
time, or skip the stack entirely.
