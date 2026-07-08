# Code Review: PR #2878 — Enhance discharge final bill logic
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `enhance/april/sprint-26/discharge-final-bill` → `development`
**Files changed:** 4 (+26 / -14)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07
**ClickUp:** https://app.clickup.com/t/9018849685/86ey2ybmc

## Summary
Deposits used to be closed during discharge completion (`discharge.service.ts:closeAllDepositWhenDC`). This PR moves that side effect onto the final-bill lifecycle: close on `createFinalBill`, reopen on `cancelFinalBillById`. Also stops the daily-bill ward-services component from querying discharge state — it now receives `isFinalBillPaid` from the parent.

## Verdict
**Request changes**
Score: 84/100
Critical: 0 | High: 1 | Medium: 1 | Low: 3 | Nit: 2

## Issues

### High
- **`cancelFinalBillById` reopens every closed deposit on the admission, not just the ones the bill closed.** `ipd-final-bill.service.ts` — where clause is `isDepositClose: true` with no link to the bill. Any deposit closed by another path (manual close, refund, prior bill) flips back to open on cancel. Asymmetric with the create path (which filters `isDepositClose: false`, so idempotent). Fix: add `closedByFinalBillId` column on `admission_deposit`, or scope to `finalBill.createdAt`. Two-line change, don't ship without it.

### Medium
- **`completeDischarge` no longer touches deposits — undocumented behavioural change.** Before: deposit closed inside discharge-completion transaction. After: deposit lives open until final bill is created. Grep `isDepositClose` across `hms-app/` before merge; anything reading it expecting "closed ⇔ discharge done" (UI badges, deposit creation guards, rollup reports) now sees different state.

### Low
- **`utilService` in `IPDFinalBillService` is wired up but never called.** YAGNI — drop the field+import, or actually route the `updateMany` through it so the abstraction earns its keep.
- **`closeAllDepositWhenDC` on `UtilService` becomes dead code.** Delete it in this PR, or it rots.
- **No test for the deposit-close/reopen path.** Money-involved code; one integration test asserting `isDepositClose` before/after each flow is the minimum.
- **Direct `tx.admissionDeposit.updateMany(...)` bypasses the `depositRepository` layer.** Rest of the IPD domain writes through repositories; this inline Prisma call skips any future repo hooks.

### Nit
- **`isFinalBillPaid` vs old `isFullyDischarged` UX shift.** New gating blocks edits when final bill is paid; old gating blocked when discharge COMPLETED. Tightens the lock — confirm with the ticket owner this is the intended direction.
- **PR title is vague.** The highest-impact user-visible change is the ward-services gating fix; the deposit-lifecycle change is hidden in "Enhance discharge final bill logic". Split into two commits or rename.

## Recommendation
1. Fix the High (scope cancel reopen to this bill).
2. Grep `isDepositClose` readers; document the timing change.
3. Drop unused `utilService` wiring, or route through it; delete dead `closeAllDepositWhenDC`.
4. Add one integration test for create→close, cancel→reopen.
5. Run `npm run tsc && npm run lint && npm test` from `hms-app/` before merging.