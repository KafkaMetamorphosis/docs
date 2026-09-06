# Impl tracker — 08 Resource management & agent provisioning schema

Deliverable: `franz/docs/impls_plan/08-resource-management-ui.md`
Status: 🚧 in progress
Executed by: codex (pending)
Started: 2026-09-06   Completed: —   Commit: —
Codex session: —

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

- `go build ./...` — pending
- `go test ./...` — pending
- `buf lint` / `buf breaking` — pending
- `make test` (vitest) / Playwright — pending
- Done-when checks — pending

## Notes / deviations

- Spec amendments (003.9, 004, 003.1, DECISIONS ADR-API-008) committed to `docs`
  main as `ca527f6` before implementation, per the user's sign-off flow.
