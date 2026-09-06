# Implementation trackers

One file per implemented `impls_plan` deliverable (`NN-<slug>.md`), created by the
**`/impl`** skill. Each records, for that deliverable:

- **Decisions** — non-obvious implementation choices and their rationale.
- **Questions & answers** — every blocking question, with **who asked** (codex /
  claude) and **who answered** (claude / user), and the source of the answer.
- **Verification** — build / test / lint results.
- **Notes / deviations** — anything that differs from the plan, handoffs, retries.

The deliverable files themselves (`franz/docs/impls_plan/NN-*.md`) carry the live
**Status** and per-task **Landed** (commit + date) plus an **`Executed by:`** line
naming the agent and model that did the work.
