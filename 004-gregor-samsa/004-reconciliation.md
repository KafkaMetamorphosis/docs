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
- **Unidirectional**: Specs flow from Franz to Kafka. There is no automatic feedback from Kafka's actual state back into Franz (beyond what Gregor Samsa reports).

---

## Reconciliation Loop

Gregor Samsa runs a continuous loop:

```
                    +-------------+
                    |   Start     |
                    +------+------+
                           |
                    +------v------+
                    |  Poll Franz |
                    |  for pending|
                    |  revisions  |
                    +------+------+
                           |
                    +------v------+
              +---->| Next        |
              |     | revision?   |
              |     +------+------+
              |            |
              |     Yes    |    No
              |     +------v------+  +-------+
              |     | Reconcile   |  | Sleep  |
              |     | against     |  | (poll  |
              |     | Kafka       |  | interval)
              |     +------+------+  +---+---+
              |            |             |
              |     +------v------+      |
              |     | Inform Franz|      |
              |     | of outcome  |      |
              |     +------+------+      |
              |            |             |
              +------------+-------------+
```

### Loop Steps

1. **Poll**: `GET /api/v0/clusters/:cluster-name/poll-pending-reconciliations`
   - Returns all revisions with status `PendingReconciliation` or `PendingDelete` for this cluster.
   - If the response is empty, sleep for the configured poll interval and try again.

2. **Reconcile**: For each revision, perform the appropriate Kafka admin operation:
   - `PendingReconciliation` with no existing topic on the cluster: **Create** the topic with the materialised config.
   - `PendingReconciliation` with an existing topic: **Update** the topic config to match the materialised config.
   - `PendingDelete`: **Delete** the topic from the cluster.

3. **Inform**: `PUT /api/v0/clusters/:cluster-name/inform-reconciliation-status/:revision-id`
   - Report the outcome of the reconciliation attempt.
   - Gregor Samsa only reports WHAT happened. Franz derives all state transitions internally.

---

## Franz API Contract (Agent Endpoints)

### Poll Pending Reconciliations

```
GET /api/v0/clusters/:cluster-name/poll-pending-reconciliations
```

Returns revisions with their associated claim and cluster details.

**Response** `200`:
```json
{
    "revisions": [
        {
            "claim": {
                "id": "550e8400-e29b-41d4-a716-446655440000",
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
                "status": "Pending"
            },
            "revision": {
                "id": "770e8400-e29b-41d4-a716-446655440002",
                "topic-configuration": {
                    "retention-ms": 604800000,
                    "partitions": 6,
                    "replication-factor": 3,
                    "configs": {
                        "cleanup.policy": "delete",
                        "compression.type": "lz4"
                    }
                },
                "kafka-cluster": {
                    "name": "production-us-east-1",
                    "bootstrap-url": "broker-1:9092,broker-2:9092"
                },
                "status": "PendingReconciliation"
            }
        }
    ]
}
```

**Important fields for Gregor Samsa:**

| Field | Usage |
|---|---|
| `revision.id` | Used in the inform call to report outcome. |
| `revision.status` | Determines the operation: `PendingReconciliation` = create/update, `PendingDelete` = delete. |
| `revision.topic-configuration` | The exact config to apply to the Kafka topic. |
| `revision.kafka-cluster.bootstrap-url` | Where to connect (should match the instance's own config). |
| `claim.topic-definition.name` | The Kafka topic name to create/update/delete. |

### Inform Reconciliation Status

```
PUT /api/v0/clusters/:cluster-name/inform-reconciliation-status/:revision-id
```

Gregor Samsa reports one of four outcomes:

#### Topic Created

```json
{
    "outcome": "created",
    "last-topic-configuration": {
        "retention-ms": 604800000,
        "partitions": 6,
        "replication-factor": 3,
        "configs": {
            "cleanup.policy": "delete",
            "compression.type": "lz4"
        }
    }
}
```

#### Topic Updated

```json
{
    "outcome": "updated",
    "last-topic-configuration": {
        "retention-ms": 604800000,
        "partitions": 6,
        "replication-factor": 3,
        "configs": {
            "cleanup.policy": "delete",
            "compression.type": "lz4"
        }
    }
}
```

#### Topic Deleted

```json
{
    "outcome": "deleted"
}
```

No `last-topic-configuration` is needed since the topic no longer exists.

#### Error

```json
{
    "outcome": "error",
    "error": "failed to connect to broker at broker-1:9092: connection refused"
}
```

Error with partial configuration (Gregor Samsa read the current state before failing):
```json
{
    "outcome": "error",
    "error": "cannot reduce partition count from 6 to 4",
    "last-topic-configuration": {
        "retention-ms": 604800000,
        "partitions": 6,
        "replication-factor": 3,
        "configs": {
            "cleanup.policy": "delete"
        }
    }
}
```

### Retry Endpoints

```
POST /api/v0/clusters/:cluster-name/claims/:claim-id/retry
```

Retries a single errored claim. Creates a new revision copying the intent from the failed one.

**Preconditions:**
- Claim must be in `Error` status.
- Latest revision must be in `Error` status. If the latest revision is not in `Error` (e.g., already picked up), the request is rejected with `409`.

**Response** `201`:
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

**Response** `200`:
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
| `PendingDelete` | Delete the topic | `deleted`, `error` |

Gregor Samsa determines whether to create or update based on whether the topic already exists on the Kafka cluster. Franz does not distinguish between create and update at the revision level; the `PendingReconciliation` status covers both.

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

### Backoff Strategy

Gregor Samsa should implement exponential backoff on its poll interval when encountering repeated errors:

| Condition | Behaviour |
|---|---|
| Successful poll with revisions | Process immediately, reset backoff |
| Successful poll with no revisions | Sleep for base poll interval |
| Franz API unreachable | Exponential backoff (e.g., 5s, 10s, 20s, 40s, max 120s) |
| Kafka cluster unreachable | Report error for all attempted revisions, exponential backoff before next poll |

### Franz Responsibilities

- Franz does NOT retry automatically. Retries are operator-initiated via the retry endpoints.
- Franz records the `error` message and `last-topic-configuration` on the revision for debugging.
- Franz tracks the `attempts` count but does not enforce a maximum. Operators decide when to stop retrying.

---

## Gregor Samsa Reconciliation Logic

For each revision received in a poll response, Gregor Samsa executes:

### PendingReconciliation

```
1. Extract topic name from claim.topic-definition.name
2. Extract desired config from revision.topic-configuration
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
4a. If topic exists:
      - Delete topic
      - Inform Franz: outcome=deleted
4b. If topic does NOT exist (already deleted or never created):
      - Inform Franz: outcome=deleted (idempotent)
5. On any failure:
      - Inform Franz: outcome=error, error=<message>
```

---

## Concurrency Model

- Gregor Samsa processes revisions **sequentially within a single poll batch** for simplicity and to avoid race conditions on the same topic.
- Multiple Gregor Samsa instances for different clusters run fully independently and in parallel.
- Franz handles concurrent inform calls from different Gregor Samsa instances safely because each instance only touches revisions for its own cluster.

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
| `Paused` | `Paused` | `PendingReconciliation` / `PendingDelete` | Was in flight when paused -- Gregor Samsa should skip these |
| `Paused` | `Paused` | `Error` | Failed before pausing, frozen in error state |
| `Deleted` | `Pending` | `PendingDelete` | Deletion requested, topic removal in flight on Kafka |
| `Deleted` | `Deleted` | `Deleted` | Topic successfully removed from Kafka |
| `Deleted` | `Error` | `Error` | Deletion failed -- topic likely still exists on Kafka |
