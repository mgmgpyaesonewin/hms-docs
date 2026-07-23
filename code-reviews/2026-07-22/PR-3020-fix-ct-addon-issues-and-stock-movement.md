# Code Review: PR #3020 — fix: ct addon issues and stock movement
**Repository:** MyanCare/Ycare-HMS
**Author:** @Xkill119966
**Branch:** `fix/ct-addon-issues` → `development`
**Files changed:** 20 (+412 / -91)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86extdadg

## Summary
CT Add-On module gets OPD-aware cancellation/de-acknowledgment paths that reverse pharmacy stock and delete the linked pharmacy sale. Stock Movement gains QTYIN/QTYOUT display and a generic quantity-movement creator used by proxy-bill cancellations. CT detail/list surfaces are slimmed (removed redundant phone/group/created-by/updated-by/store fields) and OPD-bill-paid detection is wired into the add-on lock check. A "Back" button is added to the CT Add-On form.

## Verdict
**Request changes**
Score: 47/100
Critical: 2 | High: 3 | Medium: 4 | Low: 2 | Nit: 2

## Issues

### Critical

1. **`reverseAddOnCharges` calls `restorePharmacyStockAndMovement` twice and restores stock qty three times** — `src/app/(dashboard)/shared/imaging/services/ct-add-on-billing.service.ts:220-243`. After `removeDailyBillPosting`, the function calls `restorePharmacyStockAndMovement` (which itself does `addStockQty` per item + a stock-movement `createMany`). Then the next block loops `addStockQty` again AND calls `restorePharmacyStockAndMovement` a second time. Net effect per cancellation: stock qty is added back **3x** and **2** stock-movement rows are written for the same reversal. Cancelling an OPD CT add-on will inflate on-hand stock by `3 * qty` and create duplicate movement audit rows. Delete one of the two restoration blocks (keep the dedicated `restorePharmacyStockAndMovement` call, drop the manual `addStockQty` loop + duplicate call).

2. **Likely typo breaks `OpdConfirmPaymentModal` prop binding** — `src/app/(dashboard)/membership/member-card-bill-list/features/components/member-card-bill-list-table-columns.tsx:183`. Changed `existingBilling={opdBilling}` → `exitingBilling={opdBilling}`. The receiving component (in submodule `src/app/(dashboard)/opd/.../opd-confirm-payment-modal`) and the rest of the codebase use `existingBilling` (e.g. `PatientSelect` in `patient-select.tsx`). Renaming the prop on the caller without renaming the receiver will silently drop the OPDBilling value passed to the modal and may break confirm-payment behavior. Either revert to `existingBilling` or also rename on the receiver.

### High

3. **Activity-log write moved inside transaction but is still non-atomic with the cancellation stock reversal** — `src/app/(dashboard)/shared/imaging/services/ct.service.ts:262-282, 298-317, 356-371, 390-405`. Moving `activityLog.create` inside the Prisma transaction is good (the log row will roll back if the txn aborts). However, when `ctAddOnBillingService.reverseAddOnCharges` already runs inside the same txn (and itself writes `stockMovement` rows + updates `isReversed`), the cancellation path now creates activity logs that reference add-on IDs that were just marked `isReversed`. Verify whether downstream consumers filter on `isReversed` first; if so this audit-log row becomes misleading (it says "Added" for a now-reversed record). Also, `createdAddOn` is returned even though some callers already received `result` — confirm no caller still relies on the prior `result` shape (the renamed variable makes the diff harder to grep).

4. **`handleOPDCancellation` is named as "OPD cancellation" but is also used for de-acknowledgment, and it deletes pharmacy sale without guarding against concurrent re-use** — `src/app/(dashboard)/shared/imaging/services/imaging-ipd.service.ts:382-475`. The early-return check `if (!addOn || addOn.isReversed) return;` is good for idempotency, but `deletePharmacySaleAndMovements` does `tx.pharmacySale.delete({ where: { id: pharmacySaleId } })` followed by `restorePharmacyStockAndMovement`. If the same `pharmacySaleId` is referenced from a non-add-on flow (sale referenced elsewhere), the FK cascade in the schema may be relied upon — verify there is no other consumer of `pharmacySaleId` that would now dangle. Add a regression test for double-cancel.

5. **`proxy-bill-stock.rollbackCancelledItems` duplicates existing logic and adds a no-op validation** — `src/app/(dashboard)/shared/proxy-bill/services/proxy-bill-stock.service.ts:124-162`. The legacy `stock.service.rollbackCancelledItems` already does validate + addStockQty for cancelled items; the new method adds stock-movement rows on top. The `validateStockQtyForInventoryUpdate({ isDeduction: false })` is effectively a no-op for the restoration path (only checks `qty >= 1`). The new method also ignores the case where `itm.focQty` is non-zero — wait, it does include `focQty` in `qtyToRestore`, good. But the behavior change (now creates movement rows where the old one didn't) is undocumented in the PR. Confirm this is intentional and that `StockMovementService` consumers expect these extra QTYIN rows.

### Medium

6. **`handleDeAcknowledgment` for OPD has subtle bug — passes `status: DE_ACKNOWLEDGED` to `handleOPDCancellation`, which then early-returns if not CANCELLED or DE_ACKNOWLEDGED** — `src/app/(dashboard)/shared/imaging/services/imaging-ipd.service.ts:376-403`. Wait, `handleOPDCancellation` does accept DE_ACKNOWLEDGED. Re-reading: the path is correct. However, if `isIPDService=true` and the status is DE_ACKNOWLEDGED, the call to `handleCancellation` passes `status: CANCELLED` + `isIPDService: true`, which proceeds. But `userId` is propagated, OK. The behavior is correct, but the branching is hard to follow. Suggest a small inline comment explaining the two branches, or rename `handleOPDCancellation` to `handleCancellation` and have a single entry point branch on `isIPDService`.

7. **`stock-movement-table.tsx` string-builder inconsistency for QTYIN/QTYOUT** — `src/app/(dashboard)/pharmacy/stock/stock-movement/features/components/stock-movement-table.tsx:121-126`. Returns plain `"Qty In Movement"` / `"Qty Out Movement"` without the `(${invoiceNo})` suffix used by sibling return paths. Either accept the new format or add a date/qty hint for parity.

8. **`stock-movement-columns.tsx` ternary nesting for `transferLocation` is hard to read** — `src/app/(dashboard)/pharmacy/stock/stock-movement/features/components/stock-movement-columns.tsx:225-265`. Three-way nested ternary on `transferIn.from` / `transferOut.to` / empty. Extract to a small helper `formatTransferLocation(reason): string`.

9. **CTDetails.tsx `isOPDBillPaid` assumes `bill` is either `OPDBilling | OPDBilling[]`** — `src/app/(dashboard)/imaging/ct/list/features/components/ct-details.tsx:43-46`. Defensive `Array.isArray` check. This implies the schema is inconsistent. Either normalize at the repository layer (return `OPDBilling[]` always) or document the dual shape. The new branch is correct but propagates an upstream smell.

### Low / Nit

10. **Dead store variable removed without flag** — `src/app/(dashboard)/imaging/ct/list/features/components/ct-info-card.tsx:39-45` and `ct-service-activity-log-modal.tsx:47-50`. The `store` variable is deleted along with its `ctInfoSectionItems` entries. Good cleanup. Also removed "Patient Phone" / "Patient Group" / "Created By" / "Updated By" from `ct-list-table.tsx` and `ct-service-activity-log-modal.tsx`. Worth a sentence in the PR description — this is a user-visible change.

11. **`handleBack` repeated in two `<Group>` blocks** — `src/app/(dashboard)/imaging/ct/add-on/features/components/ct-add-on-form.tsx:285-289, 386-405`. The same Back button is rendered twice (one inside `!isViewMode`, one inside `isViewMode`). Since the surrounding button groups are mutually exclusive, you could put one `<Group>` after both branches and conditionally render Clear/Save. Minor.

12. **`AddOthersColumn.isOPDViewMode` unlock** — `src/app/(dashboard)/imaging/ct/list/features/components/ct-service-columns.tsx:341`. Changed `module === "OPD" && false` → `module === "OPD" && isFinalBillPaid`. Previously the OPD add-on was always editable (view/lock was a TODO). This is the actual feature change behind the ticket. Confirm with product: when an OPD bill is paid, the add-on should now lock — verify the UX is intentional (it means a doctor cannot correct a paid add-on row). The companion change `isFinalBillPaid` ternary in `ct-details.tsx:174` is fine, but the name `isFinalBillPaid` is now misleading for OPD (it is `isOPDBillPaid`).

### Low / Nit (continued)

13. **Submodule commit bumps only — `appointment` and `opd`** — `src/app/(dashboard)/appointment` and `src/app/(dashboard)/opd`. Cannot review the contained diffs from this PR. Acceptable for submodule workflow, but flag in PR description which tickets each submodule bump covers.

## Recommendation

1. **Block until Critical #1 (triple-stock-restoration) and Critical #2 (`existingBilling` typo) are fixed.** The stock-restore loop in `ct-add-on-billing.service.ts:226-243` will silently corrupt inventory on every IPD add-on cancellation — this is a high-blast-radius data-integrity bug.
2. Add a regression test for `reverseAddOnCharges` that asserts stock qty returns to its pre-add-on value (not 3x).
3. Re-run the `member-card-bill-list` confirm-payment modal end-to-end to verify the prop rename (or revert it).
4. After fixes, request a re-review.

**Ponytail score (over-engineering):** net -8 lines possible.
- `ct-add-on-billing.service.ts:493-552` — `restorePharmacyStockAndMovement` and `deletePharmacySaleAndMovements` are reasonable extractions; keep.
- `imaging-ipd.service.ts:382-475` — `handleOPDCancellation` JSDoc is OK; the branching is unavoidable.
- No speculative abstractions introduced.