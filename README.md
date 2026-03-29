# KafkaMetamorphosis — Documentation

This directory contains the technical documentation for the KafkaMetamorphosis system: a distributed platform for managing Kafka resources at scale across multiple clusters and locations.

## Vision of the project

Make Kafka management as easy as maintain http connections by offering tools to keep kafka clusters under governance.

### Franz (Control Plane)

Franz is the central authority of the fleet. It maintains the desired state of all registered Kafka clusters and their resources — topics, ACLs, and related configuration. It exposes a management API and propagates desired state to reconcilers via Topic Claims, which track the binding between a Topic Definition and a target Cluster through their reconciliation lifecycle.

### Gregor Samsa (Execution Plane / Reconciler)

Gregor Samsa runs as a sidecar or agent scoped to a single Kafka cluster. It reads the desired state produced by Franz, reconciles it against the actual state of the cluster, and reports status updates back. Multiple Gregor Samsa instances run in parallel — one per cluster — forming the distributed execution layer of the system.

## Documents

| Document | Description |
|---|---|
| [IMPLEMENTATION.md](./IMPLEMENTATION.md) | Implementation status — what is built, when, and what is still missing. |

### Specs

| Document | Description |
|---|---|
| [001-architecture-overview.md](./001-architecture-overview.md) | High-level system architecture, full domain model, and all state machines. |
| [002-clojure-projects-structure.md](./002-clojure-projects-structure.md) | Clojure project layout and namespace conventions. |
| [003-franz/003.0-franz.md](./003-franz/003.0-franz.md) | Franz overview and dependencies. |
| [003-franz/003.1-kafka-cluster.md](./003-franz/003.1-kafka-cluster.md) | Cluster registration — CRUD API. |
| [003-franz/003.2-kafka-topic-definition.md](./003-franz/003.2-kafka-topic-definition.md) | TopicConfiguration and TopicDefinition — schemas, state machine, API. |
| [003-franz/003.3-topic-claim.md](./003-franz/003.3-topic-claim.md) | TopicClaim and TopicRevision — state machines, reconciliation API, retry, outcome mapping. |
| [003-franz/003.4-topic-cluster-selection.md](./003-franz/003.4-topic-cluster-selection.md) | Topic Definition Expansion — taint/toleration, affinity, shard-size, scheduling pipeline. |
| [003-franz/003.5-governance.md](./003-franz/003.5-governance.md) | Governance rules — EDN config controlling topic and cluster create/update behaviour. |
| [004-gregor-samsa/004-reconciliation.md](./004-gregor-samsa/004-reconciliation.md) | Gregor Samsa reconciliation loop. |
