# 006 DRAFT — `expr-lang/expr` worked examples

> **DRAFT.** One of four candidate condition engines. Overview, shared context,
> action catalogue and the decision live in
> **[dsl-comparison.md](./dsl-comparison.md)** — read that first.
>
> ⭐ **This is the recommended option.**

`and` / `or` / `not` are keywords. Conditions are single-line expressions over the
[shared context](./dsl-comparison.md#shared-context); `max` / `stdev_pct` /
`max_over` / `avg_over` are Go host functions.


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

when: 'max(replicas_per_broker) >= governance.max_replicas'

branches:
  # skewed — moving replicas to the quieter brokers helps
  - when: 'stdev_pct(replicas_per_broker) > governance.replica_stdev'
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  # evenly loaded but at the cap — buy capacity, then spread onto it
  - when: 'cluster.brokers < governance.max_brokers and not cluster.tainted'
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

*"The same logic for leaders per broker."* Two identifiers change.

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

when: 'max(leaders_per_broker) >= governance.max_leaders'

branches:
  - when: 'stdev_pct(leaders_per_broker) > governance.leader_stdev'
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - when: 'cluster.brokers < governance.max_brokers and not cluster.tainted'
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

when: 'max(disk_used_pct) >= governance.disk_high_watermark'

branches:
  # skewed — some brokers have room, moving data helps
  - when: 'stdev_pct(disk_used_pct) > governance.disk_stdev'
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  # uniformly full — rebalancing cannot help, grow the disks.
  # UPDATE_FIELD because disk_size has no INCREASE_FIELD_BY (see the
  # action catalogue); governance.next_disk_size is an operator-set label.
  - when: 'cluster.disk_size < governance.max_disk'
    then:
      - {kind: UPDATE_FIELD, args: ["disk_size", "${governance.next_disk_size}"]}

  # disks capped, brokers are not — add capacity and spread onto it
  - when: 'cluster.brokers < governance.max_brokers'
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

when: >
  cluster.tainted
  and max(disk_used_pct) >= governance.disk_critical
  and cluster.brokers >= governance.max_brokers

branches:
  - otherwise:
    then:
      - {kind: MIGRATE_KAFKA_TOPIC, args: ["${governance.overflow_cluster}"]}
```

The cluster-wide variant, on a `KAFKA_CLUSTER` scope:

```yaml
rule: cluster-drain-saturated
scope:   {entity: KAFKA_CLUSTER, selector: "env=prod"}
guard:   {cooldown: 6h, max_fires_per_day: 1, skip_if_operation_in_flight: true}
when:    'cluster.tainted and max(disk_used_pct) >= governance.disk_critical'
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

when: >
  topic.partitions == 1
  and avg_over(throughput_in, "1h") >= governance.partition_throughput_ceiling

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

when: >
  max(replica_size) > governance.max_replica_size
  and avg_over(throughput_in, "1h") >= governance.partition_throughput_floor
  and topic.config["local.retention.ms"] <= duration("1d")

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

when: >
  topic.replication_factor < governance.target_rf
  and cluster.brokers >= governance.target_rf

branches:
  - otherwise:
    then:
      - {kind: UPDATE_FIELD, args: ["replication_factor", "${governance.target_rf}"]}
```

The second clause matters: RF must not exceed the broker count. The whitelist
already enforces that, but the rule should not attempt it in the first place.

---

## Cost

**+3.05 MB**, **1 new module** for franz, **no transitive dependencies**
(v1.17.8). Sandboxing: `MaxNodes`, `DisableBuiltin`, `WithContext`. Full table in
[dsl-comparison.md](./dsl-comparison.md#measured-cost).

## Tradeoffs

**For** — negligible cost; `and`/`or`/`not` read like the sentence an operator
would say; branch order stays in the rule document; compile-time type errors with
column positions give `DryRunPolicy` a real error surface for free; already the
Go-infrastructure default for user-authored expressions (Argo Workflows,
CrowdSec, Aqua).

Verified: custom `max()` / `stdev_pct()` inject cleanly, and the type checker
rejects mismatches before evaluation:

```
invalid operation: >= (mismatched types float64 and string) (1:15)
 | max(replicas) >= "gold"
```

**Against** — not a standard, so "it's expr-lang" is not self-documenting to
outsiders; smaller ecosystem than CEL; no static cost bound, only a node-count
cap.
