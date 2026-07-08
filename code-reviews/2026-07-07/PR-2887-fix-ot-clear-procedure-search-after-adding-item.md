# Code Review: PR #2887 — fix(ot): clear procedure search after adding item
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/27/fix-procedure-search` → `development`
**Files changed:** 3 (+112 / -1)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07

## Summary
Adds a single line in the shared `ProxyBillProcedures` component (`setSearchedPackage("")`) so the controlled procedure search input clears after a procedure is successfully added in OT services. Adds a 110-line jsdom regression test under the OT EMR test tree.

## Verdict
**Request changes**
Score: 72/100
Critical: 0 | High: 2 | Medium: 2 | Low: 2 | Nit: 0

## Issues

### Critical
None

### High

1. **Fix lives in a shared component but the test lives in OT, hiding blast radius.** `ProxyBillProcedures` is under `src/app/(dashboard)/shared/proxy-bill/` and is reused across OPD/IPD/OT workflows. The PR title says "fix(ot)" but the diff changes behavior for every consumer. Before merging:
   - Grep for `<ProxyBillProcedures` (or its import) across the repo and confirm `setSearchedPackage("")` after add is the desired UX for all callers, not just OT. If a non-OT caller wants to keep the search term (e.g. to add a second similar procedure), this is a silent behavior change.
   - Move the test to `src/app/(dashboard)/shared/proxy-bill/features/components/proxy-bill-procedures/__tests__/` so it sits next to the source it covers. The current placement under `emr/ot/.../__tests__/` signals "OT-specific behavior," which contradicts where the fix was actually applied and gives a false sense of coverage for non-OT regressions.

2. **Test does not cover the duplicate-add early-return path, which is exactly where the regression class lives.** `handleAdd` has two paths: (a) `isDuplicated === true` → `toast.error` and `return`; (b) success → `prepend` + `setSearchedPackage("")`. The PR ships behavior for (b) but no assertion for (a). If someone refactors and accidentally calls `setSearchedPackage("")` before the duplicate check (so a duplicate toast also wipes the user's search), no test will catch it. Add at least one `it("keeps the search term when the procedure is a duplicate")` case.

### Medium

1. **110-line DOM test for `setState("")` is disproportionate.** The production change is a single line in `handleAdd`. The test scaffolds a full `FormProvider` + 14-field `defaultValues`, a `ProcedureFormHost` wrapper, a `useQuery` mock that branches on `queryKey[0]`, and a jsdom render — to assert that an input's value becomes empty. Cheaper alternatives, in order of laziness:
   - Render just `ProxyBillProcedures` with the minimum default values needed for the add path (or extract `handleAdd` into a pure reducer you can unit-test).
   - Render the component, call its `handleAdd` via the search-input + click flow, and assert state via a `data-testid` on the input rather than re-querying `getByPlaceholderText`.
   The current test is correct in outcome, but the maintainer cost (re-importing the full `CreateProxyBillSchema` shape every time the schema grows) is a real drag.

2. **`opd` submodule pointer bumped with no description.** The diff bumps `src/app/(dashboard)/opd` from `b9e2dd73f` → `622e564de`. The PR body says nothing about OPD. Either:
   - The bump is required for the OT typecheck/build (e.g. a shared type the OT import now resolves), in which case say so in the description and ideally link the OPD commit.
   - Or it's an accidental `git submodule update` mixed into a focused fix. If unrelated, drop it from this PR.

### Low / Nit

1. **`useQuery` mock branches on `queryKey?.[0] === "procedure"` — fragile and misleading.** The test doesn't actually exercise the procedure query semantics (no await on `useQuery`, no loading-state assertion). The `doctors` branch is dead code for this test — the test never adds a procedure with a doctor. Drop the `doctors` mock entirely; it's only there because `ProxyBillProcedures` may fetch it, but if the search-input clear path doesn't touch doctors, don't pretend to cover it.

2. **No PR description of where `ProxyBillProcedures` is consumed.** Two sentences explaining the call sites (and confirming the UX is correct for each) would make this a 5/5 instead of a Request-changes. The fix is small but the blast-radius question is the only thing reviewers can't infer from the diff.

## Recommendation
1. Confirm `setSearchedPackage("")` after add is the right UX for every consumer of `ProxyBillProcedures`, not just OT.
2. Move the test next to the source: `src/app/(dashboard)/shared/proxy-bill/features/components/proxy-bill-procedures/__tests__/`.
3. Add a test for the duplicate-add early-return path (search input should NOT clear on duplicate).
4. Drop the `doctors` query mock — dead in this test.
5. Drop the `opd` submodule bump unless it's load-bearing for the fix; if it is, explain it in the description.
6. Optional: shrink the test scaffolding (a `data-testid` on the search input + minimum `defaultValues` would cut ~60 lines).