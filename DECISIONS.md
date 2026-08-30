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
perform every real-world infrastructure action. This preserves the invariant stated in `003.1-kafka-cluster.md`
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

**Terminology fix.** `001.1-ux.md` previously deferred "Async Channel types and providers other than
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
(`providers.html`, `register-provider.html`), navigation, ORNs (`orn:acme-platform:provider:*`), form and
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
collects identity, type, fleet API endpoint, and a context selector (`=` and `IN (…)`). ORNs are
`orn:acme-platform:agent:*`; scopes are `agent:create|read|update|delete`. The Kafka Cluster list column and
registration selector are relabelled **Cluster Provider**, and one Cluster Provider agent may now serve many
clusters (previously 1:1). Deployment modes survive only as example agent names.

### UXD-008: Governance is a policy engine over agent-published indicators

Governance becomes a top-level navigation item (peer of Home and Async Channels). The Async Admin persona
(`policy:*` scopes) registers **policies**, each composed of:

- **Indicator** — a value published by a Telemetry Agent (`replica-size`, `avg-replica-per-broker`, …).
- **Matcher** — an entity (Kafka Topic, Kafka Cluster, Async Channel) and a label selector (`=`, `IN (…)`).
- **Limit** — a comparator (`< <= = != >= >`) against a value.
- **Actions** — `add_label`, `set_status`, `update_field`, `increase_field_by`, `decrease_field_by`, run
  against every matched resource when the limit is crossed.
- **Weight** — breaks ties when several policies act on the same resource.

Actions change Franz's **declared** state only; the normal reconciliation path realises the change, so Franz
never touches infrastructure directly. Only the reactive-mutation model is in scope — admission/reject rules
from the `003.5` draft are not part of this UX.

**Screens.** `governance.html` (indicator summary strip + policy list), `register-policy.html` (builder with
a dry-run preview), `policy-detail.html` (definition + matched resources + action history), `indicators.html`
and `indicator-detail.html` (unit, source agents, samples, policies using it). A stale indicator — no sample
within its threshold — is surfaced as such and policies reading it do not act.

**Deferred** (called out in `001.1-ux.md`): the evaluation model — weight-based conflict resolution,
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

**Clients.** A client is a fleet-wide identity — globally unique `name` (= ORN `orn:acme-platform:client:<name>`)
plus labels (at least `org.com/owner`). It carries **no Read/Write role**: a client is just an identity, and
every permission comes from the channel it connects to. Navigation: "Async Channels" becomes a
`<details class="nav-group">` group holding **Channels** (`async-channels.html`) and **Clients**
(`clients.html`), matching the Kafka/Governance grouping. New screens `clients.html`, `register-client.html`,
`client-detail.html`; scopes `client:*`.

**Access policy.** Each channel has **one policy document** (S3-bucket-policy style): a list of statements,
each with a **principal** (client ORN, label selector, or both) granting `Read` / `Write`. **Zero trust** —
no matching statement means no access. Authored on the channel (create form has a statement builder; detail
page shows statements + rendered document + a derived "Clients with access" table). Edited via
`async-channel:update`, never on the client. The client-detail page shows the reverse view — every channel
whose policy matches this client.

**Consumer groups are not a Franz entity.** Default group is `<client>.<topic>`; a custom name can be passed
to the SDK. Telemetry Agents observe running groups and link them to client + owner; the client-detail page
lists them read-only. No group registry, no group config.

**SDK.** Initialised with channel ORN + client ORN; Franz checks the policy before publish/subscribe. The
`async-channel-detail.html` SDK snippets gained `.clientOrn(...)` / `ClientORN:`. Client credentials deferred.

The new screens reuse existing table, `label-builder`, and `code-box` patterns. Two small CSS additions:
`.label-builder-controls` now wraps (`flex-wrap: wrap`), and `.label-builder > textarea` is styled full-width
— the channel access-policy statement builder puts the principal on its own wide textarea row rather than
cramming a label selector into a narrow flex cell.

## API Contract (`api/proto/franz/v1`)

### ADR-API-001: protobuf/gRPC is the authoritative Franz contract

The Franz wire contract is protobuf (**edition 2024**) under `api/proto/franz/v1/`, generated with
**buf** to `pkg/gen/go/` (committed). One API surface for the console and the agents; a
**grpc-gateway** REST/JSON mapping is declared inline via `google.api.http` on console-facing RPCs.
Edition 2024's default `field_presence = EXPLICIT` is kept (every scalar is presence-tracked), which
suits FieldMask-based partial updates and distinguishing "unset" from a zero value. The
`docs/003-franz/` specs describe intent and semantics; the `.proto` files are authoritative for
message and service shapes. Agent-facing services (`FleetService`, `TelemetryService`) are gRPC-only.

Files: `common`, `kafka` (`KafkaCluster` + `KafkaTopic` + `TopicRevision`, consumption, traffic share, both
services), `topic_configuration`, `async_channel` (+ access policy), `fleet` (Resource Provider pull/report),
`agent` (registry), `client`, `governance` (`Policy` + `Indicator`), `telemetry`.

Conventions: **every RPC has its own `{Method}Request` and `{Method}Response`** — no shared or bare-resource
returns, no `google.protobuf.Empty` (Delete returns an empty `{Method}Response`). Get/Create/Update responses
wrap the resource in a single field. `PageRequest`/`PageResponse` from `common.proto`; label selectors and
ORNs are strings; custom verbs use `:verb` (`:pause`, `:setConsumption`, `:dryRun`). buf lint `STANDARD`
with **no exceptions**.

**Server-assigned fields** (`orn`, `id`, `create_time`, `update_time`, and derived `state`/`status`/
`traffic_share`/`last_*`) are marked `[(google.api.field_behavior) = OUTPUT_ONLY]` — the client provides only
`name` (or `name` + labels) at registration; Franz mints the ORN.

**Kafka Cluster shape:** broker addresses live in `repeated ConnectionString connection_strings`
(`bootstrap_urls` + `ConnectionType`, today only `PLAINTEXT`) so authenticated connection types can be added
without a breaking change. The cluster's default Kafka settings are an inline `map<string,string>
cluster_configuration` (no `TopicConfiguration` reference). The Cluster Provider link is
`cluster_provider_agent_orn`.

**REST namespacing** (grpc-gateway paths) mirrors the console navigation groups:
`/v1/kafka/{clusters,topics,topic-configurations,agents}`, `/v1/governance/{policies,indicators}`,
`/v1/async-channels/…`, `/v1/clients/…`. Agents sit under `/v1/kafka/` because the console groups them there
while Kafka is the only capability; a capability-neutral `/v1/fleet/agents` is the likely future move. gRPC
service/method names are unchanged — this is gateway routing only.

### ADR-API-002: entity renames and expansion removed

`Topic Definition` → **`AsyncChannel`**, `Topic Claim` → **`KafkaTopic`**. `TopicRevision` and
`TopicConfiguration` keep their names. The expansion engine (`003.6`) is superseded — placement is a
step of `AsyncChannel` create/update. `docs/003-franz/` files carry alignment banners; deeper rewrites
of `003.2` / `003.5` / `003.7` are pending.
