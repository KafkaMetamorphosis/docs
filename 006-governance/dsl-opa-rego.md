# 006 DRAFT — `opa-rego` worked examples

> **DRAFT.** One of four candidate condition engines. Overview, shared context,
> action catalogue and the decision live in
> **[dsl-comparison.md](./dsl-comparison.md)** — read that first.
>
> **Verdict: not recommended for embedding.** +27.2 MB, 78 new modules, and no
> first-match branch ordering. Reconsider only as a sidecar.

## Rego's shape differs from the other three

The other engines evaluate a **condition per branch, in order, first match
wins**. Rego does not work that way:

- A policy computes a **decision document**, which Franz then maps onto actions.
  Branch precedence moves out of the rule data and into Rego semantics.
- Rule bodies are **implicit AND** — newline-separated expressions.
- Rules are **unordered** and there is **no first-match-wins**. Two complete
  rules that both succeed is an `eval_conflict_error` at *runtime*, not a
  precedence decision. Mutual exclusion must be hand-written as the negation of
  every earlier branch.
- `import rego.v1` is required. Without it the first policy written for this
  document failed with `eval_conflict_error: complete rules must not produce
  multiple outputs` — a v0/v1 syntax split no type checker warns about.

Each example is therefore **two artifacts**: a `.rego` policy and an
action-mapping document.

---

## 1.a — replicas per broker

```rego
package franz.governance.cluster_replica_pressure
import rego.v1

# gate
pressure if {
	max(input.replicas_per_broker) >= input.budget.max_replicas
}

# extracted so the negation below reads as `not skewed` rather than
# repeating the whole comparison
skewed if {
	stdev_pct(input.replicas_per_broker) > input.budget.replica_stdev
}

decision := {"action": "rebalance"} if {
	pressure
	skewed
}

decision := {"action": "add_broker"} if {
	pressure
	not skewed
	input.cluster.brokers < input.budget.max_brokers
	not input.cluster.tainted
}

default decision := {"action": "taint"}
```

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
policy: franz/governance/cluster_replica_pressure.rego
actions:
  rebalance:
    - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}
  add_broker:
    - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
    - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}
  taint:
    - {kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}
```

Cluster labels: `franz.governance/max-replicas: "18000"`,
`replica-stdev: "10%"`, `max-brokers: "6"`.

## 1.b — leaders per broker

*"The same logic for leaders per broker."* For every other engine that is two
identifiers. Here it is a whole second policy file **plus** a second
action-mapping document — the duplicated `not skewed` negation included.

```rego
package franz.governance.cluster_leader_pressure
import rego.v1

pressure if {
	max(input.leaders_per_broker) >= input.budget.max_leaders
}

skewed if {
	stdev_pct(input.leaders_per_broker) > input.budget.leader_stdev
}

decision := {"action": "rebalance"} if {
	pressure
	skewed
}

decision := {"action": "add_broker"} if {
	pressure
	not skewed
	input.cluster.brokers < input.budget.max_brokers
	not input.cluster.tainted
}

default decision := {"action": "taint"}
```

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
policy: franz/governance/cluster_leader_pressure.rego
actions:
  rebalance:
    - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}
  add_broker:
    - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
    - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}
  taint:
    - {kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}
```

## 1.c — disk used per broker

Four branches, so the negation chain grows with each one. The fourth branch is
reached only by negating all three predecessors.

```rego
package franz.governance.cluster_disk_pressure
import rego.v1

pressure if {
	max(input.disk_used_pct) >= input.budget.disk_high_watermark
}

skewed if {
	stdev_pct(input.disk_used_pct) > input.budget.disk_stdev
}

disk_has_room if {
	input.cluster.disk_size < input.budget.max_disk
}

broker_has_room if {
	input.cluster.brokers < input.budget.max_brokers
}

# skewed — some brokers have room, moving data helps
decision := {"action": "rebalance"} if {
	pressure
	skewed
}

# uniformly full — rebalancing cannot help, grow the disks
decision := {"action": "grow_disk"} if {
	pressure
	not skewed
	disk_has_room
}

# disks capped, brokers are not — add capacity and spread onto it
decision := {"action": "add_broker"} if {
	pressure
	not skewed
	not disk_has_room
	broker_has_room
}

default decision := {"action": "taint"}
```

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
policy: franz/governance/cluster_disk_pressure.rego
actions:
  rebalance:
    - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}
  # UPDATE_FIELD because disk_size has no INCREASE_FIELD_BY (action catalogue)
  grow_disk:
    - {kind: UPDATE_FIELD, args: ["disk_size", "budget.next_disk_size"]}
  add_broker:
    - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
    - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}
  taint:
    - {kind: ADD_LABEL, args: ["franz.taint", "disk:no-creation"]}
```

Extracting `skewed` / `disk_has_room` / `broker_has_room` as named rules is what
keeps this readable at all. Without them the third branch would inline
`not stdev_pct(…) > …` and `not input.cluster.disk_size < …` — double negatives
over comparisons.

## 1.d — migrate topics off a saturated cluster

Uses the **proposed** `MIGRATE_KAFKA_TOPIC` action. Today this is only reachable
as `ADD_LABEL franz.taint drain`.

```rego
package franz.governance.topic_evacuate_saturated
import rego.v1

decision := {"action": "migrate"} if {
	input.cluster.tainted
	max(input.disk_used_pct) >= input.budget.disk_critical
	input.cluster.brokers >= input.budget.max_brokers
}

default decision := {"action": "none"}
```

```yaml
rule: topic-evacuate-saturated-cluster
scope:
  entity:   KAFKA_TOPIC
  selector: "env=prod"
guard:
  cooldown: 2h
  max_fires_per_day: 1
  skip_if_operation_in_flight: true
policy: franz/governance/topic_evacuate_saturated.rego
actions:
  migrate:
    - {kind: MIGRATE_KAFKA_TOPIC, args: ["budget.overflow_cluster"]}
  none: []
```

The cluster-wide variant:

```rego
package franz.governance.cluster_drain_saturated
import rego.v1

decision := {"action": "drain"} if {
	input.cluster.tainted
	max(input.disk_used_pct) >= input.budget.disk_critical
}

default decision := {"action": "none"}
```

```yaml
rule:   cluster-drain-saturated
scope:  {entity: KAFKA_CLUSTER, selector: "env=prod"}
guard:  {cooldown: 6h, max_fires_per_day: 1, skip_if_operation_in_flight: true}
policy: franz/governance/cluster_drain_saturated.rego
actions:
  drain: [{kind: MIGRATE_CLUSTER, args: ["governance-drain"]}]
  none:  []
```

## 2.a — over-retained topic → tiered storage

Flat conjunction — Rego's implicit AND suits this well.

```rego
package franz.governance.topic_retention_rightsizing
import rego.v1

decision := {"action": "tier"} if {
	input.topic.config["retention.ms"] > 86400000
	max_over(input.consumer_lag, "90d") < 86400000
}

default decision := {"action": "none"}
```

```yaml
rule: topic-retention-rightsizing
scope:
  entity:   KAFKA_TOPIC
  selector: "env=prod"
guard:
  cooldown: 7d
  max_fires_per_day: 1
  skip_if_operation_in_flight: true
policy: franz/governance/topic_retention_rightsizing.rego
actions:
  tier:
    - {kind: UPDATE_FIELD, args: ["topic_configuration.remote.storage.enable", "true"]}
    - {kind: UPDATE_FIELD, args: ["topic_configuration.local.retention.ms", "86400000"]}
    - {kind: UPDATE_FIELD, args: ["topic_configuration.retention.ms", "604800000"]}
  none: []
```

Rego has no duration type, so durations are raw milliseconds — `86400000` for 1d.
Less readable than expr's `duration("1d")`, more readable than CEL's `"2160h"`
for 90 days.

**Blocked:** `indicator_sample` prunes at 30 days (open question 1).

## 2.b — single-partition topic at throughput

```rego
package franz.governance.topic_partition_growth_throughput
import rego.v1

decision := {"action": "add_partition"} if {
	input.topic.partitions == 1
	avg_over(input.throughput_in, "1h") >= input.budget.partition_throughput_ceiling
}

default decision := {"action": "none"}
```

```yaml
rule: topic-partition-growth-throughput
scope:
  entity:   KAFKA_TOPIC
  selector: "env=prod"
guard:
  cooldown: 6h
  max_fires_per_day: 2
  skip_if_operation_in_flight: true
policy: franz/governance/topic_partition_growth_throughput.rego
actions:
  add_partition: [{kind: INCREASE_FIELD_BY, args: ["partitions", "1"]}]
  none: []
```

## 2.c — oversized replicas, retention already tuned

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

```yaml
rule: topic-partition-growth-size
scope:
  entity:   KAFKA_TOPIC
  selector: "env=prod"
guard:
  cooldown: 6h
  max_fires_per_day: 2
  skip_if_operation_in_flight: true
policy: franz/governance/topic_partition_growth_size.rego
actions:
  add_partition: [{kind: INCREASE_FIELD_BY, args: ["partitions", "1"]}]
  none: []
```

The third line encodes *"retention is already tuned"* — without it the rule would
add partitions to a topic whose real problem is over-retention, which 2.a fixes
more cheaply.

## 2.d — under-replicated topic → set replication factor

```rego
package franz.governance.topic_replication_floor
import rego.v1

decision := {"action": "set_rf"} if {
	input.topic.replication_factor < input.budget.target_rf
	input.cluster.brokers >= input.budget.target_rf
}

default decision := {"action": "none"}
```

```yaml
rule: topic-replication-floor
scope:
  entity:   KAFKA_TOPIC
  selector: "env=prod"
guard:
  cooldown: 1h
  max_fires_per_day: 2
  skip_if_operation_in_flight: true
policy: franz/governance/topic_replication_floor.rego
actions:
  set_rf: [{kind: UPDATE_FIELD, args: ["replication_factor", "budget.target_rf"]}]
  none: []
```

The second line matters: RF must not exceed the broker count. The whitelist
already enforces that, but the rule should not attempt it in the first place.

---

## Where Rego reads well, and where it does not

**Well** — 2.a through 2.d. Flat conjunctions are exactly what implicit-AND rule
bodies are for, and these read as cleanly as any other engine.

**Badly** — 1.a through 1.c, the branching rules. No first-match ordering means
every branch restates the negation of its predecessors; 1.c needs four extracted
helper rules to stay legible. And 1.b, which is *"the same but leaders"*, costs a
second policy file plus a second mapping document.

That asymmetry is the finding: Rego is a good fit for admission-style predicates
and a poor fit for ordered remediation ladders, which is most of what 006 is.

## Cost

**+27.2 MB** standalone, **78 new modules** for franz (v1.20.2). For scale,
franz's whole binary is 28 MB today — embedding OPA roughly doubles it.

Those 78 modules include `badger` (an embedded key-value store), `ristretto` (a
cache), **two** separate Levenshtein implementations, `secp256k1` crypto, and
`go-md2man` (a man-page generator). That is a policy *server* vendored into a
control plane.

Full table in [dsl-comparison.md](./dsl-comparison.md#measured-cost).

## Tradeoffs

**For** — genuinely powerful; a mature policy ecosystem with bundle
distribution, versioning and testing tools; the right answer if governance policy
must be authored by a team already standardised on OPA.

**Against** — the footprint is disproportionate to comparing broker counts; Rego
is a logic language admins must learn; **no first-match-wins**, so branch
precedence leaves the rule document and every branch hand-writes its
predecessors' negation — precisely the duplication that ruled out the
flat-policy rule shape in the first place; and the decision-document indirection
means the rule and its effects live in two artifacts instead of one.

If OPA is wanted, run it as a **sidecar** rather than embedding it.
