# Monorepo Structure

Status: **ready**

Replaces the former `002-clojure-projects-structure.md` (Clojure layout; removed).

## Context

Franz and its agents move from a Clojure multi-project setup to a single **Go monorepo**.
All contracts — console-to-control-plane and control-plane-to-agents — are **protobuf over gRPC**
with a REST/JSON gateway. Persistence stays **PostgreSQL**. The **React** console lives in the same repo.
The control-plane / agent (data-plane) split from `001-architecture-overview` is unchanged.

## Decision

### Module

One Go module at the repo root: `github.com/KafkaMetamorphosis/franz`.
Import paths therefore read `…/franz/pkg/franz/core/domain`; the `franz/pkg/franz` repetition is accepted.

### Top-level layout

```
/api/
  proto/              .proto sources — the single API contract (console + agents)
  buf.yaml, buf.gen.yaml
/cmd/
  franz/              main.go — control-plane binary
  gregor-samsa/       main.go — Resource Provider agent
  odradek/            main.go — Telemetry Agent
/pkg/
  franz/              control plane (hexagonal, see below)
  gregorsamsa/        agent — plain package, no prescribed structure
  odradek/            agent — plain package, no prescribed structure
  shared/             domain-agnostic helpers: label selectors, ORN, telemetry client, logging
  gen/go/             generated Go stubs — committed; CI verifies they are current
/webconsole/          React application (Vite)
/migrations/          SQL migrations (Flyway)
```

Only **Franz** is bound to the structure and conventions below. **Agents are deliberately simple**:
Gregor Samsa and Odradek need no hexagonal split, no `fx`.
The only hard contract an agent must honour is the protobuf/gRPC API in `/api/`.

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
