# Code Review: PR #2910 — Add searchable dropdown for Special Lab Test selection in Add Lab Group form
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-27/lab-group-86ey614ac` → `development`
**Files changed:** 7 (+299 / -69)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-08
**ClickUp:** https://app.clickup.com/t/9018849685/86ey614ac

## Summary
Replaces the static `<Select>` for both Lab Test and Special Lab Test in the Add Lab Group form with a server-backed infinite-scroll searchable dropdown. Two new wrapper components (`LabTestSearchSelect`, `SpecialLabTestSearchSelect`) wrap the existing generic `SearchSelect` and reuse the new `useEntitySearchInfinite` hook pattern that already powers service/patient/doctor selects. On the server side, three repositories (lab-test, lab-group, special-lab-test) now apply `sortEntitiesBySearch` over the result set so that exact-prefix matches float to the top, and `lab-test.repository.ts` switches the search match mode from `contains` to `startsWith`. Form wiring: `labTestOpts()` is deleted in favour of the new component's `initialLabTest` prop, and the per-row `excludeIds`/`initialItem` props handle the "exclude already-selected-in-other-rows" + "show current edit selection" cases.

## Verdict
**Request changes**
Score: 55/100
Critical: 1 | High: 1 | Medium: 2 | Low: 5 | Nit: 4

## Issues

### Critical
1. **`query.limit > 0 * 10` operator-precedence typo makes the new server-side ranking a no-op.** This expression appears in three places — `src/app/(dashboard)/shared/lab/repositories/lab-test.repository.ts:71`, `lab-group.repository.ts:88`, and `special-lab-test.repository.ts:63`. JavaScript evaluates the `* 10` first (multiplication binds tighter than `>`), so `query.limit > 0 * 10` is identical to `query.limit > 0`. The intent was almost certainly `(query.limit * 10)` so the repository fetches a 10× buffer that `sortEntitiesBySearch` can re-rank and `slice(0, query.limit)` can trim. As shipped, the `take:` value is the same as before, the `sortEntitiesBySearch(...).slice(0, query.limit)` step does nothing useful, and the new ranking code is dead weight in two of the three files. Fix: `(query.limit * 10)` in all three, and confirm the resulting `slice(0, query.limit)` makes sense for callers passing `limit > 0` (e.g. the special-lab-test table export uses `limit: 0`, which is fine). Ponytail: this is one operator-precedence fix in three files; the rest of the ranking logic can stay as-is.

### High
1. **Inconsistent search semantics between the two dropdowns.** `lab-test.repository.ts` changed `service.name` matching from `contains` to `startsWith` (and the new ranking relies on prefix match for tie-breaking), but `special-lab-test.repository.ts` was left at `contains`. A user typing "CBC" in the Lab Test dropdown will see only "CBC*" results, while in the Special Lab Test dropdown the same query still matches anywhere in the name. Either commit both to `startsWith` (consistent + supports the ranking intent) or leave both at `contains` — don't ship a one-sided change.

### Medium
1. **Leftover dead code in `lab-test-mapping-form.tsx`.** The diff comments out `useQuery(makeGetLabTest(...))` and the `labTestOpts()` helper, but `useQuery(makeFetchSpecialLabTestsQuery({ page: 1, limit: 0, offset: 0 }))` is still kept only to do `specialLabTest?.result.specialLabTests.find((item) => item.id === field.value)` per row for `initialItem`. That call fetches every Special Lab Test in the database on every form mount, on every form re-render of every row, just to resolve an id → object lookup that the new search-select already does internally. Delete the special-lab-test bulk query and compute `initialItem` from the existing per-row `specialLabTestQueries[dataIndex]?.data` (the same by-id query that already powers the Lab Unit display), or drop `initialItem` entirely and rely on the SearchSelect's own `keepSelectedItem` behaviour.

2. **Zero tests for the new surface area.** PR adds two new components (`LabTestSearchSelect`, `SpecialLabTestSearchSelect`), two new hooks (`useLabTestSearchInfinite`, `useSpecialLabTestSearchInfinite`), and three modified repositories — none of it has unit-test coverage. The repo has a working `__tests__` folder and existing testing patterns for service/repo code. The pure `sortEntitiesBySearch` ranking call in particular is a one-liner test target. Ponytail: at minimum, add one Jest test for each repository's `getLabTests` / `findLabGroupMappings` / `findSpecialLabTestAndCount` covering the `sortEntitiesBySearch` reordering and the `take:` precedence fix.

### Low / Nit
1. **`nothingFoundMessage="No services found"` copy-pasted in both new search-selects.** `lab-test-search-select.tsx:62` and `special-lab-test-search-select.tsx:88` both say "No services found" even though one is for lab tests and one for special lab tests. Use the entity name (compare `service-search-select.tsx`, `doctor-search-select.tsx`, `patient-search-select.tsx` which all use the correct message).
2. **`getItemsWithInitial` / `getItemsWithFilterAndInitial` are recreated on every render.** Both wrappers rebuild these `getItems` functions inline. The parent `SearchSelect`'s `useMemo([data, getItems])` invalidates on every render and recomputes `allItems`, which defeats `useMemo` for the heavier `data?.pages.flatMap(...)` work. Wrap with `useCallback` keyed on the inputs you actually use (`initialItem`, `excludeIds`).
3. **PR title undersells scope.** "Add searchable dropdown for Special Lab Test selection" — the PR also changes lab-test search semantics (`contains` → `startsWith`), adds server-side ranking in three repositories, and a `useState` for the lab-test search string. Mention the lab-test side and the repo changes in the title.
4. **Per-row `currentSpecialLabTest` lookup is O(rows × allSpecialLabTests).** `specialLabTest?.result.specialLabTests.find(...)` runs inside the `fields.map` for every row on every render. The list might be small today but this is the leftover from the bulk-fetch that should be deleted per Medium #1.
5. **`status: "ACTIVE"` is hard-coded in `getLabTestQueryParams()`** and threaded into the new `LabTestSearchSelect` `query` prop — fine for the form's intent but worth a comment in the diff context that this means inactive lab tests cannot be added to a new mapping (and that the existing edit-mode behaviour relies on `includeLabTestId` showing the current one).

## Recommendation
1. Fix the `query.limit > 0 * 10` typo to `(query.limit * 10)` in all three repository files (Critical #1).
2. Decide on one search semantics — `startsWith` in both `lab-test.repository.ts` and `special-lab-test.repository.ts` — and apply it consistently (High #1).
3. Delete the leftover `useQuery(makeFetchSpecialLabTestsQuery({ page: 1, limit: 0, offset: 0 }))` call and the `currentSpecialLabTest` lookup; pull `initialItem` from the existing by-id query result, or rely on the SearchSelect's own `keepSelectedItem` (Medium #1).
4. Add at least Jest tests for the three repository ranking changes so the `* 10` buffer doesn't regress (Medium #2).
5. Fix the "No services found" copy-paste, wrap `getItems` callbacks in `useCallback`, and reconsider the PR title to reflect the lab-test and server-side scope.

Score: 100 − (1 × 15) − (1 × 8) − (2 × 4) − (5 × 2) − (4 × 1) = 100 − 15 − 8 − 8 − 10 − 4 = 55.