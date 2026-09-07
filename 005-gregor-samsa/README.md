# Gregor Samsa

Status: **draft**

The **Resource Provider** agent. It turns the intent declared on an **Async
Channel** in Franz into real resources inside the Kafka clusters that back it —
today, **topics** — and streams telemetry about those resources and the clusters
back to the control plane.

Gregor Samsa is to Async Channels what the local-kafka-docker-agent (`004`) is to
Kafka Clusters: the second agent interaction contract, and the reference
implementation of the `RESOURCE_PROVIDER` type (`003-franz/003.9-agents`).

Related specs: `003-franz/003.4-async-channel` (the intent), `003-franz/003.6-kafka-topic`
(the per-partition record), `003-franz/003.9-agents` (Agent registry),
`003-franz/003.1-conventions` (labels, selectors), `003-franz/003.7-placement-and-selection`
(how a partition gets a cluster), `franz/api/franz/v1/telemetry.proto` +
`003-franz/003.8-governance` (indicators). Supersedes the earlier poll-based
REST reconciliation design (`104-kafka-topic-reconciliation`, TopicClaim /
TopicRevision — removed by ADR-API-002).

---

## Vocabulary

- **Async Channel** — the customer-facing, abstract resource (`003.4`). Declares
  a `channel_partitions` count and, via reserved `franz.affinity/*` labels, which
  clusters its partitions may land on. Holds no Kafka config of its own.
- **Async Channel Partition** — one shard of a channel, placed on exactly one
  Kafka Cluster, carrying the merged desired configuration for **one real Kafka
  topic**. This is the entity `003.6` calls *Kafka Topic* and the `kafka_topic`
  row in persistence. This document uses **"async channel partition"** (or just
  *partition*) for the Franz-side desired-state record and **"Kafka topic"** only
  for the physical object on a broker, to keep the two unambiguous.
- **Desired state** — the async channel partition's `materialized_configuration`
  (cluster config ⊕ channel/partition config), `partitions`, `replication_factor`,
  and `generation` token, as held by Franz. Franz is the **sole source of
  truth**.
- **Reconcile** — make the Kafka topic match the partition's desired state:
  create it if absent, alter it if it diverges, delete it if the partition is
  gone. Gregor Samsa never reads intent from Kafka back into Franz.
- **Scope** — the set of Kafka Clusters a Gregor Samsa instance is responsible
  for, computed by label selector (see [§1.2](#12-scope--which-clusters-an-instance-handles)).

---

## Scope of this ADR

**In scope now**

1. **Part 1 — Kafka topics from Async Channels.** How Gregor Samsa learns which
   partitions it must reconcile, how it reconciles them (create / alter / delete,
   including deletion safety), and how it reports outcomes so Franz can drive the
   `kafka_topic` state machine.
2. **Part 2 — Telemetry.** What Gregor Samsa observes about topics and brokers,
   and how it publishes that to Franz as pre-registered indicator samples,
   alongside (not replacing) Odradek.

**Stubbed — future parts, not specified here**

- **Part 3 — ACLs** from a channel's Access Policy (`003.5`). Placeholder only.
- **Part 4 — Kafka users / credentials** (SASL/SCRAM). Blocked on the auth model
  (`003.2`). Placeholder only.
- **Part 5 — Quotas** (client/user/topic byte-rate and request-rate quotas).
  Placeholder only.

Each future part reuses the Part 1 transport, scoping, and reporting model; only
the resource-specific reconcile logic and the desired-state payload change.

---

## Architecture

```
                         Franz (control plane, source of truth)
                         ┌───────────────────────────────────────┐
                         │  async_channel · kafka_topic (desired) │
                         │  ResourceProviderService (gRPC)        │
                         │  TelemetryService (gRPC)               │
                         └───────┬───────────────────────▲────────┘
             WatchPartitionAssignments │                 │ PublishIndicatorSamples
                 (server stream)       │                 │  (client stream)
                                       ▼                 │
                         ┌───────────────────────────────────────┐
                         │           Gregor Samsa (one process)   │
                         │  scope = clusters whose franz.placement/* │
                         │          match my franz.selector/*     │
                         │  ┌───────────┐  ┌───────────┐          │
                         │  │ reconcile │  │  observe  │          │
                         │  └─────┬─────┘  └─────┬─────┘          │
                         └────────┼──────────────┼───────────────┘
                          AdminClient      AdminClient / metadata
                                  ▼              ▼
                    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
                    │ Kafka        │  │ Kafka        │  │ Kafka        │
                    │ cluster A    │  │ cluster B    │  │ cluster C …  │
                    └──────────────┘  └──────────────┘  └──────────────┘
                    (in this instance's scope)
```

### Key properties

- **Multi-cluster.** One Gregor Samsa process handles **many** Kafka clusters —
  every cluster in its scope. It holds one Kafka `AdminClient` per in-scope
  cluster, built from that cluster's `connection_strings`.
- **Label-scoped.** Which clusters are in scope is decided by a label selector,
  not by static per-cluster config and not by a `cluster_provider_agent`-style
  FK. See [§1.2](#12-scope--which-clusters-an-instance-handles).
- **Stateless.** Gregor Samsa persists nothing. All desired state comes from the
  stream; all durable outcome state lives in Franz's database.
- **Push-driven.** Franz streams the work. Gregor Samsa never polls Franz for
  pending work. (It *does* call Kafka's AdminClient to read actual topic/broker
  state — that is not polling Franz.)
- **Declarative / unidirectional.** Franz's desired state wins, always. On every
  notification Gregor Samsa reconciles the Kafka topic **to** the desired
  configuration, overwriting whatever was there. It never proposes changes back
  to Franz and never treats the Kafka side as authoritative for configuration.
- **One instance per scope.** Scopes must not overlap — a given cluster is
  handled by exactly one Gregor Samsa instance (see
  [Invariants](#invariants--open-questions)).

---

# Part 1 — creating-kafka-topic-from-async-channel

## 1.1 The flow

```
operator            Franz                              Gregor Samsa
   │ register agent ──▶│  mint token (shown once)
   │  type RESOURCE_PROVIDER
   │  labels: franz.selector/env=prod, franz.selector/org=payments
   │ ◀── token         │
   │                   │      ◀── WatchPartitionAssignments (stream, Bearer token)
   │                   │  compute scope = clusters matching this agent's selector
   │                   │  ─── assignment(SET, partition desired state) ──▶  (full set on open)
   │ create channel ──▶│  placement (003.7) creates kafka_topic rows, state=PENDING
   │  franz.affinity/* │  ─── assignment(SET, partition …) ──▶            reconcile:
   │                   │                                                   AdminClient.createTopics
   │                   │  ◀── ReportPartitionReconciliation(frn, generation, CREATED, applied_config) ──
   │                   │  kafka_topic: PENDING → READY, reconciled_generation = generation
   │ ◀── console: READY │
```

## 1.2 Scope — which clusters an instance handles

A Gregor Samsa instance advertises its scope as reserved **`franz.selector/*`**
labels on its own `Agent.labels` (set at registration or via `UpdateAgent`). A
Kafka Cluster describes its coordinates with reserved **`franz.placement/*`**
labels on `KafkaCluster.labels`.

**Match rule** — a cluster is *in scope* for an instance iff, for **every**
`franz.selector/<key> = <value>` on the agent, the cluster carries
`franz.placement/<key> = <value>`. Extra `franz.placement/*` keys on the cluster
are ignored. This is a plain conjunction of exact key/value pairs — **not** the
`003.1` selector-expression grammar (that grammar stays reserved for
channel→cluster affinity).

| Side | Label | Example |
|---|---|---|
| Gregor Samsa `Agent.labels` | `franz.selector/<key>` | `franz.selector/env=prod`, `franz.selector/org=payments` |
| Kafka Cluster `KafkaCluster.labels` | `franz.placement/<key>` | `franz.placement/env=prod`, `franz.placement/org=payments`, `franz.placement/region=us-east-1` |

- **Empty selector set matches _no_ clusters.** An agent with zero
  `franz.selector/*` labels is inert — a deliberate departure from the `003.1`
  "empty selector matches everything" rule, so a misconfigured instance cannot
  silently claim the whole fleet.
- **Franz evaluates the match**, server-side, because it holds both the agent's
  labels and every cluster's labels. The stream to a given agent carries only
  in-scope partitions. Gregor Samsa does not run selector logic itself.
- **Scope is dynamic.** If a cluster's `franz.placement/*` labels change, or the
  agent's `franz.selector/*` labels change, Franz recomputes and emits
  `SET` for newly in-scope partitions and `REMOVED` (scope-loss variant, see
  §1.4) for ones that left. Scope loss does **not** delete the Kafka topic — it
  just stops this instance from managing it.

This adds two prefixes to the `003.1` reserved-label table (see
[Franz-side changes](#franz-side-changes-required)).

## 1.3 Transport

- **`WatchPartitionAssignments` — server-streaming**, Gregor Samsa → Franz. One
  long-lived stream per instance. On open, Franz sends the **full current set**
  of in-scope async channel partitions (every one as `change = SET`); thereafter
  one message per change.
- **`ReportPartitionReconciliation` — unary**, Gregor Samsa → Franz. One call per
  partition whenever the reconcile outcome for that partition changes.
- **Reconnect = full resync.** On stream drop / restart / Franz downtime the
  agent reconnects with exponential backoff; Franz replays the entire in-scope
  set as `SET`. Gregor Samsa diffs against what it last applied and issues Kafka
  operations only where the topic actually diverges — a full resync of an
  unchanged fleet performs **zero** Kafka writes. There is **no periodic drift
  loop**: the control plane is the only thing that triggers a reconcile.

### Assignment message

One `PartitionAssignment`:

| Field | Meaning |
|---|---|
| `change` | `SET` (create or spec-changed — reconcile to this), `PAUSED` (owning channel paused — stop managing, leave the topic), `REMOVED` (partition deleted / re-sharded away — delete the topic, with safety checks) |
| `partition_frn` | The async channel partition's FRN — the reporting key. |
| `generation` | The desired-state generation token (`003.6`). Echoed back in the reconciliation report. |
| `async_channel` | Channel name, for logs / telemetry labels. |
| `topic_name` | The **physical** Kafka topic name to act on. |
| `kafka_cluster` | Target cluster name + `connection_strings` (which AdminClient to use). |
| `desired_config` | `materialized_configuration` — the full merged topic-config map to apply. |
| `partitions` | Desired partition count (increase-only). |
| `replication_factor` | Desired replication factor. |

`PAUSED` / `REMOVED` carry only `change`, `partition_frn`, `generation`,
`topic_name`, `kafka_cluster`.

## 1.4 Reconcile logic

Gregor Samsa processes assignments **sequentially per cluster** (an `AdminClient`
call at a time) to avoid racing itself on the same broker; different clusters
proceed in parallel.

### `SET` — create or alter

```
1. Connect via the target cluster's AdminClient (cached per cluster).
2. describeTopics(topic_name):
   a. Not found → createTopics(topic_name, partitions, replication_factor, desired_config).
   b. Found → compute the diff:
        - partition count: if desired > actual → createPartitions. If desired < actual → ERROR
          ("cannot reduce partition count from N to M"); never destructive.
        - replication factor: if it differs, ERROR for now (RF change needs a reassignment plan —
          out of scope; a future part).
        - config entries: incrementalAlterConfigs to SET every key in desired_config;
          keys Franz does not specify are left as-is (broker defaults / operator-set).
3. Read the applied state back (describeTopics + describeConfigs).
4. Report: outcome CREATED or UPDATED, generation, applied_config = the read-back state.
5. Any failure → report ERROR with a message and, if it was read, applied_config.
```

- **Idempotent.** A `SET` whose desired state already matches produces no Kafka
  write and still reports (outcome `UPDATED`, or `NOOP` — see §1.5) so Franz can
  confirm the current generation is satisfied.
- **`materialized_configuration` is frozen at placement** (`003.6`); a later edit
  to the cluster's `cluster_configuration` does not re-flow into existing
  partitions. Gregor Samsa applies exactly what the assignment carries.

### `REMOVED` — delete (with safety checks)

Before deleting, Gregor Samsa runs two **hard** safety checks with the
AdminClient. If either fails it does **not** delete and reports `ERROR`.

1. **Unconsumed data** — `listOffsets(EARLIEST)` vs `listOffsets(LATEST)` for
   every partition. If any partition has `earliest < latest`, the topic still
   holds data → fail.
2. **Committed consumer offsets** — `listConsumerGroups` →
   `listConsumerGroupOffsets` filtered to this topic. If any group has a
   committed offset on any partition → fail. Conservative on purpose: an idle
   group that once committed still counts.

```
1. describeTopics(topic_name):
   a. Not found → report DELETED (idempotent, no checks).
   b. Found → run check 1 and check 2.
       - either fails → report ERROR, message names which check and the specifics
         ("topic has unconsumed data (partition 0: earliest=0 latest=45201)";
          "topic has active consumers (groups: payments-worker, audit)").
       - both pass → deleteTopics(topic_name) → report DELETED.
```

An operator clears the blocker (drain the topic, delete the consumer-group
offsets) and Franz re-emits the `REMOVED` assignment (generation unchanged) on
the next reconcile trigger or on reconnect.

> Naive/forced deletion and drain-based migration are **not** in this ADR — that
> is `003.13`. This ADR only guards an ordinary channel/partition deletion.

### `PAUSED`

Stop managing the partition. Do not touch the Kafka topic. Drop it from the
in-memory desired set. No report (Franz already set `kafka_topic.state = PAUSED`
from the channel pause). A later `SET` (channel resumed) brings it back.

### Scope loss

When a cluster leaves this instance's scope, Franz emits `REMOVED` **with a
`reason = SCOPE_LOSS` marker**. Gregor Samsa drops the partition from its desired
set and does **nothing** to Kafka (contrast the delete path). Whichever instance
now matches the cluster picks the partition up as `SET` on its own stream and
reconciles it (a no-op if the topic is already correct).

## 1.5 Outcome reporting

`ReportPartitionReconciliation` — one call, keyed by the async channel partition:

| Field | Meaning |
|---|---|
| `partition_frn` | The async channel partition FRN (from the assignment). |
| `generation` | The generation from the assignment being satisfied. |
| `outcome` | `CREATED` · `UPDATED` · `NOOP` · `DELETED` · `ERROR` |
| `message` | Human-readable detail; required on `ERROR`. |
| `applied_config` | The topic state Gregor Samsa read back (partition count, RF, config map). Present on every non-`ERROR` outcome and on `ERROR` when a read succeeded. |

### Franz-side state mapping

Franz applies the report in one transaction against the `kafka_topic` row:

| `outcome` | `kafka_topic.state` | Other |
|---|---|---|
| `CREATED` / `UPDATED` / `NOOP` | → `READY` (from `PENDING`/`ERROR`) | `reconciled_generation = generation`; store `applied_config` |
| `DELETED` | → `DELETED` (terminal) | — |
| `ERROR` | → `ERROR` | store `message`; store `applied_config` if present |

- **Generation gating.** Franz accepts the report only if `generation` matches
  the row's **current** `generation`. A stale report (desired changed while the
  agent was working) is acknowledged but does **not** move the row to `READY`;
  Franz has already re-emitted `SET` with the new generation, and the agent will
  report again. This is the concrete use of the `003.6` "bare generation token …
  use in agent reporting deferred to the interaction ADR".
- `ERROR → PENDING` re-offer is **automatic** on the next reconcile trigger
  (channel/cluster/label change) or on the agent's next reconnect resync. There
  is no manual retry RPC and no Franz-side retry timer — reconnect resync is the
  backstop.
- Franz never distinguishes create from alter at the desired-state level; the
  agent decides based on whether the topic exists.

## 1.6 Error handling & backoff

| Condition | Gregor Samsa | Franz |
|---|---|---|
| Kafka op fails (transient — timeout, no leader) | report `ERROR`; the op retries on the next resync | row → `ERROR`; re-offers on next trigger/resync |
| Kafka op fails (permanent — RF decrease, incompatible existing topic) | report `ERROR` with a clear message; do not loop on it | row → `ERROR`; waits for an operator to change intent |
| Target cluster unreachable | report `ERROR` for every attempted partition on that cluster; back off that cluster's AdminClient | rows → `ERROR` |
| Franz stream unreachable | exponential backoff (5s → 120s cap), keep reconciling nothing new; **do not** mutate Kafka on guesswork | — |
| Deletion safety check fails | report `ERROR` with the structured reason | row → `ERROR` |

Franz tracks an `attempts` counter on the row but enforces no maximum.

## 1.7 Concurrency

- Sequential per cluster within one instance; clusters parallel.
- Instances for disjoint scopes are fully independent; Franz handles their
  concurrent reports safely (each touches only its own partitions' rows).
- A `PAUSED` partition is skipped entirely — Franz already excludes it, and
  Gregor Samsa guards defensively.

---

# Part 2 — telemetries-of-gregor-samsa

Gregor Samsa already holds an `AdminClient` to every in-scope cluster for Part 1.
It reuses those connections to observe structural facts and publishes them to
Franz as **pre-registered indicator samples** over the existing
`TelemetryService` — the same ingest path Odradek uses, a different producer.

## 2.1 What it observes

### Per async channel partition (topic-level)

| Indicator (proposed) | Unit | Source |
|---|---|---|
| `kafka.topic.state` | enum `provisioned` / `diverged` / `missing` | describeTopics/Configs vs desired |
| `kafka.topic.partitions` | count | describeTopics |
| `kafka.topic.replication_factor` | count | describeTopics |
| `kafka.topic.under_replicated_partitions` | count | describeTopics (ISR < RF) |
| `kafka.topic.config_drift` | bool | any desired key whose broker value ≠ desired |

`resource_frn` = the async channel partition FRN, `resource_entity` = the Kafka
topic entity.

### Per cluster (broker / topology-level)

| Indicator (proposed) | Unit | Source |
|---|---|---|
| `kafka.cluster.broker_count` | count | describeCluster |
| `kafka.cluster.online_broker_count` | count | describeCluster |
| `kafka.cluster.controller_id` | string | describeCluster |
| `kafka.cluster.total_partition_replicas` | count | metadata sum |
| `kafka.cluster.replicas_per_broker` | count, one sample per broker (`resource_frn` = broker) | metadata |
| `kafka.cluster.leaders_per_broker` | count, one sample per broker | metadata |
| `kafka.cluster.under_replicated_partitions` | count | metadata |
| `kafka.cluster.offline_partitions` | count | metadata |

`resource_frn` = the `KafkaCluster` FRN (or a `…/broker/<id>` sub-resource for
per-broker samples), `resource_entity` = the Kafka cluster entity.

The exact indicator names, units, and which are registered ship with the Franz
telemetry-ingest deliverable; the set above is this ADR's proposal.

## 2.2 Transport

- **`PublishIndicatorSamples` becomes client-streaming.** Gregor Samsa opens one
  long-lived client stream and pushes batches; Franz acks periodically. (Today it
  is unary in `telemetry.proto` — see [Franz-side changes](#franz-side-changes-required).)
- Samples are **append-only 30-day time series** (`003.8` / ADR-API-005), like
  every other indicator sample. No "current value" table; the newest sample is
  the current value.
- **Cadence** — a full sweep of every in-scope cluster + partition on a
  configurable interval (default 60s), plus an immediate sample for a partition
  right after it reconciles (so `kafka.topic.state` reflects a fresh
  create/alter without waiting for the next sweep).
- Auth: the same registration bearer token. `Agent.type` is organisational only
  (`003.9`) — a `RESOURCE_PROVIDER` agent calling `TelemetryService` is allowed;
  the interceptor just needs to cover the service (see below).

## 2.3 Relationship to Odradek

Both feed `TelemetryService`; they observe **different things** and do not
overlap:

| | Odradek (`105`) | Gregor Samsa (Part 2) |
|---|---|---|
| Method | synthetic clients — actually produces & consumes | structural — reads AdminClient metadata |
| Answers | "can a client meet its SLO on this topic right now?" (latency, throughput, availability) | "does the fleet's shape match what Franz declared?" (brokers, replicas, leaders, ISR, config drift) |
| Needs a running topic | yes | no (reports `missing` if absent) |
| Agent type | `TELEMETRY_AGENT` | `RESOURCE_PROVIDER` |

Odradek stays exactly as specified. Gregor Samsa does not run synthetic traffic
and does not replace any Odradek indicator.

---

## Franz-side changes required

This ADR is a proposal; landing it needs the following in Franz (each also noted
against `003.x` where it touches a `ready` spec — those edits need sign-off
separately):

### Proto (`franz/api/franz/v1/`)

1. **New `agent_resource_provider.proto`** — `ResourceProviderService` with
   `WatchPartitionAssignments` (server stream) + `ReportPartitionReconciliation`
   (unary); messages `PartitionAssignment`, `PartitionReconciliationReport`. gRPC
   only, no REST gateway. Mirrors `agent_cluster_provider.proto`.
2. **`telemetry.proto`** — make `PublishIndicatorSamples` client-streaming
   (or add `StreamIndicatorSamples`).
3. `kafka.proto` — no change to `KafkaTopicService` (operator surface unchanged).

### Persistence (`migrations/V1__init.sql`)

4. `kafka_topic` — add `reconciled_generation bigint` (nullable; the last
   generation an agent confirmed) and `last_reconcile_message text`. `state`
   CHECK already covers the needed values.
5. No new table for reconcile history in v1 — the append-only event log is
   `003.11` OQ4, still unstarted; `reconciled_generation` + `state` + telemetry
   are enough for the first cut.

### Domain / usecases

6. `core/domain/agent` — parse & validate reserved `franz.selector/*` labels.
7. `core/domain/cluster` — document `franz.placement/*` as reserved (no schema
   change; they live in `labels`).
8. **Scope resolver** — given an agent's `franz.selector/*` and all clusters'
   `franz.placement/*`, produce the in-scope cluster set; recomputed on agent
   label change and on cluster label change.
9. `core/usecases/resourceprovider` — `InitialPartitionAssignments(ctx)` (scoped
   full set), `ReportReconciliation(ctx, …)` (generation-gated → `topic.SetState`
   + `reconciled_generation`).
10. A **work-change publisher** — like `clusters.Service` publishing cluster
    assignment deltas, `channels.Service` / placement must publish partition
    assignment deltas (SET/PAUSED/REMOVED) to connected in-scope agents. The
    `streamhub` hub needs a second channel type (or a generic payload).

### Interceptors

11. `adapters/in/grpcgateway/agentauth.go` — the bearer-token interceptor is
    hard-scoped to `/franz.v1.ClusterProviderService/`. Widen it to also cover
    `/franz.v1.ResourceProviderService/` and `/franz.v1.TelemetryService/`.

### Placement (deliverable 12)

12. Placement already creates `kafka_topic` rows in `PENDING` (ADR-API-009). It
    must additionally **notify** the scope's agent (via change #10) when a row is
    created / re-placed / removed.

---

## Invariants & open questions

**Invariants**

- An in-scope cluster is handled by **exactly one** Gregor Samsa instance.
  Operators must keep `franz.selector/*` sets disjoint across instances.
- Gregor Samsa never writes to Franz's desired state and never creates a
  `kafka_topic` row — placement does.
- Franz's `materialized_configuration` is authoritative for config; Gregor Samsa
  applies it verbatim and reports what the broker accepted.
- Deletion is guarded: a partition delete never destroys a topic that still holds
  data or has committed consumers.

**Open questions**

1. **Overlapping scopes.** Should Franz *reject* an agent whose
   `franz.selector/*` would make a cluster match two live agents, or just warn
   and pick one deterministically? (Leaning: warn + refuse the second stream for
   the contested clusters.)
2. **`franz.placement/*` vs. free-form labels.** Channel→cluster affinity
   (`003.7`) matches against *free-form* cluster labels. Agent→cluster scoping
   here uses a dedicated `franz.placement/*` prefix. Is the extra prefix worth it,
   or should agent scoping also match free-form labels via the `003.1` selector
   grammar? (This ADR takes the explicit-prefix route per the design decision;
   revisit if it proves redundant.)
3. **Replication-factor changes.** Currently `ERROR`. A future part needs a
   partition-reassignment plan (and ties into `003.13`).
4. **Config keys Franz doesn't specify.** Left untouched today. Should Gregor
   Samsa ever *reset* a broker-side override that Franz didn't ask for, to keep
   topics pristine? (Leaning: no — least surprise.)
5. **Telemetry cadence & volume.** 60s full sweeps across a large fleet is a lot
   of samples; may need per-indicator intervals or change-only publishing.
6. **Per-broker sample identity.** Whether a broker is a first-class FRN
   sub-resource or just a label on a cluster-scoped sample.
7. **Instance ↔ agent-registration cardinality.** One `Agent` row per instance,
   or one `Agent` row shared by a horizontally-scaled Gregor Samsa deployment
   (several processes, same token, same scope, coordinating by cluster)?
