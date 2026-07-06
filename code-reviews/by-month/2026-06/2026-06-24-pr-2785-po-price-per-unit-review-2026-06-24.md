# Code Review: PR #2785 — update purchase order item price

**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `april-update/po-price-per-unit` → `development`
**Files changed:** 2 (+8 / -13)
**Reviewer:** code-reviewer skill (automated, independent re-review)
**Date:** 2026-06-24
**ClickUp ticket:** https://app.clickup.com/t/9018849685/86ey0m25b

## Summary

This PR is titled "update purchase order item price" and changes the formula behind the `pricePerUnit` field on the pharmacy purchase-order item row (the *write* path used while creating/editing a PO) and the helper text under the per-unit price column on the read-only PO detail page (the *read* path). The intent — based on the title and the new label `Inc(Tax/Dis/FOC)` — is to make `pricePerUnit` reflect not just tax but also discount and free-of-charge (FOC) quantities, and to surface that in the detail view.

The write-side change in `purchase-order-item-row.tsx:51-58` replaces the old tax-inclusive formula `(grossAmount + taxAmount) / qty` with `netAmount / qty`, and the trigger condition from "taxAmount > 0" to "netAmount ≠ grossAmount". The read-side change in `purchase-order-detail.tsx:165-173` updates the label condition from `pricePerUnit !== originalPricePerUnit && pricePerUnit !== null` to a three-way check `discountAmount || taxAmount || foc`, and updates the visible label string from `Inc(Tax)` to `Inc(Tax/Dis/FOC)`.

The change is small (8 net new lines, only UI files), but it touches **financial data**: the new `pricePerUnit` is what gets written into form state by the `useEffect` (line 63) and submitted with the PO payload. Three problems stand out — one is a correctness bug for FOC lines, one is a misleading label for the existing-data read path, and one is dead code left behind from the formula change. Nothing here is unsafe to merge as an emergency hotfix, but the change should not ship without (a) a fix to the FOC case and (b) a sanity check against historical PO data whose `pricePerUnit` was stored using the old formula.

## Verdict

**Request changes**

Score: 58/100
Critical: 0 | High: 2 | Medium: 3 | Low: 2 | Nit: 2

## Strengths

- **`purchase-order-detail.tsx:165-173` — the read-side label condition is genuinely more honest about what a non-`originalPricePerUnit` value can mean.** Showing "Inc(Tax)" when the actual divergence was caused by a discount or FOC was always a lie; showing nothing at all was worse. The new `discountAmount || taxAmount || foc` check fires whenever any of those is present, which is a real improvement.
- **`purchase-order-item-row.tsx:54` — using `netAmount` from the shared helper instead of re-deriving `grossAmount + taxAmount` removes a duplicated rounding step.** The `calculatePurchaseOrderLineNetAmount` helper at `src/app/(dashboard)/shared/pharmacy/utils/purchase-order-line-amounts.ts:40-74` is already the canonical computation; reusing it here is the right direction.
- **No new `console.log` / `console.error` / `@ts-ignore` / `any` introduced.** This is a small surgical change; it doesn't compound the noise that other recent PRs have left in `general-utils.ts` and the form components.
- **No DB schema or migration.** The `pricePerUnit` column type and meaning on the wire are unchanged. Existing rows can still be read.
- **Schema (`add-purchase-order-schema.ts:26`) still types `pricePerUnit` as `z.coerce.number().optional()`** — so the form-level contract is preserved. No breaking change to the server action signature.

## Issues

### Critical

- *(none)*

### High

- **`purchase-order-item-row.tsx:53-58` — for FOC lines, the new `pricePerUnit` is *lower* than `originalPricePerUnit`, but the visible label still says "Inc(Tax/Dis/FOC)". This is a financial correctness bug, not a cosmetic one.**
  `calculatePurchaseOrderLineNetAmount` (the shared helper) is:
  ```ts
  let netAmount = calTotalDependOnTaxAndDis(...);   // gross + tax − discount
  if (foc) {
    netAmount = netAmount - foc * originalPricePerUnit;
  }
  return Math.round(netAmount ?? 0);
  ```
  So for a line with `qty=10, originalPricePerUnit=100, foc=2, taxAmount=0, discountAmount=0`:
  - `grossAmount = round(100 * 10) = 1000`
  - `netAmount = round(1000 - 2 * 100) = 800`
  - `pricePerUnit = Number((800 / 10).toFixed(2)) = 80`
  - Stored to the form via `useEffect` at `:63`, submitted with the PO payload.
  "Inc(Tax/Dis/FOC) : 80" implies an *additive* tax/discount/FOC adjustment on top of the unit price, when in fact the unit price went *down* because two units are free. The label is mathematically backwards for FOC.
  **Fix options** (pick one, do not merge as-is):
  1. When `foc > 0`, do not display the "Inc(...)" label at all — the per-unit average is misleading.
  2. Compute `pricePerUnit` only from `(grossAmount + taxAmount − discountAmount) / qty`, separate from `netAmount` which also subtracts FOC. That keeps "Inc(Tax/Dis)" honest.
  3. Show the FOC effect as a separate line item, not folded into `pricePerUnit`.
  Evidence: `purchase-order-item-row.tsx:53-58` (new formula); `purchase-order-line-amounts.ts:69-71` (FOC subtraction); `purchase-order-line-amounts.ts:73` (rounding happens before division by qty).

- **`purchase-order-detail.tsx:165-173` — for POs created before this PR, `pricePerUnit` was stored as `(gross + tax) / qty`, but the new label says "Inc(Tax/Dis/FOC)" even when only tax was applied. The label over-promises for existing data.**
  Any PO created before this PR has `pricePerUnit = (originalPricePerUnit + taxAmount/qty)` rounded to 2dp (the old formula). When that PO is opened in the detail page, the new condition `item.discountAmount || item.taxAmount || item.foc` triggers whenever *any* of those is truthy. For a tax-only line with a stored `pricePerUnit ≠ originalPricePerUnit`, the UI will now render `Inc(Tax/Dis/FOC) : 12.50` when the stored value reflects tax only — a label that contradicts itself.
  **Two fixes are reasonable:**
  1. Migrate the existing data so `pricePerUnit` matches the new formula (or, better, store *both* `unitPriceExcl` and `unitPriceInclTax` and let the view choose — but that is a schema change, out of scope for this PR).
  2. Soften the label to `Inc(Tax/Dis)` for legacy rows (where the absence of discount/FOC is not guaranteed), or compute the label from the stored `pricePerUnit` vs. the components rather than from the components themselves.
  Evidence: `purchase-order-detail.tsx:167-172` (new label condition); old formula was `purchase-order-item-row.tsx:50-58` pre-PR, which did not include discount or FOC.

### Medium

- **`purchase-order-item-row.tsx:51` — `totalWithTax` is now dead code.** The variable is still computed (`const totalWithTax = grossAmount + currentField.taxAmount!;`) but no longer referenced after the formula change. The non-null assertion (`!`) was always a soft lie — `taxAmount` is optional in the schema (`add-purchase-order-schema.ts:32-35`) — but it survives as a runtime hazard: if a form path ever reaches line 51 with `taxAmount === undefined`, the addition evaluates to `NaN`, and the `useEffect` on line 60-65 writes `NaN` into `pricePerUnit`. The PR should delete the line; the new formula no longer needs `grossAmount + taxAmount` because `netAmount` already incorporates tax via `calTotalDependOnTaxAndDis`.
  Evidence: `purchase-order-item-row.tsx:51` — `const totalWithTax = grossAmount + currentField.taxAmount!;` (no remaining reads).

- **`purchase-order-item-row.tsx:54` — `netAmount !== grossAmount` as the trigger for "show the per-unit effective price" is not equivalent to "any of tax/discount/FOC is set". The two conditions in the PR are inconsistent.**
  Concretely: a line with `taxAmount=5, discountAmount=5` (and `foc=0`) produces `netAmount === grossAmount` (the +5 and −5 cancel), so `pricePerUnit = originalPricePerUnit` and the per-unit label is suppressed. But the read-side condition (`discountAmount || taxAmount || foc`) would happily render the label for the same row when read back from DB. This is an asymmetry between the live edit form and the detail view.
  Recommended trigger for the write-side: `taxAmount || discountAmount || foc` (matching the read-side), or `(taxAmount || discountAmount || foc) && qty > 0`.
  Evidence: `purchase-order-item-row.tsx:54` (`netAmount !== grossAmount`); `purchase-order-detail.tsx:168` (`item.discountAmount || item.taxAmount || item.foc`); `purchase-order-line-amounts.ts:18-30` (the +tax / −discount composition).

- **`purchase-order-item-row.tsx:53-58` — `pricePerUnit` is silently rewritten on every render via `useEffect`, even when the user has manually edited the value or when the row is `isDisabled`.**
  The `useEffect` dependency array (`[form.setValue, index, grossAmount, netAmount, pricePerUnit]`) re-runs whenever `pricePerUnit` changes, which writes back to the form state. For rows where the user has overridden the unit price (the input is editable at `:144-186`), the effective price is recomputed and silently overrides what the user typed — but only if `netAmount !== grossAmount`. This is a subtle UX bug: the user can type a new `originalPricePerUnit`, but the *displayed* per-unit line below the input will reflect the net, not the user's input. Pre-existing behavior of the `useEffect`, but the PR makes it more visible because the new `pricePerUnit` is now more often ≠ `originalPricePerUnit`.
  Evidence: `purchase-order-item-row.tsx:60-65` (the `useEffect`); `:144-186` (the editable price input).

### Low

- **`purchase-order-detail.tsx:166-172` — `item.pricePerUnit !== item.originalPricePerUnit && item.pricePerUnit !== null` was the *only* check for showing the "Inc(...)" line; the PR replaces it with a component check but loses the `pricePerUnit !== null` guard.**
  In the new code (`:168`), `item.pricePerUnit?.toLocaleString()` is used, which is fine for the display but the *condition* doesn't check that `pricePerUnit` is not null. If `pricePerUnit` is `null` (e.g., legacy row where the formula didn't run, or a migration artifact), the UI will render `Inc(Tax/Dis/FOC) : ` (with nothing after the colon) instead of suppressing the line.
  Recommended: combine both checks: `(item.discountAmount || item.taxAmount || item.foc) && item.pricePerUnit && item.pricePerUnit !== item.originalPricePerUnit`.
  Evidence: `purchase-order-detail.tsx:168-172` (new condition lacks the `pricePerUnit != null` check).

- **`purchase-order-item-row.tsx:54` — `Number((netAmount / currentField.qty).toFixed(2))` is fine for display but loses precision if the value is stored back as a `Prisma.Decimal`.**
  Prisma's `Decimal` type serializes to a string in JSON, and the schema here uses `z.coerce.number()` which will round-trip through `Number` (53-bit float). For MMK currency values that can have many digits in a single line item (drug pricing in Myanmar can go very high), this is a pre-existing concern, but the PR doubles down by computing the value client-side and submitting it. If the column is `Decimal`, the DB column will round on read. Out of scope to fix in this PR, but worth a follow-up: compute the value server-side from `qty`, `originalPricePerUnit`, and the component fields rather than re-storing a derived value.
  Evidence: `add-purchase-order-schema.ts:26` (`z.coerce.number().optional()`); `:50-51` (`grossAmount: z.number()`, `netAmount: z.number()`); `purchase-order-item-row.tsx:63` (writes the rounded value back).

### Nit

- **`purchase-order-item-row.tsx:187-193` — the live-edit label and the read-side label now use different casing for "Dis" (the row uses `currentField.discountAmount`; the detail page uses `item.discountAmount`). Both render as "Dis" in the label, but consider replacing the parenthetical slash notation (`Inc(Tax/Dis/FOC)`) with a clearer form — e.g. tooltip with the actual breakdown, or a small grid of the components. Eight-character tight labels don't scale.**
  Evidence: `purchase-order-item-row.tsx:190-192`; `purchase-order-detail.tsx:170`.

- **`purchase-order-detail.tsx:34-37` — `STOCK_TYPE_LABELS` is defined inside the file with a fallback to the raw `purchaseOrder?.stockType ?? ""` at `:119-123`. Pre-existing and not in this PR, but worth flagging while you're in this file: `purchaseOrder?.stockType ?? ""` will hit the fallback (returning `""`) for any stockType not in the map, then the `?? purchaseOrder?.stockType` rescues it. If `purchaseOrder.stockType` is the empty string from a missing enum, the result is also `""`. Not a bug introduced by this PR.**

## Scope creep / file placement

This PR is well-scoped: two UI files, no schema changes, no helper extraction, no log statements added. The scope is a feature change (the meaning of `pricePerUnit`), not a refactor. **Good.** No recommendation to split.

## Type safety & schema issues

- The schema (`add-purchase-order-schema.ts:26`) accepts `pricePerUnit` as an *optional* number, but the form now *always* populates it via `useEffect` (`:60-65`). If the server action treats `null`/`undefined` differently from a number (e.g., skips a column write), the PR's silent change means POs that used to write `null` for `pricePerUnit` (when `taxAmount` was 0 under the old trigger) now write a number. This may invalidate any downstream queries or reports that filter on `pricePerUnit IS NULL` — verify with the analytics/reporting team before merge.
- The `pricePerUnit`/`originalPricePerUnit` distinction is *derived data*: storing both is a denormalization. The PR cements the denormalization by writing `pricePerUnit` on every render. Future PRs that change the formula will need a data migration.

## Transaction & data integrity

No DB transactions in this PR. The form's `useEffect` writes to React state only; the actual DB write happens via the PO server action. Out of scope. **But** see the High issue about FOC — the *stored value* in new POs will be mathematically wrong for FOC lines.

## Performance

- One new derived value per row per render (`pricePerUnit`). Trivial.
- No new memoization opportunities introduced (and none removed).

## Accessibility & UX

- The visible label change is purely textual; no focus / keyboard / ARIA regression.
- The `Inc(Tax/Dis/FOC)` label is rendered in a `<span className="text-xs">` (`:187`) — same as before. No contrast / size regression.
- For FOC lines, the label *is* misleading (see High #1) — that is a UX bug, not an a11y one.

## Error handling

- No new error paths. The form already shows `netAmount` errors via `:329-337`. `pricePerUnit` is not user-editable (it's derived), so it has no error state.
- The `taxAmount!` non-null assertion on `:51` survives the refactor (now unused) — see Medium #1.

## Style & consistency

- The PR is consistent with the existing label style (`Inc(...)`).
- Variable naming: `totalWithTax` (now dead) vs. the canonical `grossAmount` / `netAmount` from the shared helper. Consistent rename would be to drop `totalWithTax`.
- `Number((... / ...).toFixed(2))` is the codebase's standard rounding pattern; the PR matches it.

## Questions for the author

1. **FOC semantics**: when an item has `foc > 0`, is `pricePerUnit` meant to represent "average cost per unit after free items are netted out", or "the listed per-unit price (unchanged by FOC)"? The old code never included FOC; the new code includes FOC as a *reduction*. Which one does the business want? This drives whether the High #1 fix should be "compute a separate `unitPriceEffective`" or "show no label for FOC".
2. **Data migration**: are there POs in production with stored `pricePerUnit` from the old formula? If yes, the read-side label will say "Inc(Tax/Dis/FOC)" for rows where only tax was applied. Is a re-computation job acceptable?
3. **Why was `netAmount !== grossAmount` chosen as the trigger condition** instead of `taxAmount || discountAmount || foc` (which is what the read-side uses)? See Medium #2.
4. **`useEffect` re-write loop**: when the user edits `originalPricePerUnit`, the input `onChange` recomputes `taxAmount` / `discountAmount` (`:151-174`), which changes `netAmount`, which changes `pricePerUnit`, which triggers the `useEffect`. Is there a risk of an infinite loop if the user types fast? In practice React batches, but worth confirming.
5. **Schema question**: should `pricePerUnit` be marked `derived` / `readonly` in some way? Storing derived values in DB columns is a known smell (ADR territory).

## Cross-references

- **`/Users/pyaesonewin/.claude/CLAUDE.md` §Rules** — "Validate input at system boundaries". The PR's `useEffect` writes `pricePerUnit` into form state without any Zod re-validation; the schema's `z.coerce.number()` will accept `NaN` (`coerce` accepts any number-coercible value, and `Number(NaN) = NaN`). Worth verifying that the server action rejects `NaN` / `Infinity`.
- **`hms-app/CLAUDE.md`** — Tread carefully with migrations. **This PR does not introduce a migration, but its behavior change is equivalent to one for the `pricePerUnit` column's semantic content.** File a follow-up issue for the historical-data question.
- **PR #2780** — the team has recently cleaned up `doAgeRangesOverlap` semantics; this PR is *not* in that family, but the same pattern of "helper returns a derived value" applies: the PR cements a derived column into the form state, which makes future formula changes a migration.
- **`hms-docs/summary-service/`** — not relevant (this is hms-app UI code, no outbox / HMAC / tenant-scope concerns).

## Verification needed

Things that cannot be verified from the diff alone:

1. **Does the new `pricePerUnit` produce the right value for an FOC-only line?** Manual test: create a PO with qty=10, originalPricePerUnit=100, taxAmount=0, discountAmount=0, foc=2. Expect either (a) `pricePerUnit = 100` (FOC ignored) or (b) `pricePerUnit = 80` (FOC averaged in). The PR produces (b) but the label says "Inc(...)" — the High #1 bug.
2. **What does the detail page show for a legacy PO with tax-only?** Open any PO created before this PR with `taxAmount > 0` and `discountAmount = foc = 0`. Does the UI render `Inc(Tax/Dis/FOC)` even though the stored value reflects tax only?
3. **Does the `useEffect` loop fire when `originalPricePerUnit` is edited rapidly?** Open the form, type into the unit-price input, observe whether `pricePerUnit` recomputes and the "Inc(...)" label updates smoothly. (Pre-existing behavior, but worth re-checking.)
4. **Is there a downstream report that filters on `pricePerUnit IS NULL`?** See Question 2 — if yes, the PR silently changes the answer.
5. **Does the `taxAmount!` non-null assertion crash on any path?** The PR leaves it at `:51`; the dead-code path means `totalWithTax` is still computed, so `NaN` is possible if `taxAmount === undefined`. Even though the variable is unused, the computation runs. Confirm `strictNullChecks` doesn't flag this.
6. **SonarQube Cloud analysis.** The PR has the same `❌ The last analysis has failed.` marker as PR #2780. Confirm with infra whether this is a known transient. The `taxAmount!` non-null assertion and the dead `totalWithTax` are likely linter hits.

## Checklist results

- [ ] `console.log` / `console.error` in production — None added by this PR.
- [x] `any` type annotations — None added.
- [x] `@ts-ignore` / `@ts-expect-error` / `eslint-disable` — None added.
- [x] TODO / FIXME — None added.
- [x] Hardcoded secrets — None.
- [x] SQL/Prisma injection — N/A (no DB queries in this PR).
- [x] Long files (>500 lines) — `purchase-order-detail.tsx` is 250 lines, `purchase-order-item-row.tsx` is 353 lines. Both within limits.
- [x] God components — These files were already the dedicated PO row/detail components; the PR doesn't grow them into godhood.
- [x] Missing `key` props, index-as-key — N/A (no list rendering in the diff).
- [ ] Unsafe type assertions — `purchase-order-item-row.tsx:51` — `currentField.taxAmount!` survives the refactor on a now-unused expression. Remove the line.
- [x] Async error swallowing — N/A.
- [x] Missing `await` inside transactions — N/A.
- [x] Tenant-scope — N/A.
- [x] Permission checks — N/A (UI-only PR).
- [x] Missing Zod validation at boundary — The derived value is not Zod-validated before submission; the schema's `z.coerce.number()` will accept `NaN`/`Infinity`. Pre-existing concern, but the PR makes it more impactful.
- [x] React Query correctness — N/A (no React Query in the diff).

## Recommendation

Block merge. The **High** FOC bug means new POs with free-of-charge items will be stored with a `pricePerUnit` that contradicts its own label. Either fix the label for FOC lines (preferred — minimal diff) or fix the formula. The **High** historical-data label mismatch should be addressed by either softening the label for legacy rows or filing a one-shot data migration. The **Medium** issues (`totalWithTax` dead code, `netAmount !== grossAmount` vs. `taxAmount || discountAmount || foc` asymmetry, `useEffect` overwriting user input) are quick wins that should land with the same PR.

Once the two Highs and the dead-code Medium are fixed, the change is small enough to approve without further splitting. No helper extraction, no scope creep — just a formula + label change with a couple of bugs to chase.
