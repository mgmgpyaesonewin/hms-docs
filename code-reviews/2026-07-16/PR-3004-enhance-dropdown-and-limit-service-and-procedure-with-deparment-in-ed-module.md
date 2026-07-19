# Code Review: PR #3004 — Enhance dropdown and limit service and procedure with deparment in ed module
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-28/ed-86ey55715-86ey3pfr1` → `development`
**Files changed:** 4 (+45 / -59)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-16
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3pfr1, https://app.clickup.com/t/9018849685/86ey55715

## Summary
Mirrors PR #3000 (HD module) onto the ED module. Swaps the bespoke Mantine `Select` + `useQuery` + `useMemo`-options trios in `ed-billing-pharmacy-sales.tsx` and `ed-billing-services.tsx` for the shared `ItemSearchSelect` / `ServiceSearchSelect` (which use the infinite-scroll search infrastructure already used by cathlab/OPD). Wires `moduleDepartment={DepartmentEnum.ED}` through `ed-billing-procedures.tsx` so the procedure search hits the shared department filter (`buildModuleDepartmentNameFilter`). Adds a duplicate-item toast guard in the pharmacy-sales handler (mirrors the existing duplicate-service guard). Registers `ED → "Emergency Department"` in `MODULE_DEPARTMENT_MAPPING` so the ED module gets filtered services/procedures and shows up in the user-management department filter.

Net diff is negative (-14 lines) because the bespoke per-component data-fetch + label-mapping code is replaced by the shared components.

## Verdict
**Approve with suggestions**
Score: 82/100
Critical: 0 | High: 0 | Medium: 1 | Low: 2 | Nit: 3

## Issues

### Critical
None.

### High
None.

### Medium

1. **Duplicate-item check uses string equality, but the lookup uses an untyped cast — verify parity with the service-side guard** — `src/app/(dashboard)/ed/features/components/ed-billing-pharmacy-sales.tsx:133-141` (post-PR). The new guard compares `i.pharmacySaleItemId === curr.id` which is fine, but the surrounding code casts the inner item (`curr`) through the `Item` type the new shared select passes via `onItemSelect`. After removing `data?.items.find(...)` lookup, the handler now trusts the shared component to deliver a real `Item`. Good simplification, but worth confirming end-to-end: open the ED billing form on a slow network, pick an item, then immediately try to re-pick the same item — does the toast fire correctly? The HD-style `keepSelectedItem` path doesn't apply here (no edit mode), so this should be a one-shot.

### Low / Nit

2. **`MODULE_DEPARTMENT_MAPPING` shows up in user-management department filter — confirm `ED` is the right enum there too** — `src/app/(dashboard)/common/user-management/departments/features/const/index.ts:10`. Same caution as PR #3000 issue #5. `DepartmentEnum.ED` is the right value for the clinical ED module (confirmed: `ed-bill.repository.ts:142,261,375,830` and `ed-bill.service.ts:85,163` all use `DepartmentEnum.ED`, and `proxy-bill.schema.ts:24,365` defaults to it). The mapping constant drives both the user-management department dropdown and `buildModuleDepartmentNameFilter`, so adding `ED` here is consistent — but verify the user-management screen isn't now showing a new "Emergency Department" entry that conflicts with existing seed data.

3. **Option-label punctuation changes silently** — `ed-billing-pharmacy-sales.tsx` previously labeled items as `${name} (${itemId}) - ${generic}`; the new `ItemSearchSelect` default label is `${name} - ${category?.name ?? ""} - ${unit?.abbreviation ?? ""}`. So an ED user searching for a drug now sees the category and unit in the dropdown instead of the generic name. This is a UX regression for the ED module specifically — the old `generic` (drug-class) text was the identifying field for clinical staff. Same for services: old label `${serviceId} ${name} - ${category.name ?? "Uncategorized"}` vs new `${serviceId} ${name} – ${category.name ?? "Uncategorized"}` (en-dash instead of hyphen; minor). Pass a `getOptionLabel` override to restore the drug-generic display, or accept the new label as an intentional improvement.

4. **PR title typo: "deparment"** — Same typo as PR #3000. Not blocking, but please fix to "department" for searchability and consistency.

5. **No `ed-billing-pharmacy-sales.tsx` for duplicate-of-batch rows** — The new duplicate guard short-circuits before the `prepend`, so the user sees the toast but the existing row stays. That's the correct UX. Just noting: when the user clicks a duplicate item, the search input isn't cleared before the guard runs — actually it IS (`setSearchedItem("")` runs at line ~131 before the guard at line ~134). Good. No issue.

## Recommendation
- **Should fix before merge:** Issue #3 — pass an explicit `getOptionLabel` to `ItemSearchSelect` that keeps `generic` (drug-class) visible, since that's what clinical staff use to identify items quickly. One-line override.
- **Nice to have:** Issue #2 — sanity-check the user-management department filter doesn't show a duplicate after this change.
- **Nit:** Issue #4 — fix the title typo.

This is the structural twin of PR #3000 (HD module), which was approved-with-changes after addressing a copy-paste bug and dead-code blocks. PR #3004 doesn't carry those problems — the diff cleanly removes the old `useDebouncedValue` calls, deletes the bespoke `data?.items.find` lookup, and removes the `Loader` imports. The new shared `ServiceSearchSelect` / `ItemSearchSelect` handle debouncing, loading state, and infinite-scroll pagination internally, which is the right consolidation.

Ponytail review: net -14 lines, no new abstractions, no new dependencies, no interfaces with one implementation, no config for values that never change. This is the lazy version of the change. Ship once issue #3 is addressed.

**Net line potential after fixes:** passing a `getOptionLabel` to restore the drug-generic display adds ~5 lines but is a real UX improvement. Everything else is a deletion-or-neutral change.