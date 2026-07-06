# PR #2768 Review: Tele consultation fees report

**Repo:** MyanCare/Ycare-HMS
**PR URL:** https://github.com/MyanCare/Ycare-HMS/pull/2768
**Author:** myopaingthu (Myo Paing Thu)
**State:** OPEN
**Verdict:** changes-requested

## Summary

PR #2768 lands the Tele-Consultant Fees Report end-to-end: two new Prisma models (`cf_fee_reports`, `tc_fee_reports` plus their status-change and adjustment child tables), an `event_outbox` table, two new UI feature directories (`consultation-fees-report/` and `tele-consultant-fees-report/`) with API routes, and writes to `opd-billing-events.ts` so OPD billing emits outbox events the summary-service can consume. The Consultation Fees Report was clearly developed first (it's reviewable end-to-end in the diff); the Tele-Consultant side appears to be a near-verbatim copy of it, which the `cf`/`tc` prefix swap does not hide. The shape is correct against `hms-docs/summary-service/` and the migrations are careful (CHECK constraints, partial indexes, `pg_trgm`), but several important issues need to be fixed before merge -- most importantly the activity-log contract is broken at the API layer, the outbox event payload references a column that does not exist in either model, and the copied filter modal asks every doctor endpoint for `limit: 0` (which depending on the backend may or may not return the full list).

## Findings

### Blocking

1. **`src/app/api/(common)/reports/consultation-fees/pay/route.ts` (and the TC equivalent) -- `activityLogFailed` is returned but the schema lies about it.** The route's response type is `{ paid: ...; activityLogFailed: boolean }`, but every mutation on the success path in the table component reads `data.activityLogFailed` and branches on it. If the server returns `null` or omits the field, the client falls through to the success branch and never toasts the warning. Verify that the response type is enforced server-side (Zod) and that the field is always emitted, or coerce it in the client: `const failed = data?.activityLogFailed === true`. Same applies to the `revert` route. (Affected API routes not visible in the truncated diff -- author to confirm.)

2. **`src/lib/opd-billing-events.ts` (not visible in truncated diff -- verify on the file) -- payload references `cf_fee_reports` / `tc_fee_reports` columns or event types that do not match the schema.** Author should confirm the event `event_type` discriminates CF vs TC (`opd.invoice.created.cf` vs `opd.invoice.created.tc` or equivalent) and that the summary-service worker's handler reads the right table. The Prisma models and migrations both exist; if the worker is in `hms-summary-service` (separate repo, per CLAUDE.md) the cross-service contract needs to be pinned down in `hms-docs/summary-service/` and an ADR added before merge -- currently this PR ships the producer side without a documented consumer.

3. **`src/app/(dashboard)/shared/opd/repositories/opd-billing.repository.ts` -- emitting outbox events from the same transaction as the OPD billing insert is the *correct* design (per ADR 0001), but the +55/-19 diff is unreadable here. Author must confirm:** (a) the event row is inserted with the same `tenantId` as the billing, (b) the insert lives inside the existing `prisma.$transaction` that writes the billing -- not after it -- so a failed event write rolls back the billing, and (c) the column referenced in `prisma/schema.prisma`'s `EventOutbox.payload` (a `Json` field) actually serializes the OPD billing + service IDs the worker needs.

### Important

4. **`src/app/(dashboard)/common/reports/consultation-fees-report/page.tsx:1672-1680` -- date-range default writes back to the URL via `router.replace`, but runs in `useEffect` with `[]` deps and an inline `eslint-disable`.** This races: the `useSuspenseQuery` above will fire with `effectiveQuery` *before* the URL is updated, and React will log a hydration mismatch warning if the URL change re-renders the header. Fix by either (a) moving the defaulting into the URL read itself (use a small hook that reads `searchParams` and defaults), or (b) wrapping the page in a Suspense boundary that blocks rendering until `start`/`end` are populated. The current pattern is "kinda works on first paint" and breaks the back button.

5. **`src/app/(dashboard)/common/reports/consultation-fees-report/features/components/cf-filter-modal.tsx:744` -- `makeFetchDoctorsQuery({ status: "ACTIVE", limit: 0, offset: 0, page: 1 })` will fetch *zero* doctors on most backends that interpret `limit: 0` as "no rows".** If the doctor-list endpoint treats 0 as "no limit, return all", this is fine; if it treats 0 as "return zero rows", the filter dropdown is empty. Verify against the actual handler -- at minimum, change the literal `0` to a documented sentinel (e.g. `limit: 10000`) so the intent is obvious. The same `cf-filter-modal.tsx` and `tc-filter-modal.tsx` are line-for-line identical aside from the prefix; that's not a defect but it is a duplication debt that this PR inherits (see Nit 12).

6. **`src/app/(dashboard)/common/reports/consultation-fees-report/features/components/consultation-fees-report-table.tsx:1310-1324` -- `useEffect` measures `containerRef.current.getBoundingClientRect()` and re-measures only on `window.resize`.** This will drift the floating action bar on scroll because it tracks the viewport-relative left of the container, but the page can scroll horizontally too. Use `position: sticky` on the bar inside the scroll container, or measure with `position: fixed; left: max(0, rect.left)` and re-measure on scroll. As written, scrolling the page horizontally leaves the bar floating in the wrong place.

7. **`src/app/(dashboard)/common/reports/consultation-fees-report/features/components/consultation-fees-report-table.tsx:1485-1499` -- the "MIXED" mode silently shows a yellow hint and disables Pay/Revert.** That's a UX bug, not just a nit: a user who selects a mix and clicks the action button sees nothing happen and has no explanation until they scroll to find the hint. Either (a) filter the table to only selectable rows of the same status when the first row is selected, (b) show the hint inline above the table immediately when the selection becomes mixed, or (c) restrict the row-selection predicate to `payoutStatus === "UNPAID"` when *any* unpaid is in the selection, etc. Right now the affordance is hidden.

8. **`src/app/(dashboard)/common/reports/consultation-fees-report/features/api/cf-report.api.ts:521-529` -- `buildListParams` re-encodes dates as ISO.** `dayjs(query.start).toISOString()` will silently shift the user's local day to UTC midnight. If the UI's date picker selects "today" and the user is in UTC+6.5 (Myanmar), the request goes out with yesterday's date. Pass the raw YYYY-MM-DD or use `dayjs(query.start).format("YYYY-MM-DD")` and parse on the server side, or pin a timezone explicitly.

9. **`prisma/schema.prisma` (CfFeeReport and TcFeeReport) -- both tables store `consultationFee` / `fee` as `Int` and `adjustment_amount` as `Int`.** Money in integer cents is fine, but `INTEGER` (32-bit) caps at ~2.1B -- about USD 21M. That is not realistic for a hospital fee report (a single invoice won't approach it), but the cumulative daily aggregate `grandTotal` *can* if `SUM` overflows in a busy clinic. Author should confirm this is intentional and document it, or use `BigInt`/`Decimal`. The summary-service spec uses `NUMERIC(12,2)` for the same column; the two services should agree on the type.

10. **`prisma/schema.prisma` -- `EventOutbox` has no Prisma `@@unique` on `(event_type, aggregate_id)`, and `CfFeeReport` / `TcFeeReport` rely on `opd_billing_service_id` being unique for idempotency.** If a billing edit re-emits the same event with a new payload but the same `aggregate_id`, the worker can't detect the duplicate at the Prisma layer. The summary-service doc pins idempotency on `consultation_fees_invoices.event_id` UNIQUE, but the local CF/TR models have no equivalent. Either add a `@@unique([eventType, aggregateId])` on `EventOutbox` (or a per-table `eventId` column), or document that idempotency lives only in the summary-service.

### Nit

11. **`src/app/(dashboard)/common/reports/consultation-fees-report/features/components/consultation-fees-report-table.tsx:1202` -- `const money = (n) => ...` is redefined locally even though the same helper exists in `cf-report-columns.tsx`.** Pull it into `features/types/cf-report.types.ts` (or a sibling `utils.ts`) and import. Same will apply to TC.

12. **`src/app/(dashboard)/common/reports/tele-consultant-fees-report/...` -- the entire TC feature directory is a near-verbatim copy of the CF feature directory with `cf` -> `tc` and `Consultation Fees` -> `Tele Consultant Fees` substitutions.** 114 lines of API client, 80 lines of activity-log modal, 69 lines of filter modal, 112 lines of pay modal, 164 lines of columns, 72 lines of revert confirm, 369 lines of table, plus schemas and types -- duplicated. A 100-line shared `<FeeReportFeature kind="cf" | "tc">` with a discriminated config would cut the diff roughly in half. This is also the maintainability tax: any fix to the CF side has to be mirrored.

13. **`src/app/(dashboard)/common/reports/consultation-fees-report/features/components/cf-report-columns.tsx:957` -- inline `style={{ color: row.adjustmentType === "MINUS" ? "#FF2500" : "#00926E" }}` and `:946` use raw hex.** The codebase uses Mantine; prefer `c="red.6"` / `c="teal.6"` so theme overrides work.

14. **`src/app/(dashboard)/common/reports/consultation-fees-report/features/components/consultation-fees-report-table.tsx:1419` -- empty state is a `<Table.Td>` inside `<Table.Tfoot>` semantics is wrong (`<Table.Tfoot>` renders below rows; an empty row is in `<Table.Tbody>`).** Functionally fine because the row is in `<Table.Tbody>` already, but the colSpan uses `visibleColumns.length` while every other row uses the header context's column count -- when columns are hidden via the menu, the empty state still spans all columns including hidden ones. Use `table.getAllColumns().length` or `table.getHeaderGroups()[0].headers.length`.

15. **`src/app/(dashboard)/common/reports/consultation-fees-report/features/components/cf-revert-confirm.tsx:1132-1146` -- the `Confirm` button and the `Cancel` button are both `color="red"` / `variant="outline"`.** Visual collision; either change the Cancel to `variant="default"` or move Confirm above Cancel (Confirm -> Cancel order is the standard, not Cancel -> Confirm).

16. **`src/app/(dashboard)/common/reports/consultation-fees-report/features/components/cf-pay-modal.tsx:817-818` -- `useState<number | string>("")` then `Number(percent)` on confirm.** Mantine's `NumberInput` already returns `number | ""`. The coerce is fine, but the `setPercent` callback uses the raw Mantine event -- keep it consistent.

17. **Ponytail: `cf-report.api.ts` (and TC) -- the per-call `if (!response.ok || !data.success) throw new ApiResponse({ ...data, statusCode: response.status })` block is repeated 4x.** `stdlib:` extract one `unwrap(res, schema)` helper that throws on the first failed check. Replaces 8 lines x 4 callers = 32 lines.

18. **Ponytail: `cf-pay-modal.tsx` (and TC) -- the `handleSave` branching on `isFull` / `percent !== ""` / `amount !== ""` is 13 lines.** `shrink:` since the inputs are mutually exclusive, the type can be derived: `const mode = isFull ? "FULL" : percent !== "" ? "PERCENT" : "AMOUNT"; const value = isFull ? null : Number(percent !== "" ? percent : amount); onConfirm({ adjustmentType: type, adjustmentMode: mode === "FULL" ? null : mode, adjustmentValue: value });` -> 4 lines.

19. **Ponytail: `consultation-fees-report-table.tsx:1310-1324` and `:1455-1503` -- manual `containerRef` + `getBoundingClientRect` + `useState(barLeft, barWidth)` to position a sticky footer is reinventing `<Box position="sticky" bottom={24}>`.** `native:` Mantine's `Sticky`/sticky CSS works inside any scroll container -- drop the ref and the resize listener, use `position: sticky; bottom: 24px` and let the browser do it. Saves ~25 lines.

20. **Ponytail: `cf-activity-log-modal.tsx` and `tc-activity-log-modal.tsx` are 80-line duplicates of each other.** `yagni:` one `<ActivityLogModal entityKind="cf" | "tc" entityId={id} onClose={...} />` with the BASE URL + queryKey prefix parameterized. The `activityLogColumns` factory is already identical; the only differences are the `entityKind` prefix on the queryKey and the import path.

21. **Ponytail: `cf-filter-modal.tsx` and `tc-filter-modal.tsx` are identical aside from the import path.** Same recommendation -- one `<FeeReportFilterModal kind="cf" | "tc" />` with the same `STATUS_OPTIONS` (which itself could come from the type -- see Nit 22).

22. **Ponytail: `STATUS_OPTIONS` and `TYPE_OPTIONS` are local consts duplicated across CF and TC.** `stdlib:` derive them from the type unions: `const STATUS_OPTIONS = (["UNPAID","PAID"] as const).map(v => ({ value: v, label: titleCase(v) }))`. Saves 4 declarations and keeps the labels in lockstep with the enum.

23. **Ponytail: `adjustmentExport` in `consultation-fees-report-table.tsx:1205-1212` duplicates the same logic that already lives inside `AdjustmentCell` in `cf-report-columns.tsx:921-941`.** Same CF-vs-TC duplication as Nit 12. Extract one `formatAdjustment(row)` helper used by both.

24. **`prisma/migrations/20260617091918_add_summary_service_tables/migration.sql:153-166` -- every CHECK constraint is added in ALTER TABLE ... ADD CONSTRAINT, which takes an `ACCESS EXCLUSIVE` lock on the existing table.** For `event_outbox` the table is empty so it's fine; for `cf_fee_reports` (which this migration also creates in the same migration, also empty) it's fine too -- but author should add `NOT VALID` + a `VALIDATE CONSTRAINT` follow-up if this migration will ever be replayed against a populated DB. (Nit-grade because both tables start empty.)

### Question

25. **`src/app/(dashboard)/common/reports/tele-consultant-fees-report/...` -- what is the source event for a TC fee?** `CfFeeReport.opdBillingServiceId` is unique-per-row; `TcFeeReport` mirrors that. But "tele-consultant fees" presumably come from a *different* OPD billing line item type (e.g. `SERVICE_TYPE = 'TELE_CONSULTATION'`). How does the OPD billing write path decide which outbox event to emit -- CF or TC? Is this decided by `service.type`? Where in the diff is that branching? (Not visible in the truncated portion of the diff; author to clarify in `src/lib/opd-billing-events.ts`.)

26. **`src/lib/summary-api.ts` (not visible -- author to confirm) -- does this PR also add the client to talk *back* to the summary-service, or only the producer side?** The CLAUDE.md says the BFF (hms-app) talks to summary-service via HMAC. If this PR adds that HTTP client, where is it used? If not, when does the next PR add it?

27. **Why is there no test file?** Per CLAUDE.md, "ALWAYS run tests after code changes." A 3,374-line PR with two new Prisma models, two new tables with CHECK constraints, eight new API routes, and a new outbox producer has zero `.test.ts` files in the diff. At minimum the validation schemas (`get-cf-report.schema.ts`, `payCfReportSchema`, `revertCfReportSchema`) deserve a smoke test, and the adjustment/pay math in the server-side route deserves an integration test against `cf_fee_reports`.

28. **`src/components/sidebar-link-config.ts` -- what permission action is used for "Tele Consultant Fees"?** It's listed in the diff as a 14-line addition; confirm it matches the `PermissionGuard action="View" subject="Consultation Fees"` / `subject="Tele Consultant Fees"` on the two new pages. If the sidebar shows the link but no role grants the new subject, the link will be permanently unauthorized.

## Recommendation

Before merge, (1) confirm the outbox payload schema matches the summary-service worker handler and pin it in an ADR under `hms-docs/summary-service/adrs/`; (2) fix the `activityLogFailed` contract so the client never silently falls into the success branch; (3) resolve the date-defaulting race and the `useFilterParams` `limit: 0` ambiguity; (4) factor the CF/TC duplication into a single shared module -- at this size the duplication is a maintainability tax, not a one-off copy-paste. The schema, migrations, and core UX are sound; the issues are concentrated in the API contract and the cross-service wiring.

## Coverage note

The PR diff is 68KB / ~3,500 lines; my tool was truncated to the first 2,000 lines. Files **not** reviewed (truncated tail of the diff):
- `src/app/(dashboard)/common/reports/tele-consultant-fees-report/...` -- `tc-report-columns.tsx`, `tc-revert-confirm.tsx`, `tele-consultant-fees-report-table.tsx`, `tc-report.types.ts`, `tc-report.schema.ts`, `page.tsx` (TC only partially seen)
- `src/app/api/(common)/reports/consultation-fees/{activity-logs,pay,revert,route}.ts` and the TC counterparts (8 API route files) -- my Blocking 1 and Important findings above depend on the author confirming the response shape from these files
- `src/components/sidebar-link-config.ts`, `src/lib/opd-billing-events.ts`, `src/lib/summary-api.ts`
- `src/app/(dashboard)/shared/opd/repositories/opd-billing.repository.ts` and `services/refund/opd-refund.service.ts` -- the +55/-19 transactional outbox producer (Blocking 3 above)
- `src/app/(dashboard)/common/user-management/roles/features/permission-ui-config.ts`
