# Impl tracker — 16 Client

Deliverable: `franz/docs/impl_plans/16-client.md`
Status: ✅ done
Executed by: claude (claude-sonnet-5) — codex out of quota (resets 2026-09-28), never ran
Started: 2026-09-13   Completed: 2026-09-13   Commit: —
Codex session: — (quota-exhausted, no code)

Branch: `impl/16-client` (off `main`, deliverable 15 merged as `f21a345`).

## Decisions

- **Deletion ledger, not a state column** — the plan's own task 16.1 already
  rules out a `state` column, and its Notes call for "the ledger approach".
  Shipped `deleted_client_frn (realm_id, name, frn, deleted_at)`, written in
  the same transaction as the `client` row's `DELETE`. `Create` checks it
  first and rejects a reused name with the same `errs.AlreadyExists` a live
  duplicate gets — an operator sees one error kind for "this name is taken"
  regardless of which table proves it. No FK from the ledger back to
  `client`: the row it reserves is already gone by the time it's written.
- **`ListObservedConsumerGroups`/`ListConsumerGroupObservations` resolve the
  client first.** Both RPCs take a bare `name`, not an FRN, so the service
  does `repo.Get` before querying deliverable 15's
  `ObservedConsumerGroupRepository`, both to 404 a nonexistent client and to
  get the canonical `FRN.Path()` to scope the query by. An alternative —
  building the FRN from `(realm, name)` without a lookup — would silently
  "succeed" (empty results) for a client that was never created, which is a
  worse failure mode than one extra query.
- **The current-view and history-view proto mapping share one function**
  (`observationsToProto`) — `client.proto`'s comment on `last_seen_at` says
  both views read the same field ("Current view: most recent sighting.
  History view: the sighting's time."), so `consumergroup.Observation.ObservedAt`
  is the only value either one ever needs.
- **`custom` is never accepted from a request** — deliverable 15 already
  established this at ingest (`ReportConsumerGroups`); 16 just reads it back,
  so there was nothing to decide here, only to preserve.
- **No proto change.** `client.proto` was already complete (`003.10` status:
  ready) before this deliverable started.

## Questions & answers

_(none — no blocking questions; the deletion-ledger call was already made by
the plan file itself, not left to this deliverable to resolve.)_

## Verification

- `go build ./...` — clean
- `go vet ./...` — clean
- `gofmt -l cmd pkg migrations` — clean
- `go test ./...` with `FRANZ_TEST_DB_DSN` → Postgres integration active —
  **40 packages ok, 0 fail**. New suites: `domain/client` (`TestNewClient*`,
  `TestSetLabels*`), `usecases/clients` (`TestCreateThenGet`,
  `TestCreateRejectsDuplicateName`, `TestCreateRejectsRecreatingADeletedName`,
  `TestUpdateReplacesLabelsWholesale`, `TestUpdateRequiresAMaskedField`,
  `TestListFiltersBySelector`, `TestListRejectsInvalidSelector`,
  `TestListObservedConsumerGroupsRequiresAnExistingClient`,
  `TestListObservedConsumerGroupsScopesByClientFRN`,
  `TestListConsumerGroupObservationsScopesByClientFRN`),
  `adapters/out/postgres` (`client_integration_test.go` —
  `TestClientRepoLifecycle`, `TestClientNameIsRealmWideUniqueAndNeverReused`,
  `TestClientDeleteOfAbsentClientIsNotFound`,
  `TestClientRepoListAppliesSelectorAndPages`,
  `TestObservedConsumerGroupViewsScopeByClientFRN` — a real
  `observed_consumer_group` row from deliverable 15's table, read back scoped
  by a real client's FRN), `adapters/in/grpcgateway` (`client_test.go` —
  `TestCreateClientRendersFRN`, `TestClientErrorMapping`,
  `TestUpdateClientOnlyForwardsMaskedLabels`,
  `TestUpdateClientRejectsNameInMask`, `TestDeleteClientForwardsName`,
  `TestObservedConsumerGroupViewsShareTheSameWireMapping`,
  `TestListConsumerGroupObservationsUnsetTimestampsStayZero`).
- `buf lint` (from `franz/api`) — clean. **No proto change** — `client.proto`
  was already complete.
- `git status --porcelain | grep -E '\.proto$|gen/go|openapi|schema.d.ts'` —
  empty, confirming no codegen drift.
- **Done when** — both: (1) CRUD through the gateway, a deleted client's
  `name` cannot be recreated (`TestClientNameIsRealmWideUniqueAndNeverReused`,
  `TestCreateRejectsRecreatingADeletedName`); (2) observed-consumer-group
  views return the latest sighting per `(group, topic)`
  (`TestObservedConsumerGroupViewsScopeByClientFRN`).

## Notes / deviations

- codex never ran (quota, resets 2026-09-28) — claude implemented it directly
  in one pass, no handoff mid-deliverable.
- Per the standing convention added to `impl_plans/README.md` alongside
  deliverable 15's follow-up: `local/seed/05-clients.sql` seeds two example
  clients (`billing`, `payments-consumer`), and new deliverable
  **[21 — Client UI](../../franz/docs/impl_plans/21-client-ui.md)** was
  scoped (routes, tasks, done-when) but **not built** — 16 ships no console
  screens, same split 19/20 use for their backends.
- `ListClientChannelAccess` is the one `ClientService` RPC left
  `Unimplemented` — it needs 17's access-policy engine, exactly as the plan
  file's Goal section says.
