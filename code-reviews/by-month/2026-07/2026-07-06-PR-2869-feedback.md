# PR #2869 — Cathlab / daycare: add infinite-scroll search selects

**Repo:** MyanCare/Ycare-HMS · **PR:** https://github.com/MyanCare/Ycare-HMS/pull/2869
**Branch:** `feat/ppz/sprint-26/cathlab-86ey3pg5q` → `development` · **Author:** Pyae41
**Diff:** 21 files · +1,303 / -285 · **ClickUp:** 9018849685/86ey3pg5q
**Verdict:** Changes requested (3 blocking, 6 important, 7 nit)

> A prior draft existed at this path. It has been discarded. This document is the synthesized review of the current diff and supersedes the earlier draft.

## Summary

The PR adds an infinite-scroll search-select primitive and applies it to the cathlab pharmacy-sale, cathlab procedures, cathlab services, IPD patient-selection, and IPD-EMR standard-service-request forms. The work touches 4 cathlab/IPD components, the daycare features directory (8 new files for the new primitive + its hooks), 4 repository files (re-using a new `sortEntitiesBySearch` helper), and `general-utils.ts` (the helper itself).

The primitive design (one generic `SearchSelect<T,D,F>` over `useInfiniteQuery` + Mantine `Select` + scroll-area bottom detection) is right and worth landing. What blocks the merge is mostly the surrounding noise:

- ~250 lines of commented-out dead code left in production files (the previous implementation, swapped out for the new primitive but not deleted).
- A debug `console.log("Service Data", data)` left in `service-search-select.tsx`.
- A self-debt comment `// TODO: comment out when inifinite is not working` and the matching 60-line commented-out `<Select>` block in `cathlab-pharmacy-sale.tsx`.
- An out-of-scope `startsWith` → `contains` change on `items.itemId` filtering that will change search-by-exact-id semantics for every caller of `ItemsRepository.findItems`.
- The 6 entity-specific `useXxxSearchInfinite` hooks are 6 near-identical copies of the same `useInfiniteQuery` config — one generic `useEntitySearchInfinite<T>` collapses them.
- A `keepSelectedItem` feature on `SearchSelect` that re-derives the selected option from a ref + a synthetic option, which (a) reintroduces options the user just filtered out of view, (b) does not honour the user's "empty the search" intent.

The repository / schema additions are clean and correct.

## Strengths

- The `SearchSelect` primitive is the right shape: one generic, well-typed (`<T,D,F>`), forwards Mantine `SelectProps`, owns the infinite-scroll wiring via the scroll-area viewport ref + `onScrollPositionChange`. The `_loader_` sentinel option pattern for "Loading more…" rows is a workable substitute for a Mantine `Combobox.Option`-style footer.
- `useDebouncedValue(..., 1000)` moves into the hook itself, which removes a per-call-site mistake and shortens every consumer.
- `sortEntitiesBySearch` in `general-utils.ts` is a clean two-rank heuristic (name prefix match → id prefix match → everything else) and is small enough to keep.
- Threading `referralInOut={DoctorType.IN_SERVICE}` through `DoctorSearchSelect` instead of pre-filtering `doctorsInOpts`/`doctorsOutOpts` at the form is a real improvement — it removes the `useSuspenseQuery({ limit: 0 })` calls that used to download every doctor to power two filters.
- The new `storeId` query param on `GetItemsSchema` is correctly optional and merges with `baseQuerySchema`.

## Issues

### Blocking

**B1. Out-of-scope `startsWith` → `contains` on `items.itemId`** — `src/app/(dashboard)/common/items/features/items-repository.ts:43`. The PR is supposed to land infinite scroll for cathlab. It silently flips the `itemId` predicate from `startsWith: query.search` to `contains: query.search`. Any other caller of `findItems` that expects exact-prefix matching (e.g. barcode scanners, ID-prefix lookup in pharmacy flow) will now match items whose ID merely contains the search string anywhere. Revert to `startsWith` — this PR is not the place to widen the search semantics. If the new component wants substring search on `itemId` (which `search-select` is happy to do server-side), do it in the search-select layer, not the repository.

**B2. Self-debt + commented-out production code in `cathlab-pharmacy-sale.tsx`** — `src/app/(dashboard)/cathlab/features/components/cathlab-pharmacy-sale.tsx:48` (commented-out `useDebouncedValue`), `:60-114` (a 55-line commented-out `handleSelect` block), `:215-219` (a `// TODO: comment out when inifinite is not working` comment). The PR description literally says "to quickly recover the original workflow" — fine for development, unacceptable to ship. Git has the history. Delete the entire commented block and the TODO. The 1-second debounce is already covered inside `useItemSearchInfinite`, so the local `useDebouncedValue` was double-debouncing before the swap.

**B3. Debug `console.log("Service Data", data)` left in production** — `src/app/(dashboard)/daycare/features/components/search-bar-select-with-infinite-scroll/service-search-select.tsx:54`. The output of `data?.pages.flatMap(...)` on every service page-change is verbose, leaks the full service catalogue to the browser console, and is plainly debug-only. Delete.

### Important

**I1. 6 near-identical `useXxxSearchInfinite` hooks** — `src/app/(dashboard)/daycare/features/hooks/use-search-select-infinite.tsx:25-241`. The six hooks differ only by `queryKey` first element, fetcher, and two field names in `getNextPageParam`. ~217 of 241 lines are copy-pasted. Factor into one generic hook:

```ts
export function useEntitySearchInfinite<TItem, TFilters>({
  search,
  filters,
  enabled,
  queryKey,
  fetcher,
  extractItems,
  getTotalCount,
}: {
  search?: string;
  filters?: TFilters;
  enabled?: boolean;
  queryKey: readonly unknown[];
  fetcher: (q: TFilters & { search: string; limit: number; offset: number; page: number }) => Promise<unknown>;
  extractItems: (page: unknown) => TItem[];
  getTotalCount: (page: unknown) => number;
}) { /* one body, parameterised on the four callables */ }
```

The six entity wrappers then become 3-5 lines each (default labels and IDs only). Net: ~241 lines → ~80 lines + ~30 lines across the wrappers.

**I2. `keepSelectedItem` re-injects filtered-out options** — `search-select.tsx:87-95` and `search-select.tsx:152-158`. The implementation reads from a ref captured at last selection and pushes a synthetic `{ label, value }` into the dropdown even when the current `getItems(data)` does not include it. Two consequences:

1. On `cathlab-procedures.tsx` and `cathlab-services.tsx` the consumer immediately calls `setSearched*("")` after selection, so on the next render the search input is empty but the synthetic option is still in the list — confusing UI.
2. The hook re-fetches as the user types, so a selected item that no longer matches the current `search` (or was filtered by a now-narrower `query`) disappears from `getItems(data)` and the ref-based fallback is what keeps it visible. That is correct *intent* for "remember the last pick", but the implementation is fragile (ref never cleared on `clearable`, so a cleared select still shows the previous selection).

Either: drop `keepSelectedItem` and document that callers pass the selected item explicitly via `value`, or back the ref with a one-time injection at select time and clear it on `clearable` clicks. Right now it is half-implemented.

**I3. `SearchPagination` / `intersection observer` referenced in the previous feedback do not exist** — the implementation uses `scrollAreaProps.onScrollPositionChange` instead. Confirm the bottom-detection threshold (`y + viewport.clientHeight >= viewport.scrollHeight - 20`) is large enough to fire on small pages. With `PAGE_SIZE = 30` and a 200px max-height dropdown, 30 items may fit in 1-2 page-downs; a 20px slack should be fine, but a single fast scroll past the bottom will skip the "Loading…" sentinel and trigger two `fetchNextPage` calls (which the `isFetchingNextPage` guard handles, but a comment would help). Also: Mantine `Select`'s `scrollAreaProps.viewportRef` is not a documented prop — verify it survives the next Mantine minor bump.

**I4. Three store-side `usePatients()` and `useQuery()` callers still in `patient-selection.tsx`** — `src/app/(dashboard)/emr/ipd/features/components/patient-selection.tsx:151-194, 300-322, 379-389`. The whole point of swapping to `PatientSearchSelect` was to drop these, but the file still calls `usePatients({ patientsQuery, ... })`, still declares `setSearchedPatient`/`setPatientsQuery` machinery, and still has a `useEffect` that writes `patientData.name` into both `searchedPatient` and `patientsQuery.search` on edit pages. The `useEffect` also depends on `patientData` but not on `setSearchedPatient`/`setPatientsQuery` (stable references from `useState`, fine). Bigger issue: in `getNextPageParam`-style pagination over the new `usePatientSearchInfinite`, the previous `usePatients` hook's "include the currently-selected patient even if filtered out" logic is lost — the new code relies on `keepSelectedItem` for that, which is broken (see I2). Either fix `keepSelectedItem` or have the form pass `keepSelectedItem={false}` and manage the selected patient via `value` only.

**I5. `load` / `label` mismatch in `ItemSearchSelect` default label** — `search-bar-select-with-infinite-scroll/item-search-select.tsx:46-49`. The default label is `${item.name} (${item.itemId}) - ${item.generic}`. Previously the cathlab-pharmacy-sale rendered the same shape but used `${item.category.name}` and `${item.unit.abbreviation}` in the *appended* row, not in the picker label. So the dropdown will now show "Paracetamol (P-001) - paracetamol" while the appended table row still says `Paracetamol - ANALGESIC - tab`. Not a bug, but visually inconsistent with the legacy `<Select>` that the rest of the cathlab form used. Document the label change in the PR description or restore the legacy label format.

**I6. `useServiceSearchInfinite` produces `NaN` pagination when filter changes mid-session** — `use-search-select-infinite.tsx:80-83`. `JSON.stringify(filters)` is part of the query key, so a filter object that contains a `Date` (or `undefined`) will be stringified inconsistently between renders, causing cache misses but not bugs. However: `offset: (pageParam - 1) * PAGE_SIZE` with `pageParam` of 1 on the *second* page is `(2 - 1) * 30 = 30`, which is correct; but the `initialPageParam: 1` and `getNextPageParam` returning `allPages.length + 1` means the *next* call sends `page: 2`, `offset: 30`. This is fine, but the API (`GetServicesSchema`) might enforce `page` ≥ 1 with no upper bound — confirm the server accepts `offset`-based pagination for `page >= 2`.

### Nit

- **N1. `usePatientSearchInfinite` schema vs. `useServiceSearchInfinite` shape inconsistency** — `use-search-select-infinite.tsx:152-159` reads `lastPage.result?.patients?.length ?? 0` while `useItemSearchInfinite` reads `lastPage.items?.length`. The repositories return differently-shaped envelopes (`{ items, totalCount }` vs `{ result: { patients, totalCount } }`). Standardize the API envelope before the second component reaches a fourth caller, otherwise this divergence will keep spreading.
- **N2. `queryKey` redundancy** — every hook has `[entity, "infinite", debouncedSearch, JSON.stringify(filters)]`. The string `"infinite"` is the only thing distinguishing it from any other key; pick either separate namespaces (`["services-infinite", …]` vs `["services", …]`) or rely on the hook name only.
- **N3. `staleTime: 1000 * 60 * 5` hardcoded 5 times** — promote to a module-level constant `STALE_TIME_MS = 1000 * 60 * 5;` (collapsed to one line once I1 is applied).
- **N4. `cathlab-services.tsx` still uses `useDebouncedValue` indirectly via the new component but no longer needs `useDebouncedCallback`** — the import block keeps `useDebouncedCallback`. Verify it is still used after the swap; if not, delete. Same for `cathlab-procedures.tsx`.
- **N5. `Make` `getItems` returns `(data: D) => T[]` but `getOptionLabel`/`getOptionValue` are called on every render with stale closures** — `search-select.tsx:75-78` lists them in the `useMemo` dep array, so they're called fresh each render anyway. The `getItems` is also a fresh closure each render. The `useMemo` is barely earning its keep here; consider inlining `allItems.map(...)` unless profiling shows a hot path.
- **N6. `IconOptions` defaults to `position: "right"` but `renderContent()` returns the loader if `isFetching && !isFetchingNextPage`** — for `iconOptions.showLoader = false` (the default in cathlab-procedures and patient-selection), `renderContent()` still returns the icon. The intent is "show loader only during initial load, icon otherwise", which is what the code does, but the boolean `showLoader` and the conditional render are tangled. A two-line comment naming the invariant would help.
- **N7. `cathlab-procedures.tsx:402` passes `style={{ display: isDetailPage ? "none" : "block" }}` to `ProcedureSearchSelect` but the parent already gates on `{!isDetailPage && (...)}` at line 392** — the inline style is dead code.

## Recommendations

1. **Resolve B1–B3 before merging.** Revert the `contains` change on `items.itemId`. Delete the commented-out blocks and the TODO in `cathlab-pharmacy-sale.tsx`. Remove the `console.log` in `service-search-select.tsx`. None of these are negotiable; they're sloppiness, not design choices.
2. **Apply I1's generic hook.** Six hooks → one. Saves ~160 lines, makes the next entity a 3-line wrapper instead of a 35-line copy.
3. **Either fully implement `keepSelectedItem` or delete it.** Half-implemented "remember the last pick" is worse than not having it.
4. **Add one Jest test for `useEntitySearchInfinite`** covering: `getNextPageParam` returns `undefined` once `loaded >= total`, and `getNextPageParam` returns `allPages.length + 1` otherwise. Without this, the next entity wrapper is free to break the pagination contract silently.
5. **Post-deploy smoke check**: open cathlab, type "Para" in the pharmacy item picker, scroll to the bottom — confirm a single extra page loads and the bottom-of-list row reads "Loading...". Repeat for cathlab procedure picker. Repeat for IPD-EMR service picker.

## Reviewer notes

- ClickUp ticket is `9018849685/86ey3pg5q` and is referenced in the PR body. Reading it before approval is recommended.
- Confirm with the team whether `items.itemId` matching was deliberately loosened before merging B1's revert — if the loosening is the actual ask, do it in a separate PR with a migration to update search expectations in pharmacy.
- `next.config.ts` ignores ESLint/TS errors at build time. Run `npm run lint && npm run typecheck` locally before approval.
- The PR title `Adding infinite scroll in cathlab` undersells the diff: cathlab is 4 files; the other 17 files are the daycare primitive and the wiring into IPD-EMR. Consider renaming to `feat(ui): introduce infinite-scroll search selects + apply to cathlab/ipd-emr`.