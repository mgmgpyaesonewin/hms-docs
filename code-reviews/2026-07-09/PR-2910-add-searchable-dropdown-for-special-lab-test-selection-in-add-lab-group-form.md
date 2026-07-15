# Code Review: PR #2910 — Add searchable dropdown for Special Lab Test selection in Add Lab Group form
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-27/lab-group-86ey614ac` → `development`
**Files changed:** 7 (+313 / -70)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-09
**ClickUp:** https://app.clickup.com/t/9018849685/86ey614ac

## Summary
Replaces the static paginated `<Select>` for Lab Test and Special Lab Test in the Add/Edit Lab Group form with two new reusable `*SearchSelect` wrappers that drive an infinite-scroll search hook (`useEntitySearchInfinite`). Backend repositories are rewritten to over-fetch (`take = limit * 10`) and rank results client-side via a new `sortEntitiesBySearch` utility, so prefix-matching gets promoted to the top while substring matches still surface as a fallback. The repositories also flip `contains` → `startsWith` on the DB side to feed the ranking pipeline.

## Verdict
**Request changes**
Score: 68/100
Critical: 0 | High: 1 | Medium: 4 | Low: 3 | Nit: 2

## Issues

### Critical
None

### High

**H1. `contains` → `startsWith` is a silent behaviour regression on the lab-test / special-lab-test list endpoints.**
Files: `src/app/(dashboard)/shared/lab/repositories/lab-test.repository.ts:143`, `src/app/(dashboard)/shared/lab/repositories/special-lab-test.repository.ts:47`.

Both `buildWhereQuery` switched from `contains` to `startsWith` on the search term. The ranking wrapper treats prefix hits as rank 0 and substring hits as a lower rank, but it only sees whatever the server returns. Substring matches that fall outside the leading-prefix slice are now never returned to non-search-select callers (the lab-test listing page, the special-lab-test listing page, etc., wherever these repositories feed the standard table view). Users who used to type "CBC" or any keyword and find rows containing it elsewhere in the name will now get an empty result list when the term is not at the start.

Either:
- Keep the DB match as `contains` and rely on client ranking for ordering, OR
- If prefix-only ranking is genuinely desired, gate `startsWith` behind the new search-select components (e.g., a `rankedSearch?: boolean` flag on the query schema) so list pages keep `contains`.

This needs a deliberate decision before merging.

### Medium

**M1. Dead/commented code left in `lab-test-mapping-form.tsx`.**
File: `src/app/(dashboard)/lab/lab-test-mapping/features/components/lab-test-mapping-form.tsx`.

The PR comments out the `useQuery(makeGetLabTest(...))` block, the entire `labTestOpts()` function, AND keeps the `import { makeGetLabTest }` as a commented line. The `useQuery(makeFetchSpecialLabTestsQuery(...))` on the next block is dropped to just `const { data: specialLabTest } = useQuery(...)` (no `isLoading`) and only the `specialLabTest` result is used (to look up `currentSpecialLabTest` for the `initialItem` prop). None of the old `getSpecialLabTestData` / `getSpecialLabTestLoadingState` consumers remain. All of this dead code should be deleted, not commented out — also drop the now-unused `Loader`, `useQueries`, `makeFetchSpecialLabTestingById`, `makeFetchSpecialLabTestsQuery`, and `useQuery` imports where they are no longer referenced.

**M2. `excludeIds` filter logic is correct but unreadable.**
File: `src/components/search-bar-select-with-infinite-scroll/special-lab-test-search-select.tsx:68-72`.

```ts
const filteredItems = items.filter(
  (item) => !excludeIds?.includes(item.id) || item.id === initialItem?.id,
);
```

The clause relies on truthy short-circuit (`excludeIds?.includes` is `undefined` when excludeIds is undefined) to express "keep items unless excluded, but always keep the initial item". It works, but the next reader will reach for a debugger. Rewrite as:
```ts
const filteredItems = items.filter((item) => {
  if (excludeIds?.includes(item.id) && item.id !== initialItem?.id) return false;
  return true;
});
```

**M3. `take: query.limit * 10` is a magic multiplier without a name.**
Files: `lab-test.repository.ts:71`, `lab-group.repository.ts:88`, `special-lab-test.repository.ts:63`.

Each repository multiplies the requested limit by 10 and then the client slices back to `query.limit`. There's no comment explaining the budget (which implies an unstated assumption that fewer than ~10% of rows are substring fallbacks to the prefix match). Lift to a named constant — e.g. `const SEARCH_OVERFETCH_MULTIPLIER = 10` — and add a one-line `// ponytail: over-fetch by N so substring fallbacks land within the page; revisit if ranking drops precision`. A comment helps reviewers see this is deliberate, not arbitrary.

**M4. `getLabTestQueryParams()` rebuilds the params object on every render.**
File: `lab-test-mapping-form.tsx:83-107`.

The function returns a fresh object literal each call, and it is invoked inside the render: `query={getLabTestQueryParams()}`. `useEntitySearchInfinite` memoises `filters` with `useMemo(() => filters, [filters])`, so the new object identity re-keys the React Query cache on every render — wasted refetches and wasted RQ churn. Memo the result with `useMemo` over `[isEdit, labGroup?.id]`, or inline the call. (Sub-issue, but pairs with the over-fetch multiplier above.)

### Low / Nit

**L1. Wrong `nothingFoundMessage` copy on both new wrappers.**
Files: `lab-test-search-select.tsx:64`, `special-lab-test-search-select.tsx:91`. Both hardcode `"No services found"`. Other variants in `search-bar-select-with-infinite-scroll/` use entity-specific text (`"No items found"`, `"No doctors found"`, `"No clinics found"`). Use `"No lab tests found"` and `"No special lab tests found"`.

**L2. `searchValue` / `onSearchChange` are not part of the typed props.**
`LabTestSearchSelectProps` extends `SearchSelectProps` minus a fixed list, but `searchValue`/`onSearchChange` are not in the omit list, so they pass through via spread. That works, but the type signature implies these props aren't accepted — they are. Either add them to the interface explicitly so callers know, or rely on the consumer having seen the SearchSelect signature. Both wrappers should be consistent here (only `LabTestSearchSelect` accepts search-state; `SpecialLabTestSearchSelect` doesn't because the form doesn't manage its own `searchValue` for special-lab-test — intentional asymmetry, worth a comment).

**L3. Per-row `useQueries(makeFetchSpecialLabTestingById)` keeps firing even though the new wrapper already returns the picked entity.**
The form still runs N by-id queries on every render of `specialLabTests` to populate the disabled `Lab Unit` TextInput. With `onItemSelect`/`keepSelectedItem` available on the wrapper, the chosen entity is sitting right there in component state. Hook `onItemSelect` and cache `labUnit.name` by row index, drop the `useQueries` block. Not introduced by this PR, but the PR removes the only piece that looked load-bearing and leaves the by-id fetch as the actual source of `labUnit.name`.

**N1. Identical `onLabTestSelect` prop name on the `SpecialLabTestSearchSelect` for an entity that's not a lab test.**
File: `special-lab-test-search-select.tsx:31`. The prop is named `onLabTestSelect?: (specialLabTest: SpecialLabTest) => void` — should be `onSpecialLabTestSelect` (the type and value are correct, the name is wrong). Signature confusion at the call-site.

**N2. Repeated `displayName` per wrapper.**
Same as every sibling in the folder — not bad, just noise. Keep.

## Recommendation
1. Address H1: decide whether list pages should keep `contains` matching, and ship the change as a flag (`rankedSearch: boolean`) on the query schema rather than a silent regression. Re-test the lab-test listing and special-lab-test listing endpoints with a mid-string keyword.
2. M1 + L3: clean up `lab-test-mapping-form.tsx` — delete the commented code AND the now-unused imports (`Loader`, `useQueries`, `makeFetchSpecialLabTestsQuery`, `makeFetchSpecialLabTestingById`, `useQuery` if no longer needed, the entire `getSpecialLabTestData`/`getSpecialLabTestLoadingState` machinery, the `isLabTestLoading`/`isSpecialLabTestLoading` references).
3. M4: memo the `getLabTestQueryParams()` result.
4. M2/L1/N1: tidy up while you're in there — `excludeIds` logic, copy, prop name.
5. M3: name the over-fetch multiplier.

Once H1 is resolved and dead code is removed, this is a clean, conventional addition to an already-clear pattern (matches `ServiceSearchSelect`, `DoctorSearchSelect`, etc.).
