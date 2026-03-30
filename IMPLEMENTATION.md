# Implementation Status

Tracks what has been implemented in Franz against the documented spec. Updated as features are completed.

---

## Overview

| Feature | Pillar | Docs | Code | Date | Commit |
|---|---|---|---|---|---|
| Database schema | Central Registry | ✅ | ✅ | 2026-03-29 | `81bc779` |
| Cluster CRUD | Central Registry | ✅ | ✅ | 2026-03-15 | `b0f7fe8` |
| TopicConfiguration CRUD | Central Registry | ✅ | ✅ | 2026-03-22 | `35e8ba2` |
| TopicDefinition CRUD + state machine | Central Registry | ✅ | ✅ | 2026-03-29 | `7a28d4e` |
| Labels as metadata on all entities | Central Registry | ✅ | ✅ | 2026-03-29 | `7a28d4e` |
| Topic Definition Expansion engine | Traffic Management | ✅ | ✅ | 2026-03-29 | `4f94066` |
| Cluster migration flow | Traffic Management | ✅ | ❌ | — | — |
| Gregor Samsa API (poll / inform / retry) | Reconciliation | ✅ | ❌ | — | — |
| Claim management (update-config, migration) | Reconciliation | ✅ | ❌ | — | — |
| Governance rules engine | Governance | ⚠️ EDN sketch only | ❌ | — | — |
| Governance integration flow | Governance | ❌ | ❌ | — | — |
| Resilience / noisy neighbor protection | Resilience | ❌ | ❌ | — | — |
| Fleet observability / reporting API | Operation Burden | ❌ | ❌ | — | — |
| Label-driven automation | Operation Burden | ❌ | ❌ | — | — |
| Cost efficiency / right-sizing rules | Cost Efficiency | ⚠️ examples only | ❌ | — | — |
| Tiered storage integration | Cost Efficiency | ❌ | ❌ | — | — |
| ACL management | Central Registry | ❌ | ❌ | — | — |
| Gregor Samsa service | Reconciliation | ✅ | ❌ | — | — |
| Operations / deployment guide | Operation Burden | ✅ | — | — | — |

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

### Topic Definition Expansion Engine
**Commit:** `4f94066` -- 2026-03-29

The scheduling engine that creates TopicClaims and TopicRevisions based on taint/toleration, affinity selectors, weight ranking, and shard-size.

| Method | Path | Notes |
|---|---|---|
| `POST` | `/api/v0/topic_definitions_expansion` | Manual trigger, expands all PendingExpansion definitions |

**Trigger points:**
- Topic definition create: expands inline (synchronous)
- Topic definition update (labels or config change): re-expands inline
- Topic definition delete: creates PendingDelete revisions for all active claims
- Cluster create: marks all active definitions as PendingExpansion
- Cluster update (labels change): marks all active definitions as PendingExpansion

**Pure logic (expansion.clj):**
- `parse-taint` / `parse-tolerations` -- label parsing
- `taint-allows-placement?` -- drain always blocks; no-creation requires matching toleration
- `parse-affinity-selectors` / `cluster-matches-selectors?` -- comma-separated `key=value` matching
- `cluster-weight` / `parse-shard-size` -- weight-based ranking, shard-size only with selectors
- `select-eligible-clusters` -- full pipeline: drain separation, taint filter, selector filter, weight sort, shard-size limit
- `materialize-topic-configuration` -- three-layer merge (cluster default, definition config, claim override)
- `compute-expansion-plan` -- stale-revision guard, claim upsert/revision create/drain logic
- `compute-deletion-plan` -- PendingDelete revisions for soft-deleted definitions

**Orchestration (ops/expansion.clj):**
- `expand-topic-definition!` -- single transaction: upsert claims, create revisions, drain, update expansion status
- `expand-deleted-definition!` -- PendingDelete revisions + claim status to Deleted
- `expand-all-pending!` -- batch expansion with per-definition error isolation

**Test coverage:**
- 12 unit tests (72 assertions) for all pure logic functions
- 9 integration tests covering: basic expansion, taint/toleration, selector filtering, shard-size, no-selector, deletion, manual trigger, cluster-create marking

Spec: [003-franz/003.4-topic-cluster-selection.md](./003-franz/003.4-topic-cluster-selection.md) | [003-franz/003.6-expansion-engine.md](./003-franz/003.6-expansion-engine.md)

---

## Not Yet Implemented

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

Spec: [003-franz/003.3-topic-claim.md](./003-franz/003.3-topic-claim.md) | [004-gregor-samsa/004-reconciliation.md](./004-gregor-samsa/004-reconciliation.md)

---

### Claim Management Endpoints
User-facing endpoints for modifying existing claims.

| Method | Path |
|---|---|
| `PUT` | `/api/v0/clusters/:cluster-name/claims/:claim-id/update-config` |
| `PUT` | `/api/v0/clusters/:cluster-name/claims/:claim-id/cluster-migration` |

Spec: [003-franz/003.3-topic-claim.md](./003-franz/003.3-topic-claim.md) | [003-franz/003.7-claim-management.md](./003-franz/003.7-claim-management.md)

---

### Governance Rules Engine
EDN-based rules engine evaluating indicators against topic and cluster create/update events. Controls actions like rejecting topic creation, increasing partitions, or moving retention to tiered storage.

Spec: [003-franz/003.5-governance.md](./003-franz/003.5-governance.md)

---

## Gregor Samsa (Reconciler Service)

Not started. Separate service from Franz.

Spec: [004-gregor-samsa/004-reconciliation.md](./004-gregor-samsa/004-reconciliation.md) | [005-operations/005.0-overview.md](./005-operations/005.0-overview.md)
