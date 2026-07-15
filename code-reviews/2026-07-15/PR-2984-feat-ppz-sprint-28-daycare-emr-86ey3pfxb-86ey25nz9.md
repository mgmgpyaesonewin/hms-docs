# Code Review: PR #2984 — Feat/ppz/sprint 28/daycare emr 86ey3pfxb 86ey25nz9
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-28/daycare-emr-86ey3pfxb-86ey25nz9` → `development`
**Files changed:** 4 (+130 / -85)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-15
**ClickUp:** https://app.clickup.com/t/9018849685/86ey25nz9
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3pfxb

## Summary
The PR integrates the daycare EMR module with the shared `*SearchSelect` components (`ItemSearchSelect`, `ServiceSearchSelect`) and the shared `ProxyBillProcedures` component, and adds a `DAYCARE` entry to `MODULE_DEPARTMENT_MAPPING` so the `buildModuleDepartmentNameFilter(moduleKey)` helper can resolve `moduleDepartment=DAYCARE` to the actual department name. Net win: the daycare pharmacy/services/procedures screens now use the project's standardized infinite-scroll search components (with shared debouncing and module-scoping) instead of bespoke `Mantine Select` + manual query implementations.

Mechanically the swap is correct — the underlying hooks (`useItemSearchInfinite`, `useServiceSearchInfinite`, `useProcedureSearchInfinite`) debounce internally, the shared `*SearchSelect` wrappers expose `query` filters and `onItemSelect` callbacks that match what the callers used to do manually, and the `moduleDepartment=DepartmentEnum.DAYCARE` plumbing is consistent with the existing pattern. The 1-line mapping addition in `MODULE_DEPARTMENT_MAPPING` is load-bearing: without it, `buildModuleDepartmentNameFilter("DAYCARE")` returns `undefined`, and daycare procedures would silently bypass the department filter (currently no procedure would render because filtering against undefined returns nothing for filter arrays, or *everything* — the inconsistency depends on the server-side coercion).

## Verdict
**Request changes**
Score: 80/100
Critical: 0 | High: 1 | Medium: 2 | Low: 1 | Nit: 2

## Issues

### Critical
None.

### High
1. **daycare-pharmacy.tsx / daycare-services.tsx — large blocks of commented-out dead code committed (`ponytail: delete`)**. Both files leave 25-30 lines of the old `useQuery` + `useMemo` + `Mantine Select` implementation wrapped in `//` comments alongside the new `*SearchSelect`. This is dead code: it does not run, it is not load-bearing for documentation (the diff in the PR description should be the source of truth), and it makes the file harder to scan and review. The diff is +130 / -85 — the deletions never happened. Replace each commented block with nothing.

   - daycare-pharmacy.tsx lines ~22, ~86, ~113-135, ~254-267
   - daycare-services.tsx lines ~19, ~99, ~126-139, ~145-155, ~270-284

   Deductions covered by Medium #3 below; the severity is "High" because the diff advertises deletions that are not really deletions.

### Medium
1. **dead-code comment `// import { makeFetchItemsQuery ... }` left in the import block**. Same root cause as High #1, but separate line. Drop it.

2. **`toast.show` vs `toast.error` API inconsistency between near-identical code paths**. `daycare-pharmacy.tsx` was migrated to `toast.error(...)` for both the no-patient and duplicate-item paths. `daycare-services.tsx` was migrated to `toast.error(...)` for no-patient but still calls `toast.show(...)` for the duplicate-service path. Pick one API (`error`, since the toast is about a user-facing failure) and use it consistently across both files. If `toast.show` is intentionally deprecated, replace it.

3. **Duplicate guard for `watchedServiceFields?.some((f) => f.serviceId === service.id)` is a behavior change worth flagging**. The old code had a defensive `if (!curr) return;` after finding the service from the fetched result list; the new code skipped that branch but kept the duplicate check. Net behavior is equivalent (the duplicate check would also catch "not found in fresh fetch"), but the removal of the `curr`-from-fetch lookup means the service object's identity now relies entirely on `useServiceSearchInfinite` having returned that item in the current paginated results. With infinite scrolling and 1s debounce, the user can in principle select an item from page 1, the cache gets stale, page 1 gets re-fetched from another tab — `ServiceSearchSelect` still passes the full `Service` object via `onServiceSelect`, so this is fine in practice. Note it for posterity; no fix required.

### Low / Nit
1. **daycare-pharmacy.tsx — leftover `useQuery` import is now unused** (no callers left after the dead code is removed). Also `Loader` from `@mantine/core` is only used in the deleted `<Select>` block (the new `ItemSearchSelect` owns its own loader via `iconOptions.showLoader`). Clean both on the same pass that deletes the dead code.
   - `daycare-services.tsx` has the analogous situation but it has already dropped the `Loader` import in the new version; `useQuery` is still imported and used by `makeFetchDoctorServicesQuery`, so it stays.

2. **`icon: <Search />` vs `icon: <SearchIcon size={16} />` — minor consistency**. `daycare-pharmacy.tsx` removed the `size={16}` prop on `Search` (it now uses `<Search />`). The previous code used `SearchIcon size={16}`; the rest of the file likely uses varied icon conventions. Not worth a separate PR but mention it.

## Recommendation
1. **Delete the commented-out code** in `daycare-pharmacy.tsx` and `daycare-services.tsx`. After removal, both files should drop their unused imports (`makeFetchItemsQuery`, `useDebouncedValue`, `Loader` from `@mantine/core`, `getServices` already dropped, `useQuery` may stay in services since it is used by `makeFetchDoctorServicesQuery`). Net delta after cleanup: roughly -30 lines per file.
2. **Pick one `toast.*` method** for the duplicate-item guard — `toast.error` — and use it consistently across both files.
3. **Re-run `npm run tsc && npm run lint`** before merge to confirm the cleanup didn't leave dangling references.
4. Once these are addressed, this is a clean Approve. The 1-line `MODULE_DEPARTMENT_MAPPING` addition is small but load-bearing and the correct shape of the change.
