# Code Review: PR #2905 — DIsplay Tax in Pharmacy Sale
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `fix/april/sprint27/pharmacy-sale-tax-display` → `development`
**Files changed:** 4 (+71 / -37)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-08
**ClickUp:** https://app.clickup.com/t/9018849685/86ey5vudn

## Summary
Hides the Tax column in pharmacy sale, pharmacy sale details, sale-return form, and sale-return detail screens when the effective tax amount is zero — letting tenants with tax disabled by default not see empty Tax rows, while still showing Tax when there's an actual amount. Mirrors an existing pattern from `pharmacy-sale-ipd-detail.tsx`: read `displayTaxField` from `DefaultSetting.settings`, plus a derived `hasTax` flag, and render the column only if either is true. Also incidentally fixes a hardcoded `0` for Discount in `sale-return-detail.tsx` (now bound to `saleReturn.discountAmount`).

## Verdict
**Approve with suggestions**
Score: 88/100
Critical: 0 | High: 0 | Medium: 1 | Low: 1 | Nit: 2

## Issues

### Critical
None

### High
None

### Medium

1. **`hasTax` boolean is computed incorrectly in two files** — `pharmacy-sale-form.tsx:306` and `sale-details.tsx:66` use `pharmacySale?.taxAmount && pharmacySale.taxAmount > 0`. When `taxAmount` is exactly `0`, the first clause short-circuits to `0` (falsy), so `displayTax` falls back to `displayTaxField` and may force the Tax column to render even when the rule says "hide when zero." The canonical pattern already in the codebase (`pharmacy-sale-ipd-detail.tsx:37`) writes `(pharmacySale?.taxAmount || 0) > 0`, which handles `0` correctly. Fix:
   ```ts
   const hasTax = (pharmacySale?.taxAmount ?? 0) > 0;
   ```
   File(s): `pharmacy-sale-form.tsx`, `sale-details.tsx`, `sale-return-detail.tsx`, `sale-return-form.tsx`.

### Low

2. **`sale-return-detail.tsx` quietly changes Discount behavior, but the PR title only mentions tax.** The pre-patch code hardcoded `<Text c="black" size="md">0</Text>` for the Discount cell. The patch binds it to `saleReturn?.discountAmount?.toLocaleString() || "0"`, which is almost certainly the right fix but is an unrelated, undocumented behavioral change. Either split into a separate commit, or note it in the PR description so reviewers know to validate Discount values in QA.

### Low / Nit

3. **`sale-return-form.tsx:91` derives `hasTax` from `sale.taxAmount` (the source `sale`) but the rendered value comes from `totalTaxAmount` (sum of return items).** If the source sale has zero tax but the return somehow accumulates one (e.g., per-item tax rounding), the column won't render. Likely intentional (matches the source sale's tax posture), but worth confirming. Nit.

4. **Pattern repetition (acknowledged, not a blocker).** `useQuery(makeFetchDefaultSettingQuery()) + destructure displayTaxField + hasTax + displayTax` now appears across 6 components (the 2 new + `pharmacy-sale-ipd-detail`, both `pharmacy-transfer-detail` files, both `pharmacy-transfer-form` files). A `useDisplayTax(taxAmount)` hook would compress each call site to a line. Flagging as Nit because extracting prematurely across 6 sites before the abstraction is well-formed is a `YAGNI` trap — leave as-is until the third or fourth true duplicate appears with identical semantics.

## Recommendation
- Apply the one-line fix for `hasTax` across all 4 touched files: change `pharmacySale?.taxAmount && pharmacySale.taxAmount > 0` to `(pharmacySale?.taxAmount ?? 0) > 0` (and the `sale.` / `saleReturn.` equivalents).
- Update the PR description to call out the Discount hardcoded-`0` → bound-to-field change in `sale-return-detail.tsx`, or split it into a separate commit.
- No other blockers. Ponytail pass: lean — the change mirrors an established codebase pattern (`pharmacy-sale-ipd-detail.tsx:39`) and introduces no speculative abstractions.
