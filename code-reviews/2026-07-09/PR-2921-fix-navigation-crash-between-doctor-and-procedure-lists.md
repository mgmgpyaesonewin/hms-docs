# Code Review: PR #2921 — Fix - Navigation Crash Between Doctor and Procedure Lists
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `issue/ppz/sprint-27/navigation-error-86ey6jwq7` → `development`
**Files changed:** 1 (+16 / -9)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-09
**ClickUp:** https://app.clickup.com/t/9018849685/86ey6jwq7

## Summary
Fixes a navigation crash between the doctor and procedure list screens. The crash was caused by `departmentOptions` and `specializationOptions` accessing `result.data` / `result.specializations` without optional chaining — when the query result is briefly undefined during navigation between routes, the `.map()` call throws and crashes the screen. The PR wraps both derivations in `useMemo`, adds optional chaining, and falls back to `[]`.

## Verdict
**Approve with suggestions**
Score: 88/100
Critical: 0 | High: 0 | Medium: 1 | Low: 0 | Nit: 1

## Issues

### Critical
None

### High
None

### Medium

**M1. `useMemo` is unnecessary and adds coupling to the query result identity.**
`departmentOptions` and `specializationOptions` are cheap `.map()` derivations over small option lists (departments and specializations are bounded, low-cardinality). `useMemo` here:
- Adds a dependency on the query result reference — every refetch with a new array reference invalidates the memo, so it gains nothing.
- Re-renders happen with the parent component anyway; Mantine's `Select` is not a perf bottleneck at this size.
- Increases diff size (+16/-9) and adds hook-order coupling for no measurable benefit.

The fix the ticket actually needs is just the optional chaining + `?? []` fallback. Same bug, half the diff:
```ts
const departmentOptions =
  departmentsData?.result?.data?.map((department) => ({
    label: department.name,
    value: department.id,
  })) ?? [];

const specializationOptions =
  specializationData?.result?.specializations?.map((specialization) => ({
    label: specialization.name,
    value: specialization.id,
  })) ?? [];
```

If kept, `useMemo` should at least also memoize when `departmentsData` is `undefined` (which it now does via `?? []`) — but the better fix is to drop it.

### Low / Nit

**L1. Crash likely exists in sibling consumers of the same query shape.**
`makeFetchSpecializationsQuery` is consumed in `specialization/features/specialization.api.ts` and likely elsewhere. A grep for `result.specializations` without optional chaining would surface any sibling callers that crash on the same navigation. Out of scope for this PR, but worth a follow-up issue so the next "navigation crash" ticket isn't needed.

## Recommendation
Approve. The crash fix is correct. Drop the `useMemo` wrappers in a follow-up — the optional chaining + `?? []` is enough. Optionally grep for sibling consumers of `specializationData.result.specializations` to confirm there are no other crash sites.