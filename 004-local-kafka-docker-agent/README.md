# Local Kafka Docker Agent

Status: **ready**

The first Cluster Provider agent, and the interaction contract every Cluster
Provider agent will follow. It turns a **Kafka Cluster registration** (intent) in
Franz into a **running Kafka cluster** on the local machine, using Docker.

Related: `003-franz/003.9-agents` (Agent registry), `003-franz/003.3-kafka-cluster`
(the intent), `003-franz/003.1-conventions` (labels). Implementation plan:
`franz/docs/impls_plan/` deliverables 06–08.

## Vocabulary

- **Intent** — the `KafkaCluster` registration in Franz: connection strings,
  `cluster_configuration`, and the typed `brokers` / `disk_size`. Franz never
  holds deployment mechanics or the container image.
- **Recipe** — agent-owned logic that turns intent into containers. One recipe
  family per agent — this agent ships `local-docker`.
- **Assignment** — the desired state of one cluster, pushed to the agent that owns
  it (`KafkaCluster.cluster_provider_agent == agent.name`).

## The flow

```
operator                 Franz                         agent (local, Docker)
   │ register agent ───────▶ │  mint token (shown once)
   │ ◀── token               │
   │                         │        ◀── WatchClusterAssignments (stream, Bearer token)
   │ register KafkaCluster ─▶ │  cluster_provider_agent = <agent>
   │   cluster_configuration  │  ─── assignment(cluster desired state) ──▶
   │   + brokers / disk_size  │
   │                         │                                    render recipe
   │                         │                                    docker: create/start
   │                         │  ◀── ReportClusterStatus(phase, reachable, recipe_hash) ──
   │                         │  append cluster_provider_event
   │ ◀── console shows        │
   │     provider: READY      │
```

## 1. Transport

- **`WatchClusterAssignments` — server-streaming**, agent → Franz. The agent opens
  one long-lived stream; Franz sends the **full current set** of its assignments
  on open, then a message per change (added / spec-changed / paused / removed).
- **`ReportClusterStatus` — unary**, agent → Franz, one call per cluster whenever
  the agent's observed state changes.
- Franz keeps an **in-memory registry** of connected agents + their open streams.
  The stream's liveness is *observable* but `AgentStatus` stays
  `ACTIVE / PAUSED / DELETED` (`003.9`) — a derived "connected" flag on
  `GetAgent` is a later refinement, not modelled now.
- The agent reconnects with backoff; on reconnect it re-syncs from the full set.

## 2. Authentication

- `CreateAgent` returns a **one-time bearer token** (`frz_agt_…`); Franz stores
  only its hash on the `agent` row.
- The agent sends `authorization: Bearer <token>` in gRPC metadata on the stream
  and on `ReportClusterStatus`. An interceptor resolves it to the agent identity;
  a request for a cluster the agent does not own is `PERMISSION_DENIED`.
- `RotateAgentToken` issues a new token and invalidates the old.
- This is self-contained and independent of `003.2` (still a placeholder).

## 3. Intent — cluster config + typed shape (ADR-API-010)

The recipe's inputs come from the `KafkaCluster` itself, delivered on the
assignment:

| Input | Source | `local-docker` behaviour |
|---|---|---|
| Kafka version | `cluster_configuration["kafka-version"]` | `apache/kafka:<version>`, default `3.9.0`. The image is the agent's choice — a `kafka-image` override is **not** modelled. |
| Broker count | `KafkaCluster.brokers` (typed, `ClusterAssignment.brokers`) | **warned + single node** if `> 1` |
| Disk size | `KafkaCluster.disk_size` (typed, `ClusterAssignment.disk_size`) | ignored locally |
| Broker settings | other `cluster_configuration` keys, via the recipe's allow-list | passed through as `KAFKA_*` env; unknown keys warned + dropped |

There is no `deployment-type` — one recipe family per agent; you select
`local-docker` by pointing the cluster at this agent.

`cluster_configuration` keys are Franz-friendly (`partitions`,
`replication-factor`, `retention.ms`, …); the recipe / config-merge translate to
real Kafka keys. The resolved version + allow-listed settings feed the recipe
hash, so changing them recreates the container (data volume kept).

The agent advertises sensible defaults as **`franz.default-kafka-config/*`**
labels on its own registration (`003.9`, ADR-API-010) so the console pre-fills
the cluster-config form:
`franz.default-kafka-config/{partitions,replication-factor,retention.ms,kafka-version}`
plus `franz.default-kafka-config/available-versions=3.7.0,3.9.0,4.0.0` for the
version picker. Advisory — Franz enforces nothing. For local dev these labels
(and the agent registration itself) ship in the DB seed —
`franz/local/seed/01-local-agent.sql`, applied by `make deps`.

## 4. Status — `cluster_provider_event`

`ReportClusterStatus` appends to a `cluster_provider_event` table
(`cluster_frn`, `phase`, `reachable`, `message`, `reporting_agent`,
`recipe_ref`, `occurred_at`). Pruned nightly (30 days, matching `003.14`).
"Current provider status" = the latest row per `cluster_frn`, surfaced on
`GetKafkaCluster` and the console. `KafkaCluster.state` (operator intent) is
never written by an agent.

`phase`: `PROVISIONING` / `READY` / `DEGRADED` / `ERROR` / `STOPPED` /
`REMOVED`.

## 5. Recipe — `local-docker`

Agent-owned. `recipe_ref` in the status report is the recipe name + a hash of the
rendered spec.

- **One container per cluster**: `apache/kafka:<version>` (`version` from
  `cluster_configuration["kafka-version"]`, default `3.9.0`), KRaft combined mode
  (`process.roles=broker,controller`), no ZooKeeper.
- `advertised.listeners` = the cluster's single `connection_strings[0].bootstrap_urls[0]`
  (must be `PLAINTEXT`, `003.3`). The published host port is parsed from it.
- Allow-listed keys from `cluster_configuration` become broker config
  (`replication-factor` → `default.replication.factor`, `partitions` →
  `num.partitions`, …); `kafka-version` is consumed above, not passed as env;
  unknown keys are warned + dropped.
- `brokers > 1` on the assignment → warn, provision a single node.
- Container labels: `franz.managed-by=<agent>`, `franz.cluster=<frn>`,
  `franz.recipe-hash=<sha>`.

## 6. Agent implementation

- **Go, in the Franz module** — `franz/cmd/localkafkaagent/` (main) and
  `franz/pkg/localkafkaagent/` (`stream`, `recipe`, `docker`, `reconcile`).
  Reuses `pkg/gen/go` and `pkg/shared`.
- **Docker** via the official Go Engine API SDK
  (`github.com/docker/docker/client`) — no `docker compose` dependency.
- **Stateless.** No local file/db. Current state is discovered each reconcile:
  `ContainerList(label=franz.managed-by=<agent>)`. Desired vs. running is a
  `franz.recipe-hash` comparison → recreate on mismatch.
- **Reconcile loop**: for each assignment, render → compare hash → create / recreate
  / leave; for a `REMOVED`/`PAUSED` assignment, stop + remove; report each outcome.
- **Config**: `FRANZ_ENDPOINT`, `FRANZ_TOKEN`, `DOCKER_HOST` (default local socket).
- Level-triggered and idempotent — a full re-sync on reconnect must not disturb a
  correct container.

## Lifecycle mapping

| Franz | Agent action |
|---|---|
| assignment appears | render + create; `PROVISIONING` → `READY` |
| `cluster_configuration` / `brokers` / `disk_size` change | recompute hash; recreate if changed |
| `KafkaCluster` `PAUSED` | stop the container (keep it); `STOPPED` |
| `KafkaCluster` `PAUSED` → `ACTIVE` | start the container; `READY` |
| `KafkaCluster` `DELETED` | stop + remove container + volume; `REMOVED` |
| agent disconnects | container keeps running; Franz shows the last event, stream gone |

## New proto

A `ClusterProviderService` (new file, e.g. `agent_cluster_provider.proto`):

```
service ClusterProviderService {
  rpc WatchClusterAssignments(WatchClusterAssignmentsRequest)
      returns (stream WatchClusterAssignmentsResponse);   // { ClusterAssignment }
  rpc ReportClusterStatus(ReportClusterStatusRequest)
      returns (ReportClusterStatusResponse);
}
```

`ClusterAssignment` carries the cluster `cluster_name` / `cluster_frn`, `change`
enum (`CHANGE_SET` / `CHANGE_PAUSED` / `CHANGE_REMOVED`), `connection_strings`,
`cluster_configuration`, and the typed `brokers` / `disk_size`. (The former
`provisioning` map is removed by ADR-API-010 — field 6 is `reserved`.)

Also: `agent.proto` — `token` in `CreateAgentResponse`, `RotateAgentToken`
(`token_hash` stored on the row). `common.proto` — `ClusterProviderPhase`.
`kafka.proto` — `KafkaCluster.provider_status` (`ClusterProviderStatus`),
`ClusterProviderEvent`, `ListClusterProviderEvents`.

## Open questions

1. **Multi-broker `local-docker`** — a later recipe iteration; advertised-listener
   and port-allocation design deferred.
2. **Health probe** — how the agent decides `READY` vs `DEGRADED` (broker API
   probe? container health check? topic round-trip?).
3. **Port conflicts** — two local clusters both wanting `localhost:9092`; reject
   at registration, or let the agent report `ERROR`?
4. **Derived "agent connected" flag** on `GetAgent` from the stream registry —
   worth adding, or leave liveness fully deferred (`003.9`)?
5. **Recipe distribution** for non-bundled recipes (later, when agents ship
   separately from Franz).
6. **`cluster_provider_event` retention** — share the 30-day telemetry default or
   set its own.
