# Impl tracker — 08 Resource management & agent provisioning schema

Deliverable: `franz/docs/impls_plan/08-resource-management-ui.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex out of quota (usage limit resets 2026-09-28)
Started: 2026-09-06   Completed: 2026-09-06
Commits (franz, impl/08-resource-management-ui): 9a1e679 (stage A — proto+backend),
4c78444 (stage B — console), 40b7640 (stage C/D — recipe + self-declare)
Docs (docs main): ca527f6 (spec amendments), fa2a5dd (tracker kickoff)
Codex session: — (codex `exec` returned "You've hit your usage limit" on the first call)

## Decisions

- **Scope expanded** — the user chose to grow deliverable 08 from "console edit
  forms" to the full agent-provisioning-label-schema feature (proto + backend +
  console + local agent), rather than split it. Spec amendments landed first
  (`docs` commit `ca527f6`).
- **Schema is advisory** — `Agent.provisioning_labels` is stored/served by Franz
  and rendered by the console, but Franz never validates a `KafkaCluster`'s
  labels against the referenced agent's schema. `cluster_provider_agent` stays
  an unvalidated string. Rationale: no coupling of Franz to agent recipe logic;
  the agent remains the authority. (ADR-API-008)
- **Edit lives on separate `/…/edit` pages** with an "Edit" button on detail —
  not inline panels. Matches the Register-page pattern.
- **`connection_strings` edit** = bootstrap URLs of the single entry; type stays
  `PLAINTEXT`. Multi-entry / other auth types deferred.
- **`franz.provisioning/kafka-image`** — full apache/kafka-compatible image ref,
  precedence over `kafka-version`, feeds the recipe hash. Not arbitrary Kafka
  distributions (same KRaft env contract).
- **17 assumptions from trackers 03/04/05 — all ratified as-is** (agent `type`
  mutable, soft-deleted Get returns the row, pause/resume idempotent, list
  `total_size = 0`, delete-agent-with-dangling-cluster-ref allowed, etc.). Those
  tracker sections can be marked resolved.

## Questions & answers

### Q1 — provisioning label presentation in the edit form
- **Asked by:** claude (during /impl kickoff)
- **Answered by:** user
- **Question:** how should `franz.provisioning/*` labels appear in the cluster
  edit form — dedicated fields, or generic label editor?
- **Answer:** neither as-is — the agent should declare its accepted labels,
  allowed values and defaults at registration; the console pre-fills resource
  forms from that schema. Also add a full-image label to the local agent.
- **Source:** user decision; formalised in ADR-API-008 + 003.9 amendment.

### Q2 — scope: expand 08 vs. split
- **Asked by:** claude
- **Answered by:** user
- **Answer:** expand 08 to include the whole schema feature.

## Verification

- `go build ./...`, `go vet ./...`, `gofmt -l` — ✅ clean
- `go test ./...` (with `FRANZ_TEST_DB_DSN`) — ✅ pass. New/extended: `agent`
  domain (`ValidateProvisioningLabels` table), `grpcgateway` (create forwards
  `provisioning_labels`; `UpdateAgent` `provisioning_labels` mask path in
  isolation), `postgres` agent integration (jsonb round-trip + wholesale replace
  + clear), `localkafka/recipe` (`kafka-image` overrides `kafka-version`, hash
  change), `localkafka` (`EnsureRegistered` sends the schema on create and
  refreshes it via `UpdateAgent` on reuse).
- `buf lint api` — ✅. `buf breaking` — could **not** run locally: `main` has no
  `buf.yaml` yet (the `api/` layout landed in 05/06, still unmerged), same
  limitation as the rest of the stacked chain. The change is additive
  (new message, new field numbers 8/4/5), non-breaking by construction.
- webconsole `typecheck` / `lint` / `test` (vitest, 15) / `build` — ✅.
  Playwright (`npm run e2e`, against a live Franz) — ✅ 2/2, including the new
  edit round-trip.
- Manual REST probe confirmed the gateway parses `update_mask` as **camelCase**
  comma paths and rejects snake_case (`FieldMask.paths contains invalid path`) —
  the console builds the mask from camelCase body keys accordingly.

## Notes / deviations

- **codex out of quota** on the first `codex exec` call ("You've hit your usage
  limit … try again Sep 28"). Per the skill's handoff rule, claude implemented
  the whole deliverable in 4 stages (proto+backend → console → recipe →
  self-declare), each its own commit.
- Spec amendments (003.9, 004, 003.1, DECISIONS ADR-API-008) committed to `docs`
  main as `ca527f6` before implementation, per the user's sign-off flow.
- The 17 assumptions from trackers 03/04/05 were **all ratified as-is** by the
  user during this run — those "Assumptions (need a yes/no later)" sections can
  be treated as resolved.
- New console files: `provisioning.ts` (+ test), `keyvalues.ts`,
  `components/ProvisioningFields.tsx` (+ test),
  `components/ProvisioningLabelEditor.tsx`, `pages/agents/AgentEdit.tsx` (+ test),
  `pages/clusters/ClusterEdit.tsx` (+ test).
- `agent.New` signature changed (added `provisioningLabels` param) — all callers
  and tests updated.
- **Follow-up (same day, user request):** the `FRANZ_REGISTER=1` self-register
  path from deliverable 07 (`pkg/localkafka/register.go`) was removed as
  "dev code in the agent binary". Replaced by a **DB seed**: `franz/local/`
  (`docker-compose.yml` + `seed/01-local-agent.sql`) installs the
  `local-kafka-agent` row (schema + a fixed public dev token) via `make deps`
  before Franz starts. Agent takes `FRANZ_TOKEN` only. `Makefile` `$(COMPOSE)`
  now points at `local/docker-compose.yml`; root `docker-compose.yml` removed.
  Task 08.12 restated accordingly. Verified: `make agent-e2e` green, `make agent`
  authenticates with the seeded token, full go + webconsole suites + Playwright
  green.
