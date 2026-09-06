# Impl tracker — 06 Web console bootstrap

Deliverable: `franz/docs/impls_plan/06-web-console-bootstrap.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex unavailable (usage limit resets 2026-09-28)
Started: 2026-09-06   Completed: 2026-09-06   Commit: c57c43c (franz, impl/06-web-console-bootstrap)
Codex session: — (probe returned "You've hit your usage limit")

## Decisions

All four were **asked** (the user has resumed answering questions):

### Q1 — Packaging
- **Asked by:** claude   **Answered by:** user
- **Answer:** **Separate static build.** `webconsole/` builds and deploys
  independently; Franz stays API-only. Vite dev proxies `/v1` + `/healthz` to
  `:8080`; `VITE_API_BASE` points at the gateway in prod. `cmd/franz` unchanged.

### Q2 — Frontend stack
- **Answer:** Vite + React + TS + React Router + **TanStack Query**; no component
  library; `franz-console.css` ported verbatim + a small `console.css`.

### Q3 — Typed REST client
- **Answer:** **Generate from the protos.** `buf.gen.yaml` gains
  `protoc-gen-openapiv2` → `api/openapi/franz.swagger.json` (Swagger 2.0,
  committed, CI-verified). `webconsole/scripts/gen-api.mjs` converts 2.0 → 3.0
  (`swagger2openapi`) and runs `openapi-typescript` → `src/api/schema.d.ts`
  (committed, CI-verified). `openapi-fetch` is the runtime.

### Q4 — 06.7 Playwright scope
- **Answer:** **Scope down.** The real local-kafka-agent is deliverable 07, so
  nothing reports `READY`. The smoke asserts: sign in → register agent → copy
  token → register cluster → the detail page renders the provider-status panel +
  event timeline ("no report yet"). The full flow moves to deliverable 07.

### Implementation choices (not asked — mechanical)

- **Auth stub** — `AuthProvider` records an account label + installs a
  placeholder `Bearer console-stub:<account>` token; the backend ignores it
  (02.10 allow-all). Session persists in `sessionStorage`.
- **`client.ts` baseUrl** is always absolute (`window.location.origin` fallback)
  so URL parsing works in the jsdom test env; `fetch` is wrapped in a closure so
  `vi.stubGlobal("fetch", …)` takes effect after module load.
- **`StatusPill`** maps any proto enum short form to a coloured pill + friendly
  label — one component for agent status, cluster state, and provider phase.
- **Nav** shows Async Channels / Governance groups disabled ("Coming with the
  feature") to keep the prototype's information architecture recognisable.

## Questions & answers

_(the four decisions above; no mid-build blockers)_

## Verification

Run from `franz/webconsole/`:

- `npm run gen:api` — ✅ produces `src/api/schema.d.ts` from the committed spec
- `npm run typecheck` (`tsc --noEmit`) — ✅ clean
- `npm run lint` — ✅ 0 errors (1 react-refresh warning on `useAuth` co-location)
- `npm run test` (Vitest, jsdom) — ✅ 4 pass: `LabelEditor` add/remove/ignore
  incomplete; `AgentRegister` token-reveal + request body, gateway field
  violation → alert
- `npm run build` — ✅ `dist/` (244 kB JS / 75 kB gzip)
- `npm run e2e` (Playwright, against real Franz + Postgres) — ✅ the scoped-down
  smoke passes end to end

From `franz/`:

- `go build ./...`, `go vet ./...` — ✅ unaffected
- `buf generate api` — ✅ emits `pkg/gen/go` + `api/openapi/franz.swagger.json`;
  `buf lint api` clean (no `.proto` change)

## Follow-on

- **`franz/Makefile`** (user ask, same PR): `make dev` runs Postgres + the
  control plane + the console together, health-gated, Ctrl-C stops all. Plus
  `run` / `console` / `gen` / `test` / `e2e` / `lint` / `clean`. Verified: both
  `:8080/healthz` and `:5173` come up and the SIGINT trap leaves no orphans.

## Notes / deviations

- Codex out of quota → Claude implemented the whole deliverable.
- `openapi-typescript` v7 only reads OpenAPI 3.x; grpc-gateway emits Swagger 2.0
  → added `swagger2openapi` conversion in `gen-api.mjs`.
- New CI jobs: `webconsole` (gen check + lint + typecheck + test + build) and
  `console-e2e` (Postgres service + built Franz + Playwright).
- The `go` job's "generated code is current" check now also covers `api/openapi`.
