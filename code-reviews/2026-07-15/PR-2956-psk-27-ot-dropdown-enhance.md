# Code Review: PR #2956 — Psk/27/ot dropdown enhance
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/27/ot-dropdown-enhance` → `development`
**Files changed:** 15 (+451 / -366)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-15
**ClickUp:** https://app.clickup.com/t/9018849685/86ey557a6
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3pg4h

## Summary
PR replaces the "fetch-everything-once" `Select`/`MultiSelect` dropdowns in the OT module (and several shared proxy-bill components) with already-shipped `*SearchSelect` wrappers around the shared `useEntitySearchInfinite` hook, so the dropdowns paginate on demand instead of pulling every row. A new `MainProcedureSearchMultiSelect` component, a matching `useMainProcedureSearchInfinite` hook, and four new test files accompany the swap. Net diff is negative once you ignore tests and the schema-line constant; the UI behaviour, types, and search-key serialization stay consistent with the existing pattern.

## Verdict
**Approve with suggestions**
Score: 77/100
Critical: 0 | High: 0 | Medium: 3 | Low: 4 | Nit: 3

## Issues

### Critical
None.

### High
None.

### Medium

1. **`ProxyBillProcedures` retains a `moduleDepartment` prop that is no longer used.** [src/app/(dashboard)/shared/proxy-bill/features/components/proxy-bill-procedures.tsx:34,45,215]
   After this PR the new `procedureQuery` prop drives the `ProcedureSearchSelect`'s `query`, but the body still reads `moduleDepartment` from the destructured props. Because the destructured value is no longer fed to the select, callers that previously set `moduleDepartment` (OT, Daycare, EMR, CathLAB screens) now silently lose department filtering. Recommend either deleting the prop outright or forwarding it as the default `procedureQuery.moduleDepartment` so existing behaviour is preserved.

2. **`OTRequestForm` Surgeon / Anesthetist / Assistant Doctor selectors lost their `DoctorType` filter.** [src/app/(dashboard)/ot/request-list/features/components/ot-request-form.tsx:790–1132]
   Previously each of the three controls was wired to a separate `doctors*Opts` list (`IN_SERVICE` / `OUT_SERVICE` / all). After the swap they all use `DoctorSearchSelect` with only `query={{ status: "ACTIVE" }}`, so all three lists now include every active doctor regardless of type. If the form previously distinguished IN- vs OUT-service surgeons/anesthetists (it did at least for `referralDoctor`), this is a behavioural regression. Either parameterise `DoctorSearchSelect` to accept a `doctorType` filter or document why the filter was intentionally dropped.

3. **`ot-form.tsx` Patient selector disables infinite scroll beyond text search.** [src/app/(dashboard)/ot/features/components/ot-form.tsx:487–520]
   `usePatientSearchInfiniteForOT` (vs the generic `usePatientSearchInfinite` used in OPD) appears to carry an OT-eligibility gate. The PR swaps the legacy `usePatientsForOT` (which already encoded that gate) for the new hook — good. However the new wiring only forwards the hook; there is no test or comment indicating the gate survives. Recommend adding a test in the new `ot-dropdown-infinite-components.node.test.ts` that asserts the OT patient eligibility filter still runs, or at minimum a one-line code comment near `useSearchHook={usePatientSearchInfiniteForOT}` documenting why the OT-specific hook is required (otherwise someone will "deduplicate" it back to `usePatientSearchInfinite` later).

### Low / Nit

**Low**

1. **`MainProcedureSearchMultiSelect` fakes a sentinel `__loader__` option to render the next-page spinner.** [src/components/search-bar-select-with-infinite-scroll/main-procedure-search-multi-select.tsx:131–172]
   Mantine `MultiSelect` renders every option through `renderOption`. The workaround avoids async per-option loading (which Mantine 7 doesn't support), but it leaks the sentinel into `onChange` payloads — mitigated with `filter((item) => item !== "__loader__")`. If Mantine ever offers a real `ListFooter` slot this should be replaced. Acceptable now; flag for future cleanup.

2. **`MainProcedureSearchMultiSelect` synthesises a `label` from `value` for pre-selected-but-not-in-current-page items.** [main-procedure-search-multi-select.tsx:53–58]
   `mapped.push({ label: selectedValue, value: selectedValue })` displays the raw id when the matching page has been dropped from the cache. This is a stop-gap; the long-term fix is to hydrate selected chips with their canonical labels (likely the same `procedureCache` shared in `useEntitySearchInfinite`). Mark with a `// lazy:` comment so the next maintainer understands why a synthetic label is acceptable here.

3. **`stableStringify` short-circuits `Date` to ISO but does not handle `BigInt`, `Map`, `Set`, or cyclic refs.** [src/hooks/use-search-select-infinite.tsx:66–84]
   Today's callers only pass plain object filters, so this is fine — but `Omit<X, ...>` for the filter type doesn't preclude a `Date` in practice (Zod date coercion). One-line guard or a TODO is enough.

4. **Tests assert on source-text presence/absence rather than behaviour.** [src/app/(dashboard)/shared/ot/__tests__/ot-dropdown-infinite-components.node.test.ts:1–49]
   `expect(source).toContain("<PatientSearchSelect")` is a hygiene test, not a regression test — it will pass for both a working and a half-broken wiring. For the assertion to actually catch a regression it would need to mount the component or assert the rendered output. The two repository tests at the top of `service-and-procedure-department-filter.node.test.ts` are real coverage; these string-match tests are belt-and-braces at best.

**Nit**

1. **Dead imports linger in `ot-request-form.tsx`.** After deletion of `useDebouncedCallback`/`debounced`/`useState` users, `useState` import is gone (good) but `makeFetchAnesthesiaTypesQuery`, `makeFetchClinicsQuery`, `makeFetchDoctorsQuery`, `makeFetchPatientsQuery`, `makeGetUsersQuery`, `useDebouncedCallback` imports should all be 100% gone — `git diff` shows them correctly removed. (Nit because they were already removed; flagging only to confirm.)
2. **`useStoreSearchInfinite` and `useAnesthesiaTypeSearchInfinite` declarations were swapped in `use-search-select-infinite.tsx` for no functional reason.** [use-search-select-infinite.tsx:296–358] Pure re-order; harmless. Note for reviewers who skim the diff and see "moved hooks".
3. **`MODULE_DEPARTMENT_MAPPING` adds an `OT` line in a const file unrelated to the rest of the diff.** [src/app/(dashboard)/common/user-management/departments/features/const/index.ts:9] The change is correct (you cannot filter by `DepartmentEnum.OT` without the mapping), but the PR mixes it into a dropdown-enhancement branch. Trivial; squash-merge fine.

## Recommendation
Land after addressing the three Medium items:

1. Either delete `ProxyBillProcedures`'s unused `moduleDepartment` prop or forward it as a default `procedureQuery.moduleDepartment`. A safe stop-gap is to keep the prop, derive `procedureQuery` as `{ ...procedureQuery, moduleDepartment: procedureQuery?.moduleDepartment ?? moduleDepartment }`, and call sites remain untouched.
2. Re-add the `DoctorType` filter to the Surgeon / Anesthetist / Assistant Doctor selectors — either by adding `doctorType` to `useDoctorSearchInfinite` filters (preferred, one-line in the hook), or by extending `DoctorSearchSelect` with a `doctorType` prop.
3. Add a short comment or a Jest assertion confirming that `usePatientSearchInfiniteForOT` keeps the OT-eligibility filter.

Everything else is polish (sentinel loader, label hydration for stale pages, string-match tests) and can be follow-ups.
