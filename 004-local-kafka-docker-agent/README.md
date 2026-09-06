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
  `cluster_configuration`, and `franz.provisioning/*` labels. Franz never holds
  deployment mechanics.
- **Recipe** — agent-owned logic that turns intent into containers. Selected by
  `franz.provisioning/deployment-type`. Feature 1 ships one: `local-docker`.
- **Assignment** — the desired state of one cluster, pushed to the agent that owns
  it (`KafkaCluster.cluster_provider_agent == agent.name`).

## The flow

```
operator                 Franz                         agent (local, Docker)
   │ register agent ───────▶ │  mint token (shown once)
   │ ◀── token               │
   │                         │        ◀── WatchClusterAssignments (stream, Bearer token)
   │ register KafkaCluster ─▶ │  cluster_provider_agent = <agent>
   │   franz.provisioning/*   │  ─── assignment(cluster desired state) ──▶
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

## 3. Intent — provisioning via reserved labels

No new `KafkaCluster` field. Provisioning intent is expressed with the reserved
**`franz.provisioning/*`** prefix on `KafkaCluster.labels` (added to the `003.1`
reserved-label set):

| Label | Meaning | Feature 1 (`local-docker`) |
|---|---|---|
| `franz.provisioning/deployment-type` | selects the recipe family | `local-docker` (only one handled) |
| `franz.provisioning/kafka-version` | image tag | `apache/kafka:<version>`, default `3.7.0` |
| `franz.provisioning/brokers` | desired broker count | **warned + ignored** if `> 1` |
| `franz.provisioning/disk-size` | volume size hint | ignored locally |

The prefix is open — more keys are added without a breaking change. The agent
reads only the keys its recipe understands.

## 4. Status — `cluster_provider_event`

`ReportClusterStatus` appends to a `cluster_provider_event` table
(`cluster_orn`, `phase`, `reachable`, `message`, `reporting_agent`,
`recipe_ref`, `occurred_at`). Pruned nightly (30 days, matching `003.14`).
"Current provider status" = the latest row per `cluster_orn`, surfaced on
`GetKafkaCluster` and the console. `KafkaCluster.state` (operator intent) is
never written by an agent.

`phase`: `PROVISIONING` / `READY` / `DEGRADED` / `ERROR` / `STOPPED` /
`REMOVED`.

## 5. Recipe — `local-docker`

Agent-owned, keyed by `deployment-type`. `recipe_ref` in the status report is the
recipe name + a hash of the rendered spec.

- **One container per cluster**: `apache/kafka:<version>`, KRaft combined mode
  (`process.roles=broker,controller`), no ZooKeeper.
- `advertised.listeners` = the cluster's single `connection_strings[0].bootstrap_urls[0]`
  (must be `PLAINTEXT`, `003.3`). The published host port is parsed from it.
- Selected keys from `cluster_configuration` become broker config
  (`default.replication.factor`, `num.partitions`, …); unknown keys are passed
  through where safe.
- Container labels: `franz.managed-by=<agent>`, `franz.cluster=<orn>`,
  `franz.recipe-hash=<sha>`.

## 6. Agent implementation

- **Go, in the Franz module** — `franz/cmd/local-kafka-agent/` (main) and
  `franz/pkg/localkafka/` (`stream`, `recipe`, `docker`, `reconcile`). Reuses
  `pkg/gen/go` and `pkg/shared`.
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
| `franz.provisioning/*` or `cluster_configuration` change | recompute hash; recreate if changed |
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

`ClusterAssignment` carries the cluster `cluster_name` / `cluster_orn`, `change`
enum (`CHANGE_SET` / `CHANGE_PAUSED` / `CHANGE_REMOVED`), `connection_strings`,
`cluster_configuration`, and the `franz.provisioning/*` labels.

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
