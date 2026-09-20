# Impl tracker — 23 Governance Rule Engine & Console Editor

Deliverable: `franz/docs/impl_plans/23-governance-rule-engine-and-editor.md`
Status: ⬜ not started
Executed by: —
Started: —   Completed: —   Commit: —

Branch: `impl/23-governance-rule-engine-and-editor` (off `main`).

## Context

Follows `006-governance/README.md` and `DECISIONS.md` ADR-API-012. Replaces the simple single-indicator/single-limit `Policy` model with composite remediation rules powered by `expr-lang/expr`. Adds sub-resource descent, execution guards, dynamic disk sizing with 24h projection, and a CodeMirror 6 text editor in the console with debounced server validation and side-by-side live dry-run simulation.

## Decisions

- **Condition Engine:** `expr-lang/expr` (+3.05 MB, 0 transitive dependencies, compile-time position-aware type checks).
- **Document Format:** Single pure YAML documents for rule definition.
- **Console UX:** Text editor with debounced server validation (`POST /v1/governance/rules:dryRun`) and real-time live dry-run simulation against local fleet snapshots.
- **Scoping & Sub-resources:** Parent selection (`KAFKA_CLUSTER` / `KAFKA_TOPIC`) with optional `descend: {kind: broker}` for broker-level aggregates.
- **Governance Ceilings:** Cluster labels `franz.governance/*` injected as `governance.<snake_case>`; `${governance.*}` arg interpolation; missing/malformed labels skip the instance, record `PolicyAction(result=skipped)`, and flag a Rule Health Warning (`CONFIG_MISSING`).
- **Guards:** Mandatory `cooldown`, `max_fires_per_day`, and `skip_if_operation_in_flight`.
- **Dynamic Disk Sizing:** Target usage % with 24h consumption projection guard (no re-trigger within window, bounded by `governance.max_disk`).
- **Operations Bridge:** Rebalance emits declarative signal `franz.governance/needs-rebalance: "$now"` (paving way for ADR 007 operations). Migration actions dropped from 006.
- **Sample Retention:** Configurable pruning (`telemetry.sample_retention`), time windows validated against retention ceiling.

## Questions & answers

_(None yet — deliverable not started)_

## Verification

_(To be completed during implementation)_

## Notes / deviations

_(To be recorded during implementation)_
