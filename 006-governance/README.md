# 006 — Governance Rule Engine & Console Editor

Status: **ready**

The rule engine and authoring experience for Franz Governance. It evolves the single-indicator/single-limit `Policy` model (`003.8`) into **composite remediation rules** powered by `expr-lang/expr`, featuring sub-resource aggregates, ordered branching ladders, mandatory execution guards, and a text-based console editor with real-time server-side validation and live dry-run simulation.

Related specs: [`003-franz/003.8-governance`](../003-franz/003.8-governance.md) (base governance & whitelist), [`005-gregor-samsa`](../005-gregor-samsa/README.md) (telemetry & indicators), [`006-governance/dsl-comparison.md`](./dsl-comparison.md) (engine benchmark).

---

## 1. Decisions & Rationale

### 1.1 Condition Engine: `expr-lang/expr`
- **Decision:** Use `github.com/expr-lang/expr` for condition expressions.
- **Rationale:** Adds only +3.05 MB to the binary with zero transitive dependencies. Provides compile-time type checking with exact line/column coordinates, readable boolean syntax (`and`, `or`, `not`), and fast in-memory evaluation.
- **Alternatives Rejected:** `cel-go` (larger footprint, verbose syntax for simple conditions), `opa-rego` (+27 MB, 78 dependencies, lacks first-match branch ordering), custom AST (high maintenance, poor authoring UX).

### 1.2 Document Format: Pure YAML Document
- **Decision:** Rules are authored, stored, and edited as single pure YAML documents.
- **Rationale:** Keeps remediation ladders, scope, and guards together in one versionable, copy-pasteable artifact. Avoids deeply nested, brittle form builders.

### 1.3 Console Experience: Code Editor + Real-Time Server Validation + Live Dry-Run
- **Decision:** The console provides a code editor (CodeMirror 6) with:
  1. **Debounced server validation (`POST /v1/governance/rules:dryRun`):** Compiles the YAML and expressions against Franz's Go environment; reports syntax and type errors with line/column markers.
  2. **Live Dry-Run Simulation:** Evaluates the rule against real-time fleet snapshots without mutating state. Displays matched resources, triggered branches, projected actions, and warnings for missing labels.
- **Rationale:** Text editing gives operators full expressive power; immediate simulation provides complete safety before applying changes to running clusters.

### 1.4 Scoping & Sub-Resource Descent
- **Decision:** Rules select a parent entity (`KAFKA_CLUSTER` or `KAFKA_TOPIC`) via label selectors, and optionally `descend` to sub-resources (e.g. `descend: {kind: broker}`).
- **Rationale:** Brokers are not standalone Franz resources with their own labels; they exist only as sub-resources. Descent allows aggregates like `max(replicas_per_broker)` across a cluster's brokers without cross-cluster data leakage.

### 1.5 Governance Ceilings & Parameters (`governance.*`)
- **Decision:** Per-cluster operational limits are defined as `franz.governance/*` labels on `KafkaCluster`. During evaluation, Franz injects them as `governance.<snake_case>`.
  - Action arguments interpolate them via `${governance.<name>}`.
  - **Missing or malformed labels:** The rule instance is **skipped** (recorded in `PolicyAction` with `result = skipped`), and a **Rule Health Warning (`CONFIG_MISSING`)** is surfaced on the Rule to force operator configuration. Never default.
- **Rationale:** Allows one rule definition to govern a fleet of clusters with different capacities (e.g., 6 brokers vs 24 brokers). Defaulting a spend/capacity limit is dangerous.

### 1.6 Execution Guards
- **Decision:** Every rule must declare a `guard` block containing:
  - `cooldown`: Minimum duration between rule triggers on the same resource (e.g. `30m`).
  - `max_fires_per_day`: Daily execution budget to prevent flapping.
  - `skip_if_operation_in_flight: true`: Suppresses execution if an operation is active.

### 1.7 Dynamic Disk Auto-Sizing with 24h Projection Guard
- **Decision:** Disk capacity growth is calculated dynamically rather than using a static next-size label. A rule specifies:
  - `target_usage_pct`: Desired utilization after resize (e.g., `60%`).
  - `projection_window`: Growth horizon (e.g., `24h`).
  The engine projects usage $U_{\text{proj}} = U_{\text{current}} + (\text{growth\_rate} \times \text{window})$ and sets disk size $S = U_{\text{proj}} / \text{target\_usage\_pct}$, clamped by `governance.max_disk`.
- **Rationale:** Prevents thrashing where a disk resize immediately re-triggers the high watermark rule on the next evaluation cycle.

### 1.8 Operational Actions Bridge (Rebalance)
- **Decision:** Rebalance actions emit a declarative signal label: `ADD_LABEL franz.governance/needs-rebalance: "$now"`.
- **Rationale:** Preserves `003.8`'s invariant that governance only mutates declared state. Dedicated imperative operations (`Operation` entity) are deferred to ADR 007.

### 1.9 Migration Actions Dropped from Scope
- **Decision:** Direct migration actions (`MIGRATE_KAFKA_TOPIC`, `MIGRATE_CLUSTER`) are omitted from 006.
- **Rationale:** Cluster saturation and hot topics are handled via `franz.taint` (`no-creation` or `drain`), topic configurations, and quotas.

### 1.10 Configurable Sample Pruning
- **Decision:** Indicator sample pruning is configurable (`telemetry.sample_retention`, default 30d). Rule validation verifies that any time-window function (e.g. `max_over(lag, "90d")`) does not exceed the configured retention.

---

## 2. Rule Structure & Syntax

```yaml
rule: <unique-name>
scope:
  entity: KAFKA_CLUSTER | KAFKA_TOPIC
  selector: "<003.1 label selector>"
  descend: {kind: broker}            # optional sub-resource descent
guard:
  cooldown: <duration>               # e.g. 30m, 1h
  max_fires_per_day: <int>           # e.g. 4
  skip_if_operation_in_flight: bool

when: '<expr-lang gate condition>'

branches:
  - when: '<expr-lang branch condition>'
    then:
      - {kind: <ACTION_KIND>, args: ["<arg1>", "<arg2>"]}
  - otherwise:
    then:
      - {kind: <ACTION_KIND>, args: ["<arg1>", "<arg2>"]}
```

### Expression Context & Host Functions
- **Variables:**
  - `cluster.brokers`, `cluster.disk_size`, `cluster.state`, `cluster.tainted`
  - `topic.partitions`, `topic.replication_factor`, `topic.config["<key>"]`
  - `governance.<param>`: Values parsed from `franz.governance/<param>` labels.
  - `<indicator-name>`: Array of sample values across descended sub-resources.
- **Go Host Functions:**
  - Aggregates: `max(arr)`, `min(arr)`, `avg(arr)`, `sum(arr)`, `count(arr)`, `stdev(arr)`, `stdev_pct(arr)`
  - Windowed: `max_over(indicator, duration_str)`, `avg_over(indicator, duration_str)`
  - Parsing: `duration(str)` (e.g. `duration("1d")`)

---

## 3. Worked Examples

### 3.1 Cluster Replica Pressure (Remediation Ladder)
Skewed replica load triggers a rebalance signal; balanced load adds a broker if within budget; otherwise taints the cluster against new allocations.

```yaml
rule: cluster-replica-pressure
scope:
  entity: KAFKA_CLUSTER
  selector: "env=prod"
  descend: {kind: broker}
guard:
  cooldown: 30m
  max_fires_per_day: 4
  skip_if_operation_in_flight: true

when: 'max(replicas_per_broker) >= governance.max_replicas'

branches:
  # 1. Skewed: rebalance onto quieter brokers
  - when: 'stdev_pct(replicas_per_broker) > governance.replica_stdev'
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  # 2. Balanced but at capacity: add broker headroom and rebalance
  - when: 'cluster.brokers < governance.max_brokers and not cluster.tainted'
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  # 3. Ceilings reached: taint to stop new topic allocations
  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "capacity:no-creation"]}
```

### 3.2 Dynamic Disk Sizing
```yaml
rule: cluster-disk-pressure
scope:
  entity: KAFKA_CLUSTER
  selector: "env=prod"
  descend: {kind: broker}
guard:
  cooldown: 1h
  max_fires_per_day: 2
  skip_if_operation_in_flight: true

when: 'max(disk_used_pct) >= governance.disk_high_watermark'

branches:
  # Skewed disk usage: rebalance data
  - when: 'stdev_pct(disk_used_pct) > governance.disk_stdev'
    then:
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  # Uniformly full: resize disk to target usage with 24h growth buffer
  - when: 'cluster.disk_size < governance.max_disk'
    then:
      - {kind: UPDATE_FIELD, args: ["disk_size", "${governance.calculated_disk_target}"]}

  # Disk capped: add a broker
  - when: 'cluster.brokers < governance.max_brokers'
    then:
      - {kind: INCREASE_FIELD_BY, args: ["brokers", "1"]}
      - {kind: ADD_LABEL, args: ["franz.governance/needs-rebalance", "$now"]}

  - otherwise:
    then:
      - {kind: ADD_LABEL, args: ["franz.taint", "disk:no-creation"]}
```

### 3.3 Topic Rightsizing & Growth
```yaml
rule: topic-partition-growth
scope:
  entity: KAFKA_TOPIC
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
      - {kind: INCREASE_FIELD_BY, args: ["partitions", "1", "max=16"]}
```

---

## 4. Console Editing & Validation API

### 4.1 RPC Definition
```protobuf
service GovernanceService {
  // Compiles and simulates a rule definition without saving or mutating state.
  rpc DryRunRule(DryRunRuleRequest) returns (DryRunRuleResponse) {
    option (google.api.http) = {
      post: "/v1/governance/rules:dryRun"
      body: "*"
    };
  }
}

message DryRunRuleRequest {
  string yaml_definition = 1;
}

message DryRunRuleResponse {
  bool valid = 1;
  repeated RuleValidationError errors = 2;
  repeated RuleMatchSimulation simulations = 3;
}

message RuleValidationError {
  int32 line = 1;
  int32 column = 2;
  string message = 3;
}

message RuleMatchSimulation {
  string resource_frn = 1;
  SimulationStatus status = 2; // TRIGGERED, NO_ACTION, SKIPPED
  string skip_reason = 3;      // e.g. "missing label franz.governance/max-brokers"
  int32 matched_branch = 4;
  repeated Action planned_actions = 5;
}
```

### 4.2 Web Console Flow
1. **Editor:** CodeMirror 6 with YAML syntax highlighting.
2. **Real-time Linting:** On input (debounced 400ms), calls `DryRunRule`.
   - Errors are mapped to editor lines as red diagnostic squiggles and a summary alert. Save is disabled.
3. **Simulation Panel:** Rendered adjacent to the editor. Shows real fleet impact:
   - Total resources matched by selector.
   - Per-resource simulated outcome (triggered branch, resolved action parameters, or warning if skipped due to missing labels).
