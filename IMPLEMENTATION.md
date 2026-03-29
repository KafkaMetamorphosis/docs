# Implementation Status

Tracks what has been implemented in Franz against the documented spec. Updated as features are completed.

---

## Implemented

### Database Schema
**Commit:** `81bc779` — 2026-03-29

All four production tables created and correct:
- `topic_configurations` — full schema with JSONB configs/labels
- `clusters` — with `default_topic_configuration_id` FK
- `topic_definitions` — with `status` (Active/Paused/Error/Deleted), `expansion_status` (Expanded/PendingExpansion), `UNIQUE` on `topic_name`
- `topic_claims` — with `topic_configuration_override_id` (nullable), correct status values (Pending/Ready/Paused/Deleted/Error)
- `topic_revisions` — with `PendingReconciliation`/`PendingDelete` initial statuses, `last_topic_configuration`, `retry_of_revision_id`

Spec: [001-architecture-overview.md](./001-architecture-overview.md)

---

### Cluster CRUD
**Commit:** `b0f7fe8` — 2026-03-15

Full CRUD with validation and pagination.

| Method | Path |
|---|---|
| `GET` | `/api/v0/clusters` |
| `POST` | `/api/v0/clusters` |
| `GET` | `/api/v0/clusters/:cluster-name` |
| `PUT` | `/api/v0/clusters/:cluster-name` |
| `DELETE` | `/api/v0/clusters/:cluster-name` |

Spec: [003-franz/003.1-kafka-cluster.md](./003-franz/003.1-kafka-cluster.md)

---

### TopicConfiguration CRUD
**Commit:** `35e8ba2` — 2026-03-22

Full CRUD with validation (partitions increase-only) and pagination.

| Method | Path |
|---|---|
| `GET` | `/api/v0/topic_configurations` |
| `POST` | `/api/v0/topic_configurations` |
| `GET` | `/api/v0/topic_configurations/:topic-configuration-id` |
| `PUT` | `/api/v0/topic_configurations/:topic-configuration-id` |
| `DELETE` | `/api/v0/topic_configurations/:topic-configuration-id` |

Spec: [003-franz/003.2-kafka-topic-definition.md](./003-franz/003.2-kafka-topic-definition.md)

---

### TopicDefinition CRUD + State Machine
**Commit:** `7a28d4e` — 2026-03-29

Full CRUD with soft delete, user-driven state machine (Active↔Paused, Error→Paused), status filter on list.

| Method | Path | Notes |
|---|---|---|
| `GET` | `/api/v0/topic_definitions` | Paginated; optional `?status=` filter |
| `POST` | `/api/v0/topic_definitions` | Creates with status=Active, expansion_status=PendingExpansion |
| `GET` | `/api/v0/topic_definitions/:topic-definition-name` | Excludes Deleted |
| `PUT` | `/api/v0/topic_definitions/:topic-definition-name` | Guards invalid state transitions |
| `DELETE` | `/api/v0/topic_definitions/:topic-definition-name` | Soft delete — row preserved, status=Deleted |

State machine transitions available via API: `Active → Paused`, `Paused → Active`, `Error → Paused`. `Error` and `Deleted` cannot be set via PUT.

Spec: [003-franz/003.2-kafka-topic-definition.md](./003-franz/003.2-kafka-topic-definition.md)

---

## Not Yet Implemented

### Topic Definition Expansion Engine
The scheduling engine that creates TopicClaims and TopicRevisions when a TopicDefinition is created/updated/deleted or a Cluster is created/updated.

- Taint/toleration evaluation (`franz.taint`, `franz.taint/toleration`)
- Affinity selector matching (`franz.affinity/selector`)
- Weight-based cluster ranking (`franz.affinity/weight`)
- Shard-size selection (`franz.affinity/shard-size`)
- Batch insert of TopicClaims + TopicRevisions in one transaction
- Sets `expansion_status` on TopicDefinition (`Expanded` / `PendingExpansion`)
- Manual expansion endpoint: `POST /api/v0/topic-definitions-expansion`

Spec: [003-franz/003.4-topic-cluster-selection.md](./003-franz/003.4-topic-cluster-selection.md)

---

### Gregor Samsa API
The reconciler-facing endpoints. Gregor Samsa polls for pending revisions and reports outcomes.

| Method | Path |
|---|---|
| `GET` | `/api/v0/clusters/:cluster-name/poll-pending-reconciliations` |
| `PUT` | `/api/v0/clusters/:cluster-name/inform-reconciliation-status/:revision-id` |
| `POST` | `/api/v0/clusters/:cluster-name/claims/:claim-id/retry` |
| `POST` | `/api/v0/topics/:topic-name/retry` |

Inform contract: Gregor Samsa reports `outcome: created | updated | deleted | error`. Franz derives all state transitions internally.

Spec: [003-franz/003.3-topic-claim.md](./003-franz/003.3-topic-claim.md)

---

### Claim Management Endpoints
User-facing endpoints for modifying existing claims.

| Method | Path |
|---|---|
| `PUT` | `/api/v0/clusters/:cluster-name/claims/:claim-id/update-config` |
| `PUT` | `/api/v0/clusters/:cluster-name/claims/:claim-id/cluster-migration` |

Spec: [003-franz/003.3-topic-claim.md](./003-franz/003.3-topic-claim.md)

---

### Governance Rules Engine
EDN-based rules engine evaluating indicators against topic and cluster create/update events. Controls actions like rejecting topic creation, increasing partitions, or moving retention to tiered storage.

Spec: [003-franz/003.5-governance.md](./003-franz/003.5-governance.md)

---

## Gregor Samsa (Reconciler Service)

Not started. Separate service from Franz. Spec: [004-gregor-samsa/004-reconciliation.md](./004-gregor-samsa/004-reconciliation.md)
