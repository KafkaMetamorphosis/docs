# 006 — Condition-expression engine comparison

> **DRAFT.** Not the ADR. Picks one thing — the engine that evaluates a rule's
> conditions — before `006-governance/README.md` is written. No code written.

## The detail files

The complete worked examples live one file per engine. Each contains **all eight
examples in full syntax**; this file holds only the shared reference material and
the decision.

| Engine | Detail | Verdict |
|---|---|---|
| `expr-lang/expr` | **[dsl-expr-lang.md](./dsl-expr-lang.md)** | ⭐ **recommended** |
| `cel-go` | [dsl-cel.md](./dsl-cel.md) | runner-up |
| `opa-rego` | [dsl-opa-rego.md](./dsl-opa-rego.md) | not recommended |
| structured AST | [dsl-custom.md](./dsl-custom.md) | not recommended (baseline) |

## Why an engine has to be chosen first

`003.8`'s `Policy` is one indicator against one limit. The rules that motivate 006
need boolean composition (`and`/`or`/`not`), aggregates over a cluster's brokers,
and ordered first-match branches. `Policy` can express none of the three.

## Locked

| Q1a | Aggregates are **expressions** | Q5 | Guard rails are `franz.governance/*` **cluster labels** |
|---|---|---|---|
| **Q1b** | Scope = **label-select parent, descend** to sub-resources | **Q7** | Cooldown + in-flight guard + budget **mandatory** |
| **Q3** | **High** stdev triggers rebalance | **—** | Aggregate vocabulary is a **closed Go-defined set** |
| **Q4** | Rebalance = **label signal** now; Operation with ADR 007 | | |

## Shared context

Referenced by every detail file.

```
cluster.brokers  cluster.disk_size  cluster.state  cluster.tainted
topic.partitions  topic.replication_factor  topic.config[<key>]
budget.<name>                    ← franz.governance/<name> label on the cluster
<indicator-name>                 ← sample set for the descended resources
```

Host functions (closed set, defined in Go — no engine has these built in):
`max min avg sum count stdev stdev_pct`, `max_over(ind, window)`,
`avg_over(ind, window)`.

**Scope invariants** — one evaluation per matched resource, each with its own
cooldown and budget state; aggregates never cross the parent, so `max()` is over
*that* cluster's brokers, never the fleet. Brokers carry no labels (there is no
broker table; they exist only as FRN sub-resources), which is why `descend`
exists.

For a **topic** rule, `budget.*` resolves from the topic's **cluster** — topics
carry no budget labels.

## Action catalogue

From `governance/whitelist.go` — the implemented `(entity, field, kinds)` matrix.
**Every field name used in the detail files comes from here.**

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

### Three findings from reading the whitelist

1. **`brokers` already takes a direct set** (`UPDATE_FIELD`) as well as
   `INCREASE_FIELD_BY`. No new action needed.
2. **`disk_size` has no `INCREASE_FIELD_BY`** — it is a size-hint *string*, so
   "grow by 100Gi" is not expressible; only an absolute `UPDATE_FIELD`. Every
   1.c example is written against that limit. See open question 3.
3. **Migration is not a governance action.** No `MIGRATE` kind exists.
   Governance reaches migration only indirectly, by writing `franz.affinity/*`
   on a channel or `franz.taint=drain` on a cluster, which the
   placement/migration flow resolves (`003.7`, `003.13`).

### Proposed for 006 (do not exist yet)

| Kind | args | Maps to |
|---|---|---|
| `MIGRATE_KAFKA_TOPIC` | `[target_cluster]` | `MigrateKafkaTopic{kafka_topic, target_cluster}` |
| `MIGRATE_CLUSTER` | `[reason]` | `MigrateCluster{kafka_cluster, reason}` |

Both are **async operations, not declared-state writes**, so they carry
rebalance's caveat (Q4): they break `003.8`'s "actions only change declared
state" invariant and need the in-flight guard. Used in example 1.d.

## The eight examples

Every detail file encodes all of these.

| # | Rule | Entity | Actions exercised |
|---|---|---|---|
| **1.a** | Replicas/broker at cap → rebalance if skewed, else add broker, else taint | cluster | `ADD_LABEL`, `INCREASE_FIELD_BY` |
| **1.b** | Same logic for **leaders**/broker | cluster | as 1.a |
| **1.c** | Disk/broker at watermark → rebalance, grow disk, add broker, taint | cluster | `UPDATE_FIELD`, `INCREASE_FIELD_BY`, `ADD_LABEL` |
| **1.d** | Saturated cluster → migrate its topics away | topic | `MIGRATE_KAFKA_TOPIC` *(proposed)* |
| **2.a** | 7d retention, lag never 1d in 90d → 1d local + tiered | topic | `UPDATE_FIELD` ×3 |
| **2.b** | 9 MB/s on one partition → add a partition | topic | `INCREASE_FIELD_BY` |
| **2.c** | Oversized replicas, retention tuned → add a partition | topic | `INCREASE_FIELD_BY` |
| **2.d** | Under-replicated → set replication factor | topic | `UPDATE_FIELD` |

`1.b` is deliberately included: it is `1.a` with two identifiers changed. How
much text an engine needs to say *"the same, for leaders"* is a direct
readability measure — and the one place `opa-rego` diverges sharply.

## The same condition in all four

Gate for 1.a — *"the busiest broker is at or over the replica cap"*:

| `expr-lang` | `max(replicas_per_broker) >= budget.max_replicas` |
|---|---|
| `cel` | `max(replicas_per_broker) >= budget.max_replicas` |
| `opa-rego` | `max(input.replicas_per_broker) >= input.budget.max_replicas` |
| structured AST | `{fn: max, of: replicas_per_broker, op: ">=", value: budget.max_replicas}` |

Branch 2 of 1.a — *"there is broker budget left **and** the cluster is not tainted"*:

| `expr-lang` | `cluster.brokers < budget.max_brokers and not cluster.tainted` |
|---|---|
| `cel` | `cluster.brokers < budget.max_brokers && !cluster.tainted` |
| `opa-rego` | two body lines (implicit AND) + `not` — and no first-match ordering |
| structured AST | `{all: [{field: cluster.brokers, op: "<", …}, {not: {field: cluster.tainted}}]}` |

## Measured cost

Built and ran each engine against a representative condition. franz today:
**28 MB**, 139 modules.

| | binary Δ | new modules for franz | transitive | sandbox |
|---|---|---|---|---|
| structured AST | **+0** | **0** | none | inherent |
| **`expr-lang`** v1.17.8 | **+3.05 MB** | **1** | **none** | `MaxNodes`, `WithContext` |
| `cel-go` v0.32.0 | +9.29 MB | 3 | ANTLR, `x/exp` | **`CostLimit`** (static) |
| `opa-rego` v1.20.2 | +27.2 MB | **78** | incl. embedded KV store | query budgets |

- expr rejected a type error at **compile** time with a column marker:
  `invalid operation: >= (mismatched types float64 and string) (1:15)`
- CEL's standalone `+9.29 MB` overstates it in franz: franz already has **15 of
  CEL's 18** deps, including `cel.dev/expr` via gRPC. Module path is now
  `cel.dev/cel-go`, not `github.com/google/cel-go`.
- OPA's 78 modules include `badger` (embedded KV), `ristretto`, **two**
  Levenshtein implementations and `go-md2man`. The first policy written for this
  document failed with `eval_conflict_error` until `import rego.v1` was added.

## Recommendation

### ⭐ `expr-lang/expr`

1. **Negligible cost** — 1 module, no transitive deps, +3 MB on 28 MB.
2. **Reads like the rule was described** —
   `stdev_pct(disk_used_pct) > budget.disk_stdev and cluster.brokers < budget.max_brokers`.
3. **Branch order stays in the rule document**, which is what makes 1.a a single
   readable artifact.
4. **Compile-time type errors with positions** give `DryRunPolicy` a real error
   surface for free.
5. Already the Go-infra default for user-authored expressions (Argo Workflows,
   CrowdSec, Aqua).

**Runner-up `cel`** — pick it if cross-organisation standardisation beats 6 MB,
or if `CostLimit`'s static bound is required. Compare
[dsl-expr-lang.md](./dsl-expr-lang.md) against [dsl-cel.md](./dsl-cel.md): the
files are near-identical, so **switching later is mechanical.**

**Against `opa-rego`** — +27 MB and 78 modules to compare broker counts, and no
first-match ordering, so every branch restates its predecessors' negation. That
is the duplication that ruled out the flat-policy rule shape to begin with.
Reconsider only as a sidecar, for a team already standardised on OPA.

**Against the structured AST** — verbose, and every operator and error message is
yours to write. Its one real advantage survives without it: the console can
generate expr strings from a form, giving a condition-builder UI either way.

## Open

1. **90-day windows vs. 30-day pruning** (2.a) — raise retention, roll up daily aggregates, or shorten the window.
2. **Who publishes** `disk_used_pct`, `throughput_in`, `consumer_lag`, `replica_size` — none exist; Gregor Samsa reads metadata, not JMX.
3. **`disk_size` needs `INCREASE_FIELD_BY`**, or 1.c stays absolute-only.
4. **Migration as a first-class action** (`MIGRATE_KAFKA_TOPIC` / `MIGRATE_CLUSTER`) vs. routing through `franz.affinity/*` and `franz.taint=drain`.
5. **Operations break the declared-state invariant** — rebalance and both migrate kinds are async operations, not field writes (Q4, ADR 007).
6. **`budget.*` typing** — labels are strings; `"10%"`, `"18000"`, `"100Gi"` parse differently. Does a malformed budget label disable the rule or fail loudly?
7. **First deliverable scope** — cluster rules only, or cluster and topic together.
