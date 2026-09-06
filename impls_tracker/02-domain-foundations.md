# Impl tracker — 02 Domain foundations

Deliverable: `franz/docs/impls_plan/02-domain-foundations.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex unavailable (usage limit resets 2026-09-28)
Started: 2026-09-06   Completed: 2026-09-06   Commit: a84e4ee (franz, go-monorepo)
Codex session: — (probe returned "You've hit your usage limit")

## Decisions

- **Identifier is the FRN with a configurable prefix (ADR-API-007)** — after the
  initial `orn:` implementation, the user asked for `frn:` (Franz Resource Name)
  as the default, overridable by control-plane config. Applied as a **full
  concept rename** (specs, proto fields `frn`/`client_frn`/`resource_frn`/
  `cluster_frn`, Go package `core/domain/frn`, demo HTML) plus:
  - config key `resource_prefix` (env `FRANZ_RESOURCE_PREFIX`), default `frn`,
    `^[a-z][a-z0-9]*$`, 2–16 chars, **read once at bootstrap** (an `fx.Invoke`
    forces the codec so a bad value fails startup);
  - **prefix-less persistence** — `FRN.Path()` (`<realm>:<type>:<name>`) is what
    the DB stores; `frn.Codec.Render` prepends the configured prefix only at the
    API boundary, so changing `resource_prefix` never rewrites rows;
  - **lenient parsing** — `frn.Codec.Parse` accepts the configured prefix, the
    `frn:` / `orn:` aliases, or a bare path.
  Chosen over "prefix string only" (inconsistent naming) and "store full string"
  (config change would need a data migration).

- **Migration on boot vs. Flyway (`003.12`)** — `003.12` names Flyway as the
  migration tool and the deliverable task 02.8 says "migration run on boot".
  Resolved by doing *both*: `migrations/*.sql` is embedded (`migrations/embed.go`)
  and `postgres.DB.Migrate` runs it inside a transaction on start, gated on the
  new `db.auto_migrate` config (default `true`). Every statement in
  `V1__init.sql` is idempotent (`CREATE TABLE IF NOT EXISTS`,
  `INSERT … ON CONFLICT DO NOTHING`), so the docker-compose Flyway job and the
  boot runner cannot corrupt each other. Rationale: `go run ./cmd/franz` against
  a fresh database should just work for local dev; Flyway stays the authority once
  the schema freezes (set `db.auto_migrate: false` there).

- **`realm` as its own domain subpackage** (`core/domain/realm`) rather than a
  type in `core/domain` + a context helper in `pkg/shared`. Keeps the value
  object and its request-context plumbing together and avoids `pkg/shared`
  depending on `core/domain`.

- **`uuid.UUID` in the domain** — `core/domain/realm` imports
  `github.com/google/uuid` for the realm id. It is a value-type library, not a
  framework/transport/persistence dependency, so it does not break the hexagonal
  rule; the fixed default-realm id lives there as `realm.DefaultID`.

- **Selector matcher semantics** — `!=` / `NOT IN` on an *absent* key *matches*
  (Kubernetes semantics); glob applies to selector values, and `\*` is a literal
  asterisk. `Selector.String()` renders canonical form sorted by key and
  round-trips through `Parse`.

- **Pagination token binding** — `page_token` carries the last `name` seen plus a
  16-char hash of the query (filter + parent scope). Replaying a token against a
  different query is rejected with `INVALID_ARGUMENT` on `page_token` rather than
  silently returning wrong rows.

- **Auth interceptor covers three paths** — gRPC unary, gRPC stream (via a
  wrapped `ServerStream`), and a gateway HTTP middleware (the gateway reaches the
  services in-process and skips the gRPC interceptors). `/healthz` is deliberately
  left outside the middleware so it needs no database. HTTP middleware fails
  closed (500) if the realm cannot be resolved.

## Questions & answers

_(none — no blocking questions; the Flyway/boot-migration tension was resolved by
Claude from `003.12` + task 02.8, recorded under Decisions.)_

## Verification

Run from `franz/` with go 1.25 toolchain:

- `go build ./...` — ✅ pass
- `go vet ./...` — ✅ pass (clean)
- `gofmt -l pkg cmd migrations` — ✅ clean
- `go test ./...` — ✅ pass. Unit suites: `glob`, `selector` (exhaustive
  table-driven: every requirement type, whitespace, quoted values, empty
  selector = match-all, error cases), `frn`, `naming`, `errs`, `pagetoken`,
  `fieldmask` (against the generated `KafkaCluster` message), `grpcgateway`
  (errmap + interceptor unit tests with a fake realm lookup).
- Postgres integration (`adapters/out/postgres/db_integration_test.go`:
  `Migrate` idempotency, `WithTx` commit + rollback, seeded-realm repo) — ⏭
  **self-skips** unless `FRANZ_TEST_DB_DSN` is set. No Docker daemon was
  available in the implementing session; these run in CI / locally with
  `docker compose up -d postgres`.
- fx graph — ✅ resolves end-to-end; the built binary boots through every
  constructor and stops only at the DB connect step (no Postgres running).
- `buf lint api` — ✅ pass; `.proto` fields renamed `orn`→`frn` (and
  `client_orn`/`resource_orn`/`cluster_orn` → `_frn`), `buf generate api`
  re-run, `pkg/gen/go` regenerated and committed.
- Bad `resource_prefix` (`FRANZ_RESOURCE_PREFIX=Bad`) — ✅ fails boot with an
  `INVALID_ARGUMENT` before servers start.

## Notes / deviations

- Codex was out of quota (usage limit, resets 2026-09-28 12:47 PM) — per the
  `/impl` skill's credit-exhaustion rule, Claude implemented the whole
  deliverable directly.
- Deviation from `003.12`: boot-time migration runner added alongside Flyway
  (see Decisions). New config key `db.auto_migrate` (default `true`).
- New direct deps: `github.com/jackc/pgx/v5`, `github.com/google/uuid`.
- `grpcgateway.New` signature changed to take `...Option`; existing callers /
  tests unaffected (variadic).
- FRN rename (ADR-API-007) touched both repos: proto field renames +
  regenerated `pkg/gen/go`, `core/domain/frn` package, `config.resource_prefix`,
  and — in `docs/` — `003.1`, `003.12`, `DECISIONS.md` (new ADR-API-007), and the
  `001-ux/demo/*.html` example strings.
