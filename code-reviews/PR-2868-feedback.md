# PR #2868 — Reading Fees Report

## Summary

PR #2868 adds the seventh "fees report" module to the dashboard (Reading Fees) **and, in the same PR, retroactively introduces the schema, server-to-summary-api wiring, transactional outbox, and shared event-emit helpers for all six sibling reports** (CF, TC, IHD, PF, RF, Reading). Net change: +10,302 / -50 across 112 files — 9 Prisma models, 8 migrations, ~70 frontend files arranged as 7 near-identical report folders, 28 API route handlers (4 per report), 4 `lib/*-events.ts` outbox emitters, and a `summary-api.ts` HTTP client. The new module itself is small; the PR's real payload is a sweeping infrastructure change disguised as a feature delivery.

**Verdict: changes requested — blocking issues.** Functionally the approach (transactional outbox + server-side proxy routes to summary-api + per-report UI folders) matches the `hms-docs/summary-service/` design and the ADR invariants. But the PR ships **~6,000 lines of carbon-copied UI and API code** with no shared abstraction, **silently disables HMAC auth** on the summary-api client, and **does not error** when `DEFAULT_TENANT_ID` is unset (events become no-ops instead of errors). Author needs to factor the duplication into a generic `<FeesReportTable>` + a `makeReportRoutes()` helper, re-add a service-identity check on `summary-api.ts`, and verify each emit site actually runs inside a transaction.

## Strengths

- **Schema and invariants match the design doc faithfully.** Migrations carry CHECK constraints, partial unique indexes, `pg_trgm` GIN indexes for invoice search, and the "nullable unique per channel" pattern for IHD/PF/RF — exactly the pattern documented in `hms-docs/summary-service/data-model/`. CHECK value sets line up with the summary-service's TS constants. Good comments explaining why Prisma can't express these (CHECKs, partial unique, trgm).
- **Transactional outbox is wired correctly at the call sites.** The five `enqueueOpdBillingEvent` / `enqueueIpdDailyBillEvent` / `enqueueLabReadingEvent` / `enqueueImagingReadingEvent` calls all sit inside `prisma.$transaction` callbacks or accept an explicit `tx` parameter. The PR correctly distinguishes `bill_created` from `bill_reconciled` and carries only `serviceIds` / `procedureIds` in the refund payload (the one bit of state the worker can't re-derive).
- **`ipdDailyBillId` re-read after proxy-bill create** (`proxy-bill-template.service.ts` ~line 9580) — the author spotted that `proxyBill.ipdDailyBillId` is null on the freshly-created object because the field is linked later, and re-reads via `tx.proxyBill.findUnique`. A subtle correctness fix that's easy to miss.
- **Permission/visibility wiring is consistent.** Every route handler declares `permissions: [{ action: "View", subject: "<Report Name>" }]`, every page is wrapped in `<PermissionGuard>` with the same subject, and `permission-ui-config.ts` is updated for the new `Reading Fees` subject.
- **CHECK constraints on `patient_type` and `source` for the new Reading model** match the same CHECK pattern used for the other reports.

## Issues

### Blocking

- **HMAC auth was deleted from the summary-api client.** `src/lib/summary-api.ts` lines ~11230-11297. The CLAUDE.md and `hms-docs/summary-service/api/hmac-auth.md` say HMAC-SHA256 with `X-Service-Id` / `X-Signature` / `X-Timestamp` is **required** (ADR 0008), and the summary-service middleware rejects without it. The new client only sends `X-Tenant-Id` and the in-file comment says *"Server-to-service auth was removed (summary-service v1)."* This contradicts the documented contract — summary-service v1 still requires HMAC. **Either**: (a) this is a v2 summary-service that has actually shipped without HMAC (then update `hms-docs/summary-service/` ADRs and the runbook to match — blocking-on-docs); or (b) the HMAC code was forgotten and needs to be reinstated. As-is, the routes will 401 in production against the existing summary-service.

- **7 reports × ~10 files = ~70 files of near-identical code.** Every report folder under `src/app/(dashboard)/common/reports/` contains the same files with only the prefix changed (`cf`/`tc`/`ihd`/`pf`/`rf`/`reading`): `*-report.api.ts`, `*-report-columns.tsx`, `*-pay-modal.tsx`, `*-revert-confirm.tsx`, `*-activity-log-modal.tsx`, `*-filter-modal.tsx`, `*-report-table.tsx`, `get-*.schema.ts`, `*.types.ts`, `page.tsx`. The four route handlers under `src/app/api/(common)/reports/<name>/{route,pay,revert,activity-logs}/route.ts` are likewise copy-pasted with only the subject string, entity name, and report label varying. Estimated ~6,000 lines of duplication. This will not survive contact with the next report, and every bug fix now has to be applied 7 times.

- **Outbox writes silently no-op when `DEFAULT_TENANT_ID` is unset.** `src/lib/opd-billing-events.ts` lines ~11206-11213 (and the parallel warn-and-return in the other three `*-events.ts`). A misconfigured deploy emits **no event**, the worker's outbox stays empty, and CF/TC/IHD/PF/RF/Reading reports silently fall behind with no error anywhere in the logs (only a `warn` line per call). This is exactly the failure mode "data drift between HMS and summary-service with no alarm" that the design doc warns about. Should be a hard fail (throw / 500) at startup, not a per-call `logger.warn`.

- **`@unique` mapped on `opdBillingServiceId` for `cfFeeReport` may block legitimate re-bills.** `prisma/schema.prisma` line ~994: `opdBillingServiceId String @unique(map: "uq_cf_opd_billing_service")`. If an OPD bill line is cancelled and re-issued (e.g. refund-and-rebook), the new line has a new `id` (so the unique holds) — but if the same service line is updated in place and the reconciliation layer decides to UPSERT by `opdBillingServiceId` instead of by `id`, the second reconcile hits a unique violation. Worth confirming the worker's grain key. The IHD/PF/RF tables already use the "nullable unique per channel" pattern to support source switching — the CF model may need the same if a consultation line ever becomes a tele-consultation line.

### Important

- **Re-read of `ipdDailyBillId` adds a roundtrip on every proxy-bill create.** `src/app/(dashboard)/shared/proxy-bill/services/proxy-bill-template.service.ts` lines ~9579-9590. The `findUnique` is needed because the link is set inside `resolveCreatePayload` *after* the `proxyBill` object is returned, but this is brittle. Either include the field in `proxyBillRepository.createProxyBill`'s return shape (Prisma can `include: { ipdDailyBill: { select: { id: true } } }`), or move the event emit until after `resolveCreatePayload`.

- **`activityLogFailed` flag masks a real durability gap.** Each pay/revert route returns a 200 with `activityLogFailed: true` if the `prisma.activityLog.createMany` call throws. The summary-service has already mutated state and committed; the activity log is then best-effort. The UI shows a yellow toast ("Payment recorded, but the activity log entry failed to save") which is **misleading** — it implies the user can retry, but the payment has been paid and a second retry would create a duplicate activity log entry. Either persist activity logs inside the summary-service transaction, or rename the flag to `auditLogInconsistent` and surface a support workflow.

- **`sourceVoided` rows are kept selectable for the "Revert to Unpaid" path.** `consultation-fees-report-table.tsx` line ~2263 (and 6 copies): `enableRowSelection: (row) => !row.original.sourceVoided`. This blocks selection only on the *pay* flow direction. But if a row's source has been voided, reverting its payout to UNPAID would re-open a report line for an invoice that no longer exists. Selection should be disabled for voided rows in **both** directions, or the revert button should refuse voided rows. Confirm the same logic across all 7 tables.

- **No pagination on the list endpoint.** `src/app/api/(common)/reports/consultation-fees/route.ts` explicitly says "Returns ALL rows for the date range (no pagination)" — fine for a single day but a year-wide filter will return tens of thousands of rows over the wire. The summary-service already supports cursor pagination (`hms-docs/summary-service/api/openapi.yaml` per CLAUDE.md). The frontend `<DataTable>` can virtualize, but the route should still cap or paginate.

- **`search` filter may not be case-insensitive on the route.** The DB has a `lower(invoice_no) gin_trgm_ops` index, but the route handler passes `query.search` verbatim to the summary-api without lowercasing. The summary-service query layer (per `hms-docs/summary-service/`) is responsible for `LOWER(...) ILIKE ...` — but worth confirming end-to-end.

- **Tenant id comes from `process.env.DEFAULT_TENANT_ID` at request time, not from session.** Every event-emit helper and the `summaryApi` client hard-code `process.env.DEFAULT_TENANT_ID`. CLAUDE.md says multi-tenancy is defense-in-depth (ADR 0007) with the Prisma extension forcing `tenantId` on every CFI query. Fine if HMS is single-tenant for now, but if/when v2 adds real multi-tenancy this is a rewrite surface.

- **Side-effect `proxyBillTemplate.createServiceBill` emits outbox event from a service that also commits data via `prisma` directly when `tx` is undefined.** When no transaction was passed, the event write is *not* atomic with the daily-bill writes above. Comment says "transactional outbox" but it isn't always transactional. Either require `tx` or document the at-most-once nature.

- **Empty `body` POST serialization.** `src/lib/summary-api.ts` line ~11261: `init.body = body === undefined ? "" : JSON.stringify(body)`. Express's body-parser will reject `""` for JSON content-type. The pay/revert routes always pass a body so this never triggers in practice, but the helper advertises itself as generic.

### Nit

- **`STATUS_OPTIONS` and `TYPE_OPTIONS` are redefined in 7 filter modals and 7 pay modals** — trivially shared, lift to `@common/reports/_shared/constants.ts`.
- **`money()` and `formatDate()` are redefined in every `*-report-columns.tsx`** — same fix.
- **`adjustmentExport()` is redefined in every `*-report-table.tsx`** — same fix.
- **`usePageView({ page: "Reading Fees Report" })` is called inside `useSuspenseQuery`'s component** — confirm the existing convention from the other reports.
- **Each pay modal's `NumberInput` for "%" allows 0-100 but the schema accepts `nonnegative`** — for PERCENT adjustment a 0% adjustment is meaningless.
- **`router.replace` in the `useEffect` with empty deps** masks the fact that `effectiveQuery.start/end` are derived from `parsed`; the disabled rule means any future change to `parsed` derivation won't re-run the replace.
- **Four duplicate copies of `useFetchDoctorsQuery({ status: "ACTIVE", limit: 0, ... })`** in every filter modal — `limit: 0` suggests "give me everything" but the rest of the API takes `page`/`offset`. Confirm that `limit: 0` truly returns all (not just one page).
- **`formatToDefaultDate` + `toLocaleTimeString` combo** in every activity-log-modal — the time portion is duplicated logic; `formatToDefaultDate` could optionally return both.

## Recommendations

1. **Factor the seven report modules into one.** Concrete shape, in priority order:
   - Move `STATUS_OPTIONS`, `ADJUSTMENT_TYPE_OPTIONS`, `money()`, `formatDate()`, and `adjustmentExport()` to `@/app/(dashboard)/common/reports/_shared/`.
   - Create `<FeesReportTable<TRow, TAdjustment>>` that takes `{ columns, fetchPage, pay, revert, fetchActivityLogs, moneyField, totalField, feeFieldLabel, moneyGetter, ... }` — one component, one set of tests, one place to fix the bug.
   - Create a `<FeesReportPage<TRow>>` that handles URL state, default-date-routing, and PermissionGuard.
   - For the API: a single helper `makeReportRoutes({ subject, entityName, payPath, revertPath, reportLabel })` returns the four `route.ts` handlers — 7×4=28 files collapses to 7×1 invocation + 1 helper.
   - Expected: PR shrinks from ~10k lines to ~3.5k. New report types become a config object + a schema.
2. **Re-add HMAC auth to `src/lib/summary-api.ts`** (or, if the summary-service really has dropped it for v1, update `hms-docs/summary-service/adrs/` and `api/hmac-auth.md` to mark HMAC as deferred, and remove the misleading ADR 0008 references).
3. **Make `DEFAULT_TENANT_ID` a hard requirement at boot.** A small `lib/tenant.ts` that asserts the env var once at module load and re-throws on every event emit / summary-api call if it's missing in test envs. Replace the `logger.warn` + return pattern with `throw new AppError(...)`.
4. **Confirm `opdBillingServiceId` is the right grain key for CF.** If reconciliation may UPSERT by service id across cancels, add the nullable-unique-per-source pattern (like IHD/PF/RF) or a `(opd_billing_service_id, deleted_at)` partial unique.
5. **Tighten the activity-log flow.** Either persist activity logs inside the summary-service transaction (preferred), or rename `activityLogFailed` to `auditLogInconsistent` and surface it as an alert, not a toast.
6. **Disable selection on `sourceVoided` rows in both pay and revert flows** across all 7 tables.
7. **Add an ADR or runbook entry** for the 7 reports' "default date range = today" behavior — it diverges from the summary-service default (no default).
8. **Page the list endpoint or cap the row count** — use the cursor pagination summary-service already supports.

## Reviewer notes

- The ClickUp ticket (`9018849685/86exqc3a1`) is the only context — there's no design doc linked from the PR description. Given the PR's scope (schema, infra, 7 reports), a 2-line body is insufficient. Recommend the author link to a `hms-docs/summary-service/reading-fees/` brief or an ADR before merging.
- The migrations introduce 8 sequential `*_add_*_fee_report_tables` migrations dated 2026-06-17 through 2026-07-02. Six of the seven reports appear to have been merged through this single PR — there's no migration naming convention that says "all of one feature" vs "incremental per feature". Worth confirming with the HMS team that this isn't a squash-merge hiding per-report PRs.
- The outbox-emit pattern is solid but the four `lib/*-events.ts` files are near-identical clones with only the event type and aggregate id varying. A generic `enqueueOutboxEvent(tx, eventType, aggregateId, payload)` would unify them.
- `src/components/sidebar-link-config.ts` is updated for the new report — quick check that this matches the existing convention.
- The CLAUDE.md note *"tread carefully with migrations; consult peers before installing new dependencies"* applies: this PR adds 8 migrations in one shot. Recommend a peer review from someone who has run Prisma migrations against the live DB.
- No tests added. The `hms-summary-service` repo has a Jest tenant-scope test (per CLAUDE.md) but the hms-app side has nothing new here. At minimum: (a) one integration test for the outbox-emit helpers, (b) one test for `summary-api.ts` request/response mapping.

**Expected outcome if recommendations applied:** ~3.5k net lines instead of ~10.3k.