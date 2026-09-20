# 006 DRAFT — structured-AST (custom DSL) worked examples

> **DRAFT.** One of four candidate condition engines. Overview, shared context,
> action catalogue and the decision live in
> **[dsl-comparison.md](./dsl-comparison.md)** — read that first.
>
> **Verdict: not recommended.** This is the build-it-ourselves baseline the other
> three are measured against. Its one real advantage — a console condition
> builder — is achievable without it.

No expression parser. Conditions are structured data with explicit `all` / `any`
/ `not` nodes, so the rule document is pure YAML the whole way down.

Node forms used below:

```yaml
{fn: <host-fn>, of: <indicator>, op: <cmp>, value: <literal|governance.x>}
{fn: <host-fn>, of: <indicator>, window: <dur>, op: <cmp>, value: …}
{field: <path>, op: <cmp>, value: …}
{field: <path>}                       # truthiness
{all: [...]}   {any: [...]}   {not: {...}}
```


> Every `governance.*` identifier used below is backed by a
> `franz.governance/*` label on the matched cluster — the complete list, with
> families and a worked set, is in
> [dsl-comparison.md](./dsl-comparison.md#governance-labels-used-by-the-eight-examples).
> `${governance.x}` inside an action arg is interpolated at evaluation time; a
> missing or malformed label skips that rule instance rather than defaulting.

---

## 1.a — replicas per broker

Rebalance if skewed, else add a broker if there is headroom, else taint.

```yaml
rule: cluster-replica-pressure
scope:
  entity:   KAFKA_CLUSTER
  selector: "env=prod"
  descend:  {kind: broker}
guard:
  cooldown: 30m
  max_fires_per_day: 4
  skip_if_operation_in_flight: true

when:
  all:
    - {fn: max, of: replicas_per_broker, op: ">=", value: governance.max_replicas}

branches:
  # skewed — moving replicas to the quieter brokers helps
  - when:
      all:
        - {fn: stdev_pct, of: replicas_per_broker, op: ">", value: governance.replica_stdev}
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  # evenly loaded but at the cap — buy capacity, then spread onto it
  - when:
      all:
        - {field: cluster.brokers, op: "<", value: governance.max_brokers}
        - not: {field: cluster.tainted}
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  # out of headroom — stop new topics landing here
  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}
```

Cluster labels this rule reads:

```yaml
franz.governance/max-replicas:  "18000"
franz.governance/replica-stdev: "10%"
franz.governance/max-brokers:   "6"
```

## 1.b — leaders per broker

*"The same logic for leaders per broker."* Two identifiers change — but each
condition is three times the text of its expression equivalent.

```yaml
rule: cluster-leader-pressure
scope:
  entity:   KAFKA_CLUSTER
  selector: "env=prod"
  descend:  {kind: broker}
guard:
  cooldown: 30m
  max_fires_per_day: 4
  skip_if_operation_in_flight: true

when:
  all:
    - {fn: max, of: leaders_per_broker, op: ">=", value: governance.max_leaders}

branches:
  - when:
      all:
        - {fn: stdev_pct, of: leaders_per_broker, op: ">", value: governance.leader_stdev}
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - when:
      all:
        - {field: cluster.brokers, op: "<", value: governance.max_brokers}
        - not: {field: cluster.tainted}
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}
```


Cluster labels this rule reads:

```yaml
franz.governance/max-leaders:  "9000"
franz.governance/leader-stdev: "10%"
franz.governance/max-brokers:  "6"
```

## 1.c — disk used per broker

Four branches: rebalance if skewed, else grow the disks, else add a broker, else
taint.

```yaml
rule: cluster-disk-pressure
scope:
  entity:   KAFKA_CLUSTER
  selector: "env=prod"
  descend:  {kind: broker}
guard:
  cooldown: 1h
  max_fires_per_day: 2
  skip_if_operation_in_flight: true

when:
  all:
    - {fn: max, of: disk_used_pct, op: ">=", value: governance.disk_high_watermark}

branches:
  # skewed — some brokers have room, moving data helps
  - when:
      all:
        - {fn: stdev_pct, of: disk_used_pct, op: ">", value: governance.disk_stdev}
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  # uniformly full — rebalancing cannot help, grow the disks.
  # UPDATE_FIELD because disk_size has no INCREASE_FIELD_BY (action catalogue).
  - when:
      all:
        - {field: cluster.disk_size, op: "<", value: governance.max_disk}
    then:
      - {kind: UPDATE_FIELD, args: ["disk_size", "${governance.next_disk_size}"]}

  # disks capped, brokers are not — add capacity and spread onto it
  - when:
      all:
        - {field: cluster.brokers, op: "<", value: governance.max_brokers}
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "disk:no-creation"]}
```

```yaml
franz.governance/disk-high-watermark: "70%"
franz.governance/disk-stdev:          "10%"
franz.governance/max-disk:            "2Ti"
franz.governance/next-disk-size:      "1Ti"
franz.governance/max-brokers:         "6"
```

## 1.d — migrate topics off a saturated cluster

Uses the **proposed** `MIGRATE_KAFKA_TOPIC` action. Today this is only reachable
as `ADD_LABEL franz.taint drain`, which the migration flow picks up.

```yaml
rule: topic-evacuate-saturated-cluster
scope:
  entity:   KAFKA_TOPIC
  selector: "env=prod"
guard:
  cooldown: 2h
  max_fires_per_day: 1
  skip_if_operation_in_flight: true

when:
  all:
    - {field: cluster.tainted}
    - {fn: max, of: disk_used_pct, op: ">=", value: governance.disk_critical}
    - {field: cluster.brokers, op: ">=", value: governance.max_brokers}

branches:
  - otherwise:
    then:
      - {kind: MIGRATE_KAFKA_TOPIC, args: ["${governance.overflow_cluster}"]}
```

The cluster-wide variant, on a `KAFKA_CLUSTER` scope:

```yaml
rule: cluster-drain-saturated
scope: {entity: KAFKA_CLUSTER, selector: "env=prod"}
guard: {cooldown: 6h, max_fires_per_day: 1, skip_if_operation_in_flight: true}

when:
  all:
    - {field: cluster.tainted}
    - {fn: max, of: disk_used_pct, op: ">=", value: governance.disk_critical}

branches:
  - otherwise:
    then:
      - {kind: MIGRATE_CLUSTER, args: ["governance-drain"]}
```

## 2.a — over-retained topic → tiered storage

7d retention but lag never reached 1d in 90d → 1d local, 6d remote, 7d total.

```yaml
rule: topic-retention-rightsizing
scope:
  entity:   KAFKA_TOPIC
  selector: "env=prod"
guard:
  cooldown: 7d
  max_fires_per_day: 1
  skip_if_operation_in_flight: true

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

Note `field: 'topic.config["retention.ms"]'` — the *pure data* property leaks
here. A keyed path has to be smuggled into a string, which is a small expression
language with no parser and no error messages. See the tradeoffs.

**Blocked:** `indicator_sample` prunes at 30 days, so a 90-day window is
currently unanswerable from stored data (open question 1).

## 2.b — single-partition topic at throughput

```yaml
rule: topic-partition-growth-throughput
scope:
  entity:   KAFKA_TOPIC
  selector: "env=prod"
guard:
  cooldown: 6h
  max_fires_per_day: 2
  skip_if_operation_in_flight: true

when:
  all:
    - {field: topic.partitions, op: "==", value: 1}
    - {fn: avg_over, of: throughput_in, window: "1h",
       op: ">=", value: governance.partition_throughput_ceiling}

branches:
  - otherwise:
    then:
      - {kind: INCREASE_FIELD_BY, args: ["partitions", "1"]}
```

## 2.c — oversized replicas, retention already tuned

```yaml
rule: topic-partition-growth-size
scope:
  entity:   KAFKA_TOPIC
  selector: "env=prod"
guard:
  cooldown: 6h
  max_fires_per_day: 2
  skip_if_operation_in_flight: true

when:
  all:
    - {fn: max, of: replica_size, op: ">", value: governance.max_replica_size}
    - {fn: avg_over, of: throughput_in, window: "1h",
       op: ">=", value: governance.partition_throughput_floor}
    - {field: 'topic.config["local.retention.ms"]', op: "<=", value: "1d"}

branches:
  - otherwise:
    then:
      - {kind: INCREASE_FIELD_BY, args: ["partitions", "1"]}
```

The third clause encodes *"retention is already tuned"* — without it the rule
would add partitions to a topic whose real problem is over-retention, which 2.a
fixes more cheaply.

## 2.d — under-replicated topic → set replication factor

`replication_factor` takes `UPDATE_FIELD` only (absolute), which suits it.

```yaml
rule: topic-replication-floor
scope:
  entity:   KAFKA_TOPIC
  selector: "env=prod"
guard:
  cooldown: 1h
  max_fires_per_day: 2
  skip_if_operation_in_flight: true

when:
  all:
    - {field: topic.replication_factor, op: "<", value: governance.target_rf}
    - {field: cluster.brokers, op: ">=", value: governance.target_rf}

branches:
  - otherwise:
    then:
      - {kind: UPDATE_FIELD, args: ["replication_factor", "${governance.target_rf}"]}
```

The second clause matters: RF must not exceed the broker count. The whitelist
already enforces that, but the rule should not attempt it in the first place.

---

## Where a mixed condition gets awkward

None of the eight examples needs `any:`, because each branch is a conjunction.
The moment one does — *"disk is high **and** (skew is high **or** disks are not
yet capped)"* — nesting shows its cost:

```yaml
when:
  all:
    - {fn: max, of: disk_used_pct, op: ">=", value: governance.disk_high_watermark}
    - any:
        - {fn: stdev_pct, of: disk_used_pct, op: ">", value: governance.disk_stdev}
        - not: {field: cluster.disk_size, op: ">=", value: governance.max_disk}
```

Against the same thing in expr:

```
max(disk_used_pct) >= governance.disk_high_watermark
  and (stdev_pct(disk_used_pct) > governance.disk_stdev
       or cluster.disk_size < governance.max_disk)
```

Eight lines of nested YAML against three of prose, for identical semantics.

## Cost

**+0 MB**, **0 new modules**. Sandboxing is inherent — the AST cannot express
unbounded work, so there is nothing to bound.

That is the whole case for this option, and it is a real one. Every other cost
moves from the dependency graph into code you write and maintain.

## Tradeoffs

**For** — no dependency, no parser, no string escaping; the console can render a
**condition builder** (dropdowns for `fn`, `op`, `field`) rather than a text box,
which is a genuine advantage for non-programmer admins; trivially
machine-editable and diffable; conditions validate structurally at `CreateRule`
with precise field paths in the error.

**Against** — verbose, and nested `all`/`any`/`not` is materially harder to read
than `a and (b or not c)`; every operator, type coercion, comparison rule and
error message is yours to write and test; `topic.config["retention.ms"]` already
smuggles an expression into a string, so the pure-data property leaks as soon as
paths get interesting; and the honest end state is a slow reimplementation of
`expr` with worse diagnostics.

**The idea worth keeping.** The condition-builder UI does not require this
engine. A console form can *generate* `expr` strings, giving the same
click-to-build experience while the stored rule remains an expression. That is
the recommendation in [dsl-comparison.md](./dsl-comparison.md#recommendation).
