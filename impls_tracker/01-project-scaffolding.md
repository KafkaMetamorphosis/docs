# Impl tracker — 01 Project scaffolding

Deliverable: `franz/docs/impls_plan/01-project-scaffolding.md`
Status: ✅ done
Executed by: claude + user (repo/branch) → codex (blocked) → claude (claude-sonnet-5)
Started: 2026-09-06   Completed: 2026-09-06   Commit: see franz `go-monorepo`
Codex session: 01a076cb-7154-7012-bb8f-3b2ecd16f814 (model: gpt-5.6-terra) — reached its usage limit before writing any code

## Decisions

- **Branch strategy** — the Go rewrite lands on a new branch `go-monorepo` cut
  from `main`; one "reset to Go monorepo" commit removes the 49 Clojure files
  (LICENSE kept) and adds `api/` + `docs/impls_plan/` + the scaffold. Rationale:
  reviewable, keeps Clojure in history on `main`. (user)
- **Module location** — the Go module is rooted at `franz/` (module path
  `github.com/KafkaMetamorphosis/franz`), because that is where the git repo and
  the `franz.git` remote physically are. ADR-002 updated to match. (user)
- **codex sandbox network** — codex's `workspace-write` sandbox blocks network by
  default, which stalls every `go get` / `buf install`. Re-run with
  `-c sandbox_workspace_write.network_access=true` (fs still confined to the
  workspace). Rationale: `go mod` downloads are unavoidable for the scaffold; the
  project dirs are already `trusted` in `~/.codex/config.toml`. (claude)
- **edition 2024 + grpc-gateway** — `use_opaque_api=true` **must** be passed to
  the `protoc-gen-grpc-gateway` plugin. For editions, `protoc-gen-go` emits the
  Opaque API (hidden fields, `Get*`/`Set*` accessors); the gateway plugin's
  default (`use_opaque_api=false`) emits Open-Struct field access
  (`protoReq.Name = …`) which does not compile against opaque messages. With the
  flag it emits `protoReq.SetName(…)`. Kept `edition = "2024"` and grpc-gateway
  unchanged. (claude)
- **Go 1.25** — `go mod tidy` raised `go.mod` to `go 1.25.0` (transitive
  `google.golang.org/grpc` requirement); CI pins `1.25`. (tooling)
- **`buf.gen.yaml` at `franz/` root** (moved from `api/`) — `buf generate api`
  looks for the template in CWD. `buf.yaml` + `buf.lock` stay under `api/`. (claude)
- **Module at `franz/`** — ADR-002 updated (module rooted at `franz/`, repo root
  a plain dir). (user)
- **Branch `go-monorepo` off `main`** — one reset commit; Clojure kept in
  `main`'s history. (user)

## Questions & answers

### Q1 — Repo boundary, branch, and the existing Clojure code
- **Asked by:** claude (deliverable 01 is Claude+user territory per the skill)
- **Answered by:** user
- **Question:** Where should the Go rewrite start (branch), how should the Clojure
  code be handled, does the module sit at `franz/`?
- **Answer:** New branch `go-monorepo` off `main`; one reset commit removing the
  Clojure tree; module at `franz/`; update ADR-002 to match.
- **Source:** user decision (2026-09-06)

### Q2 — `buf` unavailable / no network in the codex sandbox
- **Asked by:** codex
- **Answered by:** claude
- **Question:** `buf` is not installed and `go install …buf@latest` fails —
  `proxy.golang.org` is unreachable (DNS). Provide buf or enable network.
- **Answer:** The machine has network; only codex's sandbox blocked it. Re-run
  codex with `-c sandbox_workspace_write.network_access=true`, then
  `go install github.com/bufbuild/buf/cmd/buf@latest` and continue.
- **Source:** `curl https://proxy.golang.org` → 200 from a normal shell;
  `~/.codex/config.toml` has no `[sandbox_workspace_write]` block (network
  defaults off).
- **Outcome:** On the resume, codex could reach the network but its
  `workspace-write` sandbox still could not write the Go module cache
  (`~/.gvm/.../pkg/mod`, outside the workspace); it then hit its **OpenAI usage
  limit** (resets 2026-09-28). Handed off to Claude.

### Q3 — edition 2024 protos won't compile with grpc-gateway (Claude self-resolved)
- **Asked by:** claude (blocker found while implementing)
- **Answered by:** claude
- **Question:** `protoc-gen-go` emits the Opaque API for `edition = "2024"`;
  the generated `.pb.gw.go` does `protoReq.Name = …` (Open Struct) →
  `type GetAgentRequest has no field or method Name`. The user uses
  edition 2024 + grpc-gateway elsewhere and asked what actually causes this.
- **Answer:** `protoc-gen-grpc-gateway` has a `use_opaque_api` bool flag,
  **default `false`**. Set `use_opaque_api=true` on that plugin in `buf.gen.yaml`
  → it emits `protoReq.SetName(…)` and compiles. No proto change; editions and
  grpc-gateway both kept.
- **Source:** `grpc-ecosystem/grpc-gateway/v2@v2.30.0/protoc-gen-grpc-gateway/main.go:39`
  (`flag.Bool("use_opaque_api", false, …)`); Opaque API support added in
  grpc-gateway v2.27.3 (PR #5723), edition-2024 support in v2.29.0; v2.30.0 latest.
- **Related trap (research agent):** edition 2024 *forces* `api_level = API_OPAQUE`
  in protoc-gen-go via `go_features.proto`'s `edition_defaults`. The
  `default_api_level=API_OPEN` / `apilevelM<path>=API_OPEN` plugin flags are
  **silently ignored** for edition-2024 files. The only way to get the Open API
  for an edition-2024 file is `option features.(pb.go).api_level = API_OPEN;`
  *inside* the `.proto`. So the two viable combos are:
  (a) protoc-gen-go opaque (default) + gateway `use_opaque_api=true` — **chosen**;
  (b) `(pb.go).api_level = API_OPEN` file-option in every proto + gateway default.

## Verification

- `go build ./...` — **pass**
- `go vet ./...` — **pass**
- `go test ./...` — **pass** (`config`, `grpcgateway` packages; others have no tests yet)
- `buf lint api` — **pass** (STANDARD, no exceptions)
- `buf breaking api --against api` — **pass** (self, sanity)
- `buf generate api` — deterministic; `pkg/gen/go` committed
- Boot check — `go run ./cmd/franz` starts via `fx`, `GET /healthz` → `200 {"status":"ok"}`, SIGTERM → graceful shutdown
- Dependency rule — `go list -deps ./pkg/franz/core/...` pulls in no adapter / transport / `fx` / `pgx` / gRPC package

## Notes / deviations

- Deliverable 01 is handled specially: Claude + user settle repo/branch/module.
- **Codex handoff → Claude.** Codex was blocked twice: (1) its `workspace-write`
  sandbox has no network *and* cannot write the Go module cache
  (`~/.gvm/.../pkg/mod`, outside the workspace); (2) it then hit its OpenAI usage
  limit (resets 2026-09-28). Per the `/impl` skill's credit-exhaustion rule,
  Claude (`claude-sonnet-5`) implemented tasks 01.2–01.8 directly.
- Follow-up: fixed the `/impl` skill — `codex exec resume` does not accept
  `-C` / `-s`; initial `codex exec` needs
  `-c sandbox_workspace_write.network_access=true`; and it needs the Go module
  cache dir added as a writable root (or a workspace-local `GOMODCACHE`).
