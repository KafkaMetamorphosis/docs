# KafkaMetamorphosis — Documentation

Specs and decision records for **KafkaMetamorphosis** — a control plane that makes
running a fleet of Kafka clusters feel like using a managed queue: declare the
channel you need, let the system place it on a cluster, and keep the whole fleet
under governance.

## Systems

- **Franz** — the control plane. Holds the declared state of every cluster,
  channel, topic, client, and policy; exposes a gRPC + REST API; applies
  fleet-wide governance.
- **Gregor Samsa** — the Resource Provider agent. Materialises Async Channel
  intent (topics today; ACLs, users, quotas later) into the Kafka clusters it is
  label-scoped to, and streams topic/broker telemetry back.
- **Odradek** — a telemetry agent that publishes the SLO / indicator metrics
  Franz's governance reacts to.

## Layout

| Path | What |
|---|---|
| [`001-architecture-overview.md`](./001-architecture-overview.md) | System architecture, domain model, state machines |
| [`001-ux/`](./001-ux/README.md) | Franz UX RFC + clickable prototype (`demo/`) |
| [`002-monorepo-structure/`](./002-monorepo-structure/README.md) | Go monorepo layout — proto, hexagonal Franz, buf, grpc-gateway |
| [`003-franz/`](./003-franz/README.md) | Franz specs — entities, conventions, placement, governance, persistence |
| [`004-local-kafka-docker-agent/`](./004-local-kafka-docker-agent/README.md) | First Cluster Provider agent — interaction contract + local Docker recipe |
| [`005-gregor-samsa/`](./005-gregor-samsa/README.md) | Resource Provider agent — materialises Async Channel intent (topics) into Kafka + telemetry |
| [`105-odradek/`](./105-odradek/005-odradek.md) | Odradek telemetry agent |
| [`106-operations/`](./106-operations/006.0-overview.md) | Deployment, configuration, observability |
| [`DECISIONS.md`](./DECISIONS.md) | Architecture Decision Records |

Every spec carries a `Status:` — `ready`, `draft`, or an explicit placeholder.
The `.proto` files under `franz/api/franz/v1/` are authoritative for API shapes;
the `003-franz/` docs own semantics, invariants, and cross-entity behaviour.
