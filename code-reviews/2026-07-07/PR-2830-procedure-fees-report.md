# Code Review: PR #2830 — Procedure fees report
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `feat/procedure-fees-report` → `development`
**Files changed:** 77 (+6870 / -21)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07
**ClickUp:** https://app.clickup.com/t/9018849685/86exqc0u6

## Summary

This PR is the fourth (and reportedly the last) installment of a series that ships a generic, event-driven summary-report system on top of `hms-summary-service`. It adds the **Procedure Fees** report and folds in the three earlier reports (Consultation Fees, Tele-Consultant Fees, In-house Doctor Fees) that were previously landing as separate PRs (#2768, #2798). On the HMS side it adds:

- A shared `event_outbox` write API (`src/lib/opd-billing-events.ts`, `src/lib/ipd-daily-bill-events.ts`) plus a typed `summaryApi` client (`src/lib/summary-api.ts`).
- Per-bill event hooks inside `OpdBillingRepository`, `ProxyBillTemplateService`, `WardServiceService`, `ServiceRequestService`, `CathLabService`, `IPDDailyBillService`, and `CtAddOnBillingService`.
- Four near-identical UI modules under `src/app/(dashboard)/common/reports/{consultation-fees,tele-consultant-fees,in-house-doctor-fees,procedure-fees}-report/` plus matching API routes under `src/app/api/(common)/reports/*`.
- The schema for `event_outbox` and four parallel report-table sets (`CfFeeReport*`, `TcFeeReport*`, `IhdFeeReport*`, `PfFeeReport*`).
- Sidebar entries, permission strings, and `.env.example` additions (`SUMMARY_API_URL`, `DEFAULT_TENANT_ID`).

The event-emission design is sound: domain events on the bill (`bill_created` / `bill_reconciled` / `refund_created`) instead of one event per report — adding a new report type does not require new emit sites. The four frontend modules are near-clones, which is the obvious over-engineering risk called out below.

## Verdict
**Request changes**
Score: 57/100
Critical: 1 | High: 3 | Medium: 4 | Low: 4 | Nit: 3

## Issues

### Critical

1. **`deleteWardService` writes the outbox event outside the transaction — breaks the transactional-outbox invariant.**
   `src/app/(dashboard)/shared/ipd/services/ward-service.service.ts` (lines ~522–540 in the diff): the capture-then-delete pattern reads `existing.ipdDailyBillId` *before* calling `deleteWardRequestItemsAndRefundDeposit` and `wardServiceRepository.deleteWardService`, then calls `enqueueIpdDailyBillEvent(prisma, ...)` using the **base `prisma` client** (not `tx`). The whole point of a transactional outbox (called out in the CLAUDE.md invariants and the `event_outbox` ADR) is that the event row is committed in the same tx as the data mutation. If the ward-service delete commits and the event insert fails (DB blip, pool exhaustion, etc.), the report rows for those lines will never reconcile and become stale forever — the very thing this whole PR is trying to prevent. Wrap the delete in a `prisma.$transaction` and call `enqueueIpdDailyBillEvent(tx, ...)`; the pre-read can move inside the tx.

### High

2. **Four 370-line table components are near-byte-identical clones.**
   `procedure-fees-report-table.tsx`, `in-house-doctor-fees-report-table.tsx`, `consultation-fees-report-table.tsx`, `tele-consultant-fees-report-table.tsx` each carry the same TanStack table setup, selection-mode derivation (`allUnpaid`/`allPaid`/`MIXED`), mutation onSuccess/onError pair, column-visibility menu, the `containerRef`/`barLeft`/`barWidth` sticky-bar useEffect, and `adjustmentExport` helper. The only differences are (a) the row type, (b) the row→export mapper, and (c) which `pay*Reports`/`revert*Reports` import is used. Genericize over `<R extends { id: string; payoutStatus: "UNPAID" | "PAID"; sourceVoided: boolean }>` with callbacks for `payApi`/`revertApi`/`exportRow` and you delete ~1,100 lines. The same applies to `pf-report-columns.tsx` / `ihd-report-columns.tsx` / `cf-report-columns.tsx` / `tc-report-columns.tsx` (164 lines × 4 with one column-set difference), and to the 4 `pay-modal` / 4 `filter-modal` / 4 `revert-confirm` / 4 `activity-log-modal` files. Realistically a `BaseFeeReportTable<R>` + 4 thin column configs + 4 type files is the minimum.

3. **Four `*.api.ts` client files duplicate the same 4 functions.**
   `cf-report.api.ts` / `ihd-report.api.ts` / `pf-report.api.ts` / `tc-report.api.ts` are line-for-line identical except for the `BASE` URL constant and the exported function names. Same for the four sibling route folders under `src/app/api/(common)/reports/*/{route,pay,revert,activity-logs}.ts` — the `pay` / `revert` / `activity-logs` routes only differ in the `entity:` string passed to `prisma.activityLog.createMany` and the upstream `summary-api` path. Hoist a `makeFeeReportClient<T>(basePath: string)` factory and one `makeActivityLogRoute(entity: string, summaryPath: string)` factory, then each report is ~10 lines.

4. **Frontend components hardcode the `summary-api` auth context the CLAUDE.md invariants say is still trusted on the wire.**
   `src/lib/summary-api.ts` ships `X-Tenant-Id: ${process.env.DEFAULT_TENANT_ID}` with no auth header at all — the comment "v2 will reintroduce an auth context" admits the gap. Two side effects: (a) any process inside the cluster that can reach `summary-api:4000` (or a misconfigured next-hop proxy) can drive CFI/TFI/IHDI/PFI pay+revert as any tenant; (b) every `prisma.activityLog` write on the HMS side uses the *current user's* `userId` for the audit trail but the summary-api mutation it accompanies is trust-bound to the env-var tenant id — the audit and the mutation have different tenant scopes. Either gate the env-var tenant behind a service-to-service header now, or document that summary-api binding to a per-request user is an explicit Phase 3 task with a ticket.

### Medium

5. **4 × 164 lines of "PF/TC/IHB/CF report columns" duplicate 90% of their columns.**
   `pf-report-columns.tsx` / `tc-report-columns.tsx` / `ihd-report-columns.tsx` / `cf-report-columns.tsx` define the same `Invoice No`, `Billing Date`, `Doctor Name`, `Doctor Code`, `Specialization`, `Status`, `Payment Date`, `Payout Amount`, `Adjustment`, and `Activity` columns. The only difference is the fee column (`procedureFee` vs `fee` vs `consultationFee` vs `inHouseDoctorFee`) and the source-channel enum. Same fix as #2.

6. **`enqueueOpdBillingEvent` swallows the missing-tenant case silently.**
   `src/lib/opd-billing-events.ts`: when `DEFAULT_TENANT_ID` is unset, the helper logs a warning and returns. In dev or a misconfigured CI env that means every OPD bill goes through the repository with no outbox row — silent data loss, exactly the bug the whole feature exists to prevent. Either fail-fast on the first call per process (an in-memory guard) or throw at boot when the env var is missing in non-prod. Production should hard-fail.

7. **Eight event-emit call sites with a hand-rolled `await` after the mutation — easy to forget the emit on the next code path.**
   The PR adds event-emit lines to ~10 repository/service methods. There is no compile-time guard that a mutation method also enqueues the matching event. A reviewer adding a new mutation method (e.g. the next batch-edit endpoint) will not get an error if they forget `await enqueue...`. At minimum, add a comment block above each mutated method listing its required emit, or — better — extract a `withOpdBillingEvent(tx, op, ...)` helper that takes the mutation as a callback and emits the event after, so the pairing is impossible to miss.

8. **`updateOPDBilling` emits `bill_reconciled` after the mapping layer.**
   `src/app/(dashboard)/shared/opd/repositories/opd-billing.repository.ts` (around line 2452): the new emit sits *after* `await this.mapAppointmentReferral(...)`. The map function may itself perform DB writes (similar patterns in this file do); if it throws, the parent `prisma.$transaction` rolls back the data writes but the reconcile event is already queued… actually no, the emit uses `tx`, so a `tx` rollback will roll back the event. Marking this as Medium because the ordering is fragile and easy to break in a future refactor — move the emit directly after the data mutations, before the mapper.

### Low / Nit

9. **`usePageView` import path uses the `@common/...` alias with a non-existent source folder.**
   `page.tsx` files import `@common/reports/activity-logs/features/hooks/use-page-view`. That feature folder is not present anywhere in this PR's diff — it's referenced as if it already exists. Confirm it does (and isn't being created here), or the four new pages will fail to compile.

10. **Money formatting re-implemented inline four times.**
    `const money = (n) => n == null ? "-" : n.toLocaleString("en-US");` appears once per table file. If the project already has a money formatter (search `toLocaleString` in `src/utils` and `src/lib`), reuse it; otherwise lift this one-liner into `src/utils/format.ts`.

11. **Each `page.tsx` defaults to "today" via `useEffect` URL rewrite — runs once and silently no-ops if `parsed` later diverges from the URL.**
    `page.tsx`: `useEffect(() => { if (!searchParams.get("start") && !searchParams.get("end")) { ... } }, []);` with `eslint-disable-next-line react-hooks/exhaustive-deps`. Compute `effectiveQuery` and call `router.replace` synchronously in a `useState` initializer or via a one-shot ref pattern instead — the eslint-disable comment is a smell.

12. **`adjustmentExport` ternary chain in every table file.**
    `if (r.adjustmentType === "FULL") return "Full Pay"; const sign = r.adjustmentType === "MINUS" ? "-" : "+"; ...` — copy-pasted across all four table files. Hoist into `formatAdjustment(row)` next to `money`.

13. **`summaryApi.get<T>` / `summaryApi.post<T>` do not pass through request cancellation / `AbortSignal`.**
    On a date-range change the previous fetch can resolve after the new one, causing a stale result. Low because this is a follow-the-leader pattern across the report pages, but worth fixing once with `signal` plumbing through the query options.

14. **`.env.example` adds `SUMMARY_API_URL=http://summary-api:4000` (Docker service name) without documenting the local-host override.**
    Anyone running `npm run dev` outside `docker compose -f infra/docker-compose.yml up` will hit `summary-api:4000` and get a connect error. Either add a comment ("set to `http://127.0.0.1:4000` for local dev outside Docker") or default it to `http://127.0.0.1:4000`.

15. **Prisma schema: `Int` columns for money values.**
    `consultation_fee`, `in_house_doctor_fee`, `procedure_fee`, `adjustment_value`, `adjustment_amount`, `payout_amount` are all `Int` (Kip amounts in MMK are fine up to ~2.1B; this is acceptable for the use case) — but the rest of HMS uses `Decimal` for fees. Worth a one-line ADR comment or a `Decimal` switch for consistency with the OPD/IPD domains.

16. **`sourceVoidedReason` CHECK enum hardcoded in SQL across 4 migrations.**
    `'CANCELLED', 'REFUNDED', 'REMOVED_ON_EDIT'` is repeated in 4 migration files. Hoist into a shared `prisma/migrations/_common_voided_reasons.sql` (or a single consolidated migration) to avoid drift.

17. **`api-handler` activity-log routes trust the `entityId` query param without any UUID validation.**
    `activity-logs/route.ts` files: `const entityId = req.nextUrl.searchParams.get("entityId"); if (!entityId) throw new AppError("entityId is required", 400);`. Zod-validate it as a UUID to avoid passing arbitrary strings into `prisma.activityLog.findMany` (and to fail fast on the kind of typo the frontend would otherwise mask as a 500).

## Recommendation

1. **Block on #1** (the broken transactional-outbox in `deleteWardService`). It is the single invariant the whole feature rests on.
2. **Address #2 and #3** before merging — refactor the four UI/API clones into one parameterized factory each. With 1,100 lines of dedup available, the PR's net diff drops from +6,870 to something closer to +5,000 and the next report type (round fees, reading fees — already in flight per the open tasks) becomes ~100 lines instead of ~1,700.
3. **File the auth-gap ticket (#4) explicitly** — at minimum document the v2 HMAC re-introduction as a hard Phase 3 deliverable, with a `gh issue` linked from the ClickUp task.
4. The four follow-up report PRs in flight (`#2768`, `#2798`, `#2852`, `#2868`) should *not* be merged independently — they share the same template, so any refactor in this PR affects them all. Land this PR's refactor first, then rebase the others.