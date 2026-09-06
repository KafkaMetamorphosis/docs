# Architecture Decision Records

## Odradek

### ODR-001: Header encoding for `produced-at`

The `com.franz.odradek/produced-at` Kafka header carries the epoch-ms as a UTF-8 string (not raw bytes).
This makes headers human-readable in tooling (kafkacat, Confluent Control Center) and avoids
endianness ambiguity across producer/consumer implementations.

### ODR-002: Observer status atom shape

Observer loop statuses are tracked in a single shared atom:

```clojure
{[observer-name cluster-name :producer] {:status :running :since 1712345678000}
 [observer-name cluster-name :consumer] {:status :backoff :since 1712345670000}}
```

Composite vector keys allow O(1) lookup per loop. The `:since` timestamp enables time-based
health checks (e.g., detect prolonged backoff).

### ODR-003: Producer threads use `Thread.` not `go` blocks

Producer `.send().get()` is a blocking call. Using `go` blocks would exhaust the core.async
fixed-size thread pool (8 threads by default), starving all other go blocks in the system.
Dedicated `Thread.` instances isolate blocking I/O from the core.async scheduler. Consumer
loops follow the same pattern for the same reason (`.poll()` and `.commitSync()` block).

### ODR-004: `/metrics` bypasses `wrap-json-response`

The Prometheus `/metrics` endpoint must return `text/plain; version=0.0.4`. Rather than adding
conditional logic inside `wrap-json-response`, the metrics route is composed at the Compojure
level *before* the JSON middleware stack. The ops routes pass through JSON middleware normally.

### ODR-006: ConfigComponent reads from CONFIG_PATH env var with classpath fallback

`ConfigComponent` checks the `CONFIG_PATH` environment variable at startup. If set, the file is
read directly from the filesystem (intended for Kubernetes ConfigMap volume mounts). If unset,
it falls back to the classpath resource `config.json` so that local dev (`lein run`) and unit
tests continue to work without any environment configuration.

This keeps the container image free of any config data — the image never bundles a production
`config.json`. The classpath resource is exclusively for local development.

### ODR-007: Dockerfile uses multi-stage build; no hardcoded max-heap

The Odradek Dockerfile uses two stages: `clojure:temurin-21-lein-alpine` for the build and
`eclipse-temurin:21-jre-alpine` for the runtime image. This keeps the runtime image small by
excluding Leiningen, the Clojure toolchain, and all intermediate build artefacts.

`-Xmx` is intentionally omitted. Container memory is controlled entirely by the Kubernetes
resource limit. `-XX:+UseContainerSupport` and `-XX:MaxRAMPercentage=75.0` translate that
limit into a JVM heap ceiling automatically. `-Xms64m` sets a low initial heap to avoid
over-allocating at startup in environments with many small pods.

The process runs as UID 1001 (`odradek`) — never as root — to satisfy standard Kubernetes
pod security policies.

### ODR-008: kafka_clusters keys must be stringified after JSON parsing

Cheshire's `(json/parse-string ... true)` keywordizes all JSON object keys, including cluster
names inside `kafka_clusters` (e.g. `"local-1"` becomes `:local-1`). Observer `:clusters`
vectors contain plain strings from the same JSON array. All three observer builder functions
(`topic-info`, `producer`, `consumer`) look up cluster configs using those string names, so the
lookup always returned `nil`, causing `bootstrap.servers = null` and a Kafka `ConfigException`
at startup.

Fix: `normalize-config` in `config/component.clj` runs after parsing and calls `(name k)` on
each `kafka_clusters` key to restore the string representation before the config is stored.
The normalization is applied in both `read-config-from-filesystem` and `read-config-from-classpath`
so all config sources are consistent.

Two additional latent issues were noted but do not cause a startup crash:
1. `parse-config` (schema validation) in `config/schema.clj` is defined but never called from
   `config/component.clj`. Runtime config is currently unvalidated.
2. `custom-labels` values in `config.json` are JSON numbers, but the schema declares
   `CustomLabels {s/Str s/Str}`. If `parse-config` were wired in, it would throw immediately
   on any observer with numeric custom-label values.

### ODR-009: Producer config keys are keywordized by Cheshire — use `(name k)` in `->properties`

Cheshire's `(json/parse-string ... true)` keywordizes **all** JSON object keys, including keys
inside `producer-config` and `consumer-config` maps (e.g. `"max.request.size"` → `:"max.request.size"`).

The original `->properties` used `(str k)` to convert keys to strings. For keywords, `(str k)`
produces `":max.request.size"` — with a leading colon — which Kafka does not recognize as a valid
property name and silently ignores. The result was that `max.request.size` was never applied and
the default 1048576 (1 MB) limit remained in effect, causing `RecordTooLargeException` for any
observer sending messages above that threshold.

Fix: change `->properties` to use `(name k)` instead of `(str k)`. `(name k)` on a keyword strips
the leading colon; on a plain string it is a no-op. This makes `->properties` correct for both
keyword-keyed maps (from Cheshire) and string-keyed maps (from inline construction in `new-producer`
and `new-consumer`).

Additionally, the `1mb-messages-small-topic-producer` observer config did not set `max.request.size`.
A 1 MB body generates ~1048774 bytes after Kafka record framing (headers + overhead), which exceeds
the default 1048576 limit. `max.request.size` was set to 2097152 (2 MB) for that observer to give
safe headroom.

### ODR-010: Custom-labels — union schema, sanitization at registry boundary

Custom-labels defined per observer in `config.json` must appear as Prometheus label dimensions.

**Union schema at registration time.** At `MetricsRegistryComponent` startup, the registry reads
all observers from its injected `config` component, computes the sorted union of all custom-label
keys across all observers, and appends them to the 5 standard label names. Every metric is
registered with this full union array. Observers that don't define a given key emit `""` for that
label at observation time.

**Sanitization lives at the registry boundary only.** Prometheus label names must match
`[a-zA-Z_][a-zA-Z0-9_]*`. Hyphens are illegal (`slo-latency-ms` must become `slo_latency_ms`).
The private `sanitize-label-name` function in the registry applies this transformation. It is
called both when computing union keys (registration) and when building observation value arrays
(via `stringify-custom-labels`). The two paths use the same function, so they always agree.
No sanitization or coercion happens in `logic` namespaces — they pass raw `:custom-labels` through.

**No separate `observers/labels.clj`.** All label coercion is private to the registry, which is
the Prometheus boundary. This avoids leaking Prometheus naming constraints into domain logic.

**Schema allows numeric values.** `CustomLabels` in `config/schema.clj` uses `{s/Str s/Any}` so
that numeric values (e.g. `"slo-latency-ms": 20`) pass schema validation. `stringify-custom-labels`
calls `str` on all values before building the label array.

### ODR-011: Grafana dashboard — dynamic SLO thresholds via label_values variables

The Grafana dashboard was updated to eliminate all hardcoded SLO thresholds and replace them
with four dashboard variables derived from Prometheus label values emitted by each observer.

**Observer selector variable.** A query variable named `observer` calls
`label_values(kafka_odradek_messages_produced_total, observer)`. Selecting an observer
automatically cascades into all three SLO dimension variables below.

**SLO dimension variables.** Three additional query variables are chained on the `observer`
selection:

- `slo_latency_ms` — production latency threshold in milliseconds:
  `label_values(kafka_odradek_messages_produced_total{observer="$observer"}, slo_latency_ms)`
- `slo_latency_meta_ms` — percentile used for the latency SLO (e.g. `99.5` means p99.5):
  `label_values(kafka_odradek_messages_produced_total{observer="$observer"}, slo_latency_meta_ms)`
- `slo_latency_window_minutes` — rate window in minutes for SLO evaluation:
  `label_values(kafka_odradek_messages_produced_total{observer="$observer"}, slo_latency_window_minutes)`

These values are sourced from the `custom-labels` map in `config.json`, which the metrics
registry emits as Prometheus label dimensions on every metric.

**Why this approach over recording rules or info metrics.** The SLO values are already
present as label string values on the time series. Grafana's `label_values()` function reads
them directly via the Prometheus label API (`/api/v1/label/<name>/values`) without requiring
any additional recording rules, exposition changes, or separate info metrics.

**Rate window interpolation.** PromQL expressions use `[${slo_latency_window_minutes}m]` for
the rate window. Grafana string-interpolates the variable value before sending the query, so
an observer with `slo-latency-window-minutes: 5` produces `[5m]` in the final query.

**Percentile arithmetic.** `histogram_quantile` requires a fractional argument (0–1).
The `$slo_latency_meta_ms` variable holds a value like `99.5`. The PromQL expression
`histogram_quantile($slo_latency_meta_ms/100, ...)` works because PromQL evaluates the
scalar arithmetic `99.5/100 = 0.995` natively — Grafana interpolates the variable value
and Prometheus evaluates the division.

**SLO threshold dashed line.** Latency panels carry a second query (refId `B`) that returns
a constant series equal to the SLO limit:
`max(kafka_odradek_messages_produced_total{observer="$observer"} * 0 + $slo_latency_ms)`.
Multiplying by 0 zeros the counter value; adding `$slo_latency_ms` (a Grafana variable
string interpolated as a scalar) produces a flat series at the threshold value. A Grafana
field override names this series "SLO Threshold" and styles it as a dashed red line.

**What remains hardcoded.** The error budget compliance percentages (99.98%, 99.5%, 99.999%)
are the SLO _target_ percentages (what fraction of time windows must be green), not the latency
or throughput limits. These are distinct from `slo_latency_meta_ms` (which is a percentile, not
a compliance target) and are not stored in `config.json`, so they remain as panel constants.

### ODR-012: Grafana dashboard — topic-based selector variable replaces observer-based variable

The original `observer` dashboard variable was sourced from
`label_values(kafka_odradek_messages_produced_total, observer)`. This only returned names of
producer observers (ending in `-producer`). Panels that query consumer-side metrics
(`kafka_odradek_e2e_message_age_ms_bucket`, `kafka_odradek_full_e2e_ms_bucket`,
`kafka_odradek_messages_fetch_error_total`, `kafka_odradek_messages_fetched_total`) use consumer
observer names (ending in `-consumer`), so `observer="$observer"` never matched them — those
panels returned no data.

**Fix: replace `$observer` with `$topic` throughout.**

The `topic` label is emitted on all workload metrics (both producer and consumer sides share the
same Kafka topic name). The new variable is:

```
label_values(kafka_odradek_messages_produced_total, topic)
```

All PromQL label matchers in every panel were changed from `observer="$observer"` to
`topic="$topic"`. The three SLO dimension variables (`slo_latency_ms`, `slo_latency_meta_ms`,
`slo_latency_window_minutes`) were updated to filter by `topic="$topic"` against the producer
metric, which carries those custom-labels and is reliably present whenever a producer observer
is configured.

**Why not Option A (strip suffix via Grafana regex).** A Grafana variable regex on the
`observer` variable strips suffixes from the _display_ name only. The actual `$observer` value
substituted into panel queries would still be the full producer name (e.g.
`small-messages-small-topic-producer`), making `observer=~"$observer-(producer|consumer)"`
evaluate to `observer=~"small-messages-small-topic-producer-(producer|consumer)"` — which
never matches anything. This approach is fundamentally broken.

**Why not Option C (regex matcher in queries).** If the variable emitted only the base name
(by custom Grafana regex stripping), `observer=~"$topic-(producer|consumer)"` would work in
PromQL. But base names are not an actual Prometheus label — `topic` is. Using `topic` is both
cleaner and simpler.

**Retained `sum by (observer)` in throughput and error panels.** These panels benefit from
splitting the series by observer name so the legend distinguishes the producer from the consumer.
Since the filter is now by topic (covering both sides), `sum by (observer)` produces two series:
one for the `-producer` observer and one for the `-consumer` observer — which is the correct
behavior for those panels.

**`topic-config` observer not affected.** The `topic-info` observer type has no `topic` label
and therefore does not appear in the `$topic` dropdown. This is correct — it is an infrastructure
observer, not a workload SLO observer.

### ODR-013: topic-info observer — list all topics rather than derive from other observers

The original topic-info observer derived its topic list from the union of `:topic` values across
all other producer/consumer observers targeting the same cluster (`topics-for-cluster`). This
means it only scraped the small set of Odradek-monitored topics, not the actual cluster population.

The observer was rewritten to:
1. Call `kafka-admin/list-topics` (which wraps `AdminClient.listTopics` with `listInternal=false`)
   to discover every non-internal topic in the cluster.
2. Call `describe-topics` and `describe-topic-configs` on that full list.
3. Export numeric gauges per topic per cluster, plus retain the legacy 14-label info gauge
   (`kafka_odradek_topic_config`) for backward compatibility with existing Grafana panels.

The `all-observers` parameter was removed from `new-topic-info-observer` since the component
no longer has any dependency on sibling observer configuration.

**New metrics added** (independent of the union custom-labels mechanism):

Process metrics (labels: `cluster_name`):
- `kafka_odradek_topic_scrape_duration_seconds` — full scrape cycle
- `kafka_odradek_topic_list_duration_seconds` — list step
- `kafka_odradek_topic_describe_duration_seconds` — describe step
- `kafka_odradek_topic_config_describe_duration_seconds` — config-describe step
- `kafka_odradek_topic_scrape_errors_total` — label `step` = list|describe|describe-config

Per-topic gauges (labels: `cluster_name`, `topic`):
- `kafka_odradek_topic_partitions`
- `kafka_odradek_topic_replication_factor` (replicas count for partition 0)
- `kafka_odradek_topic_min_isr` (ISR count for partition 0 as proxy)
- `kafka_odradek_topic_retention_ms`
- `kafka_odradek_topic_retention_bytes` (-1 = unlimited)

Error counters are initialized to 0 at startup (`init-scrape-error-counters!`) so Grafana
shows 0 rather than "no data" even when no errors have occurred.

### ODR-014: topic-info observer — topics-filter and observe-configs

Two new features were added to the topic-info observer:

**`topics-filter` (required regex string).** Applied after `list-all-topics`. Only topics whose
full name matches the regex are passed to `describe-topics`, `describe-topic-configs`, and the
metric export step. Unmatched topics are completely invisible to Prometheus — no describe call,
no metric write. This avoids polluting metric output with internal or irrelevant topics and keeps
describe calls cheap on large clusters.

**`observe-configs` (list of config key strings).** Controls which Kafka config keys are exposed
as metrics. Keys are classified into two categories at scrape time (once per cycle, not per topic):

- **Numeric keys** (`retention.ms`, `retention.bytes`, `min.insync.replicas`, `max.message.bytes`):
  Each gets a dedicated Gauge named `kafka_odradek_topic_config_<sanitized_key>` with labels
  `["cluster_name" "topic"]`. This replaces the old hardcoded `kafka_odradek_topic_retention_ms`
  and `kafka_odradek_topic_retention_bytes` gauges which are removed.
- **String keys** (all others, e.g. `cleanup.policy`, `compression.type`): Exposed as labels on
  a single Gauge named `kafka_odradek_topic_string_config` with labels
  `["cluster_name" "topic" <sanitized_key1> ...]`. If no string keys are configured, the gauge
  is not registered at all.

The set of known numeric keys is the Clojure set `numeric-config-keys` in `observers.topic-info.logic`.
Classification is done in `classify-observe-configs` which returns `{:numeric [...] :string [...]}`.

**Legacy gauge retained.** `kafka_odradek_topic_config` (the 14-label info gauge) is preserved
unchanged for backward compatibility with existing Grafana panels. It uses a private
`legacy-config->label-map` that always extracts the original 6 hardcoded configs.

**Prometheus `_info` suffix restriction.** The Prometheus Java client 1.x rejects Gauge registrations
with names ending in `_info` (reserved for the `Info` metric type). The string-config gauge was
therefore named `kafka_odradek_topic_string_config` rather than `kafka_odradek_topic_info`.

**Naming migration in Grafana.** `kafka_odradek_topic_retention_ms` →
`kafka_odradek_topic_config_retention_ms` and `kafka_odradek_topic_retention_bytes` →
`kafka_odradek_topic_config_retention_bytes` in `topic_overview.json`.

**Integration test timing fix.** The `wait-for-metric` helper uses `str/includes?`, so waiting
for `"kafka_odradek_topic_config"` now false-positives on the new
`kafka_odradek_topic_config_retention_ms` gauge. The legacy info gauge tests now wait for
`"kafka_odradek_topic_config{"` (with the opening brace) to require an exact name match.

### ODR-005: Consumer startup sequence

Consumer initialization follows: subscribe -> poll(100ms) -> seekToEnd -> real poll loop.

The initial poll(100ms) triggers partition assignment by the coordinator. Without it,
`seekToEnd` would operate on an empty assignment set and have no effect. After seeking,
we call `.position()` on each partition to force the seek to materialize before entering
the real consumption loop.

## UX Prototype (`docs/001-ux`)

### UXD-001: One page per resource action — list page and create/register form are separate screens

`register-kafka-cluster.html` originally hosted both the Kafka Cluster list table and the inline
registration form, with the page-heading button jumping to an in-page anchor (`#register-cluster`).
That conflated two distinct screens and diverged from the Async Channel flow, which already models
the pattern correctly: `async-channels.html` (list) + `create-async-channel.html` (form).

**Decision.** The list lives at `kafka-clusters.html`; `register-kafka-cluster.html` holds only the
registration form. The page-heading button is a plain `href` to the form page, and the form's Cancel
link and `form action` both return to `kafka-clusters.html`.

**Why the list took the new filename rather than the form.** The verb-shaped name
(`register-kafka-cluster`) describes an action, so it belongs to the form page — mirroring
`create-async-channel.html`. Renaming the list instead keeps both services structurally identical:
plural-noun list page, verb-phrase action page. The cost is updating every inbound link, which is
bounded (8 prototype files) and was done in the same change.

**Breadcrumbs.** The form page uses `Console Home / Kafka Clusters / Register Kafka Cluster`, matching
the three-level breadcrumb on `create-async-channel.html`. Both service pages keep the
`Kafka Clusters` sidebar entry in the `nav-link active` state, since the form is inside the service.

### UXD-002: List tables show 10 rows plus pagination; cluster row anchors are real targets

The cluster list now renders 10 mock rows out of 12 with the same `nav.pagination` markup used by
`async-channels.html` (`pagination-summary`, `current`, page links, next). Ten rows is the page size
already implied by the Async Channel list, so both services paginate identically and no new CSS was
needed.

Cross-page deep links (`kafka-topic-detail.html`, `async-channel-detail.html`, `home.html`) point at
`kafka-clusters.html#<cluster-name>`. Those fragments previously had no target anywhere in the
document, so each `<tr>` now carries an `id` equal to the cluster name. Mock data reuses the contexts
already established elsewhere in the prototype (`env=prod|staging`, `country=br|us|co|mx`,
`shard=s0`–`s9`) and preserves the four cluster names referenced by other screens.

### UXD-003: Provider is stored configuration, not a provisioning capability of Franz

A **Provider** is the background system that serves a capability to the fleet. For Kafka, it describes
how a cluster is deployed (`LocalDocker`, `MSK`, `Strimzi`) and holds the configuration a Fleet Agent
needs to provision and maintain that cluster.

**Franz's role is unchanged.** Franz stores provider configuration and never uses it — agents read it and
perform every real-world infrastructure action. This preserves the invariant stated in `003.3-kafka-cluster.md`
("Franz does not manage/interact with the clusters like brokers and infrastructure resource") and the
unidirectional, declarative property in the architecture overview. Registering a provider does not create,
contact, or validate infrastructure.

**Cardinality is 0..1, one to one when present.** The link from Kafka Cluster to Provider is optional. A
cluster with no provider is fully usable — Franz records it and topics still reconcile against it — and is
the correct representation for a cluster provisioned and operated outside Franz. When a provider is linked
the relationship is one to one in both directions, because the provider configuration identifies a single
deployment: an MSK cluster ARN, a Strimzi `Kafka` resource, or a Docker stack.

A provider may therefore exist before the cluster that uses it, so the cluster registration form offers only
*unlinked* providers. The wireframe mock data carries two unlinked clusters and the two matching unlinked
providers, so both empty states are visible rather than theoretical.

**Deployment mode is immutable after registration.** The configuration of one mode has no meaning in another,
so changing mode is a migration rather than an edit. The register form states this; migration is deferred.

**Providers carry no labels in this scope.** Context labels remain on the Kafka Cluster, where they are already
the authoritative placement selector. Adding a second label-bearing layer would require an inheritance and
precedence rule that is not yet defined, so the wireframe deliberately omits a provider label editor rather
than implying semantics that have not been decided.

**Terminology fix.** `001-ux/README.md` previously deferred "Async Channel types and providers other than
`kafka-topic`", where "provider" meant the technology implementing a channel — a different layer from this
one. That bullet now reads "Async Channel types other than `kafka-topic`" to free the term.

### UXD-004: Provider screens follow the established list + action page pattern

`providers.html` (list) and `register-provider.html` (form) reuse the conventions from UXD-001 and UXD-002:
plural-noun list page, verb-phrase action page, three-level breadcrumbs, Cancel returning to the list,
10 rows plus `nav.pagination`, and `<tr>` ids so cross-page deep links resolve.

The register form shows one mode-specific `.form-section` at a time, chosen by the deployment-mode select.
Hidden sections use the native `hidden` attribute — `.form-section` declares no `display` rule, so no CSS was
needed. Inputs inside hidden sections are also `disabled`, so a hidden field can never block form submission
or receive focus. The mode sections sit between the first and last `.form-section`, so the
`:first-child` / `:last-child` border rules stay correct regardless of which mode is showing.

### UXD-005: Navigation groups Clusters and Providers under Kafka

Providers are specific to the technology they serve, so a provider is not a fleet-wide service the way an
Async Channel is — a Provider only means anything relative to Kafka. Top-level destinations therefore sit at
the root of the sidebar, and only the technology-specific screens are grouped:

```text
Home
Async Channels
Kafka                 (expand / collapse)
  Clusters
  Providers
```

The uppercase `Console` and `Services` group headings were removed. They labelled every item in the sidebar
without distinguishing anything, so they cost a row of vertical space each and pushed real destinations down.
`Home` and `Async Channels` are single destinations, not groups, so they read better unheaded at the root.
Adding a capability later means adding a sibling collapsible group, not lengthening a flat list.

**The Kafka group expands and collapses**, in the style of the AWS EC2 console navigation. It is a native
`<details class="nav-group">` with a `<summary>`, so the behaviour needs no JavaScript and is keyboard
operable and screen-reader announced for free. The disclosure chevron is a CSS `::before` on the summary that
rotates 90 degrees under `[open]`; the default marker is suppressed via `list-style: none` plus
`::-webkit-details-marker`.

This is the one place CSS was genuinely missing, so `.nav-group` rules were added. The now-unused
`.sidebar-title` and `.nav-section` rules were deleted rather than left as dead code, making the change close
to size-neutral in the stylesheet.

Every page ships the group `open`, matching the AWS behaviour of expanded-by-default sections. `<details>`
state does not survive navigation in a static multi-page prototype, so a collapsed group would silently
re-expand on the next click and read as a bug rather than a feature.

Page identities are unchanged: the list page is still titled "Kafka Clusters" with breadcrumbs
`Console Home / Kafka Clusters`. Only the sidebar abbreviates to "Clusters", which reads correctly under the
"Kafka" group heading. The Kafka Cluster list gains a `Provider` column showing the linked provider or
`Not linked`, and the registration form gains an optional provider selector.

### UXD-006: "Provider" replaces "Backend"; a deployment mode may collect no configuration

**Rename.** The concept is now **Provider** throughout the UX doc and the prototype. "Backend" was ambiguous
in two directions at once: it collided with the existing use of "backend" for the technology implementing an
Async Channel, and it reads as *the thing being managed* rather than *the system that supplies it*. Provider
names the supplier of a capability, which is what the entity is. Renamed everywhere: screens
(`providers.html`, `register-provider.html`), navigation, FRNs (`frn:acme-platform:provider:*`), form and
element ids, scopes (`provider:create|read|update|delete`), and the prior UX decision records, which describe
this same unshipped design rather than a shipped one.

**MSK collects no configuration.** The MSK configuration section was removed from the register form. MSK
remains a selectable deployment mode: it is a managed service, so there is nothing for a Fleet Agent to
record beyond the agent endpoint. Rather than leaving a blank area when MSK is selected, the form shows an
explicit note, so "no configuration needed" is distinguishable from "configuration missing". The mode-toggle
script now tracks whether any section matched and reveals that note when none did, which generalises to any
future managed mode without further changes.

Because MSK survives as a mode, no mock data changed — providers named `*-msk` on the list screens remain
valid. If the intent was to drop MSK as a supported mode entirely, the list mock data and the provider names
that reference it would need to change with it.

### UXD-007: "Provider" becomes "Agent", a registered program with a type and a context selector

The "Provider" concept is replaced by **Agent**: a program registered with Franz that connects to the fleet
API over gRPC, pulls the work matching its context selector, and reports results. Franz never calls an agent.

An agent carries a **type**, used only as an organisational filter in the console — it does not change how
the agent connects:

| Type | Responsibility |
|---|---|
| Cluster Provider | Deploys and maintains a substrate — Kafka clusters, RabbitMQ, etc. Examples: `br-prod-msk`, `br-prod-strimzi`, `local-docker`. |
| Resource Provider | Realises individual resources — Kafka topics, RabbitMQ queues, SQS queues. Gregor Samsa is one. |
| Telemetry Agent | Publishes indicator data over the telemetry protocol. Governance reads these indicators. |
| Custom | Any other program acting on fleet data. |

**Consequences.** `providers.html` → `agents.html`, `register-provider.html` → `register-agent.html`. The
per-mode deployment configuration blocks (Docker / MSK / Strimzi) were dropped from the register form:
agents read deployment specifics from the fleet, they are not Franz-collected fields. The register form now
collects identity, type, fleet API endpoint, and a context selector (`=` and `IN (…)`). FRNs are
`frn:acme-platform:agent:*`; scopes are `agent:create|read|update|delete`. The Kafka Cluster list column and
registration selector are relabelled **Cluster Provider**, and one Cluster Provider agent may now serve many
clusters (previously 1:1). Deployment modes survive only as example agent names.

### UXD-008: Governance is a policy engine over agent-published indicators

Governance becomes a top-level navigation item (peer of Home and Async Channels). The Async Admin persona
(`policy:*` scopes) registers **policies**, each composed of:

- **Indicator** — a value published by a Telemetry Agent (`replica-size`, `avg-replica-per-broker`, …).
- **Matcher** — an entity (Kafka Topic, Kafka Cluster, Async Channel) and a label selector (`=`, `IN (…)`).
- **Limit** — a comparator (`< <= = != >= >`) against a value.
- **Actions** — `add_label`, `remove_label`, `set_status`, `update_field`, `increase_field_by`,
  `decrease_field_by`, run against every matched resource when the limit is crossed.
- **Weight** — breaks ties when several policies act on the same resource.

Actions change Franz's **declared** state only; the normal reconciliation path realises the change, so Franz
never touches infrastructure directly. Only the reactive-mutation model is in scope — admission/reject rules
from the `003.5` draft are not part of this UX.

**Screens.** `governance.html` (indicator summary strip + policy list), `register-policy.html` (builder with
a dry-run preview), `policy-detail.html` (definition + matched resources + action history), `indicators.html`
and `indicator-detail.html` (unit, source agents, samples, policies using it). A stale indicator — no sample
within its threshold — is surfaced as such and policies reading it do not act.

**Deferred** (called out in `001-ux/README.md`): the evaluation model — weight-based conflict resolution,
ordering, cooldown / anti-thrash, per-field action constraints — and the telemetry protocol wire format.
This is a UX example; the DSL and engine evolve separately.

**Navigation (revision).** Governance is a collapsible `<details class="nav-group">` group — matching the
Kafka group — holding **Indicators** and **Policies**, with no parent landing page (the `<summary>` is a
disclosure toggle, not a link). `governance.html` was split: the policy list moved to `policies.html`, and
the indicator health summary moved to the top of `indicators.html`. Breadcrumbs and topbar labels follow the
Kafka precedent — they name the leaf screen (`Policies`, `Indicators`), never the group.

### UXD-009: Async Channel detail shows load distribution and per-topic consumption control

The Generated Kafka Topics panel on `async-channel-detail.html` gains two table columns: **Traffic share**
(percentage of channel traffic written to the topic over 24h) and **Consumption** (`Consuming` /
`Consumption disabled`). Each row has a toggle button; a small script flips the row status, the button label,
and the traffic share (to `0%` on disable, restoring the prior value on enable).

**Semantics:** disabling consumption **drains** the topic — producers stop writing to it and its traffic
share drops to 0% — while the topic and its data are retained. Distinct from pausing the channel (which stops
Franz maintaining it) and from a `Pending reconciliation` control-plane status.

**No proportional bar and no CSS added.** An earlier draft rendered the split as a stacked bar; it was
removed in favour of the plain percentage column. `franz-console.css` is unchanged.

### UXD-010: Clients are label-only identities; permission lives entirely in the channel access policy

**Clients.** A client is a fleet-wide identity — globally unique `name` (= FRN `frn:acme-platform:client:<name>`)
plus labels (at least `org.com/owner`). It carries **no Read/Write role**: a client is just an identity, and
every permission comes from the channel it connects to. Navigation: "Async Channels" becomes a
`<details class="nav-group">` group holding **Channels** (`async-channels.html`) and **Clients**
(`clients.html`), matching the Kafka/Governance grouping. New screens `clients.html`, `register-client.html`,
`client-detail.html`; scopes `client:*`.

**Access policy.** Each channel has **one policy document** (S3-bucket-policy style): a list of statements,
each with an **effect** (`Allow` / `Deny`, `EFFECT_UNSPECIFIED` rejected), a **principal** (client FRN,
label selector, or both — `*` wildcard allowed in both the FRN and label values), and one or more
`permissions` (`Read` / `Write`). Evaluation for `(client, action)`: explicit `Deny` wins → explicit
`Allow` → otherwise no access (**zero trust**). So a broad `Allow` (`client:xpto-*`) can coexist with a
narrow `Deny` (`client:xpto-blah`). Authored on the channel (create form has a statement builder; detail
page shows statements + rendered document + a derived "Clients with access" table). Edited via
`async-channel:update`, never on the client. The client-detail page shows the reverse view — every channel
whose policy matches this client.

**Consumer groups are not a Franz entity.** Default group is `<client>.<topic>`; a custom name can be passed
to the SDK. Telemetry Agents observe running groups and link them to client + owner; the client-detail page
lists them read-only. No group registry, no group config.

**SDK.** Initialised with channel FRN + client FRN; Franz checks the policy before publish/subscribe. The
`async-channel-detail.html` SDK snippets gained `.clientFrn(...)` / `ClientFRN:`. Client credentials deferred.

The new screens reuse existing table, `label-builder`, and `code-box` patterns. Two small CSS additions:
`.label-builder-controls` now wraps (`flex-wrap: wrap`), and `.label-builder > textarea` is styled full-width
— the channel access-policy statement builder puts the principal on its own wide textarea row rather than
cramming a label selector into a narrow flex cell.

## API Contract (`franz/api/franz/v1`)

### ADR-API-001: protobuf/gRPC is the authoritative Franz contract

The Franz wire contract is protobuf (**edition 2024**) under `franz/api/franz/v1/`, generated with
**buf** to `pkg/gen/go/` (committed). One API surface for the console and the agents; a
**grpc-gateway** REST/JSON mapping is declared inline via `google.api.http` on console-facing RPCs.
Edition 2024's default `field_presence = EXPLICIT` is kept (every scalar is presence-tracked), which
suits FieldMask-based partial updates and distinguishing "unset" from a zero value. The
`docs/003-franz/` specs describe intent and semantics; the `.proto` files are authoritative for
message and service shapes.

**Codegen note (deliverable 01).** Edition 2024 **defaults `api_level` to `API_OPAQUE`** in
`protoc-gen-go` (≥ v1.36) — hidden fields, `Get*`/`Set*` accessors. The `default_api_level=` /
`apilevelM<path>=` plugin flags are **ignored** for edition-2024 files (the edition default wins); the
only way to force the open API back is `option features.(pb.go).api_level = API_OPEN;` *in the
`.proto`* — which we do not do. Instead: **`protoc-gen-grpc-gateway` is run with
`use_opaque_api=true`** (its default `false` emits Open-Struct field access — `protoReq.Name = …` —
that will not compile against opaque messages; with the flag it emits `protoReq.SetName(…)`). Opaque
support requires grpc-gateway ≥ v2.27.3 (edition-2024 support ≥ v2.29.0; latest is v2.30.0).
`buf.gen.yaml` lives at the `franz/` root; `buf.yaml` + `buf.lock` under `api/`. `go.mod` is `go 1.25`
(transitive gRPC requirement).

Files: `common`, `kafka` (`KafkaCluster` + `KafkaTopic`, consumption, traffic share, both services),
`async_channel` (+ access policy), `agent` (registry only), `client`, `governance` (`Policy` + `Indicator`),
`telemetry`. **The agent ↔ Franz interaction model (how agents receive work and report results) is deferred
to a separate ADR — there is no `fleet.proto`.**

Conventions (full detail in `003-franz/003.1-conventions.md`): **every RPC has its own `{Method}Request` and
`{Method}Response`** — no shared or bare-resource returns, no `google.protobuf.Empty` (Delete returns an
empty `{Method}Response`). Get/Create/Update responses wrap the resource in a single field.
`PageRequest`/`PageResponse` from `common.proto`; label selectors and FRNs are strings; custom verbs use
`:verb` (`:pause`, `:setConsumption`, `:dryRun`). buf lint `STANDARD` with **no exceptions**. FRN is
`frn:<realm>:<type>:<name>` (realm = the tenant/authz boundary). Every timestamp field uses the `_at` suffix.

**Explicit requests, no `field_behavior`.** Every `Create*` / `Update*` / `DryRun*` request lists only the
client-settable fields — it never embeds the resource message. Server-assigned fields (`frn`,
`created_at`, `updated_at`, derived `state`/`status`/`traffic_share`/`generation`) exist only on the
resource message, which appears only in responses. `google.api.field_behavior` / `OUTPUT_ONLY` was dropped
entirely: it's a doc-only annotation that only earned its keep under resource-embedded requests, which we no
longer use. `Update*` requests keep a `google.protobuf.FieldMask update_mask` for partial updates. Gateway
`body: "*"` and `{name}` path params throughout.

**Kafka Cluster shape:** broker addresses live in `repeated ConnectionString connection_strings`
(`bootstrap_urls` + `ConnectionType`, today only `PLAINTEXT`) so authenticated connection types can be added
without a breaking change. The cluster's default Kafka settings are an inline `map<string,string>
cluster_configuration` (no `TopicConfiguration` reference). The Cluster Provider link is
`cluster_provider_agent`.

**REST namespacing** (grpc-gateway paths) mirrors the console navigation groups:
`/v1/kafka/{clusters,topics,agents}`, `/v1/governance/{policies,indicators}`,
`/v1/async-channels/…`, `/v1/clients/…`. Agents sit under `/v1/kafka/` because the console groups them there
while Kafka is the only capability; a capability-neutral `/v1/fleet/agents` is the likely future move. gRPC
service/method names are unchanged — this is gateway routing only.

### ADR-API-002: entity renames, expansion / TopicRevision / TopicConfiguration removed

`Topic Definition` → **`AsyncChannel`**, `Topic Claim` → **`KafkaTopic`**. The expansion engine is
superseded (see `003-franz/README.md`) — placement is a step of `AsyncChannel` create/update.

**`TopicConfiguration` is removed for now.** No named, reusable, CRUD-managed config entity. Kafka topic
settings are plain `map<string, string>` merged by Franz across two layers:
`KafkaCluster.cluster_configuration` → `KafkaTopic.topic_configuration`. `AsyncChannel` carries **no** Kafka
config — it's the transport-agnostic boundary, and `001-ux` puts Kafka-specific settings on the generated
topics. The merged map is what an agent applies when it reconciles the topic (delivery mechanism TBD in the
interaction ADR). No `/v1/kafka/topic-configurations` routes.

**Field trims.** `AsyncChannel` dropped `context_selector` (a dedicated placement-selector string);
placement inputs live in `labels` (`franz.affinity/*`), per `003.7`. `Agent` dropped `context_selector`
and `fleet_api_endpoint` — it is now `name` + `type` + `labels` + status/timestamps. `labels` is metadata
and an extension point. The demo's `register-agent` form still shows the removed fields (`UXD-007`); it will
be reconciled later.

**Agent interaction model removed / deferred.** An earlier `fleet.proto` defined a pull-based
`FleetService` (`PollWork` / `ReportWork` / `WorkItem` / outcomes). It is **deleted** — the way agents
receive work, report results, recover from errors, and are scoped is a distinct architecture question for a
separate ADR, not something to fix in the proto yet.

**`TopicRevision` is removed for now.** Rationale: the per-attempt revision entity (state machine +
retry chain + stale-revision guard) added a lot of surface for a first cut. Instead, `KafkaTopic` carries
its desired state directly plus an `int64 generation` (a bare optimistic-concurrency token — its exact use
belongs to the interaction ADR). `traffic_share` is a `TrafficShare` message (`value` + `unit`).

**Trade-offs accepted:** no per-attempt failure history or error/retry-chain audit, and no
`ListTopicRevisions` endpoint. No explicit topic-retry RPC. Migration/delete flows in `003.11` that were
revision-based need a rework when revisited.

Superseded by ADR-API-003 — the full `003-franz/` rewrite is complete.

### ADR-API-003: 003-franz doc restructure + resolved entity semantics

**Doc strategy.** `.proto` files under `franz/api/franz/v1/` are authoritative for **shapes and RPCs**; the
`003.x` markdown is authoritative for **semantics, invariants, state transitions, and cross-entity
behaviour**. Markdown keeps only a short "key fields" summary + a link to the proto — no full field tables.
`003-franz/` was renumbered once to a 0–11 layout (`003.6-expansion-engine.md` deleted; several files
renamed). This entry accumulates the design decisions settled during the rewrite.

**Readiness.** `Status: ready` — `003-franz/README` (index), `003.1`, `003.3`, `003.5`, `003.6`,
`003.9`, `003.10`. Still `Status: draft` — `003.4` (shard routing → SDK ADR), `003.7` (retry-sweep
interval, uneven distribution), `003.8` (per-action caps, config-key set), `003.11` (control-plane
event log), `003.12` (sample volume / TSDB question), `003.13` migration & data movement (data-copy
mechanism), `003.14` telemetry ingest (agent auth, ingest→eval delivery). `003.2` is a deliberate
placeholder (`Status: open — not yet decided`). Most remaining draft open questions are narrowed —
see ADR-API-005.

**Kafka Cluster (`003.3`).**
- Cluster has a persisted `state`: `ACTIVE` / `PAUSED` / `DELETED` only (no degraded/draining/health yet).
  `PauseKafkaCluster` / `ResumeKafkaCluster` toggle `ACTIVE ↔ PAUSED`; `PAUSED` removes the cluster from
  **new** placement without touching existing topics. `DeleteKafkaCluster` is a terminal soft delete.
  Proto: added `KafkaClusterState` enum + `state` field + `Pause`/`Resume` RPCs to `kafka.proto`.
- `cluster_provider_agent` is an **unvalidated** free string — Franz does not check the agent exists or is
  a Cluster Provider.
- Editing `cluster_configuration` applies to **new topics only**; already-created topics keep their
  materialized config and are not re-reconciled.
- **Still open (own ADR):** deleting a cluster that still hosts live topics — today a hard
  `FAILED_PRECONDITION`; whether to add a `force`/drain path is deferred.

**Async Channel (`003.4`).**
- Abstract resource — carries **no** Kafka configuration.
- `ChannelState` trimmed to `ACTIVE` / `PAUSED` / `DELETED` (no `PENDING`/`ERROR` — reconciliation
  progress and failures live on the individual Kafka Topics). Pause stops reconciling the channel's
  shards; delete is a terminal soft delete. Proto: `ChannelState` enum reduced in `async_channel.proto`.
- `channel_partitions` = **shard count**. Franz splits the channel into that many Kafka Topics named
  **`<async-channel-name>-<index>`** (`0..n-1`); the cluster name is **not** in the topic name, so a
  shard keeps its name across re-placement. Shards may sit on different clusters.
- Changing `channel_partitions` (up *or* down) is a **staged re-shard operation** with drain steps to
  avoid data loss — not an `UpdateAsyncChannel` field. Concrete RPC/steps → `003.11`.
- `access_policy` is mutated only via `SetAccessPolicy`, never an `UpdateAsyncChannel` mask.
- **Still open:** re-shard RPC + step sequencing, shard routing key/hash, re-placement on label change.

**Kafka Topic (`003.6`).**
- Franz owns the entity end to end — no `Create` / `Update` / `Delete` RPC, and **no manual retry RPC**
  (`ERROR` shards are re-offered automatically). `SetConsumption` is the only client-facing mutation.
- `KafkaTopicState` keeps `PENDING` / `READY` / `PAUSED` / `ERROR` / `DELETED` — this is where
  reconciliation progress/failure lives (the channel no longer has `PENDING`/`ERROR`). Channel pause/delete
  propagate to the shards.
- `consumption` is **orthogonal** to `state`. `CONSUMPTION_DISABLED` drains the shard: producers re-route
  its key range to the channel's other shards, `traffic_share` → 0, topic + data retained. This is the
  mechanism the re-shard flow uses to retire a shard.
- Config merge is two layers, `cluster_configuration ← topic_configuration`, **materialised at
  create/change time**; not re-applied when `cluster_configuration` later changes.
- Partition count and replication factor are **dedicated `KafkaTopic` fields** (`partitions`,
  `replication_factor`) — *not* config-map keys. Franz seeds them from cluster defaults;
  `partitions` may only increase.
- `traffic_share` is an **intended** producer-routing split, **not** a telemetry measurement. Franz keeps
  an equal split across `ENABLED` shards and rebalances on drain/restore/re-shard. Proto `traffic_share`
  comment reworded.
- No persisted `error` string on the topic; failure reason is surfaced through operational signal
  (`003.11`).
- **Still open:** exact cluster-default keys that seed `partitions`/`replication_factor`, the
  operator/governance override path for `traffic_share`, automatic-retry cadence, `generation` echo rules.

**Access Policy (`003.5`).**
- One `AccessPolicy` per channel, embedded in `AsyncChannel`, replaced wholesale by `SetAccessPolicy` —
  no per-statement add/remove RPC. Data-plane only (SDK read/write); distinct from `003.2` API authz.
- A `Principal` matches on `client_frn` **OR** a label selector (at least one set) — `*` glob per `003.1`.
- Evaluation for `(client, action)`: matched **DENY** wins → matched **ALLOW** → deny (zero trust).
  Order-independent. READ and WRITE evaluated separately. `EFFECT_UNSPECIFIED` rejected at write.
- A statement whose `client_frn` resolves to no Client is **valid** (matches nothing) — supports
  pre-provisioning and survives client deletion (FRNs are not reclaimed).
- `Client` holds **no** permission of its own. Governance never writes access policies.
- **Still open:** SDK enforcement point + live-connection behaviour on policy change, statement cap value,
  `ListChannelClients` evaluation cost, `matched_by` semantics on multi-match.

**API Authorization (`003.2`) — deferred.** The authorization model for console / API callers is **not
decided**; `003.2` is a placeholder framing the problem and listing options (permission unit, verb
granularity, resource-scoped grants, telemetry/agent boundary, cross-realm access, representation).
Only the invariants stand: authenticated + realm-scoped caller, checked centrally before the handler,
`PERMISSION_DENIED` / `UNAUTHENTICATED`. **Authentication** is a further separate ADR, also unwritten.
Note: the *data-plane* access policy (`003.5`) is decided and unaffected.

**Placement & Selection (`003.7`).**
- Placement is **label-only** — no cluster field on `AsyncChannel`. Channel declares intent via
  `franz.affinity/selector` (003.1 grammar), `franz.antiaffinity/selector` (negation),
  `franz.affinity/shard-size` (how many distinct clusters to spread shards across, default 1),
  `franz.taint/toleration`. Cluster describes itself via `franz.taint` (`no-creation` / `drain`) and
  `franz.affinity/weight` (default 1).
- Deterministic 5-step algorithm: ACTIVE clusters matching affinity → minus anti-affinity → minus
  untolerated taints → order by weight desc then `name` asc → round-robin the `channel_partitions`
  shards across the top `min(shard-size, |candidates|)` clusters.
- `no-creation` blocks new shards (tolerable); `drain` blocks new **and** marks existing shards for
  migration (untolerable). Migration flow → `003.11`.
- **Still open:** absent-selector semantics (this doc assumes "no candidates"), no-eligible-cluster
  behaviour, re-placement on label change (only `drain` forces a move today), `shard-size` ↔
  `channel_partitions` interplay, a dry-run `PreviewPlacement` RPC, multi-toleration encoding.

**Governance (`003.8`).**
- **Reactive only — no admission control.** A Policy never rejects or delays a `Create`/`Update`; it
  watches an Indicator and mutates *declared* state after the fact, which then reconciles. The old
  `reject-topic-creation` / `reject-*` actions are removed.
- `Policy` = `indicator` + `Matcher` (entity + 003.1 selector) + `Limit` (one `operator` + string
  `value` in the indicator's unit) + ordered `actions` + `weight` (higher wins ties) + `enabled`. A
  lower+upper band is **two policies**.
- 6 `ActionKind`s: `ADD_LABEL` / `REMOVE_LABEL` / `SET_STATUS` / `UPDATE_FIELD` / `INCREASE_FIELD_BY` /
  `DECREASE_FIELD_BY`; `amount` may be a percentage.
- Actions change **declared state only** — never call agents, never edit access policies (`003.5`).
- Disabled policies and stale indicators (past `staleness_threshold`) never fire. Every automated
  change is a `PolicyAction` audit record. `DryRunPolicy` takes an inline definition and neither
  mutates nor audits.
- `Indicator` is read-only over `GovernanceService`; samples arrive via `telemetry.proto` from
  Telemetry Agents.
- **Still open:** the `(entity, field)` write whitelist for `*_FIELD` actions and per-entity
  `SET_STATUS` values; equal-weight conflict resolution; anti-thrash / hysteresis; evaluation cadence;
  saved-policy dry-run + `simulated_effect`; unknown-indicator handling; range limits; how `Indicator`
  records are provisioned (no `CreateIndicator` today).

**Agents (`003.9`).**
- The doc is the **registry + lifecycle only**. `Agent` = `name` (immutable key) + `type` + `labels` +
  server-managed `status` / `last_contact_at`.
- The 4 `AgentType`s are an **organisational filter only** — no effect on how the agent connects, what
  it may do, or how Franz treats it.
- Franz **never calls an agent**; agents connect in. Registration is inert (no connection, no work).
- `AgentStatus` is a **lifecycle** machine — `ACTIVE` / `PAUSED` / `DELETED` only, mirroring Kafka
  Cluster (`003.3`): `PauseAgent` / `ResumeAgent` toggle `ACTIVE ↔ PAUSED`, `DeleteAgent` is a terminal
  soft delete. **Agent liveness/health is not modelled** — `last_contact_at` and any connected/stale
  signal are dropped for now, to be added later if needed. Proto: `AgentStatus` enum rewritten,
  `last_contact_at` removed, `Pause`/`Resume` RPCs added.
- The `cluster_provider_agent` link stays an unvalidated string (`003.3`) — dangling references
  tolerated.
- **Deferred to their own ADRs:** the agent ↔ Franz interaction model, agent liveness/health,
  telemetry ingest semantics, agent authentication.
- **Still open:** endpoint namespace (`/v1/kafka/agents` vs `/v1/agents`), whether `type` is mutable,
  delete-while-referenced behaviour, exact `PAUSED` semantics, `labels`-as-work-scoping.

**Clients (`003.10`).**
- A `Client` is a **realm-wide, flat-namespace** SDK identity. **No** type / role / state field, and
  **no permission of its own** — the channel access policy (`003.5`) is the sole authority for
  Read/Write. Labels *should* carry `org.com/owner`.
- **Consumer groups are not registered.** Default name `<client-name>.<topic-name>`; custom names
  allowed. Franz learns of groups only from Telemetry Agents as `ObservedConsumerGroup` (observation,
  not declaration).
- `ListClientChannelAccess` and `ListObservedConsumerGroups` are **read-only projections** computed on
  read.
- `DeleteClient` does not free the `name` / FRN; FRN-matched policy statements go dormant.
- **Deferred:** client credentials (issuance / rotation / proof), connection testing.
- **Still open:** owner-label enforcement, custom-group→client attribution, deletion cascade + name
  reuse, `ObservedConsumerGroup` retention, realm-wide vs future sub-scope.

**Lifecycle & Operations (`003.11`).** Coordinating doc — per-entity state machines stay in their own
`003.x` files.
- **Pause** (cluster / channel / agent) is always reversible and never removes real-world resources:
  cluster = out of new placement, channel = its shards go `PAUSED`, agent = no work handed to it.
- **Soft delete** (cluster / channel / topic / agent) → terminal `DELETED`, retained for audit,
  `name` / FRN **never freed**, `FAILED_PRECONDITION` afterwards. Channel delete cascades to its shards.
  `Client` currently has no `DELETED` state — reconciling that is open.
- **Cluster delete with live topics** and **shard migration** (drain taint / re-placement) share one
  unsolved problem: there is no data-movement RPC, mechanism, or safety guarantee — its **own ADR**.
  The old `cluster-migration` endpoint and `TopicRevision` are gone; error recovery is continuous
  reconciliation, not revisions.
- **`SetConsumption(DISABLED)`** is the shared drain primitive for re-shard and migration.
- **History**: only `PolicyAction` (`003.8`) is persisted. There is **no general control-plane event
  log** (state transitions, reconciliation outcomes, operator actions) — designing one is open, and
  reconciliation failure reasons (`003.6`) have nowhere durable to live yet.

### ADR-API-004: persistence and data model

Full doc: `003-franz/003.12-persistence-and-data-model.md`.

- **PostgreSQL only.** Reached solely through `franz/pkg/franz/adapters/out/postgres/`, implementing
  `core/ports/out`; `core/domain` and `core/usecases` hold no SQL.
- **Table per entity**, surrogate `id uuid` PK; domain identity is a `UNIQUE (realm_id, name)`
  constraint plus a `UNIQUE` `frn` column. `name` is never reused (constraint is unconditional).
- **`realm_id` on every table**; every query is realm-scoped.
- **Enums = `text` + `CHECK`** (not PG `enum`); the proto enum is the source of truth.
- **`jsonb` for maps and documents** — `labels`, `cluster_configuration`, `topic_configuration`
  (GIN-indexed for selectors), `connection_strings`, `access_policy` (whole document), `actions`.
- **Soft delete** = `state = 'DELETED'` row retained; repos hide it by default, `Get` still returns it.
- **`kafka_topic` stores both** `topic_configuration` (override) and `materialized_configuration` (the
  frozen `cluster_configuration ⊕ topic_configuration` the agent reconciles against — matches the
  "`cluster_configuration` edits hit new topics only" rule from `003.3`/`003.6`).
- **Telemetry ingest tables**: `indicator_sample` (latest-only upsert per `(indicator, resource_frn)`),
  `observed_consumer_group` (upsert). `policy_action` is append-only.
- **Derived views** (`ChannelClientAccess` / `ClientChannelAccess`) are computed in Go, not stored.
- **Optimistic concurrency** via `WHERE updated_at = $prev`; `kafka_topic.generation` is the separate
  domain token. Compound operations (channel + shards + placement) are one transaction.
- **Migrations: Flyway** in `franz/migrations/`; single `V1__init.sql` edited in place until the schema
  is frozen.
- **Still open:** query layer (`pgx`+`sqlc` vs hand-written vs ORM), `indicator_sample` history/retention,
  Client-deletion FRN reservation, `realm` bootstrap, how much selector grammar pushes down to SQL,
  whether staged operations need their own state tables, `updated_at` vs a dedicated `row_version`.
  *(Most of these are resolved in ADR-API-005.)*

### ADR-API-005: implementation-planning decisions (Franz build)

Decisions made while turning the specs into `franz/implementation_plan.md`. They update the draft specs
`003.4` / `003.7` / `003.8` / `003.12` and add `003.13` (migration) and `003.14` (telemetry ingest).

**Persistence & runtime (`003.12`).**
- Query layer: **hand-written `pgx/v5`** — no ORM, no query generator. Dynamic `List*` filters built as
  parameterised `WHERE` fragments in Go.
- Lost-update prevention: **`SELECT … FOR UPDATE`** inside the update transaction. No version column, no
  client token; last committed write wins across requests.
- Realm bootstrap: **one `default` realm seeded in `V1__init.sql`**; a context resolver returns it for
  every request until auth (`003.2`) carries the realm.
- Config: **checked-in `config.yaml` + `FRANZ_`-prefixed env overrides via `koanf`** (supersedes the
  `DB_*` convention in `106-operations`).
- Migrations (impl of deliverable 02, refines `003.12`): Flyway stays the authority, **and** Franz
  embeds `migrations/*.sql` and applies them on boot when `db.auto_migrate` is set (default on). Every
  statement in `V1__init.sql` is idempotent (`… IF NOT EXISTS`, `ON CONFLICT DO NOTHING`) so the two
  paths cannot conflict; disable `db.auto_migrate` wherever Flyway owns schema changes.

**Placement (`003.7`).**
- Absent `franz.affinity/selector` ⇒ **no candidates**; the channel's shards stay `PENDING` /
  `kafka_cluster = NULL`.
- No eligible cluster ⇒ shard stays unplaced; a **retry sweep (~30 s)** places it when a cluster
  becomes eligible. Channel create never fails for this.
- Re-placement of an already-placed shard: it is **never moved silently**. Losing eligibility marks it
  *misplaced* and queues a migration (`003.13`) — **auto-relocate**. Interim (until the migration flow
  lands): only the marker is set.

**Governance (`003.8`).**
- Write whitelist: **full enumerated matrix** (see `003.8`). Includes `channel_partitions` ↑/↓,
  `franz.taint` = `no-creation` **or** `drain`, `franz.affinity/*` + `antiaffinity/*` edits,
  `SET_STATUS` → `PAUSED` / `ACTIVE` / `DELETED` on channel and cluster. `KafkaTopic.state` is not
  writable.
- Conflict on the same `(resource, field)`: apply in `(weight desc, name asc)` order, **last write
  wins**; every action logged.
- **No anti-thrash** (no cooldown / hysteresis) — deferred until flapping is observed. Per-action
  caps are the only bound.
- Evaluation is **event-driven per incoming sample** (couples the eval loop to telemetry ingest).
- Governance's placement / taint / re-shard actions all resolve to the migration flow (`003.13`);
  until it lands they queue work that does not execute.

**Telemetry ingest (`003.14`, new).**
- Indicators are **pre-registered** by an admin — `CreateIndicator` / `UpdateIndicator` /
  `DeleteIndicator` added to `GovernanceService`. Samples / policies for an unknown indicator are
  rejected.
- `indicator_sample` and `observed_consumer_group` are **append-only time series**, pruned nightly at
  **30 days**. `ListIndicatorSamples` and `ListConsumerGroupObservations` added. "Current" value is
  the latest `sample_at` per `(indicator, resource)`.

**Migration & data movement (`003.13`, new).** The single flow behind re-placement, `drain`,
cluster-delete-with-live-topics, re-shard, and the governance placement actions. v1 is **drain-based**
— no historical byte copy; the serving position moves, not the bytes. A `shard_migration` bookkeeping
table tracks phases. **On the critical path** — it blocks completing `003.7`, `003.3` cluster delete,
`003.4` re-shard, and governance OQ1a–c.

**Shard routing key** — deferred to a future **SDK/client ADR**; Franz stores only `channel_partitions`.

**API authorization** — remains a `003.2` placeholder; near-term implementation stubs an allow-all
interceptor behind the realm resolver.

### ADR-006: Cluster Provider agent + local Kafka Docker agent

Full doc: `004-local-kafka-docker-agent/README.md`. The first agent-interaction contract (Cluster
Providers) and the first agent implementation. Feature 1 of `franz/docs/impls_plan/`.

- **Transport** — `ClusterProviderService.WatchClusterAssignments` (server-stream, Franz → agent, full
  set on open then deltas) + `ReportClusterStatus` (unary). New `agent_cluster_provider.proto`. Franz
  holds an in-memory per-agent stream registry.
- **Auth** — a **bearer token minted at `CreateAgent`**, returned once, stored hashed on the `agent`
  row; `authorization: Bearer` metadata; `RotateAgentToken` RPC. Self-contained, independent of `003.2`.
- **Provisioning intent** — expressed with **`franz.provisioning/*` reserved labels** on
  `KafkaCluster.labels` (`deployment-type`, `kafka-version`, `brokers`, `disk-size`, …). No new
  `KafkaCluster` field; the prefix is open. Added to the `003.1` reserved-label set.
- **Status** — the agent's reports are an **append-only `cluster_provider_event`** log (30-day prune);
  current status = the latest event, surfaced as `KafkaCluster.provider_status` (read-only, distinct
  from `state` = operator intent) + a `ListClusterProviderEvents` RPC.
- **Recipe** — **agent-owned**, selected by `franz.provisioning/deployment-type`; the agent reports
  `recipe_ref` (name + rendered-spec hash).
- **Agent implementation** — **Go, in the Franz module** (`cmd/local-kafka-agent/`,
  `pkg/localkafka/`); **Docker Engine API SDK** (no compose); **stateless** — Docker container labels
  (`franz.cluster`, `franz.managed-by`, `franz.recipe-hash`) are the store.
- **`local-docker` recipe** — one `apache/kafka` KRaft container per cluster; version from the label;
  `brokers > 1` warned + ignored (multi-broker deferred).
- **Proto** — `agent.proto`: `token` in `CreateAgentResponse`, `RotateAgentToken`.
  `common.proto`: `ClusterProviderPhase`. `kafka.proto`: `KafkaCluster.provider_status`,
  `ClusterProviderStatus`, `ClusterProviderEvent`, `ListClusterProviderEvents`.
  New `agent_cluster_provider.proto`.
- **Still open** (ADR §Open questions): multi-broker recipe, `READY` vs `DEGRADED` health probe, local
  port conflicts, a derived "agent connected" flag, non-bundled recipe distribution,
  `cluster_provider_event` retention.

### ADR-API-007: resource identifier is the FRN, with a configurable prefix

Supersedes the "ORN" naming in ADR-API-003 / ADR-API-005 and the `003.1` conventions.

- The resource identifier is the **FRN** (Franz Resource Name), format
  `frn:<realm>:<resource-type>:<name>`. "ORN" is retired as a term; all specs, proto comments, Go code
  (`pkg/franz/core/domain/frn`), proto fields (`frn`, `client_frn`, `resource_frn`, `cluster_frn`), and
  DB columns use `frn`.
- **The prefix is configurable.** Control-plane config key `resource_prefix` (env
  `FRANZ_RESOURCE_PREFIX`), default `frn`, must match `^[a-z][a-z0-9]*$` (2–16 chars). It is **read
  once at bootstrap and immutable** for the life of the deployment.
- **Persistence is prefix-less.** The `frn` column stores the bare
  `<realm-slug>:<resource-type>:<name>` path; the prefix is applied only when rendering an API
  response. Changing `resource_prefix` therefore never rewrites stored rows.
- **Parsing is lenient.** The parser accepts the configured prefix and *always* accepts the literal
  `frn:` and `orn:` prefixes as aliases, so identifiers copied from another deployment (or from the
  pre-rename `orn:` era) still resolve.
- Rationale: matches the AWS-ARN-style pattern teams already know, lets an operator brand identifiers
  for their org, and keeps the stored identity independent of a presentation setting.
