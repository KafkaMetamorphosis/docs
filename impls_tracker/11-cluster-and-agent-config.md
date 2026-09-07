# Impl tracker — 11 Cluster & agent configuration model

Deliverable: `franz/docs/impls_plan/11-cluster-and-agent-config.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex out of quota (usage limit resets 2026-09-28)
Started: 2026-09-07   Completed: 2026-09-07
Commits (franz, impl/11-cluster-and-agent-config): bb6763b
Docs (docs main): 19166bc (spec edits) + tracker
Codex session: — (`codex exec` probe → "You've hit your usage limit … try again at Sep 28th, 2026")

## Decisions

- **`cluster_configuration` stays a `map<string,string>`** — not moved to labels.
  Kafka clusters/topics are Kafka-specific → typed shape; agents are generic
  (Kafka or RabbitMQ) → their defaults are labels. (ADR-API-010, user 2026-09-07)
- **`KafkaCluster` gains typed `brokers` (int32) + `disk_size` (string).**
  `brokers` is a nullable column; `0` on the wire = "unset" (mapped to SQL NULL by
  `brokersArg`).
- **`kafka-image` dropped** (agent's choice), **`deployment-type` dropped** (one
  recipe family per agent), **`kafka-version` lives in `cluster_configuration`**.
- **`franz.provisioning/*` cluster labels retired**; **`Agent.provisioning_labels`
  / `ProvisioningLabelSpec` removed** (ADR-API-008 superseded).
- **Agents advertise `franz.default-kafka-config/*` label defaults** — console-only,
  Franz enforces nothing (`cluster_provider_agent` stays an unvalidated string).
- **`ClusterAssignment.provisioning` map dropped** (`reserved 6`); typed
  `brokers = 7` / `disk_size = 8` added. Recipe reads `kafka-version` from
  `cluster_configuration` and translates Franz-friendly keys to broker config.
- **`cluster.New` signature kept stable** — `SetShape(brokers, diskSize)` on the
  mutable path instead of new constructor params (avoids touching ~10 call sites).

## Questions & answers

_(design settled via AskUserQuestion rounds 2026-09-06/07 — see the deliverable
file + ADR-API-010; no mid-build blockers)_

## Verification

- `go build ./...`, `go vet ./...`, `gofmt -l` — ✅ clean
- `go test ./... -count=1` (with `FRANZ_TEST_DB_DSN`) — ✅ 26 packages pass.
  Updated: `agent` domain (New signature), `cluster` domain (`SetShape`),
  `provider` domain (Assignment shape), `provider` / `clusters` usecases,
  `postgres` agent + cluster integration (col round-trips, `brokers` NULL),
  `grpcgateway` agent + kafkacluster + clusterprovider-e2e, `localkafkaagent`
  recipe (key translation) + reconcile.
- `buf lint api` — ✅. `buf breaking` — could **not** run locally (git subdir
  clone fails, same limitation as the stacked chain). Removals are pre-production,
  no gate on `main`; fields `reserved`.
- `make gen` (buf generate + `npm run gen:api`) — ✅ regenerated
  `pkg/gen/go/franz/v1/*`, `api/openapi/franz.swagger.json`,
  `webconsole/src/api/schema.d.ts`.
- webconsole `typecheck` / `lint` / `test` (vitest, 8) / `build` — ✅.
- `make deps-reset` + migration + seed on the new schema — ✅. Live REST smokes:
  `POST /v1/kafka/clusters` with `brokers` / `disk_size` / `cluster_configuration`
  → all returned by `GET`; `PATCH …?updateMask=brokers` touches only `brokers`;
  seeded agent `GET` shows the five `franz.default-kafka-config/*` labels;
  `POST /v1/kafka/agents` response has no `provisioningLabels` key.

## Notes / deviations

- **codex out of quota** on the probe → claude implemented the whole deliverable.
- Spec edits (ADR-API-010 + 003.1/003.3/003.8/003.9 + 004 + ADR-006 note) landed
  in `docs` main first (commit `19166bc`).
- `cluster.New` signature unchanged; `SetShape` added instead (see Decisions).
- Recipe allow-list is now `configKeyToBroker` (key → broker key, or `""`).
- Console: `provisioning.ts` → `clusterConfig.ts`; `ProvisioningFields` /
  `ProvisioningLabelEditor` / their tests / `provisioning.test.ts` deleted; the
  Cluster-configuration section is rendered inline (no new component).
- Playwright `npm run e2e` not run (needs a live stack); covered by REST smokes.
- Dead CSS rules for the old provisioning editor left in `styles/console.css`
  (harmless; trim later).
