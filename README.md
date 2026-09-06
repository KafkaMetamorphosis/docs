# KafkaMetamorphosis — Documentation

This directory contains the technical documentation for the KafkaMetamorphosis system: a distributed platform for managing Kafka resources at scale across multiple clusters and locations.

## Vision of the project

Make Kafka management as easy as maintain managed queues like sqs or even make it easy as http connections by offering tools to keep kafka clusters under governance.

### Franz (Control Plane)

Franz is the central authority of the fleet. It maintains the desired state of all registered Kafka clusters and their resources — topics, ACLs, and related configuration. It exposes a management API and propagates desired state to reconcilers via Topic Claims, which track the binding between a Topic Definition and a target Cluster through their reconciliation lifecycle.

### Gregor Samsa (Execution Plane / Reconciler)

Gregor Samsa runs as a sidecar or agent scoped to a single Kafka cluster. It reads the desired state produced by Franz, reconciles it against the actual state of the cluster, and reports status updates back. Multiple Gregor Samsa instances run in parallel — one per cluster — forming the distributed execution layer of the system.

## Documents

### Specs

| Document | Description |
|---|---|
| [001-architecture-overview.md](./001-architecture-overview.md) | High-level system architecture, full domain model, and all state machines. |
| [002-monorepo-structure/002.0-monorepo-structure.md](./002-monorepo-structure/002.0-monorepo-structure.md) | Go monorepo layout — proto, hexagonal Franz, buf, grpc-gateway. |
| [003-franz/README.md](./003-franz/README.md) | Franz overview, entity index, proto contract. |
| [003-franz/003.1-conventions.md](./003-franz/003.1-conventions.md) | ORN, pagination, selector & label grammar, error conventions. |
| [003-franz/003.2-api-authorization.md](./003-franz/003.2-api-authorization.md) | Console/API authorization — placeholder, model not yet decided. |
| [003-franz/003.3-kafka-cluster.md](./003-franz/003.3-kafka-cluster.md) | Kafka Cluster — registration, config, provider link. |
| [003-franz/003.4-async-channel.md](./003-franz/003.4-async-channel.md) | Async Channel — the customer-facing boundary; state machine. |
| [003-franz/003.5-access-policy.md](./003-franz/003.5-access-policy.md) | Channel access policy — Allow/Deny evaluation for clients. |
| [003-franz/003.6-kafka-topic.md](./003-franz/003.6-kafka-topic.md) | Kafka Topic — state machine, generation, consumption, config merge. |
| [003-franz/003.7-placement-and-selection.md](./003-franz/003.7-placement-and-selection.md) | Placement — affinity, taints/tolerations, shard-size. |
| [003-franz/003.8-governance.md](./003-franz/003.8-governance.md) | Governance — policies, indicators, actions, evaluation. |
| [003-franz/003.9-agents.md](./003-franz/003.9-agents.md) | Agent registry; interaction model deferred to a separate ADR. |
| [003-franz/003.10-clients.md](./003-franz/003.10-clients.md) | Client identity and consumer-group observation. |
| [003-franz/003.11-lifecycle-and-operations.md](./003-franz/003.11-lifecycle-and-operations.md) | Pause/resume, soft delete, migration, signal history. |
| [003-franz/003.12-persistence-and-data-model.md](./003-franz/003.12-persistence-and-data-model.md) | PostgreSQL schema — table-per-entity, jsonb for maps/documents, materialized topic config, migrations. |
| [004-kafka-topic-reconciliation/004-reconciliation.md](./004-kafka-topic-reconciliation/004-reconciliation.md) | Gregor Samsa reconciliation loop — full service spec, poll/inform contract, retry, error handling. |

### Operations

| Document | Description |
|---|---|
| [006-operations/006.0-overview.md](./006-operations/006.0-overview.md) | Deployment, configuration, observability, and operational procedures. |
