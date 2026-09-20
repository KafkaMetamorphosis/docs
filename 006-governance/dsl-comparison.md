# 006 — Condition-expression engine comparison

> **Status: DRAFT / working document.** This is not the ADR. It exists to pick
> *one thing* — the engine that evaluates a governance rule's conditions — before
> `006-governance/README.md` is written. Everything here is illustrative syntax,
> not a committed contract. No code has been written.

## What this document is for

ADR 006 extends governance from "one indicator crosses one limit" (`003.8`) to
indicator-driven remediation of clusters and topics. The worked examples below —
the ones that motivated 006 — need boolean composition (`and` / `or` / `not`),
aggregates over sets of brokers, and ordered branches. `003.8`'s `Policy` can
express none of that.

Four engines could provide the condition language. This document encodes **the
same six rules in all four** so the choice is made against real syntax rather
than adjectives.

## How to read it

One `##` section per engine, each containing **all six worked examples** for that
engine, then its measured cost and tradeoffs.

That layout was chosen over interleaving by example (all four engines' version of
1.a, then all four of 1.b, …) because the engines differ in *shape*, not just
spelling: Rego inverts the model entirely, and `custom-dsl` is structured data
rather than text. Reading one engine end-to-end shows whether its shape holds up
across six rules; interleaving would fragment exactly the thing being judged.

For at-a-glance syntax feel, [one condition in all four](#the-same-condition-in-all-four)
appears first.

---

## Decisions already locked

These are settled and are applied identically in every example below. They are
recorded here so this document is self-contained; the ADR will restate them.

| # | Decision |
|---|---|
| Q1a | **Aggregates are expressions**, not per-statistic indicators |
| Q1b | **Scope = label-select the parent, then descend** to its sub-resources |
| Q3 | **High** standard deviation triggers a rebalance (skew is what rebalancing fixes) |
| Q4 | Rebalance is a **label signal now** (`franz.governance/needs-rebalance`); a tracked Operation lands with ADR 007 |
| Q5 | Guard rails are **cluster labels** (`franz.governance/*`); promote to a typed field only if string parsing hurts |
| Q7 | Cooldown + in-flight guard + action budget are **mandatory**, not optional |
| — | The aggregate vocabulary is a **closed set defined in Go**; the DSL only composes it |

### Still open, and visible in the examples

- **Windowed conditions.** `2.a` needs "lag never reached 1d in 90 days", but
  `indicator_sample` is pruned at **30 days**, so a 90-day window is currently
  unanswerable from stored data. The examples write `max_over(…, 90d)` to show
  the shape; the retention/rollup decision is a separate question.
- **Indicators that do not exist yet.** `disk_used_pct`, `throughput_in`,
  `consumer_lag` and `replica_size` are not in `005 §2.1`. Who publishes them is
  an open question (Gregor Samsa reads metadata, not JMX).

---

## Shared evaluation context

Identical for every engine. Only the syntax that composes it differs.

### Scope

```yaml
scope:
  entity:   KAFKA_CLUSTER        # the thing that carries labels
  selector: "env=prod"           # the existing 003.1 selector grammar, unchanged
  descend:  {kind: broker}       # fan out to that cluster's broker sub-resources
```

Two invariants:

1. **One evaluation per matched resource.** `env=prod` matching 12 clusters
   produces 12 independent evaluations, each with its own cooldown and budget
   state.
2. **Aggregates never cross the parent.** Inside one evaluation `descend` yields
   only *that* cluster's brokers, so `max()` is the max over `local-1`'s brokers,
   never over the fleet.

Brokers carry no labels — there is no broker table; a broker exists only as an FRN
sub-resource (`frn:default:kafka-cluster:local-1/broker/1`). `descend` is what
makes them addressable without inventing a broker registry.

### Variables

| Name | Meaning |
|---|---|
| `cluster.brokers`, `cluster.disk_size`, `cluster.state` | declared fields of the matched cluster |
| `cluster.tainted` | whether `franz.taint` is set |
| `topic.partitions`, `topic.replication_factor`, `topic.config[...]` | declared fields of a matched topic |
| `budget.<name>` | parsed from the cluster's `franz.governance/<name>` label |
| `<indicator-name>` | the sample set for the descended resources, newest value each |
| `now` | evaluation time |

`budget.max_replicas` reads `franz.governance/max-replicas` off the cluster.
**For a topic rule, `budget.*` resolves from the topic's cluster** — topics do not
carry their own budget labels.

### Host functions (closed set, defined in Go)

```
max(xs)  min(xs)  avg(xs)  sum(xs)  count(xs)  stdev(xs)  stdev_pct(xs)
max_over(indicator, window)   avg_over(indicator, window)
```

No engine has `max`/`stdev_pct` built in — every option registers these as host
functions. Adding `p99` is a Go change under all four.

### Guard block

Mandatory on every rule (Q7), engine-independent:

```yaml
guard:
  cooldown: 30m                      # no re-fire within this window
  max_fires_per_day: 4               # per matched resource
  skip_if_operation_in_flight: true  # never stack a rebalance on a rebalance
```

---

## The six worked examples

Stated once in prose; each engine section encodes all six.

| # | Rule |
|---|---|
| **1.a** | Replicas per broker hit the cap → rebalance if skewed, else add a broker if budget allows, else taint |
| **1.b** | Same logic for **leaders** per broker |
| **1.c** | Disk used per broker hits the watermark → rebalance if skewed, else grow disks, else add a broker, else taint |
| **2.a** | Topic has 7d retention but lag never reached 1d in 90d → cut local retention to 1d, keep 7d total via tiered storage |
| **2.b** | Topic at 9 MB/s on a single partition → add a partition |
| **2.c** | Topic replicas oversized, throughput high, retention already tuned → add a partition |

`1.b` is deliberately included: it is `1.a` with two identifiers changed. How much
text an engine needs to say "the same, for leaders" is a direct readability
measure.

---

## The same condition in all four

Gate for 1.a — *"the busiest broker is at or over the replica cap"*:

| Engine | |
|---|---|
| `expr-lang` | `max(replicas_per_broker) >= budget.max_replicas` |
| `cel` | `max(replicas_per_broker) >= budget.max_replicas` |
| `opa-rego` | `max(input.replicas_per_broker) >= input.budget.max_replicas` |
| `custom-dsl` | `{fn: max, of: replicas_per_broker, op: ">=", value: budget.max_replicas}` |

Branch 2 of 1.c — *"disks are not yet at their cap **and** the cluster is not tainted"*:

| Engine | |
|---|---|
| `expr-lang` | `cluster.disk_size < budget.max_disk and not cluster.tainted` |
| `cel` | `cluster.disk_size < budget.max_disk && !cluster.tainted` |
| `opa-rego` | two lines in a rule body (implicit AND) + `not` |
| `custom-dsl` | `{all: [{field: …, op: "<", …}, {not: {field: cluster.tainted}}]}` |

---

## Option A — `expr-lang/expr`

Go expression language, embedded. `and` / `or` / `not` as keywords.

### 1.a — replicas per broker

```yaml
rule: cluster-replica-pressure
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 30m, max_fires_per_day: 4, skip_if_operation_in_flight: true}

when: 'max(replicas_per_broker) >= budget.max_replicas'

branches:
  - when: 'stdev_pct(replicas_per_broker) > budget.replica_stdev'
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - when: 'cluster.brokers < budget.max_brokers and not cluster.tainted'
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}
```

Required cluster labels:

```yaml
franz.governance/max-replicas:  "18000"
franz.governance/replica-stdev: "10%"
franz.governance/max-brokers:   "6"
```

### 1.b — leaders per broker

```yaml
rule: cluster-leader-pressure
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 30m, max_fires_per_day: 4, skip_if_operation_in_flight: true}

when: 'max(leaders_per_broker) >= budget.max_leaders'

branches:
  - when: 'stdev_pct(leaders_per_broker) > budget.leader_stdev'
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - when: 'cluster.brokers < budget.max_brokers and not cluster.tainted'
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}
```

Two identifiers changed from 1.a.

### 1.c — disk used per broker

```yaml
rule: cluster-disk-pressure
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 1h, max_fires_per_day: 2, skip_if_operation_in_flight: true}

when: 'max(disk_used_pct) >= budget.disk_high_watermark'

branches:
  # skewed — some brokers have room, moving data helps
  - when: 'stdev_pct(disk_used_pct) > budget.disk_stdev'
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  # uniformly full — rebalancing cannot help, grow the disks
  - when: 'cluster.disk_size < budget.max_disk'
    then:
      - {kind: INCREASE_FIELD_BY, args: ["disk_size", "budget.disk_step"]}

  # disks capped, brokers are not — add capacity and spread onto it
  - when: 'cluster.brokers < budget.max_brokers'
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "disk:no-creation"]}
```

### 2.a — over-retained topic → tiered storage

```yaml
rule: topic-retention-rightsizing
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 7d, max_fires_per_day: 1, skip_if_operation_in_flight: true}

when: >
  topic.config["retention.ms"] > duration("1d")
  and max_over(consumer_lag, "90d") < duration("1d")

branches:
  - otherwise:
    then:
      - {kind: UPDATE_FIELD, args: ["topic_configuration.remote.storage.enable", "true"]}
      - {kind: UPDATE_FIELD, args: ["topic_configuration.local.retention.ms", "86400000"]}
      - {kind: UPDATE_FIELD, args: ["topic_configuration.retention.ms", "604800000"]}
```

Total retention stays 7d; 1d local, the remaining 6d in tiered storage.
**Depends on the unresolved 90-day window question.**

### 2.b — single-partition topic at throughput

```yaml
rule: topic-partition-growth-throughput
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 6h, max_fires_per_day: 2, skip_if_operation_in_flight: true}

when: >
  topic.partitions == 1
  and avg_over(throughput_in, "1h") >= budget.partition_throughput_ceiling

branches:
  - otherwise:
    then:
      - {kind: INCREASE_FIELD_BY, args: ["partitions", "1"]}
```

### 2.c — oversized replicas with tuned retention

```yaml
rule: topic-partition-growth-size
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 6h, max_fires_per_day: 2, skip_if_operation_in_flight: true}

when: >
  max(replica_size) > budget.max_replica_size
  and avg_over(throughput_in, "1h") >= budget.partition_throughput_floor
  and topic.config["local.retention.ms"] <= duration("1d")

branches:
  - otherwise:
    then:
      - {kind: INCREASE_FIELD_BY, args: ["partitions", "1"]}
```

The third clause encodes "retention is already tuned" — without it the rule would
add partitions to a topic whose real problem is over-retention, which 2.a fixes
more cheaply.

### Measured cost

| | |
|---|---|
| Version tested | `v1.17.8` |
| Standalone binary | 5.40 MB (empty Go baseline: 2.35 MB) → **+3.05 MB** |
| **New modules for franz** | **1** (zero transitive dependencies) |
| Sandboxing | `MaxNodes`, `DisableBuiltin`, `WithContext` |

Verified working: custom `max()` / `stdev_pct()` host functions inject cleanly,
and the type checker rejects mismatches at **compile** time with a column marker:

```
invalid operation: >= (mismatched types float64 and string) (1:15)
 | max(replicas) >= "gold"
```

### Tradeoffs

**For** — negligible cost; `and`/`or`/`not` read like the sentence an operator
would say; compile-time type errors give `DryRunPolicy` a real error surface for
free; the de-facto Go infra choice for user-authored expressions (Argo Workflows,
CrowdSec, Aqua all embed it).

**Against** — not a standard, so "it's expr-lang" is not self-documenting to
outsiders; smaller ecosystem than CEL; no static cost bound (node count only).

---

## Option B — `cel-go` (Common Expression Language)

Google's expression standard. Kubernetes uses it for admission policies.

### 1.a — replicas per broker

```yaml
rule: cluster-replica-pressure
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 30m, max_fires_per_day: 4, skip_if_operation_in_flight: true}

when: 'max(replicas_per_broker) >= budget.max_replicas'

branches:
  - when: 'stdev_pct(replicas_per_broker) > budget.replica_stdev'
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - when: 'cluster.brokers < budget.max_brokers && !cluster.tainted'
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}
```

### 1.b — leaders per broker

```yaml
rule: cluster-leader-pressure
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 30m, max_fires_per_day: 4, skip_if_operation_in_flight: true}

when: 'max(leaders_per_broker) >= budget.max_leaders'

branches:
  - when: 'stdev_pct(leaders_per_broker) > budget.leader_stdev'
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - when: 'cluster.brokers < budget.max_brokers && !cluster.tainted'
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}
```

### 1.c — disk used per broker

```yaml
rule: cluster-disk-pressure
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 1h, max_fires_per_day: 2, skip_if_operation_in_flight: true}

when: 'max(disk_used_pct) >= budget.disk_high_watermark'

branches:
  - when: 'stdev_pct(disk_used_pct) > budget.disk_stdev'
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - when: 'cluster.disk_size < budget.max_disk'
    then:
      - {kind: INCREASE_FIELD_BY, args: ["disk_size", "budget.disk_step"]}

  - when: 'cluster.brokers < budget.max_brokers'
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "disk:no-creation"]}
```

### 2.a — over-retained topic → tiered storage

```yaml
rule: topic-retention-rightsizing
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 7d, max_fires_per_day: 1, skip_if_operation_in_flight: true}

when: >
  topic.config["retention.ms"] > duration("24h")
  && max_over(consumer_lag, duration("2160h")) < duration("24h")

branches:
  - otherwise:
    then:
      - {kind: UPDATE_FIELD, args: ["topic_configuration.remote.storage.enable", "true"]}
      - {kind: UPDATE_FIELD, args: ["topic_configuration.local.retention.ms", "86400000"]}
      - {kind: UPDATE_FIELD, args: ["topic_configuration.retention.ms", "604800000"]}
```

CEL has a native `duration` type, but its literals are hour-based — 90 days is
`duration("2160h")`, which is markedly less readable than `"90d"`. A host
function could accept `"90d"` instead.

### 2.b — single-partition topic at throughput

```yaml
rule: topic-partition-growth-throughput
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 6h, max_fires_per_day: 2, skip_if_operation_in_flight: true}

when: >
  topic.partitions == 1
  && avg_over(throughput_in, duration("1h")) >= budget.partition_throughput_ceiling

branches:
  - otherwise:
    then:
      - {kind: INCREASE_FIELD_BY, args: ["partitions", "1"]}
```

### 2.c — oversized replicas with tuned retention

```yaml
rule: topic-partition-growth-size
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 6h, max_fires_per_day: 2, skip_if_operation_in_flight: true}

when: >
  max(replica_size) > budget.max_replica_size
  && avg_over(throughput_in, duration("1h")) >= budget.partition_throughput_floor
  && topic.config["local.retention.ms"] <= duration("24h")

branches:
  - otherwise:
    then:
      - {kind: INCREASE_FIELD_BY, args: ["partitions", "1"]}
```

### Measured cost

| | |
|---|---|
| Version tested | `v0.32.0` (module path is now `cel.dev/cel-go`, **not** `github.com/google/cel-go`) |
| Standalone binary | 11.64 MB → **+9.29 MB** |
| **New modules for franz** | **3** — `cel.dev/cel-go`, `antlr4-go/antlr/v4`, `golang.org/x/exp` |
| Sandboxing | **`CostLimit`** (static pre-evaluation cost bound), `InterruptCheckFrequency` |

The standalone `+9.29 MB` overstates the cost in franz: franz already has **15 of
CEL's 18 dependencies**, including `cel.dev/expr` itself (pulled in transitively
via gRPC/genproto), protobuf and grpc.

Verified working: `replicas.all(r, r < 4000.0) && brokers < 6` compiles and
evaluates. CEL has native list macros (`all`, `exists`, `filter`, `map`) that the
other text engines lack.

### Tradeoffs

**For** — a genuine standard, so "conditions are CEL" is documentation you do not
write; `CostLimit` is the strongest safety guarantee of any option; native list
macros; large ecosystem; the obvious choice if these expressions ever need to be
evaluated outside Go.

**Against** — ~3× expr's binary cost; `&&`/`||`/`!` are less readable to
non-programmers than `and`/`or`/`not`; hour-based duration literals are awkward
for multi-day windows; pulls in the ANTLR runtime.

---

## Option C — `opa-rego` (Open Policy Agent)

A declarative policy language with its own evaluation model. Shape differs
fundamentally: Rego computes a **decision document**, which Franz then interprets,
rather than evaluating branches in order.

### 1.a — replicas per broker

```rego
package franz.governance.cluster_replica_pressure
import rego.v1

# gate
pressure if {
    max(input.replicas_per_broker) >= input.budget.max_replicas
}

decision := {"action": "rebalance"} if {
    pressure
    stdev_pct(input.replicas_per_broker) > input.budget.replica_stdev
}

decision := {"action": "add_broker"} if {
    pressure
    not stdev_pct(input.replicas_per_broker) > input.budget.replica_stdev
    input.cluster.brokers < input.budget.max_brokers
    not input.cluster.tainted
}

default decision := {"action": "taint"}
```

Franz maps `decision.action` onto the action list:

```yaml
rule: cluster-replica-pressure
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 30m, max_fires_per_day: 4, skip_if_operation_in_flight: true}
policy: franz/governance/cluster_replica_pressure.rego
actions:
  rebalance:  [{kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}]
  add_broker: [{kind: INCREASE_FIELD_BY, args: ["brokers", "1"]},
               {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}]
  taint:      [{kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}]
```

**Note the negation.** Rego rule bodies are implicit-AND and are *unordered* —
there is no first-match-wins. Mutual exclusion must be hand-written: the
`add_broker` rule restates `not stdev_pct(…) > …`. Two complete rules that both
succeed is an `eval_conflict_error` at runtime, not a precedence decision.

### 1.b — leaders per broker

```rego
package franz.governance.cluster_leader_pressure
import rego.v1

pressure if {
    max(input.leaders_per_broker) >= input.budget.max_leaders
}

decision := {"action": "rebalance"} if {
    pressure
    stdev_pct(input.leaders_per_broker) > input.budget.leader_stdev
}

decision := {"action": "add_broker"} if {
    pressure
    not stdev_pct(input.leaders_per_broker) > input.budget.leader_stdev
    input.cluster.brokers < input.budget.max_brokers
    not input.cluster.tainted
}

default decision := {"action": "taint"}
```

Plus the same action-mapping YAML again.

### 1.c — disk used per broker

```rego
package franz.governance.cluster_disk_pressure
import rego.v1

pressure if {
    max(input.disk_used_pct) >= input.budget.disk_high_watermark
}

skewed if {
    stdev_pct(input.disk_used_pct) > input.budget.disk_stdev
}

decision := {"action": "rebalance"} if {
    pressure
    skewed
}

decision := {"action": "grow_disk"} if {
    pressure
    not skewed
    input.cluster.disk_size < input.budget.max_disk
}

decision := {"action": "add_broker"} if {
    pressure
    not skewed
    not input.cluster.disk_size < input.budget.max_disk
    input.cluster.brokers < input.budget.max_brokers
}

default decision := {"action": "taint"}
```

The fourth branch's negation chain is the cost of having no branch ordering.
Extracting `skewed` as a named rule helps; the `not … < …` double negatives do
not.

### 2.a — over-retained topic → tiered storage

```rego
package franz.governance.topic_retention_rightsizing
import rego.v1

decision := {"action": "tier"} if {
    input.topic.config["retention.ms"] > 86400000
    max_over(input.consumer_lag, "90d") < 86400000
}

default decision := {"action": "none"}
```

### 2.b — single-partition topic at throughput

```rego
package franz.governance.topic_partition_growth_throughput
import rego.v1

decision := {"action": "add_partition"} if {
    input.topic.partitions == 1
    avg_over(input.throughput_in, "1h") >= input.budget.partition_throughput_ceiling
}

default decision := {"action": "none"}
```

### 2.c — oversized replicas with tuned retention

```rego
package franz.governance.topic_partition_growth_size
import rego.v1

decision := {"action": "add_partition"} if {
    max(input.replica_size) > input.budget.max_replica_size
    avg_over(input.throughput_in, "1h") >= input.budget.partition_throughput_floor
    input.topic.config["local.retention.ms"] <= 86400000
}

default decision := {"action": "none"}
```

2.b and 2.c read well — Rego's implicit-AND suits flat conjunctions. It is the
branching rules (1.a–1.c) where it costs the most.

### Measured cost

| | |
|---|---|
| Version tested | `v1.20.2` |
| Standalone binary | 29.52 MB → **+27.2 MB** |
| **New modules for franz** | **78** |
| Sandboxing | query budgets, bundle signing, full policy-management tooling |

For scale: franz's whole binary is **28 MB** today. Embedding OPA roughly doubles
it.

What those 78 modules include: `badger` (an embedded key-value store), `ristretto`
(a cache), **two** separate Levenshtein implementations, `secp256k1` crypto, and
`go-md2man` (a man-page generator). That is a policy *server* vendored into a
control plane.

**A real operational finding:** the first 10-line policy written for this document
failed with `eval_conflict_error: complete rules must not produce multiple
outputs`. The fix was adding `import rego.v1` — Rego has a v0/v1 syntax split that
an author hits immediately and that no type checker warns about.

### Tradeoffs

**For** — genuinely powerful; a mature policy ecosystem with bundle distribution,
versioning and testing tools; if governance policy ever needs to be authored by a
security team that already uses OPA, this is their language.

**Against** — the cost is disproportionate (+27 MB, 78 modules, an embedded KV
store to compare broker counts); Rego is a logic language admins must learn;
**no first-match-wins**, so every branch hand-writes the negation of its
predecessors — precisely the duplication that ruled out the flat-policy rule shape
in the first place; and it inverts the model, moving branch precedence out of the
rule document and into Rego semantics.

Better suited to a policy *sidecar* than an embedded condition evaluator.

---

## Option D — `custom-dsl` (structured AST)

No expression parser. Conditions are structured data with explicit `all` / `any` /
`not` nodes.

### 1.a — replicas per broker

```yaml
rule: cluster-replica-pressure
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 30m, max_fires_per_day: 4, skip_if_operation_in_flight: true}

when:
  all:
    - {fn: max, of: replicas_per_broker, op: ">=", value: budget.max_replicas}

branches:
  - when:
      all:
        - {fn: stdev_pct, of: replicas_per_broker, op: ">", value: budget.replica_stdev}
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - when:
      all:
        - {field: cluster.brokers, op: "<", value: budget.max_brokers}
        - not: {field: cluster.tainted, op: "==", value: true}
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}
```

### 1.b — leaders per broker

```yaml
rule: cluster-leader-pressure
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 30m, max_fires_per_day: 4, skip_if_operation_in_flight: true}

when:
  all:
    - {fn: max, of: leaders_per_broker, op: ">=", value: budget.max_leaders}

branches:
  - when:
      all:
        - {fn: stdev_pct, of: leaders_per_broker, op: ">", value: budget.leader_stdev}
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - when:
      all:
        - {field: cluster.brokers, op: "<", value: budget.max_brokers}
        - not: {field: cluster.tainted, op: "==", value: true}
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}
```

### 1.c — disk used per broker

```yaml
rule: cluster-disk-pressure
scope: {entity: KAFKA_CLUSTER, selector: "env=prod", descend: {kind: broker}}
guard: {cooldown: 1h, max_fires_per_day: 2, skip_if_operation_in_flight: true}

when:
  all:
    - {fn: max, of: disk_used_pct, op: ">=", value: budget.disk_high_watermark}

branches:
  - when:
      all:
        - {fn: stdev_pct, of: disk_used_pct, op: ">", value: budget.disk_stdev}
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - when:
      all:
        - {field: cluster.disk_size, op: "<", value: budget.max_disk}
    then:
      - {kind: INCREASE_FIELD_BY, args: ["disk_size", "budget.disk_step"]}

  - when:
      all:
        - {field: cluster.brokers, op: "<", value: budget.max_brokers}
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "disk:no-creation"]}
```

### 2.a — over-retained topic → tiered storage

```yaml
rule: topic-retention-rightsizing
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 7d, max_fires_per_day: 1, skip_if_operation_in_flight: true}

when:
  all:
    - {field: 'topic.config["retention.ms"]', op: ">", value: "1d"}
    - {fn: max_over, of: consumer_lag, window: "90d", op: "<", value: "1d"}

branches:
  - otherwise:
    then:
      - {kind: UPDATE_FIELD, args: ["topic_configuration.remote.storage.enable", "true"]}
      - {kind: UPDATE_FIELD, args: ["topic_configuration.local.retention.ms", "86400000"]}
      - {kind: UPDATE_FIELD, args: ["topic_configuration.retention.ms", "604800000"]}
```

### 2.b — single-partition topic at throughput

```yaml
rule: topic-partition-growth-throughput
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 6h, max_fires_per_day: 2, skip_if_operation_in_flight: true}

when:
  all:
    - {field: topic.partitions, op: "==", value: 1}
    - {fn: avg_over, of: throughput_in, window: "1h",
       op: ">=", value: budget.partition_throughput_ceiling}

branches:
  - otherwise:
    then:
      - {kind: INCREASE_FIELD_BY, args: ["partitions", "1"]}
```

### 2.c — oversized replicas with tuned retention

```yaml
rule: topic-partition-growth-size
scope: {entity: KAFKA_TOPIC, selector: "env=prod"}
guard: {cooldown: 6h, max_fires_per_day: 2, skip_if_operation_in_flight: true}

when:
  all:
    - {fn: max, of: replica_size, op: ">", value: budget.max_replica_size}
    - {fn: avg_over, of: throughput_in, window: "1h",
       op: ">=", value: budget.partition_throughput_floor}
    - {field: 'topic.config["local.retention.ms"]', op: "<=", value: "1d"}

branches:
  - otherwise:
    then:
      - {kind: INCREASE_FIELD_BY, args: ["partitions", "1"]}
```

### Measured cost

| | |
|---|---|
| Binary | **+0 MB** |
| New modules | **0** |
| Sandboxing | inherent — the AST cannot express unbounded work |

### Tradeoffs

**For** — no dependency, no parser, no string escaping; the console can render a
*condition builder* (dropdowns for `fn`, `op`, `field`) rather than a text box,
which is a genuine UX advantage for non-programmer admins; trivially
machine-editable and diffable; conditions validate structurally at
`CreateRule` with precise field paths in the error.

**Against** — verbose; nested `all`/`any`/`not` in YAML is noticeably harder to
read than `a and (b or not c)`; every operator, type coercion and error message is
yours to write and test; and the honest end state is that you slowly reimplement
`expr` with worse diagnostics. Note that `topic.config["retention.ms"]` already
smuggles an expression into a string field — the pure-data property leaks the
moment paths get interesting.

---

## Side-by-side

| | `expr-lang` | `cel` | `opa-rego` | `custom-dsl` |
|---|---|---|---|---|
| Binary delta (standalone) | **+3.05 MB** | +9.29 MB | +27.2 MB | **+0** |
| New modules for franz | **1** | 3 | **78** | **0** |
| Transitive deps | **none** | ANTLR, x/exp | 78 | none |
| AND / OR / NOT | `and` `or` `not` | `&&` `\|\|` `!` | implicit AND, `not` | `all` `any` `not` |
| First-match branches | ✅ in rule data | ✅ in rule data | ❌ hand-written negation | ✅ in rule data |
| Compile-time type check | ✅ with column | ✅ | partial | structural only |
| Static cost bound | ❌ (node count) | ✅ `CostLimit` | ✅ | inherent |
| An industry standard | ❌ | ✅ | ✅ | ❌ |
| Console condition-builder UI | hard | hard | hard | ✅ natural |
| 1.b restated as "same but leaders" | 2 identifiers | 2 identifiers | 2 identifiers + duplicated negation | 2 identifiers, verbose |

---

## Recommendation

### ⭐ `expr-lang/expr`

1. **Cost is negligible** — 1 new module, zero transitive dependencies, +3 MB on a
   28 MB binary. It is the only option whose dependency footprint does not
   require a justification.
2. **It reads like the rules were described.** `stdev_pct(disk_used_pct) >
   budget.disk_stdev and cluster.brokers < budget.max_brokers` is the sentence,
   not an encoding of it.
3. **Branch ordering stays in the rule document**, which is what makes 1.a's
   "rebalance, else add a broker, else taint" a single readable artifact.
4. **Compile-time type errors with positions** give `DryRunPolicy` a real error
   surface at no cost.
5. It is already the Go-infrastructure default for this exact job.

### Runner-up: `cel`

Choose it over expr if cross-organisation standardisation matters more than 6 MB,
or if `CostLimit`'s static bound is a hard requirement. Both are defensible; the
examples above are near-identical, so **switching later is a mechanical
migration** — one reason not to agonise.

### Not recommended: `opa-rego`

+27 MB and 78 modules — including an embedded KV store — to compare broker counts,
and it does not provide the first-match branch ordering that motivated the rule
shape. Reconsider only if governance policy must be authored by a team already
standardised on OPA, in which case run it as a sidecar rather than embedding it.

### Not recommended (but keep one idea): `custom-dsl`

The structured-AST approach loses on readability and on the volume of engine code
that must be written and tested. **Its console condition-builder advantage is
real, though** — and is achievable with expr by having the console generate
expression strings from a form, so the idea survives without the engine.

---

## Open questions this document does not settle

1. **Windowed conditions vs. 30-day retention.** `2.a` needs 90 days; samples are
   pruned at 30. Raise retention, roll up daily aggregates, or shorten the window.
2. **Who publishes the new indicators** — `disk_used_pct`, `throughput_in`,
   `consumer_lag`, `replica_size` do not exist. Gregor Samsa reads metadata, not
   JMX.
3. **Scope of the first 006 deliverable** — cluster rules only, or cluster and
   topic together.
4. **Rebalance as a tracked Operation** — deferred to ADR 007; until then `1.a`,
   `1.b` and `1.c` emit a label that nothing consumes.
5. **`budget.*` typing.** Labels are strings; `"10%"`, `"18000"` and `"100Gi"`
   parse differently. The parse rule (and its failure mode — does a malformed
   budget label disable the rule, or fail the evaluation loudly?) needs deciding.
