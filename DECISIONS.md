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

### ODR-005: Consumer startup sequence

Consumer initialization follows: subscribe -> poll(100ms) -> seekToEnd -> real poll loop.

The initial poll(100ms) triggers partition assignment by the coordinator. Without it,
`seekToEnd` would operate on an empty assignment set and have no effect. After seeking,
we call `.position()` on each partition to force the seek to materialize before entering
the real consumption loop.
