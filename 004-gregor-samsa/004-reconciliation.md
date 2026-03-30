# Kafka Topic Reconciliation

Gregor Samsa is the execution-plane service that reconciles desired state (defined in Franz) against actual state in a Kafka cluster. Each Gregor Samsa instance manages exactly one Kafka cluster.

**Status: Not yet implemented.** This document is the full specification.

---

## Architecture

```
                    Franz (Control Plane)
                    +-------------------+
                    |  State Store (PG)  |
                    |  Management API    |
                    +--------+----------+
                             |
              +--------------+--------------+
              |              |              |
     +--------v---+  +------v-----+  +-----v------+
     | Gregor     |  | Gregor     |  | Gregor     |
     | Samsa      |  | Samsa      |  | Samsa      |
     | cluster-1  |  | cluster-2  |  | cluster-3  |
     +-----+------+  +-----+------+  +-----+------+
           |              |              |
     +-----v------+  +----v-------+  +--v---------+
     | Kafka      |  | Kafka      |  | Kafka      |
     | cluster-1  |  | cluster-2  |  | cluster-3  |
     +------------+  +------------+  +------------+
```

### Key Properties

- **One instance per cluster**: Each Gregor Samsa process is configured with a single `CLUSTER_NAME` and only manages topics on that cluster.
- **Stateless**: Gregor Samsa does not persist any state locally. All state lives in Franz's PostgreSQL database.
- **Pull-based**: Gregor Samsa polls Franz for work. Franz never pushes to Gregor Samsa.
- **Drift-correcting**: In addition to applying pending revisions, Gregor Samsa continuously compares the actual Kafka state of every active topic against the desired state in Franz and corrects any divergence it finds.

---

## Reconciliation Loop

Gregor Samsa runs a continuous loop with two distinct processing paths per claim:

```
                    +-----------+
                    |   Start   |
                    +-----+-----+
                          |
                    +-----v------+
                    | Poll Franz |
                    | (all active|
                    | claims)    |
                    +-----+------+
                          |
            Empty?        |        Has claims
        +--------+--------+---------+
        |                           |
  +-----v-----+              +------v------+
  |  Sleep    |        +---->| Next claim? |
  | (interval)|        |     +------+------+
  +-----+-----+        |            |
        |              |     Yes    |     No (all done)
        |              |     +------v------+
        +------------->|     | Pending     |
                       |     | revision?   |
                       |     +------+------+
                       |            |
                       |   Yes      |       No
                       |   +--------v--+   +--------v-----------+
                       |   | Revision- |   | Drift detection:   |
                       |   | driven:   |   | read actual Kafka  |
                       |   | create /  |   | config, compare vs |
                       |   | update /  |   | desired-topic-     |
                       |   | delete    |   | configuration      |
                       |   +--------+--+   +------+------+------+
                       |            |             |      |
                       |            |         Drift?    Same
                       |            |      +----v----+  +------+
                       |            |      | Apply   |  | Skip |
                       |            |      | + log   |  | (no  |
                       |            |      | + metric|  |  op) |
                       |            |      +---------+  +------+
                       |            |
                       |    +-------v---------+
                       |    | Collect revision|
                       |    | outcome for     |
                       |    | batch inform    |
                       |    +-------+---------+
                       |            |
                       +------------+
                              |
                       (after all claims)
                       +------v------+
                       | Send batch  |
                       | inform to   |
                       | Franz       |
                       +------+------+
                              |
                              v
                           (loop)
```

### Loop Steps

1. **Poll**: `GET /api/v0/clusters/:cluster-name/poll-pending-reconciliations`
   - Returns ALL active (non-Paused, non-Error, non-Deleted) claims for this cluster.
   - Each claim includes its `desired-topic-configuration` and an optional embedded `pending-revision`.
   - If the response contains no claims, sleep for the configured poll interval and try again.

2. **For each claim, choose a path:**

   **Path A — Revision-driven** (`pending-revision` is non-null):
   - `PendingReconciliation`: create or update the topic on Kafka with the revision's config.
   - `PendingDelete`: run safety checks first (see [Deletion Safety Checks](#deletion-safety-checks)), then delete the topic.
   - Collect the outcome for the batch inform call.

   **Path B — Drift detection** (`pending-revision` is null, claim is `Ready`):
   - Read the actual topic config from Kafka using `AdminClient.describeTopics` and `AdminClient.describeConfigs`.
   - Compare against `claim.desired-topic-configuration`.
   - If configs match: no action, no outcome emitted for this claim.
   - If configs differ: apply the desired config to Kafka. Log the drift event and emit a metric (`gregor_samsa_drift_corrections_total` labelled by cluster and topic name). Do **not** report drift corrections to Franz — they are handled entirely by Gregor Samsa.

3. **Inform**: `PUT /api/v0/clusters/:cluster-name/inform-reconciliation-status`
   - After processing all claims in the poll batch, send a single batch inform call to Franz.
   - The batch contains only revision outcomes (Path A results). Drift corrections (Path B) are never included.
   - Claims with no outcome (no drift, no pending revision) are omitted.

---

## Franz API Contract (Agent Endpoints)

### Poll Pending Reconciliations

```
GET /api/v0/clusters/:cluster-name/poll-pending-reconciliations
```

Returns all active claims for the cluster with their desired state and any pending revision.

**Response `200`:**
```json
{
    "claims": [
        {
            "claim": {
                "id": "550e8400-e29b-41d4-a716-446655440000",
                "status": "Ready",
                "topic-definition": {
                    "topic-id": "660e8400-e29b-41d4-a716-446655440001",
                    "name": "user-events",
                    "labels": {
                        "my-namespace/team": "platform"
                    }
                },
                "kafka-cluster": {
                    "name": "production-us-east-1",
                    "bootstrap-url": "broker-1:9092,broker-2:9092"
                },
                "labels": {
                    "my-namespace/priority": "high"
                },
                "desired-topic-configuration": {
                    "retention-ms": 604800000,
                    "partitions": 6,
                    "replication-factor": 3,
                    "configs": {
                        "cleanup.policy": "delete",
                        "compression.type": "lz4"
                    }
                }
            },
            "pending-revision": null
        },
        {
            "claim": {
                "id": "550e8400-e29b-41d4-a716-446655440001",
                "status": "Pending",
                "topic-definition": {
                    "topic-id": "660e8400-e29b-41d4-a716-446655440002",
                    "name": "payment-events",
                    "labels": {}
                },
                "kafka-cluster": {
                    "name": "production-us-east-1",
                    "bootstrap-url": "broker-1:9092,broker-2:9092"
                },
                "labels": {},
                "desired-topic-configuration": {
                    "retention-ms": 86400000,
                    "partitions": 3,
                    "replication-factor": 3,
                    "configs": {
                        "cleanup.policy": "delete"
                    }
                }
            },
            "pending-revision": {
                "id": "770e8400-e29b-41d4-a716-446655440002",
                "status": "PendingReconciliation",
                "topic-configuration": {
                    "retention-ms": 86400000,
                    "partitions": 3,
                    "replication-factor": 3,
                    "configs": {
                        "cleanup.policy": "delete"
                    }
                }
            }
        }
    ]
}
```

**Important fields for Gregor Samsa:**

| Field | Usage |
|---|---|
| `claim.id` | Used in the inform call to identify which claim the outcome belongs to |
| `claim.status` | Determines processing path: `Ready` with no revision = drift detection; `Pending` with revision = revision-driven work |
| `claim.desired-topic-configuration` | The config to compare against actual Kafka state for drift detection |
| `claim.topic-definition.name` | The Kafka topic name to read or act on |
| `claim.kafka-cluster.bootstrap-url` | Where to connect (must match instance config) |
| `pending-revision.id` | Used in the inform call when reporting a revision outcome |
| `pending-revision.status` | Determines operation: `PendingReconciliation` = create/update; `PendingDelete` = delete (with safety checks) |
| `pending-revision.topic-configuration` | The config to apply when `PendingReconciliation` |

**`pending-revision` is `null`** when the claim is `Ready` with no active revision — drift detection only.

### Inform Reconciliation Status

```
PUT /api/v0/clusters/:cluster-name/inform-reconciliation-status
```

Gregor Samsa reports all revision outcomes from the current poll batch in a single call. **Drift corrections are not included** — they are handled locally by Gregor Samsa (logged + metric emitted).

#### Request Body

```json
{
    "reconciliations": [
        {
            "claim-id": "550e8400-e29b-41d4-a716-446655440001",
            "revision-id": "770e8400-e29b-41d4-a716-446655440002",
            "outcome": "created",
            "last-topic-configuration": {
                "retention-ms": 86400000,
                "partitions": 3,
                "replication-factor": 3,
                "configs": {
                    "cleanup.policy": "delete"
                }
            }
        }
    ]
}
```

#### Outcome Examples

**Topic created:**
```json
{
    "claim-id": "...",
    "revision-id": "...",
    "outcome": "created",
    "last-topic-configuration": { "partitions": 3, "replication-factor": 3, "retention-ms": 86400000, "configs": {} }
}
```

**Topic updated:**
```json
{
    "claim-id": "...",
    "revision-id": "...",
    "outcome": "updated",
    "last-topic-configuration": { "partitions": 6, "replication-factor": 3, "retention-ms": 604800000, "configs": {} }
}
```

**Topic deleted:**
```json
{
    "claim-id": "...",
    "revision-id": "...",
    "outcome": "deleted"
}
```

**Error:**
```json
{
    "claim-id": "...",
    "revision-id": "...",
    "outcome": "error",
    "error": "failed to connect to broker at broker-1:9092: connection refused"
}
```

Error with partial config read:
```json
{
    "claim-id": "...",
    "revision-id": "...",
    "outcome": "error",
    "error": "cannot reduce partition count from 6 to 4",
    "last-topic-configuration": { "partitions": 6, "replication-factor": 3, "retention-ms": 604800000, "configs": {} }
}
```

**Valid outcomes per revision status:**

| Revision Status | Valid `outcome` values |
|---|---|
| `PendingReconciliation` | `created`, `updated`, `error` |
| `PendingDelete` | `deleted`, `error` |

### Retry Endpoints

```
POST /api/v0/clusters/:cluster-name/claims/:claim-id/retry
```

Retries a single errored claim. Creates a new revision copying the intent from the failed one.

**Preconditions:**
- Claim must be in `Error` status.
- Latest revision must be in `Error` status. If not (e.g., already picked up), the request is rejected with `409`.

**Response `201`:**
```json
{
    "claim-id": "550e8400-e29b-41d4-a716-446655440000",
    "cluster-name": "production-us-east-1",
    "claim-status": "Pending",
    "revision": {
        "id": "880e8400-e29b-41d4-a716-446655440003",
        "status": "PendingReconciliation",
        "retry-of-revision-id": "770e8400-e29b-41d4-a716-446655440002"
    }
}
```

```
POST /api/v0/topics/:topic-name/retry
```

Retries all errored claims for a topic across all clusters. Each claim is retried independently; partial success is possible.

**Response `200`:**
```json
{
    "topic-name": "user-events",
    "retried": [
        {
            "claim-id": "550e8400-e29b-41d4-a716-446655440000",
            "cluster-name": "production-us-east-1",
            "claim-status": "Pending",
            "revision": {
                "id": "880e8400-e29b-41d4-a716-446655440003",
                "status": "PendingReconciliation",
                "retry-of-revision-id": "770e8400-e29b-41d4-a716-446655440002"
            }
        }
    ],
    "failed": [
        {
            "claim-id": "990e8400-e29b-41d4-a716-446655440004",
            "cluster-name": "staging",
            "error": "revision-not-in-error",
            "message": "Latest revision is in 'PendingReconciliation' state, cannot retry"
        }
    ]
}
```

---

## State Transitions (Franz-Side)

When Franz receives an inform call, it maps the reported outcome to revision and claim state transitions:

| Gregor Samsa Outcome | Revision Terminal State | Claim State |
|---|---|---|
| `created` | `Created` | `Ready` |
| `updated` | `Updated` | `Ready` |
| `deleted` | `Deleted` | `Deleted` |
| `error` | `Error` | `Error` |

These transitions happen atomically in a single database transaction. Franz increments the revision's `attempts` counter on every inform call. On success, Franz stores the `last-topic-configuration` reported by Gregor Samsa.

### PendingReconciliation vs PendingDelete Handling

| Revision Status | Gregor Samsa Action | Valid Outcomes |
|---|---|---|
| `PendingReconciliation` | Create or update the topic | `created`, `updated`, `error` |
| `PendingDelete` | Safety check, then delete the topic | `deleted`, `error` |

Gregor Samsa determines whether to create or update based on whether the topic already exists on the Kafka cluster. Franz does not distinguish between create and update at the revision level; the `PendingReconciliation` status covers both.

---

## Deletion Safety Checks

Before Gregor Samsa attempts to delete a topic for a `PendingDelete` revision, it runs two safety checks using the Kafka AdminClient. If either check fails, Gregor Samsa does **not** attempt the delete and reports `outcome: error` instead.

### Check 1 — Topic Has Data

Use `AdminClient.listOffsets` with `OffsetSpec.EARLIEST` and `OffsetSpec.LATEST` for all partitions of the topic.

If any partition has `log-start-offset < log-end-offset` → the topic contains unconsumed data → **fail**.

### Check 2 — Topic Has Active Consumers

Use `AdminClient.listConsumerGroups` to retrieve all consumer group IDs, then `AdminClient.listConsumerGroupOffsets` filtered to the topic being deleted.

If any consumer group has a committed offset on any partition of the topic → **fail**. This check is intentionally conservative: a group that committed offsets and then went idle is still treated as an active consumer.

### Failure Reporting

```json
{
    "claim-id": "...",
    "revision-id": "...",
    "outcome": "error",
    "error": "deletion safety check failed: topic has unconsumed data (partition 0: log-start-offset=0, log-end-offset=45201); topic has active consumers (groups: payment-consumer-group, audit-consumer-group)"
}
```

Franz applies the standard `error` mapping: Revision → `Error`, Claim → `Error`. The `TopicDefinition` remains `Deleted` (user intent is unchanged). The operator must drain the topic and clean up consumer group offsets, then call the retry endpoint.

### Idempotent Delete

If the topic does not exist on Kafka (already deleted or never created), Gregor Samsa reports `outcome: deleted` without running safety checks. Deletion is idempotent.

---

## Retry Flow

```
Revision (Error)
    |
    v
Operator calls retry endpoint
    |
    v
Franz creates NEW revision
  - Same topic-configuration as failed revision
  - retry_of_revision_id = failed revision's ID
  - status = PendingReconciliation (or PendingDelete, matching original intent)
  - attempts = 0
    |
    v
Claim status -> Pending
    |
    v
Gregor Samsa picks up new revision on next poll
    |
    v
Reconcile and inform (same flow as initial attempt)
```

The failed revision is preserved as a historical record. The `retry_of_revision_id` chain enables auditing of all retry attempts.

---

## Error Handling and Backoff

### Gregor Samsa Responsibilities

- **Transient errors** (connection timeouts, temporary broker unavailability): Gregor Samsa should report `error` and let the retry mechanism handle re-attempts.
- **Permanent errors** (invalid config, topic already exists with incompatible settings): Gregor Samsa reports `error` with a descriptive message. The claim remains in `Error` until an operator intervenes.
- **Partial application**: If Gregor Samsa successfully reads the current topic state but fails to apply changes, it should include `last-topic-configuration` in the error report so Franz has visibility into the actual state.
- **Deletion safety check failures**: Reported as `error` with a structured message identifying which check failed (see [Deletion Safety Checks](#deletion-safety-checks)).

### Backoff Strategy

Gregor Samsa should implement exponential backoff on its poll interval when encountering repeated errors:

| Condition | Behaviour |
|---|---|
| Successful poll with claims to process | Process immediately, reset backoff |
| Successful poll with no claims | Sleep for base poll interval |
| Franz API unreachable | Exponential backoff (e.g., 5s, 10s, 20s, 40s, max 120s) |
| Kafka cluster unreachable | Report error for all attempted revisions, exponential backoff before next poll |

### Franz Responsibilities

- Franz does NOT retry automatically. Retries are operator-initiated via the retry endpoints.
- Franz records the `error` message and `last-topic-configuration` on the revision for debugging.
- Franz tracks the `attempts` count but does not enforce a maximum. Operators decide when to stop retrying.

---

## Gregor Samsa Reconciliation Logic

### PendingReconciliation

```
1. Extract topic name from claim.topic-definition.name
2. Extract desired config from pending-revision.topic-configuration
3. Connect to Kafka cluster via AdminClient
4. Check if topic exists on the cluster
5a. If topic does NOT exist:
      - Create topic with desired config
      - Read back actual config
      - Inform Franz: outcome=created, last-topic-configuration=actual config
5b. If topic exists:
      - Compare current config with desired config
      - Apply config changes (partitions can only increase)
      - Read back actual config
      - Inform Franz: outcome=updated, last-topic-configuration=actual config
6. On any failure:
      - Read current config if possible
      - Inform Franz: outcome=error, error=<message>, last-topic-configuration=<current if available>
```

### PendingDelete

```
1. Extract topic name from claim.topic-definition.name
2. Connect to Kafka cluster via AdminClient
3. Check if topic exists
4a. If topic does NOT exist:
      - Inform Franz: outcome=deleted (idempotent)
4b. If topic exists:
      - Run safety checks:
          a. Check for unconsumed data (listOffsets: earliest vs latest per partition)
          b. Check for committed consumer group offsets (listConsumerGroupOffsets)
      - If any check fails:
          - Inform Franz: outcome=error, error="deletion safety check failed: <details>"
      - If all checks pass:
          - Delete topic
          - Inform Franz: outcome=deleted
5. On any unexpected failure:
      - Inform Franz: outcome=error, error=<message>
```

### Drift Detection

```
1. Extract topic name from claim.topic-definition.name
2. Extract desired config from claim.desired-topic-configuration
3. Connect to Kafka cluster via AdminClient
4. Read actual topic config:
      - describeTopics -> partition count, replication factor
      - describeConfigs -> retention-ms and all config entries
5. Compare actual vs desired:
      - partitions, replication-factor, retention-ms, and all keys in configs map
6a. If all values match:
      - No action. Skip this claim. No outcome emitted.
6b. If any value differs:
      - Apply the desired config to Kafka
      - Log the drift event: topic name, field that differed, old value, new value
      - Emit metric: gregor_samsa_drift_corrections_total{cluster=..., topic=...}
      - No inform call to Franz. Drift corrections are handled entirely by Gregor Samsa.
7. On any failure during drift check or correction:
      - Log the error
      - Emit metric: gregor_samsa_drift_check_errors_total{cluster=..., topic=...}
      - No inform call. Next poll cycle will retry automatically.
```

---

## Concurrency Model

- Gregor Samsa processes claims **sequentially within a single poll batch** for simplicity and to avoid race conditions on the same topic.
- Multiple Gregor Samsa instances for different clusters run fully independently and in parallel.
- Franz handles concurrent inform calls from different Gregor Samsa instances safely because each instance only touches revisions for its own cluster.
- Gregor Samsa must check `claim.status` before processing any claim. If `claim.status` is `Paused`, the claim must be skipped entirely — neither revision work nor drift detection. Franz already excludes Paused claims from the poll response, but Gregor Samsa must guard against this defensively.

---

## Status Reference

Combined view of all entity statuses and their meaning:

| TopicDefinition | TopicClaim | Last Revision | Meaning |
|---|---|---|---|
| `Active` | `Pending` | `PendingReconciliation` | Claim exists, topic creation or update in flight |
| `Active` | `Ready` | `Created` | Topic live, last operation was creation |
| `Active` | `Ready` | `Updated` | Topic live, last operation was a config update |
| `Active` | *(no claims)* | *(none)* | Definition exists but no cluster matches its selectors |
| `Error` | `Error` | `Error` | At least one claim failed reconciliation |
| `Paused` | `Paused` | `Created` / `Updated` | Topic live on Kafka, definition and claims suspended |
| `Paused` | `Paused` | `PendingReconciliation` / `PendingDelete` | Was in flight when paused — Gregor Samsa skips these |
| `Paused` | `Paused` | `Error` | Failed before pausing, frozen in error state |
| `Deleted` | `Pending` | `PendingDelete` | Deletion requested, topic removal in flight on Kafka |
| `Deleted` | `Deleted` | `Deleted` | Topic successfully removed from Kafka |
| `Deleted` | `Error` | `Error` | Deletion failed — topic likely still exists on Kafka. Error message indicates whether cause was safety check failure (data present or active consumers) or an unexpected error. |
