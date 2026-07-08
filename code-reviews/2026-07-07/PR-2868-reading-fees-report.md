# Code Review: PR #2868 — Reading Fees Report
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `mpt/reading-fees-report` → `development`
**Files changed:** 112 (+10302 / -50)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07
**ClickUp:** https://app.clickup.com/t/9018849685/86exqc3a1

## Summary
Largest PR in the batch. Headline feature is the **Reading Fees Report**, but it is shipped alongside five sibling "fee report" surfaces (consultation, tele-consultant, in-house-doctor, procedure, round). Each surface is a complete vertical: Prisma model + 2 audit tables + 1 status-revert migration + 4 API routes (list / pay / revert / activity-logs) + 7 React components + Zod schema + TS types + client API wrapper.

Producer side wires 5 shared services into a new `event_outbox` table via `enqueueOpdBillingEvent` / `enqueueLabReadingEvent` / `enqueueImagingReadingEvent` / `enqueueIpdDailyBillEvent` helpers, all transactional-outbox pattern, payloads minimal so the worker can re-derive.

One regression of note: `src/lib/summary-api.ts` ships BFF-to-summary-service auth as a plain `X-Tenant-Id` header, where the workspace docs and ADR 0008 mandate HMAC-SHA256 + `X-Service-Id` + `X-Timestamp`.

## Verdict
**Request changes**
Score: 27/100
Critical: 1 | High: 4 | Medium: 4 | Low: 4 | Nit: 2

## Issues

### Critical
1. **Server-to-service auth silently downgraded.** `src/lib/summary-api.ts:29-37` says "Server-to-service auth was removed (summary-service v1). The summary-service tenant-guard middleware only requires a plain `X-Tenant-Id` header ... v2 will reintroduce an auth context; until then the header is trusted on the wire." This contradicts `hms-docs/summary-service/api/hmac-auth.md` and ADR 0008 (HMAC-SHA256 + `X-Service-Id` + `X-Signature` + `X-Timestamp` required, ±5-min skew, 10k-entry replay cache). Either restore HMAC in `src/lib/summary-api.ts`, or land a paired ADR/doc update that explicitly blesses the v1 wire format and names the v2 target date. Either way, coordinate with the summary-service team — both sides must agree on what's actually accepted at the boundary.

### High
1. **Five full report trees copy-pasted.** Six fee-report surfaces (consultation, tele-consultant, in-house-doctor, procedure, round, reading) each have the same shape: `api/<name>-report.api.ts`, `schemas/get-<name>-report.schema.ts`, `types/<name>-report.types.ts`, `page.tsx`, `components/<name>-report-{table,columns,pay-modal,revert-confirm,filter-modal,activity-log-modal}.tsx`, and four `app/api/(common)/reports/<name>-{route,pay,revert,activity-logs}/route.ts`. Inside any two, the table component, pay modal, revert confirm, activity-log modal, schema, and route files differ only in the fee column name, the source enum, and a handful of label strings. The 24 route files are pure mechanical swaps (`enhancedApiHandler` + `summaryApi.post('/...-fee-reports/{pay,revert}')` + `prisma.activityLog.createMany` with `description`/`action`/`entity`/`entityId` swapped). The duplicated logic that is worth extracting is small and concrete: a shared `recordFeeReportActivityLog(userId, verb, entity, rows, remark?)` helper, and a shared `bffToSummaryParams(query)` that maps `{start, end}` → `{from, to}`. That alone deletes the bulk of the drift risk without inventing a code-generation framework.
2. **Ad-hoc `permissions.subject` strings are duplicated across 24 route files.** `"Round Fees"`, `"Procedure Fees"`, `"In House Doctor Fees"`, `"Reading Fees"`, `"Tele Consultant Fees"`, `"Consultation Fees"` appear as `subject` values in `app/api/(common)/reports/*/pay/route.ts` and siblings, with no shared constant. `permission-ui-config.ts` (30-line edit in this PR) presumably wires the same strings on the UI side. A typo silently grants access via the `hasPermission` resolver. Add a `PERMISSION_SUBJECTS` const (or extend `permission-ui-config.ts`) and reference it from the route files.
3. **No CHECK enforces "exactly one source-ref populated per `source`" on `ihd_fee_reports` / `rf_fee_reports`.** Both tables carry 5–6 nullable UUID source-ref columns (`opd_billing_service_id`, `ipd_daily_service_id`, `ipd_ward_service_item_id`, `ipd_service_bill_item_id`, `ipd_cath_lab_service_item_id`) plus a `source` discriminator. The migration comment says "each IPD row populates exactly ONE of the four channel grain columns" but the DB has no way to reject a row with `source='OPD'` and `ipd_daily_service_id` set, or `source='IPD'` with all four IPD refs NULL. The worker re-derive logic will silently mis-materialize. Add `CHECK` constraints such as `(source = 'OPD') = (opd_billing_service_id IS NOT NULL)`.
4. **No CHECK enforces the reading-fees grain on `reading_fee_reports`.** Unique index is on `(source_service_id, doctor_id)`, but neither column is `NOT NULL`. A row with `doctor_id IS NULL` will be the single such row (allowed by Postgres unique semantics) and slip past the worker. Add `NOT NULL` on both, or partial-unique `WHERE doctor_id IS NOT NULL` plus a CHECK that `doctor_id` is set.

### Medium
1. **No integration test exercises any of the six new outbox event types against the worker.** The summary-service is a separate repo and Phase 3 (runtime validation) is described as "not yet landed" in the summary-service CLAUDE.md. This PR adds 7 event types (`opd_billing.bill_created`, `opd_billing.bill_reconciled`, `opd_billing.refund_created`, `imaging_reading.reconcile`, `lab_reading.reconcile`, `ipd_daily_bill.bill_created`, `ipd_daily_bill.bill_reconciled`) and assumes the worker consumes them per the design docs. Gate this PR behind at least one smoke test per surface that fires a known event and asserts the corresponding report row materializes — otherwise Phase 2's "complete" label is what gets paged at 3am.
2. **`activityLogFailed` is reported as a yellow toast, not an error.** `reading-fees-report-table.tsx:5547` (and five siblings): when the summary-api succeeds (rows PAID/REVERTED in PG) but the HMS `activity_logs` insert fails, the user sees a yellow "Payment recorded, but the activity log entry failed to save." toast and the next `["reading-activity-logs"]` invalidate makes the activity-log modal look empty for that row. A user could re-trigger the pay action thinking nothing happened. Promote to `toast.error` with a clear "contact admin" message, and consider a banner on the activity-log modal in the failure case.
3. **`Int` fee columns + `n.toLocaleString("en-US")` formatter disagree.** `readingFee` / `consultationFee` / etc. are `Int` in Prisma, and the summary-service stores `NUMERIC(12,2)` per the design doc. The table-level `money(n)` helper (`reading-fees-report-table.tsx:5484`) prints `n.toLocaleString("en-US")`, so 1234 displays as "1,234" — readable as 1,234 MMK (whole units) or 1,234,000 MMK (cents) depending on the convention. Confirm with the summary-service team which unit the column is in, and either drop the thousand-separator (cents) or divide by 100 server-side (whole units). This is a UI bug, not just a style choice.
4. **Schema CHECK constraints denormalize identical enums into 6 migrations.** Each `*_fee_reports` migration re-declares `payout_status IN ('UNPAID','PAID')`, `adjustment_type IN ('PLUS','MINUS','FULL')`, `adjustment_mode IN ('PERCENT','AMOUNT')`, `source_voided_reason IN ('CANCELLED','REFUNDED','REMOVED_ON_EDIT')`. The TS enums (in each report's `types/*.ts`) carry the same value sets. Adding a new enum value requires editing 6 SQL files plus 6 TS files; one missed CHECK turns into a runtime fallback. Add a regression test that diffs each migration's CHECK against its TS enum; that's the smallest thing that fails when the two drift.

### Low / Nit
1. **No pagination on `/api/reports/*/route.ts`.** All six list endpoints return every row in the date range. Fine for v1 single-ward scale, but will be a 3am page on a year of hospital data. Add a default `?limit=1000` cursor at minimum.
2. **Hardcoded column index `idx === 1` for the "Grand Total" label.** `reading-fees-report-table.tsx:5715` anchors the footer label to the second column by index; hide the first checkbox and it shifts. Use `col.id === "..."` like the rows below it.
3. **`enqueueXxxEvent` is three near-identical 44-line files** (`lab-reading-events.ts`, `imaging-reading-events.ts`, `opd-billing-events.ts`, plus `ipd-daily-bill-events.ts`). One helper `enqueueDomainEvent(tx, eventType, aggregateId, payload)` with a TS union of event types would be ~20 lines. Four callers, real duplication, not speculative.
4. **`money` and `adjustmentExport` helpers are local to each table file** and identical across all six. Lift to `@/lib/format.ts` and `@/lib/format-adjustment.ts`. Already five copies, not speculative.

### Nit
1. **`@db.Timestamptz(6)` is inconsistently applied across the new Prisma models** — some `DateTime` fields have it, some don't. Pick one convention.
2. **`activityLogFailed` wording says "the activity log entry failed to save" — passive voice, vague.** Specify *what* the user should do: "Contact an admin; the payment is recorded but the audit trail was not written."

## Recommendation
This is a six-feature PR wearing a one-feature title. Before requesting re-review, the author should:

1. **Critical:** resolve the HMAC-vs-tenant-id-only mismatch in `src/lib/summary-api.ts`. Either restore HMAC signing or land a paired ADR/doc change that explicitly blesses the v1 wire format with a v2 target date.
2. **High:** extract the shared `recordFeeReportActivityLog` and `bffToSummaryParams` helpers (mentioned in High #1). Both have multiple real callers today, not speculative.
3. **High:** add the missing CHECK constraints on `ihd_fee_reports` / `rf_fee_reports` / `reading_fee_reports` (High #3, High #4).
4. **Medium:** add one smoke test per surface that fires a known outbox event and asserts the report row materializes (Medium #1).
5. **Medium:** confirm the cents-vs-whole-units convention with the summary-service team and fix the formatter accordingly (Medium #3).
6. **Medium:** add the CHECK-vs-TS-enum regression test (Medium #4).

Skip: factory functions for "the next report type that may or may not exist", pagination overhauls for non-existent scale, and speculative abstractions over the per-report feature flag toggles. The structural choices here (transactional outbox, materialized report tables, CHECK constraints, nullable-unique grain keys, minimal event payloads with worker re-derivation) are the right ones; the execution is what needs tightening.