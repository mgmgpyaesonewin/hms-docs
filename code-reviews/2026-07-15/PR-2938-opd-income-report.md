# Code Review: PR #2938 — OPD Income Report
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `mpt/opd-income-report-new` → `development`
**Files changed:** 97 (+6524 / -53)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-15
**ClickUp:** https://app.clickup.com/t/9018849685/86exnvzhf

## Summary

This PR lands the **OPD Income Report** plus five related doctor-fee reports (Consultation, Tele-Consultant, In-House Doctor, Round, Procedure, Reading). It adds:

- **Six new `*_fee_reports` materialized tables** (cf / tc / ihd / pf / rf / reading) plus the **opd_income_reports** aggregate table and the shared **`event_outbox`** — eight hand-written Prisma migrations, all referencing shared CHECK constraints / partial indexes that Prisma's schema language can't express.
- **Six nearly-identical report UIs** (page + table + filter modal + types + zod schemas) that all share a single generic `FeeReportTable` driven by a `FeeReportConfig`.
- **22 thin Next.js route handlers** (4 per report: list / pay / revert / activity-logs) that proxy to the new `summaryApi` HMAC-less HTTP client.
- **Transactional-outbox emit calls** added to existing services: OPD billing, IPD daily bill, ward service, service request, proxy bill, cath-lab, CT add-on, OPD refund, lab result entry, imaging service result, OPD EMR imaging-replace. Three new event-helper modules (`opd-billing-events.ts`, `ipd-daily-bill-events.ts`, `lab-reading-events.ts`, `imaging-reading-events.ts`) wrap `event_outbox.create`.

The architectural shape is consistent with the summary-service contract: **bill-level events → worker fans out to reports → reports re-derive from current DB state**. CHECK constraints on `payout_status`, `adjustment_type/mode`, `source` mirror the summary-service enums, keeping both Prisma clients byte-compatible.

SonarQube Cloud analysis failed on this PR — see Medium note.

**Sweep limits:** 97 files / +6.5k LOC. I read all migrations, the `schema.prisma` additions, every shared component (fee-report-table / fee-pay-modal / fee-activity-log-modal / fee-filter-modal / fee-revert-confirm / fee-report-columns), the OPD Income page + table + api, all six report pages + tables + APIs, all event-helper modules, the `summaryApi` client, the `permission-ui-config` change, the sidebar change, and the new emit-call additions in cath-lab / OPD billing / IPD / proxy-bill / CT-add-on / ward-service / service-request / OPD-EMR / OPD-refund / lab / imaging. I did **not** read line-by-line: the 22 route handlers (they're near-identical and any finding is repeated by finding-class, not by file), the test files (none present in this diff), the existing tRPC procedures the new pages delegate to (none — they hit `/api/reports/*` directly), or every renamed `*DoctorFee`-style icon (zero in this diff).

## Verdict
**Request changes**
Score: 0/100
Critical: 0 | High: 4 | Medium: 10 | Low: 12 | Nit: 8

## Issues

### Critical
None.

### High

**H1. `Summary-API → HMS` HTTP path crosses services with no authentication.** `src/lib/summary-api.ts` ships with a comment that the HMAC server-to-server auth was deliberately removed for v1 and is "trusted on the wire (both services are on the same private network)". `process.env.SUMMARY_API_URL` defaults to `http://summary-api:4000` (plain HTTP). The `CLAUDE.md` summary-service invariant is the opposite: "Auth is HMAC-SHA256 (ADR 0008 + hms-docs/summary-service/api/hmac-auth.md). Required headers: X-Service-Id (must equal hms-bff), X-Signature, X-Timestamp (±5 min skew), X-Tenant-Id (UUID). Reject with 401 on missing / bad signature / stale timestamp / replay (10k-entry LRU)." HMS is calling summary-api without X-Service-Id / X-Signature / X-Timestamp — every request will be rejected by the production middleware. **This PR cannot work against the deployed summary-service.** Either the summary-service was changed to drop the HMAC, or this is going to 401 on first request. Confirm with the summary-service owner and either (a) reinstate the HMAC here, or (b) confirm summary-service was modified to accept plain X-Tenant-Id.

**H2. Tenant id resolved from `process.env.DEFAULT_TENANT_ID` at emit / call time, not from session.** Every event-helper (`src/lib/{opd-billing-events,ipd-daily-bill-events,lab-reading-events,imaging-reading-events}.ts`) reads `process.env.DEFAULT_TENANT_ID?.trim()` and falls back to silently dropping the event with a `warn`. `summaryApi` throws 500 if unset. There is no per-request tenant resolution. HMS already has multi-tenant session data; this is consistent with the ADR 0007 defense-in-depth violation flagged in `CLAUDE.md` — the BFF must never trust an env var as the source of tenant identity. The four silent-no-op branches in the event helpers mean a misconfigured env drops outbound events without an obvious failure (worker simply never reconciles), which is the worst failure mode for a financial report. Wire tenant through the call chain (auth context → event helper signature → summaryApi), and fail-loud not fail-silent.

**H3. `summaryApi` requests bypass the HMS BFF and the permission guard runs on a stale row state.** The 22 `/api/reports/*` routes each declare `permissions: [{ action: "View", subject: "Consultation Fees" }]` etc., then call `summaryApi.post` with `paidById: user!.id`. But (a) `summaryApi` is `import "server-only"`, so it's reachable only from server code — fine, (b) `View` is the wrong permission action for a mutation (pay/revert) — the original summary-service had `Patch` / `Post` (per `hms-docs/summary-service/api/openapi.yaml`), and the new reports inherit whatever the BFF page passes. The CLAUDE.md summary-service invariant states: "Auth is HMAC-SHA256 … reject with 401". Coupled with H1, pay/revert will 401 in production for any caller besides localhost, AND the HMS permission `View` is the only gate so any user with the View permission can also pay. These two together are a real security finding.

**H4. Duplicate `opd-billing-events.ts` and `ipd-daily-bill-events.ts` already implemented in `hms-summary-service`** — but `event_outbox` is being written by HMS **and** the worker is expected to fan those events out to all six report handlers. That's the design, and it matches the brief. **However**: looking at `src/app/(dashboard)/shared/opd/repositories/opd-billing.repository.ts` (lines around 1307, 1840, 2457, 2881, 2933), `enqueueOpdBillingEvent` is called in five places inside the existing billing flow, and `enqueueIpdDailyBillEvent` is called in six other services. None of these emit calls existed before, and they all now run **inside the same transaction** as the source INSERT/UPDATE. That is the right pattern (transactional outbox). But every emit call is a silent no-op when `DEFAULT_TENANT_ID` is unset (H2), and none are covered by tests. A regression where the env var goes missing in production silently desyncs every report. Add a startup self-check (or a Redis-backed health check) that warns the on-call loudly when this happens.

### Medium

**M2. Massive copy-paste across 6 reports — both client and server sides.** `src/app/(dashboard)/common/reports/{consultation-fees-report,tele-consultant-fees-report,in-house-doctor-fees-report,round-fees-report,procedure-fees-report,reading-fees-report}/` each contain an identical-structure 4-file module (api / schemas / types / page). The only differences are: (a) the prefix on type names (`Cf`/`Tc`/`Ihd`/`Pf`/`Rf`/`Reading`), (b) the path/endpoint, (c) the fee value column name. Same for the 22 route handlers (only the endpoint suffix and the `subject` permission string differ). The `FeeReportTable` + `FeeReportConfig<T>` already does this for the React side — push the server side the same way: one `makeFeeReportRoutes({prefix, subject})` factory returns the four handlers, and one generic `createFeeReportApi({prefix, feeKey})` returns the four API functions. Today the diff is ~2x larger than it should be.

**M3. Unbounded `*ReportListResponse` API surface.** All five fee-report GET routes fetch **all rows** for the date range from summary-api with no cursor pagination. The `summaryApi.ts` comment acknowledges this is intentional ("no pagination — see CF/TC fee report Figma spec"), but the Figma spec is not in the diff. For a 30-day window at a busy clinic this can return 5–20k rows; the React `DataTable` will lag and the network payload gets large. Add server-side cursor pagination matching the rest of the HMS, and at minimum hard-cap with `LIMIT` + a "load more" or server-driven total. **The OPD Income Report is even worse** — it groups by module × counter but returns every module every time, even though 4–5 modules will usually be empty.

**M4. The OPD income report uses `Int` for `amount` (DB) and `number` (TS), with no currency conversion.** All other HMS tables storing fees use `Decimal` or `Int` cents consistently. Here the migration has `amount INTEGER NOT NULL` with a `CHECK (amount >= 0)`. Two follow-on risks: (a) integer overflow on bills ≥ MMK 2.1 billion is real in a 24h window for a busy hospital; (b) the report's "Net Income" calculation is done by the summary-service worker and is not visible in the diff — confirm the worker uses NUMERIC-safe arithmetic, not JS `number` (which silently loses precision past 2^53). At minimum change the CHECK to `BIGINT` and validate the worker's math.

**M5. Six identical `*Page` components — same 60-line `useEffect` block** that defaults the date range to today by mutating `searchParams`. The block contains an explicit `// eslint-disable-next-line react-hooks/exhaustive-deps`. That suppression is in 6 different files and hides a real bug: `effectiveQuery.start` / `effectiveQuery.end` are computed inside `useMemo` from `parsed`; if `parsed` changes (user pastes a URL with a date range) the effect won't run, but the URL replacement still fires once on mount with the *default* range, racing the URL. Use `useEffect(() => { ... }, [parsed, router])` instead, or set the search params only on first mount with a `useRef` guard. The suppression masks this in six places.

**M6. `fee-filter-modal.tsx` hardcodes doctor limit to `limit: 0, offset: 0, page: 1`.** This passes `limit: 0` to the doctors API — depends on the API semantics: does it mean "all doctors" or "no doctors"? The `useMemo` then does `doctorsData?.result.doctors ?? []`, so this is the **whole doctor list** with no bound. For a 500-doctor hospital, the modal loads every doctor upfront. Use a search-as-you-type API (the doctor's existing search field likely already supports this) instead of "give me everything". Same problem in `opd-income-filter-modal.tsx` with `stores`.

**M7. `FeeReportConfig.activityLogsQueryKeyPrefix` is a free-form string** and every report hardcodes its own variant (`"cf-activity-logs"`, `"tc-activity-logs"`, ...). The query-key invalidation in `FeeReportTable.resetAfterAction` then does `qc.invalidateQueries({ queryKey: [config.activityLogsQueryKeyPrefix] })` which invalidates a top-level key and silently nukes *every* activity log cache across reports. The prefix is supposed to scope the invalidation but React Query treats a single string as an exact match. Change to an array key (e.g. `["cf-activity-logs", "*"]` matched via a predicate), or pass the factory directly.

**M8. `FeeRevertConfirm` always sends `remark.trim()` — even when empty.** The schema `revertCfReportSchema = z.object({ … remark: z.string().trim().max(500).optional() })` accepts undefined, but the form sends `""` (a non-empty trimmed empty string) to the API. The route then does `body.remark?.trim() || undefined`, which discards the empty string, so this round-trips correctly — but it would be cleaner if the form just omitted the field when empty. Also: the `remark` is sent as part of the API body but the API then re-strips it; the worker never receives a `remark` for activity logging unless it's non-empty. Add a one-line check in the form. (Found in `fee-revert-confirm.tsx`.)

**M9. `event_outbox` write contention hot-spot.** Every OPD/IPD/imaging/lab/cath-lab mutation now writes one extra row to `event_outbox` inside its transaction. The summary-service worker is on the same DB and reads the same indexes. For a busy hospital doing 100 OPD billings/min, this is 100 inserts/min into a table the worker SELECT FOR UPDATE SKIP LOCKEDs constantly — fine for now, but the `idx_outbox_pending` partial index on `(next_attempt_at) WHERE status = 'PENDING'` is the only one without tenant, so once multi-tenant ramps up the worker scans will be tenant-blind. Plan to drop in a `(tenant_id, next_attempt_at) WHERE status = 'PENDING'` index as soon as a second tenant comes online.

**M10. `SchemaSync`-style drift risk across two Prisma clients.** `prisma/schema.prisma` adds `EventOutbox`, `CfFeeReport`, `TcFeeReport`, `IhdFeeReport`, `PfFeeReport`, `RfFeeReport`, `ReadingFeeReport`, `OpdIncomeReport` (609 lines added). The summary-service maintains its own subset. Every enum value added to summary-service constants (`payout_status`, `source`, `adjustment_type`, `measure`, `module`, `source_type`) is mirrored here as a CHECK constraint. There's no automated drift test — if summary-service adds `'PAYABLE'` to `payout_status`, the worker writes rows the HMS CHECK rejects with no compile-time warning. Add a test that diffs the two Prisma clients' CHECKs against the summary-service enum constants (referenced in `hms-docs/summary-service/constants/`).

### Low / Nit

**L1.** Six identical `*Report` config objects differ only by field name. The `FeeReportTable` already abstracts them — push the type-narrowing into the fee type and stop hand-writing 6 configs.

**L2.** `usePageView({ page: "Consultation Fees Report" })` is called 7 times in 7 page files with hardcoded strings. Pull the labels into the route-config and centralize.

**L3.** `schema.ts` files re-export `*Schema = z.infer<typeof *Schema>` and also export the schema. Every route imports both. Most routes only need the inferred type — pick one and stick with it.

**L4.** The page's `useEffect` that mutates the URL fires `router.replace` synchronously during the render cycle on first mount. Wrap in a `useRef` "has initialized" guard so React strict-mode double-mount doesn't fire it twice.

**L5.** `dayjs(query.start).toISOString()` runs twice per query (once in `buildListParams`, once in the React Query key). The two calls produce the same string but pull in two date allocations; trivial, just memoize.

**L6.** `OPD Income Report`'s `MODULE_LABELS` enum and the server `OpdIncomeModuleCode` are duplicated 9 times each. Acceptable but a shared `MODULE_CODES` constant in `@/lib/opd-income-modules` would centralize.

**L7.** `money = (n) => n.toLocaleString("en-US")` is repeated in 3 files. A shared `@/utils/money` already exists elsewhere in HMS — reuse it.

**L8.** `formatToDefaultDate(dateObj)` in `fee-activity-log-modal.tsx` is followed immediately by `dateObj.toLocaleTimeString(...)`. Use a single `formatDateTime` helper.

**L9.** `queryString` key uses camelCase (`start`, `end`, `doctorId`) on the client and the same params are translated to snake_case-ish (`from`, `to`) at the route layer. Pick one; the server-side summary-api endpoint already accepts `from`/`to`. Drop the translation step.

**L10.** `BaseFeeReportRow` in `fee-report-shared/types.ts` re-declares 14 fields that are duplicated in 6 row interfaces. The whole abstraction should have one source of truth (the Prisma model + zod schema), not 6 hand-maintained interfaces.

**L11.** `summaryApi.get` returns `json as T` with no runtime validation. If summary-service's response shape drifts, HMS shows `undefined.isPaid` crashes. Add zod-parse-on-read.

**L12.** `fee-report-table.tsx`'s `useReactTable` calls `enableRowSelection: (row) => !row.original.sourceVoided`. The selection state lives at row level but the "allUnpaid / allPaid" aggregate (`mode = ...`) only re-evaluates on render — if rows change status from another tab, the bottom bar miscomputes. Low impact (user has to refocus) but document.

**N1.** `src/app/(dashboard)/common/reports/opd-income-report/features/components/opd-income-report-table.tsx` defines a local `ColumnDef` type that shadows `@tanstack/react-table`'s. Rename to `OpdIncomeColumn` to avoid confusion.

**N2.** `// Default the date range to today when no range is in the URL.` is repeated verbatim 7 times.

**N3.** The `FeeReportTable` `useEffect` resize listener doesn't unbind on unmount if the container ref detaches mid-scroll. Wrap with the existing cleanup; today it does. (Disregard — already correct.)

**N4.** `paid` and `reverted` API response interfaces (`PaidRow`, `RevertedRow`) are redefined identically across 14 route handlers. Define once.

**N5.** `useMutation` `onSuccess` for `payMut` shows `${config.feeLabel} Paid Successfully!` — but `feeLabel` is "Consultation Fees" (plural), so the toast reads "Consultation Fees Paid Successfully!". Awkward.

**N6.** `money` in `fee-report-table.tsx` and `fee-report-columns.tsx` is byte-identical — export from one place.

**N7.** `intent=` non-existent: `Intent` Mantine prop on `Menu.Item` is not used.

**N8.** The diff removes trailing-newline behavior from `.env.example` (the file's existing `\ No newline at end of file` is dropped, two new vars are added without a final newline). Cosmetic; editors will yell.

## Recommendation

1. **Block on H1, H2, H3, H4** before merge — they are deploy blockers, not style issues.
2. **Apply M2 + M7** — the `makeFeeReportRoutes({prefix, subject})` and `makeFeeReportApi({prefix, feeKey})` factories collapse ~2,400 LOC into ~600, fix the activity-log query-key bug for free, and drop the SonarQube duplication gate.
3. **Add the cursor pagination + the doctor search-as-you-type (M3, M6)** in the same pass — they are independent but the API contract changes either way.
4. **Wire tenant through the call chain** so event-helpers and `summaryApi` resolve tenant per-request from the authenticated session, not from `DEFAULT_TENANT_ID`. Then re-introduce HMAC at the `summaryApi` boundary to match the published API spec.
5. **Add a startup self-check** that asserts `DEFAULT_TENANT_ID` is set in production and that `summaryApi` round-trips at boot (see CLAUDE.md "post-deploy monitoring" pattern).
6. **Run the schema-drift test** between this `schema.prisma` and the summary-service enum constants; commit both to a shared script under `hms-docs/summary-service/tools/`.
7. After fixes, **re-run SonarQube** before requesting a second review.

**Verdict: Request changes.** The architectural design (transactional outbox, per-report tables, fan-out worker) is sound and matches the summary-service contract. The implementation is correct in shape and the table/index/CHECK-constraint work is high-quality. But the auth/tenant plumbing is wrong end-to-end (H1–H4) and the duplication is large enough that merging now will block the next 3 PRs that touch the same area.