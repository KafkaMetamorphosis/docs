# Architecture Overview

Describe how the management of a big kafka fleet with resource across many clusters and locations.

## Franz

Is aware of the Kafka cluster and its resources (topic, acl, etc) across the fleet. It will contain the state of cluster registered and the topics that are inside them. It has the tools to manage the resources configuration, cascade them to the actual resource and keep them inside a certain governance.

**Cluster**
| Field | Type | Required | Description |
|---|---|---|---|
| `name` | `string` | Yes | Unique identifier for the cluster. Immutable after creation. Used as the natural key in API paths. |
| `bootstrap-url` | `string` | Yes | Kafka bootstrap server URL (e.g. `broker-1:9092,broker-2:9092`). |
| `labels` | `map<string, string>` | No | Arbitrary key-value metadata for categorization and filtering. Defaults to an empty map. |

**Topic Definition**

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | `string` | Yes | Unique topic name. Immutable after creation. Used as the natural key in API paths. |
| `partitions` | `integer` | Yes | Number of partitions. Can only increase, never decrease. |
| `replication-factor` | `integer` | Yes | Number of replicas per partition. |
| `retention-ms` | `long` | No | Message retention time in milliseconds. When omitted, the broker default applies. |
| `configs` | `map<string, string>` | No | Additional Kafka topic configuration entries (e.g. `cleanup.policy`, `compression.type`). Defaults to an empty map. |
| `labels` | `map<string, string>` | No | Arbitrary key-value metadata for categorization and filtering. Defaults to an empty map. |

**Topic Claim**

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | `uuid` | Yes | System-generated unique identifier. |
| `topic-id` | `FK` | Yes | Foreign key referencing the topic definition. |
| `cluster-id` | `FK` | Yes | Foreign key referencing the target cluster. |
| `status` | `enum` | Yes | One of: `pending`, `synced`, `error`, `deleting`. |
| `error-message` | `string` | No | Details of the last reconciliation error. Null when status is not `error`. |
| `last-reconciled-at` | `timestamp` | No | Timestamp of the last successful or attempted reconciliation. Null if never reconciled. |

### Franz Domain Model

```mermaid
erDiagram
    CLUSTER {
        string name PK "Immutable. Natural key in API paths."
        string bootstrap-url
        map labels
    }

    TOPIC_DEFINITION {
        string name PK "Immutable. Natural key in API paths."
        integer partitions "Can only increase"
        integer replication-factor
        long retention-ms
        map configs
        map labels
    }

    TOPIC_CLAIM {
        uuid id PK
        string topic-id FK
        string cluster-id FK
        enum status "pending | synced | error | deleting"
        string error-message "Null unless status = error"
        timestamp last-reconciled-at
    }

    TOPIC_DEFINITION ||--o{ TOPIC_CLAIM : "claimed onto"
    CLUSTER        ||--o{ TOPIC_CLAIM : "targeted by"
```

### Topic Claim Reconciliation Flow

```mermaid
stateDiagram-v2
    [*] --> pending : Topic Claim created

    pending --> synced   : Gregor Samsa applies\ndesired state successfully
    pending --> error    : Reconciliation attempt\nfails

    error   --> pending  : Retry triggered\n(next reconciliation loop)
    error   --> deleting : Deletion requested\nwhile in error

    synced  --> pending  : Topic Definition updated\n(drift detected)
    synced  --> deleting : Deletion requested

    deleting --> [*]     : Resource removed from\nKafka cluster
```

## Gregor Samsa

Is aware of a single cluster and deals with its resource, like topic, acls and make sure governance is applied. It receive the expected state defined in Franz and make sure it is applied to the actual kafka cluster, reconciling as it as needed.


## Overview

```mermaid
graph LR
    subgraph Franz["Franz (Control Plane)"]
        F_DB[("State Store\nClusters · Topic Definitions\nTopic Claims")]
        F_API["API / Management Layer"]
        F_DB <--> F_API
    end

    subgraph GS1["Gregor Samsa — cluster-1"]
        GS1_R["Reconciliation Loop"]
    end

    subgraph GS2["Gregor Samsa — cluster-2"]
        GS2_R["Reconciliation Loop"]
    end

    subgraph GS3["Gregor Samsa — cluster-3"]
        GS3_R["Reconciliation Loop"]
    end

    F_DB -- "desired state\n(Topic Claims)" --> GS1_R
    F_DB -- "desired state\n(Topic Claims)" --> GS2_R
    F_DB -- "desired state\n(Topic Claims)" --> GS3_R

    GS1_R -- "reconcile" --> KC1_T
    GS2_R -- "reconcile" --> KC2_T
    GS3_R -- "reconcile" --> KC3_T

    GS1_R -- "status updates" --> F_DB
    GS2_R -- "status updates" --> F_DB
    GS3_R -- "status updates" --> F_DB
```

