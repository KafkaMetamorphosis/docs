# Impl tracker — 11 Cluster & agent configuration model

Deliverable: `franz/docs/impls_plan/11-cluster-and-agent-config.md`
Status: 🚧 in progress
Executed by: claude (claude-sonnet-5) — codex out of quota (usage limit resets 2026-09-28)
Started: 2026-09-07   Completed: —   Commit: —
Codex session: — (`codex exec` probe returned "You've hit your usage limit … try again at Sep 28th, 2026")

## Decisions

- **`cluster_configuration` stays a `map<string,string>`** — not moved to labels.
  Rationale (user, 2026-09-07): Kafka clusters/topics are Kafka-specific → typed
  shape; agents are generic (Kafka or RabbitMQ) → their defaults are labels.
- **`KafkaCluster` gains typed `brokers` (int32) + `disk_size` (string).**
- **`kafka-image` dropped** (agent's choice), **`deployment-type` dropped**
  (one recipe family per agent), **`kafka-version` moves into `cluster_configuration`**.
- **`franz.provisioning/*` cluster labels retired.**
- **Agents advertise `franz.default-kafka-config/*` label defaults** — console-only,
  Franz enforces nothing (`cluster_provider_agent` stays an unvalidated string).
- **`Agent.provisioning_labels` / `ProvisioningLabelSpec` removed** (ADR-API-008
  superseded by ADR-API-010).
- **`ClusterAssignment.provisioning` map dropped**; typed `brokers` / `disk_size`
  added; the recipe reads `kafka-version` from `cluster_configuration`.

## Questions & answers

_(design settled via AskUserQuestion rounds on 2026-09-06/07 — see the deliverable
file and ADR-API-010; no mid-build blockers yet)_

## Verification

- `go build ./...` — pending
- `go test ./...` — pending
- `buf lint` / `buf breaking` — pending
- webconsole `typecheck` / `lint` / `test` — pending
- Done-when checks — pending

## Notes / deviations

- codex out of quota on the probe → claude implements the whole deliverable.
- Spec edits (ADR-API-010, 003.1/003.3/003.8/003.9, 004) land in the `docs` repo
  main first, per the deliverable-08 flow.
