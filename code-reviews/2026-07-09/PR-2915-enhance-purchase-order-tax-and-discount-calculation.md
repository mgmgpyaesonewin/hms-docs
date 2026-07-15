# Code Review: PR #2915 — enhance purchase order tax and discount calculation
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `enhance/april/sprint27/purchase-order-tax-discount-foc-logic` → `development`
**Files changed:** 3 (+225 / -70)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-09
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3budy

## Summary
Reworks the per-line purchase order math in `purchase-order-line-amounts.ts` and wires FOC (free-of-charge) into both line and form totals. The new pipeline applies **FOC → discount → tax** sequentially on the chargeable subtotal: discount and tax are both computed on `(qty − foc) × price`, with tax layered on top of the discounted subtotal. `calAmtDependOnPercent` is moved from the form into the shared utils, and a new `calTaxAmtDependOnPercent` does the compound tax calc. Every input change in `PurchaseOrderItemRow` (qty / price / tax% / discount% / discount-amount / foc) now recomputes both `discountAmount` and `taxAmount` inline in the onChange.

## Verdict
**Request changes**
Score: 75/100
Critical: 0 | High: 1 | Medium: 3 | Low: 2 | Nit: 1

## Issues

### Critical
None

### High

**H1. Order of operations (FOC → discount → tax) is a real behavioral change that needs product sign-off, not a refactor.**
File: `src/app/(dashboard)/shared/pharmacy/utils/purchase-order-line-amounts.ts:75-129` (new `calculatePurchaseOrderLineNetAmount`).

The previous model applied FOC at the end as a flat subtraction, with tax and discount both running on the gross `(qty × price)`. The new model:
- FOC reduces chargeable qty first,
- discount runs on the FOC-adjusted subtotal,
- tax runs on the **discounted** subtotal (i.e., tax-on-post-discount, not tax-on-gross).

Two business-rule changes are baked in here without an ADR / ticket note:
1. Discount now applies to the FOC-adjusted subtotal. (Reasonable, but was not the case before for the discount-on-FOC-items question — FOC items were effectively always free of discount before, now they are excluded from the discount base by formula, which is the right answer but needs confirming.)
2. Tax is now applied **after** the discount, not on the gross. This changes every PO's tax amount going forward. Most tax regimes (including Myanmar's commercial tax on imports/purchases) tax the gross, not the post-discount value — discount usually flows through as a price reduction outside the tax base. If the previous form computed tax on gross, the new code under-collects tax on every discounted PO.

This needs a deliberate confirmation from the pharmacy/accounting owner before merge. An ADR or a sentence in the PR description ("tax is intentionally on post-discount subtotal per discussion with @X on date Y") is the minimum. Without it, this PR silently changes the amount of tax the hospital pays.

### Medium

**M1. Item-row onChange logic is duplicated 6 times with subtle variations; the form is the largest line-by-line money path in the repo.**
File: `src/app/(dashboard)/pharmacy/purchase/purchasing/features/components/purchase-order-item-row.tsx:100-368`.

Every onChange (qty, price, tax%, discount%, discount-amount, foc) re-implements the same pair: "recompute `discountAmount` via `calAmtDependOnPercent`, then recompute `taxAmount` via `calTaxAmtDependOnPercent`." The variants differ only in which input triggered the change. This is ~200 lines of inline computation that will drift the next time someone adds a field. Extract a single helper:

```ts
const recomputeLineAmounts = (index: number, foc?: number) => {
  const f = form.getValues(`purchaseOrderItems.${index}`);
  const focQty = foc ?? Number(f.foc || 0);
  if (f.discountPercentage) {
    form.setValue(`purchaseOrderItems.${index}.discountAmount`,
      calAmtDependOnPercent({ percent: Number(f.discountPercentage), price: Number(f.originalPricePerUnit), qty: Number(f.qty), foc: focQty }));
  }
  if (f.taxPercentage) {
    form.setValue(`purchaseOrderItems.${index}.taxAmount`,
      calTaxAmtDependOnPercent({ taxPercentage: Number(f.taxPercentage), price: Number(f.originalPricePerUnit), qty: Number(f.qty), foc: focQty, discountPercentage: f.discountPercentage ? Number(f.discountPercentage) : undefined, discountAmount: f.discountPercentage ? undefined : Number(f.discountAmount || 0) }));
  }
};
```

Then each onChange is one call. Same behavior, ~10% of the diff, no drift risk.

**M2. `useEffect` in the form has `discountAmount` in its dep array while also calling `setValue("discountAmount", …)` — works today, fragile under any future change.**
File: `src/app/(dashboard)/pharmacy/purchase/purchasing/features/components/purchase-order-form.tsx:184-203`.

The effect:
- depends on `[discountPercentage, taxPercentage, subTotal, discountAmount]`,
- sets `discountAmount` first (when `discountPercentage` is set),
- then sets `taxAmount` based on the new `discountAmount`.

Today the setValue-to-self does not re-trigger the effect (react-hook-form deduplicates identical values), so it converges. The day someone passes `{ shouldValidate: true }`, swaps to `useWatch`, or changes the rounding (e.g., 2dp), this becomes a render loop. Two options:
- (preferred) Make the effect **idempotent over inputs only** — depend on `[discountPercentage, taxPercentage, subTotal]`, derive the discountAmount inside the effect, set both at once. No need to depend on discountAmount.
- Or split into two effects: one for discount, one for tax, so tax's deps don't include the value tax depends on.

**M3. `if (discountAmount)` / `if (discountAmount)` truthy checks silently treat explicit 0 as "no discount".**
Files: `purchase-order-form.tsx:188-194` (form-level), `purchase-order-line-amounts.ts:115-121` (tax helper).

```ts
if (discountAmount) {
  discountedSubtotal = chargeableSubtotal - Number(discountAmount);
} else if (discountPercentage) {
  ...
}
```

If the user has set `discountPercentage` to `0` and then typed a real `discountAmount` of `0` (i.e., they want to clear the discount), the truthy check skips both branches. The same happens for an explicit `taxAmount` of 0 vs a missing `taxAmount`. Use `!== undefined`:

```ts
if (discountAmount !== undefined) { ... }
else if (discountPercentage !== undefined) { ... }
```

Same fix in the form-level `useEffect`'s `if (discountAmount)` check.

### Low / Nit

**L1. `currentField` is a render-time snapshot, not a live read — rapid onChange sequences can use stale values.**
File: `purchase-order-item-row.tsx` (all six onChange blocks).

Each onChange closes over `currentField` from the parent render. When the user edits `discountAmount` in a way that should update `taxAmount`, the onChange for `discountAmount` reads `currentField.taxPercentage` from the snapshot at last render — fine in this case, since the user typed into the discount field. But the qty/price onChange reads `currentField.discountPercentage` from a snapshot. If the user changes discount%, then immediately changes qty, the qty handler may run with the old discount% snapshot. This is the classic react-hook-form pitfall.

The fix in the `recomputeLineAmounts` helper above — reading from `form.getValues(...)` — is the correct read. After M1 is applied, this issue goes away.

**L2. Caller-side `Number(currentField.foc || 0)` is redundant.**
File: `purchase-order-item-row.tsx` (multiple call sites).

`calAmtDependOnPercent` and `calTaxAmtDependOnPercent` both internally do `Number(foc || 0)`. The callers also wrap with `Number(currentField.foc || 0)`. Belt-and-suspenders is fine, but it makes grep-ability harder: a future maintainer who wants to find every place that defaults FOC will see both call-sites and helpers. Pick one — the helper is the right place; remove the caller-side wrapper.

**N1. Inconsistent JSDoc and naming.**
File: `purchase-order-line-amounts.ts`.

- `calAmtDependOnPercent` has no JSDoc. `calTaxAmtDependOnPercent` does. Either both or neither.
- The form uses local variable `discountedAmount` (form) vs `discountedSubtotal` (helpers). Pick one.
- The function is named `calTaxAmtDependOnPercent` but takes `discountAmount` / `discountPercentage` as required-or-undefined inputs. A name like `calCompoundTaxAmt` or `calTaxOnDiscountedSubtotal` would describe what it actually does. As-is, the name suggests "tax from percent" when it does "tax from percent on a discounted base" — the caller has to read the body to know the order of operations, which is exactly what H1 is about.

## Recommendation
1. **H1 first.** Confirm with the pharmacy owner whether tax is intended to apply on the post-discount subtotal. If yes, add a one-line PR description note and link to the discussion/ADR. If no, switch tax to the gross subtotal: `let finalNetAmount = baseSubtotal + (baseSubtotal * taxPct) / 100;` then subtract the discount at the end. The current behavior is a silent tax reduction.
2. **M1:** Extract `recomputeLineAmounts(index, foc?)` to the shared utils or a per-row hook. The form file will shrink dramatically and the six onChange blocks become single-line calls.
3. **M2 + M3:** Re-shape the form-level `useEffect` to depend on inputs only, and replace the truthy checks with `!== undefined`.
4. Once M1 lands, L1 (stale `currentField`) goes away automatically.

The mathematical model is sound; the question is whether the business rules match. Get H1 answered before merging — the rest is mechanical cleanup.
