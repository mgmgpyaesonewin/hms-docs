# Code Review: PR #2869 — Adding infinite scroll in cathlab
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-26/cathlab-86ey3pg5q` → `development`
**Files changed:** 25 (+1414 / -267)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3pg5q

## Summary
Replaces several finite Mantine `<Select>` lookups in the Cathlab module (items, services, procedures, doctors) with a new generic `<SearchSelect>` infinite-scroll component backed by a shared `useEntitySearchInfinite` hook (TanStack `useInfiniteQuery`). Six per-entity wrappers (`Item/Service/Procedure/Doctor/Patient/ClinicSearchSelect`) live under `src/components/search-bar-select-with-infinite-scroll/`. The author added `sortEntitiesBySearch` to `general-utils` so repositories over-fetch `limit * 10` rows, sort by search relevance, then slice to `limit`. The PR description explicitly notes "the infinite scroll wasn't working properly or wasn't convenient, to quickly recover the original workflow" — large blocks of original code are commented out instead of deleted.

## Verdict
**Request changes**
Score: 28/100
Critical: 2 | High: 6 | Medium: 5 | Low: 3 | Nit: 2

## Issues

### Critical

1. **Operator-precedence bug in `patients-repository.ts` silently breaks ranking.** The diff changes `take: query.limit > 0 ? query.limit : undefined` to `take: query.limit > 0 * 10 ? query.limit : undefined`. `0 * 10` evaluates first (`0`), so the expression is `query.limit > 0 ? query.limit : undefined` — i.e., **no `* 10` over-fetch and no `.slice()` afterwards**. Every other repository in this PR multiplies by 10 and slices, but for patients the ranking is now applied to whatever the default page size happens to be, not to a 10x pool. Symptom: patient search will surface matches deep in the dataset unreliably, and "total count" tells the infinite hook there's more to load even though nothing relevant is on the page.

2. **PR description explicitly admits the feature is broken — large blocks of original code are commented out, not deleted.** The author wrote: *"Commented out some code because the infinite scroll wasn't working properly or wasn't convenient, to quickly recover the original workflow."* Multiple files (`cathlab-procedures.tsx`, `cathlab-pharmacy-sale.tsx`, `cathlab-services.tsx`, `ipd-emr-standard-service-request-form.tsx`) carry 100+ lines of `// const { ... } = useQuery(...)` and full commented-out `handleSelect` / `onSelect` implementations. The mix of "live" and "commented-out" code paths on the same screen is the textbook shape of a regression waiting to happen — a future edit to the live code will not be reflected in the dead block, and vice versa. Either delete the dead blocks or revert the PR.

### High

3. **`sortEntitiesBySearch` ranking depends on caller-supplied field order with no enforcement.** The function's "name is ALWAYS higher priority than IDs" rule is implemented as `fieldWeight = i * 10`, where `i` is the array index the caller passed in. There is no type-level or runtime check that index 0 is the name field. Six repositories call it correctly today; one future call with `[itemId, name, generic]` will silently invert the ranking. At minimum, the API should require `(nameField, idFields)` explicitly rather than a generic `getFields: (entity) => string[]`.

4. **Search semantics changed silently in two repositories.**
   - `service.repository.ts`: `name: { contains }` → `name: { startsWith }`, plus a new `category.name startsWith` clause. Any previous lookup that matched "starts anywhere in name" or "matches in category" now misses.
   - `items-repository.ts`: `itemId: { startsWith }` → `itemId: { contains }`. A user typing an item ID prefix now matches items containing that string anywhere in the ID — a different (possibly noisier) result set than before.
   These are user-visible regressions masquerading as "infrastructure" changes. If the intent was to rank in-app rather than filter in-DB, the WHERE clause should not have changed.

5. **`ItemSearchSelect` default label is silently different from the original Select.** Old `<Select data=...>` option label was `${itm.name} (${itm.itemId}) - ${itm.generic}`. New `defaultLabel` in `item-search-select.tsx` is `${item.name} - ${item.category?.name || ""} - ${item.unit?.abbreviation || ""}`. Users in cathlab-pharmacy will see a different label shape with no change in their workflow. The new label also drops `itemId`, which cathlab users rely on to identify items quickly.

6. **`stableStringify` reinvents `JSON.stringify` for the express purpose of being a stable cache key.** The function sorts keys and handles Date; this is exactly what `JSON.stringify` already does for objects without circular references, and there is no `Date` field in any of the current filter schemas (`GetServicesSchema`, `GetDoctorsSchema`, …). The fallback string for `undefined` returning `"undefined"` is also surprising — it means `undefined` filter values all collide on the same cache key. This is one wrapper around a 1-line problem.

7. **`useEntitySearchInfinite` over-fetches 10x in *every* page, not just the first.** `take: query.limit * 10` runs on every page of `useInfiniteQuery`, so a 30-row page becomes a 300-row DB query. For doctors, services, procedures, items — all with low thousands of rows — this is fine for the first page but wasteful for scroll pages where the user is already past page 1 and ranking has nothing to do. Either over-fetch only the first page or push the ranking into SQL (`ORDER BY similarity(...) DESC` with `pg_trgm`, which is already enabled in this codebase).

8. **`forwardRef` + manual cast in `search-select.tsx` erases generics.** `export const SearchSelect = SearchSelectInner as <T, D, F extends object>(...) => React.ReactElement` drops `T`, `D`, and `F` from the type — callers get `SearchSelect<Doctor, DoctorSearchData, DoctorSearchFilters>` but the runtime props are only loosely typed. This works today because each wrapper component hard-codes the type parameters, but a caller who tries `<SearchSelect<Doctor, ...> ... />` directly will get no autocomplete for `getOptionLabel`. Either use a non-generic runtime wrapper (each entity wrapper passes typed lambdas) or accept the generic loss but document it.

### Medium

9. **`stableFilters = useMemo(() => filters, [filters])` is a no-op memo.** The dependency array is `[filters]`, so the memo invalidates every time `filters` changes by identity — which is the same as not memoizing at all. The intent (a stable query key) is already served by `stableStringify(stableFilters)` inside the queryKey, so the memo does nothing useful and should be removed.

10. **`usePatientSearchInfiniteFor{Hd,Endo,OT,Cathlab}` is four near-identical 8-line hooks.** Each one wraps `useEntitySearchInfinite` with a different fetcher. They can collapse to a single `usePatientSearchInfiniteForModule(fetcher, queryKeyPrefix)` factory, or — better — `usePatientSearchInfinite` accepts a `fetcher` and `queryKeyPrefix` argument the way the `useEntitySearchInfinite` already does. The proxy-bill hook file then becomes 10 lines instead of 82.

11. **Backend performance: `take: query.limit * 10` against indexed columns doubles or worse the cost of every list endpoint hit by `SearchSelect`.** This PR touches the patient, doctor, service, procedure, item, cathlab-request, and cathlab list endpoints. Even if Postgres handles each one in milliseconds, the additional index scan + 10x row fetch runs on every scroll of every select. There is no offset-keyset cursor or `LIMIT … WHERE (id, created_at) > (?, ?)` to avoid skipping work on later pages.

12. **`renderOption` in `search-select.tsx` returns `option.label` (a plain string) for non-loader rows, bypassing any label formatter the consumer passed in.** The injected `__loader__` row uses `<Loader>`, but real options go through Mantine's default option renderer with the label that was already computed in `options`. This is fine *only* because the consumer pre-formats labels in the wrapper's `getOptionLabel`. If a future caller passes a React node as the label, it will be stringified. Document or replace with `getOptionLabel(item)` lookup inside `renderOption`.

13. **`scrollAreaProps.viewportRef.onScrollPositionChange` fires on every pixel of scroll and unconditionally calls `fetchNextPage` when within 20px of the bottom.** `fetchNextPage` is already idempotent (`react-query` de-dupes while `isFetchingNextPage` is true), but the scroll handler still computes `viewport.scrollHeight` every event. For long lists this is measurable. Threshold-based `IntersectionObserver` on a sentinel would be cheaper and is the conventional pattern.

### Low / Nit

14. **`iconOptions.position` defaults to `"left"`, but `cathlab-procedures.tsx` passes `position: "right"` with `showIcon: false` — i.e., the only thing rendered on the right is the loader, and there is no clear icon.** The author appears to have been experimenting with the API. The current call is fine, but the prop name `showIcon` is misleading: it controls "render the icon at all", not "render an icon in addition to the loader" (mutually exclusive inside `renderContent`). Rename to `renderIcon` for honesty.

15. **`PatientSearchSelect`, `ClinicSearchSelect`, `DoctorSearchSelect` accept a `query` prop but never use it to filter.** `query` is passed straight to `useSearchHook({ filters: query, ... })`. The `usePatientSearchInfinite` and friends accept `filters`, but `fetchPatientForCathLab` etc. don't currently honor arbitrary filters (they just pass through to the API). Either filter by the props or drop the `query` prop until the underlying fetchers support it.

16. **In `search-select.tsx`, `keepSelectedItem` mutates the displayed option list even when `selectedItem` was set by an external `value` prop the parent never sent via `onItemSelect`.** The effect `if (value === null) setSelectedItem(null)` clears the synthetic selection, but if `value` is set and the real list doesn't contain it (e.g., another user edited the row), the synthetic label will silently drift from the real entity. Document the lifetime contract or drop the feature.

## Recommendation
Do not merge as-is. The combination of an acknowledged broken UX (commented-out blocks), a confirmed operator-precedence bug in patients repository, and silent search-semantic changes means this PR can ship regressions that won't show up in basic smoke tests. Concrete next steps:

1. Delete every commented-out block in the four `cathlab-*` and `ipd-emr-*` files (or revert the file). Land the new code on its own.
2. Fix the `patients-repository.ts` operator-precedence bug (`(query.limit > 0 ? query.limit : undefined) * 10`) and add a regression test that asserts over-fetch happens.
3. Restore the original `name.contains` and `itemId.startsWith` queries in `service.repository.ts` and `items-repository.ts` — or, if the new behavior is intended, document it in the ClickUp ticket and call it out in the commit message.
4. Restore the original `ItemSearchSelect` default label to `${name} (${itemId}) - ${generic}` (or pass `getOptionLabel` explicitly from the cathlab call sites).
5. Collapse the four `usePatientSearchInfiniteFor*` wrappers into a single factory.
6. Reconsider the `limit * 10` over-fetch. Either push ranking into Postgres (`pg_trgm` is already in this codebase per ADR notes) or only over-fetch the first page; the current approach wastes DB cycles on every scroll.
7. Add at least one integration test per entity (`Item`, `Service`, `Procedure`, `Doctor`) that hits the search endpoint through the new wrapper and asserts that a name-startsWith match outranks a name-contains match in the returned slice.

Once those are addressed, re-review for the Medium-tier items (`useMemo` no-op, `renderOption` label contract, scroll handler throttling) before approving.