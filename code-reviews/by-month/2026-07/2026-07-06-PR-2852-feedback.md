# PR #2852 — Round Fees Report (cf/tc/ihd/pf/rf report surfaces)

**Repo:** MyanCare/Ycare-HMS · **PR:** https://github.com/MyanCare/Ycare-HMS/pull/2852
**Branch:** `mpt/round-fees-report` → `development` · **Author:** myopaingthu
**Diff:** 99 files · +8,503 / −21 · **ClickUp:** 9018849685/86exqc34h
**Verdict:** Blocking — the deliverable is five near-clone feature slices where one generic abstraction would suffice. Single biggest landmine: the 8.5K diff is dominated by ~6.5K lines of copy-paste, and the unique surfaces have material correctness gaps.

## Summary

The PR lands the Round Fees Report (`rf`) and rolls out the unified CF/TC/IHD/PF/RF report family on the HMS app side:

- 5 new prisma migrations + ~470 lines of schema additions for `cf_fee_reports`, `tc_fee_reports`, `ihd_fee_reports`, `pf_fee_reports`, `rf_fee_reports` (each with a `_status_changes` and `_adjustments` table).
- 5 new API route trees under `src/app/api/(common)/reports/{cf,tc,ihd,pf,rf}/{route,pay,revert,activity-logs}`.
- 5 new feature slices under `src/app/(dashboard)/common/reports/...-report/` (table, columns, pay-modal, revert-confirm, filter-modal, activity-log-modal, schema, types, api wrapper, page.tsx).
- Summary-API client helper, sidebar link entries, role permission UI config, and small edits to OPD/IPD/Cathlab/Imaging services to emit outbox events.

## Strengths

- Hand-written CHECK constraints and pg_trgm GIN indexes in each migration are correctly applied, with comments naming the limitation (Prisma can't express them).
- Per-source nullable UNIQUE indexes on `ihd_fee_reports` / `pf_fee_reports` / `rf_fee_reports` correctly use Postgres's "NULLs distinct" semantics — one row per source-channel grain.
- The `event_outbox` schema lines up with the summary-service contract (status enum, lock fields, retry fields).
- Outbox writes are added to the existing OPD/IPD/Cathlab/Imaging/Proxy services alongside the underlying bill insert (the outbox invariant).
- `next_attempt_at` partial index `idx_outbox_pending` is hand-added where Prisma would emit only the full table version — same trick as the summary-service.
- Schema columns are correctly `Int` (not `Decimal`) for money throughout, matching the summary-service convention.
- `payCfReportSchema` correctly enforces the (mode, value) present iff `adjustmentType !== "FULL"` refinement.

## Issues

### Blocking

**B1. Five near-clone feature slices where one generic abstraction would suffice.** `cf-`, `tc-`, `ihd-`, `pf-`, `rf-` directories each contain a ~370-line table, ~164-line columns file, ~112-line pay modal, ~72-line revert confirm, ~80-line activity log modal, ~87-line filter modal, ~114-line API wrapper, ~39-line Zod schema, ~59-line types file. The five table components differ in two or three cell-render lambdas and the field name being summed (`consultationFee` vs `fee` vs `inHouseDoctorFee` vs `procedureFee` vs `roundFee`). Every column diff is a single ternary on which money column to render.

This is the dominant failure mode of the PR. The five slices are not five features; they are one feature (`<FeeKind>ReportTable<{ feeField, moneyLabel, hasSourceColumn }>`) with a config bag. Each modal is a `<FeeKind>PayModal<{ kind: 'cf' | 'tc' | 'ihd' | 'pf' | 'rf' }>` that branches on the kind prefix everywhere. The schema types and Zod schemas duplicate five times with mechanical search/replace.

Recommended target shape:

```ts
// src/app/(dashboard)/common/reports/fee-report/features/
//   buildFeeReportTable.tsx   // accepts { kind, feeField, hasSourceColumn, ... }
//   buildFeeReportApi.ts      // accepts { kind }
//   buildFeeReportSchema.ts   // returns the four Zod schemas
//   buildFeeReportTypes.ts    // returns Row/GrandTotal/... from the kind
//   components/               // PayModal, RevertConfirm, ActivityLogModal, FilterModal — each parameterized by kind
```

Each per-kind directory collapses to a one-line config + the unique bits (e.g. the RF/IHD/PF IPD-channel source-column logic, which is the only genuinely unique surface). Net: ~6.5K of the 8.5K diff can drop to ~2K.

**B2. `payCfReportSchema` refinement gap on `adjustmentValue`** — `src/app/(dashboard)/common/reports/consultation-fees-report/features/schemas/get-cf-report.schema.ts:30-34`. The schema requires `adjustmentMode != null && adjustmentValue != null` when type ≠ FULL, but does not constrain `adjustmentMode === "PERCENT"` to `0 ≤ value ≤ 100`. A `MINUS 200%` adjustment will be accepted by Zod and crash downstream (`payout = fee - (fee * 200/100) = -fee`) or worse, silently produce a negative payout. Same hole exists in the other 4 schemas.

**B3. Outbox `event_type` collision risk across emit sites** — `src/app/(dashboard)/shared/cathlab/services/cathlab.service.ts` (the +36-line add), `shared/imaging/services/ct-add-on-billing.service.ts` (+20), `shared/ipd/services/{ipd-daily-bill,service-request,ward-service}.service.ts` (+10/+10/+33), `shared/opd/repositories/opd-billing.repository.ts` (+55), `shared/proxy-bill/services/proxy-bill-template.service.ts` (+59). Each emits `event_outbox` rows with a string `event_type` literal. With 6 emit sites scattered across services, a typo on the literal is silent — the summary-worker filters on `event_type` and will no-op on a mismatch. Extract a shared `eventType` const map (`src/lib/outbox-events.ts`) and import from every site.

**B4. `revert_count` mutation race in concurrent revert calls** — the API routes and service code (not all visible in the diff but implied) read `revert_count`, increment, write back without an optimistic-lock `version` column. CFI uses `version` per ADR 0005; the new fee-report tables do not. Two simultaneous reverts on the same row can both pass the `revert_count > 0 ? reject : proceed` gate. (Distinct from CFI's `If-Match` flow — this is a smaller, easier gate to miss.) Add `version Int @default(0)` to all 5 report tables and bump on every write.

### Important

**I1. `useMemo` on `cfReportColumns` has unstable closure assumption** — `src/app/(dashboard)/common/reports/consultation-fees-report/features/components/consultation-fees-report-table.tsx:201-204`. `cfReportColumns({ onActivity: setActivityRow })` is wrapped in `useMemo(() => …, [])`. `setActivityRow` is stable (React guarantee) and the factory returns a fresh array each call, so the memo cache key `[]` accidentally produces a stable reference — *fine for today*. The fragility: if a future change starts returning JSX bound to outer-scope state, every table will re-render but the memo will lie. Add `[onActivity]` to the deps, or convert the factory to a stable module-level builder.

**I2. `grandTotal` keys are not enforced by Zod** — `src/app/(dashboard)/common/reports/consultation-fees-report/features/types/cf-report.types.ts:39-43` defines `CfReportGrandTotal = { consultationFee; payoutAmount }`. The 5 grand-total shapes diverge by one field name. The API route is hand-typed and will accept `{ consultationFee: 100 }` and silently drop `payoutAmount`. Either tighten with Zod on the response side, or — better — collapse to one type per the B1 dedup.

**I3. `payMut.onSuccess` swallows partial-failure signal** — `consultation-fees-report-table.tsx:243-256`. `data.activityLogFailed` triggers a yellow toast but `setPayOpen(false)` and `resetAfterAction()` still run, so the table refreshes and the user thinks all is well. The yellow toast is easy to miss against the page. Consider: keep the modal open, show a "report saved but log failed — contact admin" inline error, and only refresh after the user confirms. Same pattern in the revert handler.

**I4. No "pay" permission gate on the table action bar** — `consultation-fees-report-table.tsx:458-475`. The Pay / Revert buttons render whenever `selected.length > 0`, regardless of whether the user holds the action permission. The ClickUp ticket (86exqc34h) implies a single permission gate; the existing `permission-ui-config.ts` changes suggest one is wired, but the table doesn't read it. Without a `useCan("cf_report.pay")` (or equivalent), any logged-in user can pay invoices. Same for all 5 tables.

**I5. `search` query param not used server-side** — `get-cf-report.schema.ts:13` accepts `search: z.string().optional()` and `cf-report.api.ts` (per the pattern visible in the diff) forwards it, but the API route does not filter on it; the search box in the table (line ~302, `placeholder="Search Invoice No"`) silently no-ops. The pg_trgm index is built and the schema accepts the input — wiring is the missing piece. Either remove `search` from the schema or wire it to `WHERE invoice_no ILIKE %search%` using the existing GIN index.

**I6. Mixed string/number in export "Payout Amount"** — `consultation-fees-report-table.tsx:317-319` (`r.payoutAmount ?? ""`). Excel will treat `"Consultation Fees"` as a number column and `"Payout Amount"` as text (mixed). Coerce to a uniform numeric (empty → 0 or empty consistently) so downstream pivot tables don't break.

**I7. Hard-coded "62vh" table scroll height** — `consultation-fees-report-table.tsx:357`. Same magic number is duplicated in the other 4 tables. Either pull to a shared constant or accept the height as a prop.

### Nit

- **N1.** All 5 tables import `dayjs` but only use it twice (Billing Date, Payment Date). `dayjs` is already in the tree so leave it.
- **N2.** `const money = (n: number | null | undefined) => n == null ? "-" : n.toLocaleString("en-US")` is duplicated in all 5 tables. Move to a shared util alongside the B1 dedup.
- **N3.** `CfRevertConfirm` modal renders the textarea with `styles={{ label: { textAlign: "left", display: "block" } }}` (line 99). Mantine's label is left-aligned by default — this is a no-op CSS override.
- **N4.** The activity-log modal files share the same `useQuery` + table layout; if any of them are file-by-file copies, dedup into a `<FeeReportActivityLogModal kind=… row=… />`.
- **N5.** Each per-kind `page.tsx` is 71 lines and identical except for the table component import + the title string. Move the page wrapper to a shared component.
- **N6.** `api/cf-report.api.ts` exports `payCfReports`, `revertCfReports`, `getActivityLogs`, etc. The body types match the Zod schemas, but they are duplicated as TS interfaces. Drop the TS interfaces and use `z.infer` of the schemas.
- **N7.** Schema column `updatedAt` on all 5 `_fee_reports` tables uses `@updatedAt`, but `last_synced_at` is set to `now()` at create and never updated. If the worker is meant to bump it on every sync (the column name implies), the schema needs an explicit bump or the column should be removed.
- **N8.** `cfReport.types.ts` re-exports `CfPayoutStatus`, `CfAdjustmentType`, `CfAdjustmentMode` as separate types per kind; these are all the same `{ "UNPAID" | "PAID" }`, `{ "PLUS" | "MINUS" | "FULL" }`, `{ "PERCENT" | "AMOUNT" }`. Five copies of identical unions — extract `PayoutStatus`, `AdjustmentType`, `AdjustmentMode` to a shared file.

## Recommendations

1. **Resolve B1 before merging.** The five copy-paste slices are the dominant cost. Land one generic `<FeeReport>` framework with a per-kind config and the 5 individual slices collapse to ~30 lines each. Estimated diff reduction: ~6.5K of the 8.5K. This is the single highest-ROI change.
2. **Fix B2** in the same PR — add `.refine(d => d.adjustmentMode !== "PERCENT" || (d.adjustmentValue != null && d.adjustmentValue <= 100), …)`.
3. **Fix B3** by extracting a shared `eventType` const map to `src/lib/outbox-events.ts` and importing from every emit site.
4. **Fix B4** by adding `version Int @default(0)` to all 5 report tables and using the same `If-Match` flow as CFI.
5. **Apply I4** by gating the Pay/Revert buttons on a `usePermission`/`can("cf_report.pay")` hook.
6. **Wire I5** to use the pg_trgm index (or drop `search` from the schema).
7. **Coerce I6**'s export column to a uniform numeric for downstream Excel readers.
8. **Post-deploy smoke check:** create one CF + one IHD + one PF + one RF report row via the OPD/IPD bill path, then verify all 5 reports show the row with the correct fee column populated. If any of them 404, the per-kind routing path was not wired in the API.

## Reviewer notes

- The PR title is "Round Fees Report" but the diff lands 5 report families — the CF/TC/IHD/PF ones came in earlier commits on the same branch. Consider renaming the PR or splitting into 5.
- `next.config.ts` ignores ESLint/TS errors at build time. Run `npm run lint && npm run typecheck` locally before approving.
- The hand-written migrations are correct and the Prisma schema additions are well-named. The data-model risk lives entirely in the B1 dedup and the B2/B3/B4 invariants.
- The OPD/IPD/Cathlab/Imaging service edits (the +18/+10/+33/+20/+36 lines sprinkled across `shared/`) are out-of-scope for "Round Fees Report" — those should be a separate PR each, scoped to the service that owns the outbox emit. Mixing them here makes revert risky.

**Net deletion possible:** ~6,500 lines if B1 lands as recommended. Without B1, the PR ships working code but is the largest copy-paste landmine in the repo to date.