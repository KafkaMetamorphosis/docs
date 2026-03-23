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
| [architecture-overview.md](./architecture-overview.md) | High-level system architecture, domain model for Franz, and the Topic Claim reconciliation state machine. |
