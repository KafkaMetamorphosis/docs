# 006 — Condition-expression engine comparison

> **DRAFT.** Not the ADR. Picks one thing — the engine that evaluates a rule's
> conditions — before `006-governance/README.md` is written. No code written.

## Layout

**Per example, all four engines side by side.** The rule envelope (`scope`,
`guard`, `branches`, `then`) is **identical across `expr-lang`, `cel` and
`custom-dsl`** — only the condition string differs. So the envelope is shown
once per example and the engines are compared on the one line that actually
differs. `opa-rego` has a different shape and gets [its own section](#opa-rego-is-a-different-shape).

Earlier drafts repeated the full YAML four times per example; that was 4×
redundant and made comparison harder, not easier.

## Locked

| Q1a | Aggregates are **expressions** | Q5 | Guard rails are `franz.governance/*` **cluster labels** |
|---|---|---|---|
| **Q1b** | Scope = **label-select parent, descend** to sub-resources | **Q7** | Cooldown + in-flight guard + budget **mandatory** |
| **Q3** | **High** stdev triggers rebalance | **—** | Aggregate vocabulary is a **closed Go-defined set** |
| **Q4** | Rebalance = **label signal** now; Operation with ADR 007 | | |

## Shared context

```
cluster.brokers  cluster.disk_size  cluster.state  cluster.tainted
topic.partitions  topic.replication_factor  topic.config[<key>]
budget.<name>                    ← franz.governance/<name> label on the cluster
<indicator-name>                 ← sample set for the descended resources
```

Host functions (closed set, Go): `max min avg sum count stdev stdev_pct`,
`max_over(ind, window)`, `avg_over(ind, window)`.

**Scope invariants** — one evaluation per matched resource (each with its own
cooldown/budget state); aggregates never cross the parent, so `max()` is over
*that* cluster's brokers, never the fleet. Brokers carry no labels (no broker
table; they exist only as FRN sub-resources), which is why `descend` exists.

For a **topic** rule, `budget.*` resolves from the topic's **cluster** — topics
carry no budget labels.

---

## Action catalogue

From `governance/whitelist.go` — the implemented `(entity, field, kinds)` matrix.
**These are the real field names**; nothing below is invented.

| Entity | Field | Kinds |
|---|---|---|
| `KAFKA_TOPIC` | `partitions` | `UPDATE_FIELD`, `INCREASE_FIELD_BY` |
| `KAFKA_TOPIC` | `replication_factor` | `UPDATE_FIELD` |
| `KAFKA_TOPIC` | `topic_configuration.<key>` | `UPDATE_FIELD`, `INCREASE_FIELD_BY`, `DECREASE_FIELD_BY` |
| `KAFKA_TOPIC` | `consumption` | `UPDATE_FIELD` (`ENABLED`/`DISABLED`) |
| `KAFKA_TOPIC` | labels | `ADD_LABEL`, `REMOVE_LABEL` |
| `ASYNC_CHANNEL` | `channel_partitions` | `INCREASE_FIELD_BY`, `DECREASE_FIELD_BY` |
| `ASYNC_CHANNEL` | `state` | `SET_STATUS` |
| `ASYNC_CHANNEL` | labels | `ADD_LABEL`, `REMOVE_LABEL` |
| `KAFKA_CLUSTER` | `state` | `SET_STATUS` |
| `KAFKA_CLUSTER` | `cluster_configuration.<key>` | `UPDATE_FIELD` |
| `KAFKA_CLUSTER` | `brokers` | `UPDATE_FIELD`, `INCREASE_FIELD_BY`, `DECREASE_FIELD_BY` |
| `KAFKA_CLUSTER` | `disk_size` | **`UPDATE_FIELD` only** |
| `KAFKA_CLUSTER` | labels | `ADD_LABEL`, `REMOVE_LABEL` |

### Three findings that affect 006

1. **`brokers` already supports a direct set** — `UPDATE_FIELD` as well as
   `INCREASE_FIELD_BY`. No new action needed.
2. **`disk_size` has no `INCREASE_FIELD_BY`.** It is a size-hint *string*, so
   "grow by 100Gi" is not expressible today — only an absolute
   `UPDATE_FIELD`. Example 1.c below is written against that limit. **006 should
   decide** whether `disk_size` gains `INCREASE_FIELD_BY` or stays absolute.
3. **Migration is not a governance action.** There is no `MIGRATE` kind.
   Governance reaches migration only *indirectly*, by writing
   `franz.affinity/*` on a channel or `franz.taint=drain` on a cluster, which
   the placement/migration flow then resolves (`003.7`, `003.13`).
   The direct RPCs are `MigrateKafkaTopic{kafka_topic, target_cluster}` and
   `MigrateCluster{kafka_cluster, reason}` (`api/franz/v1/migration.proto`).

### Proposed for 006 (do not exist yet)

| Kind | args | Maps to |
|---|---|---|
| `MIGRATE_KAFKA_TOPIC` | `[target_cluster]` | `MigrateKafkaTopic` RPC |
| `MIGRATE_CLUSTER` | `[reason]` | `MigrateCluster` RPC |

Both are **operations, not declared-state writes**, so they carry the same
caveat as rebalance (Q4): they break `003.8`'s "actions only change declared
state" invariant and need the in-flight guard. Example 1.d shows the shape;
whether 006 adds them or keeps routing through affinity labels is open.

---

## Rule envelope

Identical for `expr-lang`, `cel` and `custom-dsl`. Only `when:` differs.

```yaml
rule: <name>
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 30m, max_fires_per_day: 4, skip_if_operation_in_flight: true}
when:  <gate condition>
branches:                      # first match wins
  - when: <condition>
    then: [<actions>]
  - otherwise:
    then: [<actions>]
```

---

## 1.a — replicas per broker

Rebalance if skewed, else add a broker if budget allows, else taint.

```yaml
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 30m, max_fires_per_day: 4, skip_if_operation_in_flight: true}
branches:
  - when: <B1>  then: [{kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}]
  - when: <B2>  then: [{kind: INCREASE_FIELD_BY, args: ["brokers", "1"]},
                       {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}]
  - otherwise:  then: [{kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}]
```

Labels: `franz.governance/max-replicas: "18000"`, `replica-stdev: "10%"`, `max-brokers: "6"`

| | gate + B1 + B2 |
|---|---|
| **expr-lang** | `max(replicas_per_broker) >= budget.max_replicas`<br>`stdev_pct(replicas_per_broker) > budget.replica_stdev`<br>`cluster.brokers < budget.max_brokers and not cluster.tainted` |
| **cel** | `max(replicas_per_broker) >= budget.max_replicas`<br>`stdev_pct(replicas_per_broker) > budget.replica_stdev`<br>`cluster.brokers < budget.max_brokers && !cluster.tainted` |
| **custom-dsl** | `{fn: max, of: replicas_per_broker, op: ">=", value: budget.max_replicas}`<br>`{fn: stdev_pct, of: replicas_per_broker, op: ">", value: budget.replica_stdev}`<br>`{all: [{field: cluster.brokers, op: "<", value: budget.max_brokers}, {not: {field: cluster.tainted}}]}` |

## 1.b — leaders per broker

*"Same logic for leaders."* Envelope and actions identical to 1.a.

| | gate + B1 |
|---|---|
| **expr-lang** | `max(leaders_per_broker) >= budget.max_leaders`<br>`stdev_pct(leaders_per_broker) > budget.leader_stdev` |
| **cel** | `max(leaders_per_broker) >= budget.max_leaders`<br>`stdev_pct(leaders_per_broker) > budget.leader_stdev` |
| **custom-dsl** | `{fn: max, of: leaders_per_broker, op: ">=", value: budget.max_leaders}`<br>`{fn: stdev_pct, of: leaders_per_broker, op: ">", value: budget.leader_stdev}` |

Two identifiers changed. Note what Rego needs for the same thing, below.

## 1.c — disk used per broker

```yaml
guard: {cooldown: 1h, max_fires_per_day: 2, skip_if_operation_in_flight: true}
branches:
  - when: <B1 skewed>     then: [{kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}]
  - when: <B2 disk room>  then: [{kind: UPDATE_FIELD, args: ["disk_size", "budget.next_disk_size"]}]
  - when: <B3 broker room> then: [{kind: INCREASE_FIELD_BY, args: ["brokers", "1"]},
                                  {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}]
  - otherwise:            then: [{kind: ADD_LABEL, args: ["franz.taint", "disk:no-creation"]}]
```

B2 uses `UPDATE_FIELD` with an absolute target, because `disk_size` has no
`INCREASE_FIELD_BY` (finding 2). `budget.next_disk_size` is a label the operator
sets — clumsy, and the reason 006 should revisit this.

| | gate + B1 + B2 + B3 |
|---|---|
| **expr-lang** | `max(disk_used_pct) >= budget.disk_high_watermark`<br>`stdev_pct(disk_used_pct) > budget.disk_stdev`<br>`cluster.disk_size < budget.max_disk`<br>`cluster.brokers < budget.max_brokers` |
| **cel** | same as expr-lang (no `and`/`or` needed in these four) |
| **custom-dsl** | `{fn: max, of: disk_used_pct, op: ">=", value: budget.disk_high_watermark}`<br>`{fn: stdev_pct, of: disk_used_pct, op: ">", value: budget.disk_stdev}`<br>`{field: cluster.disk_size, op: "<", value: budget.max_disk}`<br>`{field: cluster.brokers, op: "<", value: budget.max_brokers}` |

## 1.d — migrate topics off a saturated cluster *(proposed actions)*

Cluster is tainted and out of headroom → move its topics elsewhere.

```yaml
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 2h, max_fires_per_day: 1, skip_if_operation_in_flight: true}
branches:
  - otherwise:
    then: [{kind: MIGRATE_KAFKA_TOPIC, args: ["budget.overflow_cluster"]}]
```

| | when |
|---|---|
| **expr-lang** | `cluster.tainted and max(disk_used_pct) >= budget.disk_critical and cluster.brokers >= budget.max_brokers` |
| **cel** | `cluster.tainted && max(disk_used_pct) >= budget.disk_critical && cluster.brokers >= budget.max_brokers` |
| **custom-dsl** | `{all: [{field: cluster.tainted}, {fn: max, of: disk_used_pct, op: ">=", value: budget.disk_critical}, {field: cluster.brokers, op: ">=", value: budget.max_brokers}]}` |

The cluster-wide variant swaps in `{kind: MIGRATE_CLUSTER, args: ["governance-drain"]}`
on a `KAFKA_CLUSTER` scope. **Today this is expressible only as
`ADD_LABEL franz.taint drain`**, which the migration flow picks up — the direct
kinds are a 006 proposal.

## 2.a — over-retained topic → tiered storage

7d retention but lag never reached 1d in 90d → 1d local, 6d remote, 7d total.

```yaml
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 7d, max_fires_per_day: 1, skip_if_operation_in_flight: true}
branches:
  - otherwise:
    then:
      - {kind: UPDATE_FIELD, args: ["topic_configuration.remote.storage.enable", "true"]}
      - {kind: UPDATE_FIELD, args: ["topic_configuration.local.retention.ms", "86400000"]}
      - {kind: UPDATE_FIELD, args: ["topic_configuration.retention.ms", "604800000"]}
```

| | when |
|---|---|
| **expr-lang** | `topic.config["retention.ms"] > duration("1d") and max_over(consumer_lag, "90d") < duration("1d")` |
| **cel** | `topic.config["retention.ms"] > duration("24h") && max_over(consumer_lag, duration("2160h")) < duration("24h")` |
| **custom-dsl** | `{all: [{field: 'topic.config["retention.ms"]', op: ">", value: "1d"}, {fn: max_over, of: consumer_lag, window: "90d", op: "<", value: "1d"}]}` |

CEL duration literals are hour-based — 90d is `"2160h"`. A host function taking
`"90d"` would fix it. **Blocked**: `indicator_sample` prunes at 30 days, so a
90-day window is unanswerable from stored data today.

## 2.b — single-partition topic at throughput

```yaml
branches:
  - otherwise:  then: [{kind: INCREASE_FIELD_BY, args: ["partitions", "1"]}]
```

| | when |
|---|---|
| **expr-lang** | `topic.partitions == 1 and avg_over(throughput_in, "1h") >= budget.partition_throughput_ceiling` |
| **cel** | `topic.partitions == 1 && avg_over(throughput_in, duration("1h")) >= budget.partition_throughput_ceiling` |
| **custom-dsl** | `{all: [{field: topic.partitions, op: "==", value: 1}, {fn: avg_over, of: throughput_in, window: "1h", op: ">=", value: budget.partition_throughput_ceiling}]}` |

## 2.c — oversized replicas, retention already tuned

Same action as 2.b. The retention clause stops this firing on a topic whose real
problem is over-retention — 2.a fixes that more cheaply.

| | when |
|---|---|
| **expr-lang** | `max(replica_size) > budget.max_replica_size and avg_over(throughput_in, "1h") >= budget.partition_throughput_floor and topic.config["local.retention.ms"] <= duration("1d")` |
| **cel** | `max(replica_size) > budget.max_replica_size && avg_over(throughput_in, duration("1h")) >= budget.partition_throughput_floor && topic.config["local.retention.ms"] <= duration("24h")` |
| **custom-dsl** | `{all: [{fn: max, of: replica_size, op: ">", value: budget.max_replica_size}, {fn: avg_over, of: throughput_in, window: "1h", op: ">=", value: budget.partition_throughput_floor}, {field: 'topic.config["local.retention.ms"]', op: "<=", value: "1d"}]}` |

## 2.d — under-replicated topic → set replication factor

`replication_factor` takes `UPDATE_FIELD` only (absolute), which suits it.

```yaml
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 1h, max_fires_per_day: 2, skip_if_operation_in_flight: true}
branches:
  - otherwise:
    then: [{kind: UPDATE_FIELD, args: ["replication_factor", "budget.target_rf"]}]
```

| | when |
|---|---|
| **expr-lang** | `topic.replication_factor < budget.target_rf and cluster.brokers >= budget.target_rf` |
| **cel** | `topic.replication_factor < budget.target_rf && cluster.brokers >= budget.target_rf` |
| **custom-dsl** | `{all: [{field: topic.replication_factor, op: "<", value: budget.target_rf}, {field: cluster.brokers, op: ">=", value: budget.target_rf}]}` |

The second clause matters: RF must not exceed the broker count, which the
whitelist already enforces — the rule should not attempt it in the first place.

---

## `opa-rego` is a different shape

Rego computes a **decision document** that Franz then maps to actions. Rule
bodies are implicit-AND and **unordered — there is no first-match-wins**, so each
branch must hand-write the negation of its predecessors.

### 1.a

```rego
package franz.governance.cluster_replica_pressure
import rego.v1

pressure if { max(input.replicas_per_broker) >= input.budget.max_replicas }
skewed   if { stdev_pct(input.replicas_per_broker) > input.budget.replica_stdev }

decision := {"action": "rebalance"} if { pressure; skewed }

decision := {"action": "add_broker"} if {
    pressure
    not skewed
    input.cluster.brokers < input.budget.max_brokers
    not input.cluster.tainted
}

default decision := {"action": "taint"}
```

```yaml
policy: franz/governance/cluster_replica_pressure.rego
actions:
  rebalance:  [{kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}]
  add_broker: [{kind: INCREASE_FIELD_BY, args: ["brokers", "1"]},
               {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}]
  taint:      [{kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}]
```

**1.b** is this file again with `replicas`→`leaders`, *plus* the duplicated
negation, *plus* a second action-mapping block — against two changed identifiers
for every other engine.

### 1.c — the negation chain grows with each branch

```rego
decision := {"action": "grow_disk"} if {
    pressure; not skewed
    input.cluster.disk_size < input.budget.max_disk
}
decision := {"action": "add_broker"} if {
    pressure; not skewed
    not input.cluster.disk_size < input.budget.max_disk    # ← double negative
    input.cluster.brokers < input.budget.max_brokers
}
default decision := {"action": "taint"}
```

### 2.b — flat conjunctions read well

```rego
decision := {"action": "add_partition"} if {
    input.topic.partitions == 1
    avg_over(input.throughput_in, "1h") >= input.budget.partition_throughput_ceiling
}
default decision := {"action": "none"}
```

Rego is genuinely good at 2.a–2.d (flat ANDs). It is 1.a–1.c, the branching
rules, where it costs.

---

## Measured cost

Built and ran each engine against a representative condition. franz today:
**28 MB**, 139 modules.

| | binary Δ | new modules for franz | transitive | sandbox |
|---|---|---|---|---|
| `custom-dsl` | **+0** | **0** | none | inherent |
| **`expr-lang`** v1.17.8 | **+3.05 MB** | **1** | **none** | `MaxNodes`, `WithContext` |
| `cel-go` v0.32.0 | +9.29 MB | 3 | ANTLR, x/exp | **`CostLimit`** (static) |
| `opa-rego` v1.20.2 | +27.2 MB | **78** | incl. embedded KV store | query budgets |

- expr rejected a type error at **compile** time with a column marker:
  `invalid operation: >= (mismatched types float64 and string) (1:15)`
- CEL's standalone `+9.29 MB` overstates it: franz already has **15 of CEL's 18**
  deps, including `cel.dev/expr` via gRPC. Module path is now `cel.dev/cel-go`.
- OPA's 78 modules include `badger` (embedded KV), `ristretto`, **two**
  Levenshtein implementations, and `go-md2man`. First policy written for this doc
  failed with `eval_conflict_error` until `import rego.v1` was added.

---

## Recommendation: ⭐ `expr-lang/expr`

1. **Negligible cost** — 1 module, no transitive deps, +3 MB on 28 MB.
2. **Reads like the rule was described** — `stdev_pct(disk_used_pct) >
   budget.disk_stdev and cluster.brokers < budget.max_brokers`.
3. **Branch order stays in the rule document**, which is what makes 1.a a single
   readable artifact.
4. **Compile-time type errors with positions** give `DryRunPolicy` a real error
   surface for free.
5. Already the Go-infra default for user-authored expressions (Argo, CrowdSec, Aqua).

**Runner-up `cel`** — pick it if cross-org standardisation beats 6 MB, or if
`CostLimit`'s static bound is required. The tables above are near-identical, so
**switching later is mechanical.**

**Against `opa-rego`** — +27 MB and 78 modules to compare broker counts, and no
first-match ordering, so every branch restates its predecessors' negation. That
is the duplication that ruled out the flat-policy shape to begin with. Reconsider
only as a sidecar, for a team already standardised on OPA.

**Against `custom-dsl`** — verbose, and every operator and error message is yours
to write. Its one real advantage survives without it: the console can generate
expr strings from a form, giving a condition-builder UI either way.

---

## Open

1. **90-day windows vs. 30-day pruning** (2.a) — raise retention, roll up, or shorten.
2. **Who publishes** `disk_used_pct`, `throughput_in`, `consumer_lag`, `replica_size` — none exist; Gregor Samsa reads metadata, not JMX.
3. **`disk_size` needs `INCREASE_FIELD_BY`**, or 1.c stays absolute-only.
4. **Migration as a first-class action** (`MIGRATE_KAFKA_TOPIC` / `MIGRATE_CLUSTER`) vs. routing through `franz.affinity/*` and `franz.taint=drain`.
5. **Operations break the declared-state invariant** — rebalance and both migrate kinds are async operations, not field writes (Q4, ADR 007).
6. **`budget.*` typing** — labels are strings; `"10%"`, `"18000"`, `"100Gi"` parse differently. Does a malformed budget label disable the rule or fail loudly?
7. **First deliverable scope** — cluster rules only, or cluster and topic together.
