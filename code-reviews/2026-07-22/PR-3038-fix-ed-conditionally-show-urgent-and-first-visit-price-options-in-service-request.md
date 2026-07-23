# Code Review: PR #3038 — fix(ed): conditionally show urgent and first-visit price options in service request
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `issue/ppz/sprint-29/ed-module-86ey9ranw` → `development`
**Files changed:** 1 (+38 / -20)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86ey9ranw

## Summary
ED service-request billing form now conditionally includes price-type options based on whether the corresponding price field on the service is set (truthy / > 0), and preserves the currently-selected price type even if its underlying price is missing. Two new legacy price types (`referredPrice`, `reportingPrice`) are supported and shown when present or currently selected. Replaces an empty-JSON-object check with a "has any price > 0" check.

## Verdict
**Request changes**
Score: 71/100
Critical: 1 | High: 0 | Medium: 2 | Low: 1 | Nit: 0

## Issues

### Critical

1. **Debug `console.log` statements left in production code** (`ed-billing-services.tsx`, lines ~381–384 in the new `priceTypeOptions` useMemo). Four `console.log` calls (`servicePrice`, `urgentPrice`, `referredPrice`, `reportingPrice`) were clearly added to investigate the bug and never removed. These leak internal price values into the browser console in production and will appear in any user's DevTools. Remove all four before merge.

### High

None.

### Medium

1. **Behavior change: "First-Visit" option behavior is now asymmetric with "Urgent"** (`ed-billing-services.tsx`, in the new `priceTypeOptions` useMemo). In the old code, when `hasDoctorMapping` was true the options were a fixed list including `firstRoundPrice` regardless of whether `service.firstRoundPrice` had a value; when `hasDoctorMapping` was false, `firstRoundPrice` was never offered. In the new code, `firstRoundPrice` is only included when `hasDoctorMapping` is true (correct), but `urgentPrice` is now filtered by `hasPrice` in both branches — meaning a doctor-mapped service with a missing `urgentPrice` will no longer show "Urgent". If the legacy code intended "Urgent" to always be selectable when there is a doctor mapping, this is a regression. Confirm with product and either (a) keep the old `MAPPED_PRICE_TYPE_OPTIONS` list intact for the doctor-mapped branch, or (b) intentionally document why `urgentPrice` is now filtered even when mapped.

2. **`hasPrice` semantics changed from "empty JSON object" to "any value > 0"** (`ed-billing-services.tsx`, `hasPrice` helper). The old `isEmptyPriceJson` treated `{}` as "empty/available" (i.e., show the option) and `null`/missing as "not available". The new `hasPrice` requires `Number(price) > 0`. Services with `{ "amount": 0 }` or `{ "currency": "MMK", "amount": 0 }` will now hide options that the old code would have shown. If any seeded ED services have price objects with a zero amount (rather than null), this change silently removes their selectable price types in the UI. Verify against the data model in `hms-docs/` and the ED service seed/migration.

### Low / Nit

1. **Ponytail shrink: array literals duplicated between the two branches** (in the new `priceTypeOptions` useMemo). The core option list `[{label:"Normal",value:"servicePrice"},{label:"Urgent",value:"urgentPrice"}]` and the legacy spread `...legacyOpts` are built in both the `hasDoctorMapping` and the fallback branch. Extract a single `coreOpts` const before the `if (hasDoctorMapping)` so the two branches only differ in the `firstRoundPrice` inclusion. Net: ~4 fewer lines, easier to read.

## Recommendation
1. Remove the four `console.log` debug statements (Critical, blocks merge).
2. Decide intentionally whether "Urgent" should remain always-available in the doctor-mapped branch — restore the previous behavior or document the change with product.
3. Verify `hasPrice` against real seed data: confirm no ED service has a price object with `amount: 0` that would now be silently hidden.
4. (Optional) De-duplicate the core option list between the two branches per the Low finding.