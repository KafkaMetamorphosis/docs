# Monorepo Structure

Status: **ready**

Replaces the former `002-clojure-projects-structure.md` (Clojure layout; removed).

**Update (2026-09-06, deliverable 01).** The Go module is rooted at `franz/`, not
the repo root — that is where the git repository and the `franz.git` remote
physically live. Layout paths are relative to `franz/`.

## Context

Franz and its agents move from a Clojure multi-project setup to a single **Go monorepo**.
All contracts — console-to-control-plane and control-plane-to-agents — are **protobuf over gRPC**
with a REST/JSON gateway. Persistence stays **PostgreSQL**. The **React** console lives in the same repo.
The control-plane / agent (data-plane) split from `001-architecture-overview` is unchanged.

## Decision

### Module

The Go module is rooted at **`franz/`** — a subdirectory of the working tree and
its own git repository (`git@github.com:KafkaMetamorphosis/franz.git`). Module
path: `github.com/KafkaMetamorphosis/franz`. Import paths read
`…/franz/pkg/franz/core/domain`; the `franz/pkg/franz` repetition is accepted.

The working-tree root (`KafkaMetamorphosis/`) is a **plain directory**, not a
module and not a git repo — it holds `franz/`, `docs/` (its own git repo), and
the legacy agent directories. All paths below are **relative to `franz/`**.

### Layout (under `franz/`)

```
api/
  franz/v1/           .proto sources — the single API contract (console + agents)
  buf.yaml, buf.gen.yaml
cmd/
  franz/              main.go — control-plane binary
  local-kafka-agent/  main.go — local Docker Cluster Provider agent
pkg/
  franz/              control plane (hexagonal, see below)
  localkafka/         local-kafka-agent internals — plain packages
  shared/             domain-agnostic helpers: label selectors, FRN, logging
  gen/go/             generated Go stubs — committed; CI verifies they are current
webconsole/           React application (Vite)
migrations/           SQL migrations (Flyway)
docs/impls_plan/      the build plan (one file per deliverable)
```

Gregor Samsa and Odradek remain **separate top-level projects** (their own repos /
free to use another language); the only hard contract an agent must honour is the
protobuf/gRPC API in `franz/api/`. Agents in this module (e.g. `local-kafka-agent`)
are **deliberately simple** — plain packages, no hexagonal split, no `fx`.

### Franz — hexagonal architecture

```
pkg/franz/
  core/
    domain/           entities, value objects, invariants — no framework imports
    usecases/         application services that orchestrate the ports
    ports/
      in/             driving interfaces (invoked by adapters/in)
      out/            driven interfaces (implemented by adapters/out)
  adapters/
    in/
      grpcgateway/    gRPC server + grpc-gateway REST; maps requests onto ports/in
    out/
      postgres/       implements ports/out; SQL access
  config/             configuration loading
```

Dependencies point inward: `adapters → ports → usecases → domain`.
`domain` and `usecases` never import an adapter or a transport package.
This applies to Franz only; agents are structured however is simplest.

### Wiring

`go.uber.org/fx` provides dependency injection **for Franz**. `cmd/franz/main.go` builds an
`fx.App` that assembles config, adapters, and usecases. Agents wire themselves plainly in `main`.

### Transport

`grpc-gateway` (`google.golang.org/grpc` + `grpc-ecosystem/grpc-gateway`) serves each
gRPC service and a REST/JSON gateway generated from the same `.proto`. One API surface.
gRPC service decomposition (one service vs. per-domain) is decided in the API-contract ADR.

### Console packaging

`webconsole/` is built with react.

### Migrations

Flyway.
