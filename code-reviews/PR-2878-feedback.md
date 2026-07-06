# PR #2878 — Enhance discharge final bill logic

**Repo:** MyanCare/Ycare-HMS
**PR:** https://github.com/MyanCare/Ycare-HMS/pull/2878
**Author:** April-Naing
**Branch:** `enhance/april/sprint-26/discharge-final-bill` → `development`
**Changed files:** 5 (+44 / -14)
**ClickUp:** https://app.clickup.com/t/9018849685/86ey2ybmc
**Verdict:** Changes requested

## Summary

Moves "close all deposits when discharged" out of `discharge.service.ts` into `ipd-final-bill.service.ts`, and adds the symmetric "reopen all deposits on final-bill cancel" flow plus a UI fix that replaces a discharge-status React-Query with a passed-down `isFinalBillPaid` boolean. The intent is sound — a deposit's lifecycle is tied to the final bill, not the discharge, so the close/reopen pair belongs with the final-bill service. But the move leaves a stale `utilService.closeAllDepositWhenDC` indirection that now only exists as a one-line forwarder, the two new private methods on `IPDFinalBillService` are barely doing anything, and the new repository method `updateAllDepositReopenStatus` is a near-identical copy of `updateAllDepositCloseStatus` — both of which the new code never actually needs because the deposit's depositRepository is already injected. Net effect: a correct refactor done with one extra hop and one missed abstraction.

## Strengths

- Correct domain insight — deposit lifecycle belongs with the final bill, not the discharge. The cancel → reopen path was missing and the right place to add it is here.
- Clean removal of the `dischargeQuery` + `useQuery` + `makeGetDischargeByAdmissionIdQuery` import from the ward-services component. The `admissionId` prop and a useQuery round-trip just to read `discharge?.result?.status === "COMPLETED"` was always overkill for a render-time boolean.
- Passing `isFinalBillPaid` down as a boolean prop is the right shape — it matches the same prop already plumbed to the other six children of `DailyBillDetailView` (lines 196-248 of `daily-bill-detail-view.tsx`).
- Both close and reopen run inside the existing `prisma.$transaction` blocks, so atomicity is preserved.
- Net +30 lines for a real behavior change (reopen on cancel) plus a render-loop simplification.

## Issues

### Important

1. **`UtilService.closeAllDepositWhenDC` is now a one-line forwarder used in exactly one place** — `util.service.ts:492-497` and `discharge.service.ts` (deleted at line 324). The new `IPDFinalBillService.closeDeposits` is also a one-line forwarder (`util.service.ts` ← `deposit.repository.ts`). Two layers of forwarding for a single `updateMany` call. Pick one:
   - Drop `closeAllDepositWhenDC` from `UtilService` and have `IPDFinalBillService` call `this.depositRepository.updateAllDepositCloseStatus` directly (matches what `updateAllDepositReopenStatus` already does), OR
   - Drop the new `UtilService` indirection from `IPDFinalBillService` and just keep using `this.utilService.closeAllDepositWhenDC`.
   
   Either works; the current PR has both, which is the smell. The clean version is "IPDFinalBillService → DepositRepository directly," which also matches the reopen path and removes the `utilService` field you just added.

2. **`updateAllDepositReopenStatus` is a copy-paste of `updateAllDepositCloseStatus`** — `deposit.repository.ts:598-622`. Differ only in `isDepositClose: true` vs `false`. Either:
   - Parameterize: `updateDepositCloseStatus(admissionId, isDepositClose, tx?)` and have one private method on `IPDFinalBillService` call it with the right bool, OR
   - Inline both into the service (one `updateMany` call per branch) and delete the repository methods — they are not reused elsewhere.
   
   The repo already has `isDepositClose` as a single boolean field; two near-identical repository methods for its two values is over-engineering.

3. **The cancel path's `reopenDeposits` does not run before `cancelIpdFinalBillById`** — `ipd-final-bill.service.ts:268-294`. The order is: cancel the bill → reopen deposits → handle admission states. If the reopen fails (e.g. the deposit row has been hard-deleted, or the patient has a new admission in flight), the bill is already cancelled but deposits stay closed, which is the inconsistency the reopen is meant to prevent. Reopen *before* the cancel, or wrap both in the same `prisma.$transaction` (the cancel block already has the transaction — just move the reopen call above `cancelIpdFinalBillById`).

4. **No `isDepositClose: false` guard on reopen** — `deposit.repository.ts:611-622`. The reopen blindly flips every `AdmissionDeposit.isDepositClose` to `false`, including deposits that were already open. That's fine semantically but it means a second cancel on a final bill will still reopen deposits that were never closed by the cancel itself. Consider `where: { admissionId, isDepositClose: true }` to make the operation idempotent and self-documenting. (And the same for the close path while you're there — a `where: { admissionId, isDepositClose: false }` makes the close path also idempotent and stops two discharge events from doing two updateManys.)

### Nit

5. **Private methods that wrap a single call each** — `ipd-final-bill.service.ts:46-58`. `closeDeposits` and `reopenDeposits` are each one line. If you keep them, name them after the side effect (`closeDepositsOnDischarge` / `reopenDepositsOnCancel`) so the call site reads as intent. If you fold them per finding #1, just inline.

6. **`UtilService` import in `IPDFinalBillService` is the first cross-domain dep on `util.service.ts` from a domain service** — `ipd-final-bill.service.ts:25`. The other five services on this class (`IPDFinalBillRepository`, `DischargeRepository`, `AdmissionRepository`, `PatientsRepository`, `NewBornBabyService`) are all IPD-scoped. `UtilService` is shared/utils. Per finding #1 the right fix removes this import entirely; if you keep it, add a comment on why an IPD service reaches into shared utils.

7. **PR body is just a ClickUp link.** For a behavior change (cancel now reopens deposits; ward-services component drops its discharge query), a one-line description in the body would help reviewers and future archaeologists.

8. **PR title is vague.** "Enhance discharge final bill logic" doesn't tell me what changed. Something like `fix(ipd): move deposit close/reopen to final-bill service; reopen on cancel` would.

9. **Unused `DepositRepository` import in `discharge.service.ts`?** — check whether the diff also drops the only other use of `DepositRepository` from `discharge.service.ts`. The diff shows the import is not touched, so if `closeAllDepositWhenDC` was its only consumer (verified: `grep -r "closeAllDepositWhenDC"` returns just `util.service.ts` and the deleted line), the import can be removed.

10. **`isFinalBillPaid` rename signal** — the diff comment in `daily-bill-ward-services-and-procedures.tsx` notes `isFinalBillPaid` was already being passed to six other siblings but the ward-services-and-procedures component was previously the only one going around it with a discharge query. The rename to `isFinalBillPaid` from `isFullyDischarged` (via `discharge?.result?.status === "COMPLETED"`) is also a more correct domain meaning — `isFinalBillPaid` is the upstream fact, discharge completion is a downstream proxy. Worth a one-line comment at the source explaining why this prop wins.

## Recommendations

1. **Drop `UtilService.closeAllDepositWhenDC` and call `DepositRepository` directly from `IPDFinalBillService`** — removes one hop, removes the `utilService` field, and matches the existing pattern for the reopen path.
2. **Collapse `updateAllDepositCloseStatus` / `updateAllDepositReopenStatus` into one parameterized method** — or inline both into the service.
3. **Move `reopenDeposits` above `cancelIpdFinalBillById`** — so a failed reopen rolls back the cancel.
4. **Add `isDepositClose: <currentValue>` guards to both close and reopen** — makes both paths idempotent.
5. **Add a one-line PR description and a clearer PR title.**

## Reviewer notes

- Behavioral symmetry is the headline win: discharge closes deposits, cancel reopens them. Before this PR the cancel path left deposits closed, which is the kind of bug that surfaces as "why is the patient being told their deposit is gone when their bill was cancelled." Lock this in with a test on `cancelFinalBillById` asserting `isDepositClose` is false afterwards.
- The PR is net +30 lines for a refactor + a new behavior. With the simplifications above it could be net +5: one parameterized repository method, two direct calls from the service, one prop change, one import cleanup.
- The ward-services-and-procedures component still uses `isFinalBillPaid` to mean "the patient has paid their final bill." That's correct for hiding edit affordances, but it conflates "bill exists" with "bill is paid" — if the team later adds an `IPD_BILL_CREATED_BUT_UNPAID` state, this prop needs to be re-read. The PR description should note that the rename `isFullyDischarged → isFinalBillPaid` is a tightening, not a no-op.
- Adjacent code: `handleAdmissionStates` in `ipd-final-bill.service.ts` flips `patientType` to "OPD" on discharge and back to "IPD" on cancel. Worth checking whether the same deposit repo call there would let you retire the `discharge.service.ts` indirection entirely — the discharge service is increasingly a thin shell over the final-bill service.

**Ponytail net estimate:** -20 lines possible (drop the two private forwarders, collapse the two repo methods, drop the `utilService` field).