# Code Review: PR #2768 — Tele consultation fees report
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `mpt/tele-consult-fees-report` → `development`
**Files changed:** 38 (+3374 / -20)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07
**ClickUp:** https://app.clickup.com/t/86exqc3nt

## Summary
Adds a Tele Consultant Fees Report mirroring an existing Consultation Fees Report: 3 new Prisma tables (`tc_fee_reports`, status changes, adjustments), a shared transactional-outbox event emitter (`opd-billing-events.ts`), a server-to-service HTTP client (`summary-api.ts`), 4 route handlers per report (list, pay, revert, activity-logs), a sidebar entry, permission config, and a near-complete UI clone of the consultation fees report (page + 5 components + types + schema + api module per report). The OPD billing repository is wired to emit outbox events on bill create/edit/cancel/delete/refund.

## Verdict
**Request changes**
Score: 46/100
Critical: 0 | High: 5 | Medium: 6 | Low: 4 | Nit: 2

## Issues

### Critical
None

### High

1. **CF and TC reports are 100% duplicate UI/type/schema/api modules (~1,500 LOC cloned).** The `consultation-fees-report/` and `tele-consultant-fees-report/` trees differ only in: prefix (`cf`/`tc`), one column name (`consultationFee`/`fee`), two display strings ("Consultation Fees" / "Tele Consultant Fees"), and one API base path. Two `prisma/schema.prisma` models differ only in column rename + `@@map`. The two migrations are identical except for the table/constraint prefixes. Generics over `{ feeColumn, label, kind }` plus a `ConsultationReportPage` component reading a config object would collapse this to one file. As written, every future change (sort, filter, export column, new status) must be made twice and kept in sync. This is the highest-cost-to-value issue in the PR.

2. **List endpoint returns unbounded rows for the date range — no pagination.** `route.ts` proxy: *"Returns ALL rows for the date range (no pagination)"*. The summary-service already supports cursor pagination (per hms-docs/summary-service/api/openapi.yaml). For a busy OPD day this returns thousands of rows, blowing memory in the BFF, the worker response, and the browser table. Client-side pagination via TanStack (`getCoreRowModel` only — no pagination state) hides the problem but doesn't solve it. Add `limit`/`cursor` and the existing `getRowModel` swap to `useReactTable` with pagination, or at minimum a hard cap with a "narrow your date range" warning.

3. **The BFF writes `activity_logs` outside the summary-service transaction with a soft-fail toast (`activityLogFailed`).** Pay and revert each: call summary-api (which writes its own `cf_fee_report_status_changes` / `cf_fee_report_adjustments` rows), then call `prisma.activityLog.createMany(...)` separately. If that second insert fails, the toast says "Payment recorded, but the activity log entry failed to save." — the activity log is then permanently out of sync with the status change. The summary-service CLAUDE.md establishes the outbox + worker pattern precisely so this kind of dual-write can't drift. Either move activity-log writes into the summary-service (via HMAC-signed call from the worker back to hms-app) or fold them into the same Prisma transaction as the outbox emit — not "best-effort BFF post-write."

4. **`summary-api.ts` has no timeout on the upstream `fetch()` call.** `request<T>` builds `init` with no `AbortController`/`signal`. A hung summary-api blocks the BFF request indefinitely and ties up the Next.js worker. Add a 5–10s `AbortController.timeout()` (or `signal` from a wrapper) so the BFF can fail fast and surface a 502.

5. **Outbox event design contradicts its own file comment.** `opd-billing-events.ts` header comment claims *"So adding a new report type does NOT require a new event type or a new emit call here."* — yet three distinct `OpdBillingEventType` values are emitted (`bill_created`, `bill_reconciled`, `refund_created`), and the repository now has 5 separate `enqueueOpdBillingEvent` call sites. The worker needs to know what happened; consumers subscribe to a topic. Either collapse to a single `OpdBillingChanged` event whose payload describes the kind, or commit to per-event routing and rewrite the comment. The current shape pays the cost of both.

### Medium

1. **`revertCount` and `sourceVoided` columns have no producer.** The schema adds them, the UI renders them, but no code in the diff ever sets `source_voided = true`, writes `source_voided_reason`, or increments `revert_count`. They will always read `false`/`0` from this PR. Either wire them in the summary-service worker (out of scope here, but document the contract) or remove from the UI.

2. **`page.tsx` has a `useEffect` + `eslint-disable-next-line react-hooks/exhaustive-deps` that mutates the URL *after* the query has already fired.** `useSuspenseQuery(makeCfReportQuery(effectiveQuery))` runs with `effectiveQuery` (defaults today), then `useEffect` does `router.replace(?)` with the same defaults. Result: the query fires once with the defaults, then a re-render on URL change refetches. Either compute defaults synchronously in `useMemo` and let the URL stay empty (skip the `router.replace`), or push the URL write to a layout — not inside `useEffect`.

3. **`payCfReportSchema.refine` requires both `adjustmentMode` and `adjustmentValue` when not FULL, but `getCfReportSchema` accepts `nullish` for both.** The pay modal sends `{ adjustmentType: "MINUS" }` with empty `percent` and `amount` (empty strings) — Zod coerces, then the refine fires 400 with a confusing message. Either tighten the modal to always send a mode+value when not FULL, or make the schema accept either and resolve server-side.

4. **Filter modal fetches every doctor with `limit: 0, offset: 0, page: 1`.** `makeFetchDoctorsQuery({ status: "ACTIVE", limit: 0, ... })` — for any tenant with > a few dozen active doctors, this loads the full list into a Select. `limit: 0` is "no limit" semantics in many APIs. If 0 truly means "all", add `search`/virtualization; if it means "default page", pass an explicit page size.

5. **`DEFAULT_TENANT_ID` read on every emit and required to be set in every environment.** `enqueueOpdBillingEvent` warns and skips when missing; `summary-api.ts` throws 500 when missing. The summary-service CLAUDE.md establishes `X-Tenant-Id` as a per-request HMAC-verified header from the BFF, not an env var. Today the hms-app only has one tenant, so this works — but the shape says "trust the env" while the worker says "trust the header." Pick one source of truth and document it. When a second tenant is added, this silently drops events.

6. **The PR diverges from the documented summary-service data model.** `cf_fee_reports` here has `paymentDate`, `paidById`, `revertCount`, `sourceVoided*` — none of these exist on the documented `consultation_fees_invoices` table that the summary-service exposes via `/consultation-fees-invoices`. Either the summary-service implements new endpoints for this richer schema (out of scope here, undocumented), or these columns will never be populated because no `pay`/`revert` route on summary-api reads or writes them. Confirm the worker side or trim the schema to match.

### Low / Nit

1. **The UI passes the route handler `entity` string `"ConsultationFeesReport"` / `"TeleConsultantFeesReport"` as a magic literal in two places each** (the `pay` and `revert` route handlers). Extract `const ENTITY = "ConsultationFeesReport"` per route file (or in the schema/types file) so a typo can't drift between the two handlers.

2. **`payMut` / `revertMut` invalidations target string keys `["cf-report"]`, `["cf-activity-logs"]`** — but `makeCfReportQuery` puts the keys under `["cf-report", { ... }]` and `makeCfActivityLogsQuery` under `["cf-activity-logs", entityId]`. `invalidateQueries({ queryKey: ["cf-report"] })` matches both — fine today, but if you add a `["cf-report", "audit"]` namespace later this over-invalidates. Use the full prefix array.

3. **Mantine `<Menu.Item>` checkbox pattern uses `pointer-events-none` on a Checkbox controlled by `onChange={() => {}}`** — works but is a known Mantine smell. There is a Mantine docs pattern using `<Menu.Checkbox>` for exactly this. Use that.

4. **`DataTableExportAction` calls `async () => items` and `DataTableExportAction` is invoked in render — verify it doesn't fetch.** Reading the snippet it appears to be a client-side exporter over the already-fetched array. If that's true, the name is misleading and an export of "today's page only" is silently a "today's report only" — surface that in a tooltip or guard against an unpaginated list.

### Low / Nit (ponytail findings, structural)

1. **Eight route handler files (4 cf + 4 tc) with ~95% identical bodies.** One generic `{ kind: "cf" | "tc" }` factory + a small per-kind config table would cut this in half.

2. **`MoneyCell`/`AdjustmentCell`/`StatusBadge` are duplicated wholesale between `cf-report-columns.tsx` and `tc-report-columns.tsx`.** The only difference is the `consultationFee` vs `fee` field name. Move to a shared `report-columns.tsx` parameterized by `feeColumn`.

3. **`buildListParams` in each api file is the same code with a different BASE.** Trivially shared.

4. **`STATUS_OPTIONS = [{ UNPAID, PAID }]`** in each filter modal is also duplicated. Promote to `@/constants/payout-status.ts`.

5. **`payMut` / `revertMut` toast handlers differ only in the success string.** Either accept the duplication or parameterize.

6. **`useEffect` + `eslint-disable-next-line react-hooks/exhaustive-deps`** in both `page.tsx` files for the URL write — single-line pattern, lift to a `useUrlSyncedDefaultRange` hook if both pages share it.

## Recommendation

1. **Stop the duplication.** Before merging, extract `DoctorFeeReportPage<TFeeColumn, TKind>` and a `pay/revert/activity-logs/list` route factory; the cf/tc split becomes one config row each, not two parallel trees. This halves the diff and makes "fix a bug in the report" mean changing one file.
2. **Add pagination** to `/api/reports/consultation-fees` and `/api/reports/tele-consultant-fees` (limit/cursor like the summary-service already exposes), and wire TanStack's `getPaginationRowModel`. Without it this PR will OOM a BFF node on a busy month-end.
3. **Move activity-log writes into the same transaction as the outbox emit** (or have the summary-service worker do them), not as a best-effort BFF post-write.
4. **Add a fetch timeout** in `summary-api.ts`.
5. **Confirm the summary-service side** implements the new endpoints (`/cf-fee-reports/pay`, `/revert`, `/activity-logs`, the new columns) or trim the schema to what it actually owns.
6. **Decide the event-shape story** — either collapse to one event type (per the file's own comment) or commit to per-event routing and rewrite the comment.
7. Once those are addressed, the diff collapses to roughly a third of its current size and is much closer to shippable.

**Ponytail summary:** `net: -1,500 lines possible` if the CF/TC duplication is collapsed and the four duplicated helpers are lifted to shared files. The structural code is otherwise reasonable; the volume is the problem.