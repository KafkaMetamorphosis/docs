# 006 DRAFT — `cel-go` worked examples

> **DRAFT.** One of four candidate condition engines. Overview, shared context,
> action catalogue and the decision live in
> **[dsl-comparison.md](./dsl-comparison.md)** — read that first.
>
> **Verdict: runner-up.** Compare this file against
> [dsl-expr-lang.md](./dsl-expr-lang.md) — they are near-identical, which is why
> switching between them later would be mechanical.

Common Expression Language (Google; the engine behind Kubernetes admission
policies). `&&` / `||` / `!` instead of words. `max` / `stdev_pct` / `max_over` /
`avg_over` are registered Go host functions; CEL supplies `duration` natively.


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
  - when: 'cluster.brokers < governance.max_brokers && !cluster.tainted'
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

  - when: 'cluster.brokers < governance.max_brokers && !cluster.tainted'
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
  && max(disk_used_pct) >= governance.disk_critical
  && cluster.brokers >= governance.max_brokers

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
when:    'cluster.tainted && max(disk_used_pct) >= governance.disk_critical'
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
  topic.config["retention.ms"] > duration("24h")
  && max_over(consumer_lag, duration("2160h")) < duration("24h")

branches:
  - otherwise:
    then:
      - {kind: UPDATE_FIELD, args: ["topic_configuration.remote.storage.enable", "true"]}
      - {kind: UPDATE_FIELD, args: ["topic_configuration.local.retention.ms", "86400000"]}
      - {kind: UPDATE_FIELD, args: ["topic_configuration.retention.ms", "604800000"]}
```

**CEL's duration literals are hour-based**, so 90 days is `duration("2160h")` —
noticeably less readable than `"90d"`. A host function accepting `"90d"` would
fix it, at the cost of having two duration spellings in one language.

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
  && avg_over(throughput_in, duration("1h")) >= governance.partition_throughput_ceiling

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
  && avg_over(throughput_in, duration("1h")) >= governance.partition_throughput_floor
  && topic.config["local.retention.ms"] <= duration("24h")

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
  && cluster.brokers >= governance.target_rf

branches:
  - otherwise:
    then:
      - {kind: UPDATE_FIELD, args: ["replication_factor", "${governance.target_rf}"]}
```

The second clause matters: RF must not exceed the broker count. The whitelist
already enforces that, but the rule should not attempt it in the first place.

---

## A CEL-only capability worth noting

CEL has native list macros the other text engines lack — `all`, `exists`,
`filter`, `map`. So a condition like *"every broker is under the cap"* needs no
host function at all:

```
replicas_per_broker.all(r, r < governance.max_replicas)
```

Verified working: `replicas.all(r, r < 4000.0) && brokers < 6` compiles and
evaluates. None of the eight examples above needs this, but it would matter if
conditions ever grow set-quantifier logic.

## Cost

**+9.29 MB** standalone, **3 new modules** for franz — `cel.dev/cel-go`,
`antlr4-go/antlr/v4`, `golang.org/x/exp` (v0.32.0). Sandboxing: **`CostLimit`**
(static, pre-evaluation — the strongest of any option) and
`InterruptCheckFrequency`.

The standalone figure overstates the real cost: franz already has **15 of CEL's
18** dependencies, including `cel.dev/expr` itself via gRPC/genproto. Note the
module path is now `cel.dev/cel-go`, **not** `github.com/google/cel-go`.

Full table in [dsl-comparison.md](./dsl-comparison.md#measured-cost).

## Tradeoffs

**For** — a genuine standard, so "conditions are CEL" is documentation you do not
write; `CostLimit` is the strongest safety guarantee available; native list
macros; large ecosystem; the obvious choice if these expressions ever need
evaluating outside Go.

**Against** — roughly 3× expr's binary cost; `&&` / `||` / `!` are less readable
to non-programmers than `and` / `or` / `not`; hour-based duration literals are
awkward for multi-day windows (see 2.a); pulls in the ANTLR runtime.
