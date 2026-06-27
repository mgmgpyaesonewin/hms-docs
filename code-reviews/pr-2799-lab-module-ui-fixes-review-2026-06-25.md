# Code Review: PR #2799 — Fix lab module wrong UI

**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41 (Pyae Phyo Zan)
**Branch:** `issue/ppz/25/lab-module-issue-86exzr2jd` → `development`
**Files changed:** 15 (+1010 / -1096) — large
**Reviewer:** code-reviewer skill (independent re-review)
**Date:** 2026-06-25
**ClickUp tickets:** [9018849685/86exzr2jd](https://app.clickup.com/t/9018849685/86exzr2jd), [86ey025p8](https://app.clickup.com/t/9018849685/86ey025p8)
**Figma:** [Figjam — HMS Sprint 20](https://www.figma.com/board/j3nWtYER1wNJxs9gZurWKd/Figjam---HMS--Sprint-20-?node-id=2270-202429)
**PR URL:** https://github.com/MyanCare/Ycare-HMS/pull/2799

## Summary

This is a **2100-line, 15-file rewrite** of four lab pages (`lab-acknowledge`, `lab-result-entry`, `lab-sample-collection`, `lab-test-done`, `lab-testing`) and their shared repositories. The headline change is "fix wrong UI," which on the surface means replacing two separate form components (a normal-services form and a microbiology-services form) with a single unified form on each page. Underneath that, the diff:

1. Replaces the dual-selection pattern (`microbiologySelection` + `normalSelection`) with a single `useServiceSelection` for all services.
2. Moves the "warn about pending items" filter from `acknowledgeStatus === "TOCOLLECT"` to `(acknowledgeStatus === "TOCOLLECT" && collectStatus !== "CANCELLED")` to suppress warnings for cancelled samples.
3. Adds a microbiology-template validation block that cross-checks each selected microbiology item against the lab group of its parent service.
4. Back-writes per-item `acknowledgeStatus` / `testDoneStatus` / `resultEntryStatus` in the repositories (was previously only on the parent `labService`).
5. Tightens the `hasEmptyResults` / `isPending` derivation in `enter-results/page.tsx` to avoid emitting them while the templates are still loading.

The diff's name ("Fix wrong UI") undersells the scope. This is a substantive architectural change to the lab workflow with at least one critical clinical-data-integrity risk in the new microbiology lab-group validation, plus several reliability and security concerns that the diff does not call out.

## Verdict
**Request changes**
Score: 48/100
Critical: 1 | High: 6 | Medium: 7 | Low: 5 | Nit: 4

## Strengths

- **`lab-result-entry/[id]/enter-results/page.tsx:96-127`** — `hasEmptyResults` and `isPending` are now `useMemo`-wrapped and skip computing while templates are loading. This avoids a transient "all results empty" flash on first paint, which previously caused the submit button to flicker between disabled and enabled.
- **`lab-result-entry/[id]/enter-results/page.tsx:427-434`** — `useEffect` now no-ops while `isLoading` is true (passes `{ hasEmptyResults: false, isPending }` instead). Same fix as above, applied at the prop-emit boundary. Subtle but correct.
- **`lab-acknowledge/[id]/page.tsx:631-720`** — the unified single-selection model (`selection.getSelectedServiceIds()` for everything) is simpler than the dual-selection model it replaces. For pages where microbiology and normal services co-exist on the same patient, this removes a real UX foot-gun (the old code could let the user select "acknowledge" for normal items and "de-acknowledge" for microbiology items in the same click — confusing and error-prone).
- **`lab-acknowledge/[id]/page.tsx:730-733`** — extending the warn-message filter to exclude `collectStatus === "CANCELLED"` is the right fix for cancelled samples (otherwise the user sees a misleading "X still pending" warning after they've explicitly cancelled).
- **`lab-result-entry.repository.ts:874-887`** — the new `getMicrobiologyTemplateItems()` shape includes `specialLabTest.labTestMappings`, which is the data the new validation block needs. The repository change is correctly aligned with the page-level addition.
- **`lab-test-done.repository.ts:271-283`** and **`lab-testing.repository.ts:271-283`** — back-writing per-item `resultEntryStatus` / `testDoneStatus` is a real improvement. Previously the per-item status was implicit (derived by joining against the parent's status); now it's denormalized onto the item itself, which makes the result-entry page render correctly without joining.
- **`lab-acknowledge/[id]/page.tsx:265-272`** — collapsing the dual-selection two-call API into a single `handleSubmitAction(action)` with a switch on `action` is cleaner than the old 30-line if-cascade.
- **`lab-result-entry/[id]/page.tsx:265-274`** — `selectedMicrobiologyItems = selectedServices.filter(hasMicrobiologyItems).flatMap(s => s.labServiceItem || [])` is the right shape for "give me all the microbiology items the user has selected across all parent services." The `flatMap` correctly handles the 1:N relation between `labService` and `labServiceItem`.

## Issues

### Critical

- **`src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:297-321` (in the unified diff; corresponding to `labGroupMappingMap` construction at `:192-204`) — microbiology lab-group validation uses `Map.set(item.specialLabTestId, mapping.labTestId)` which collapses a many-to-many relation.**
  The intent of the validation block is "block submission if a microbiology item is mapped to a *different* lab group than the parent service's `LabTest.id`." But `labTestMappings` is a many-to-many relation (one `specialLabTest` can be mapped to multiple `labTest` groups, and one `labTest` can be mapped to multiple `specialLabTest`s). The `map.set(item.specialLabTestId, mapping.labTestId)` call only retains the *last* mapping per `specialLabTestId`. If the same `specialLabTestId` is mapped to lab group A in row 1 of the template and lab group B in row 2, the map silently drops row 1.
  The downstream check then compares the (possibly wrong) `mappedLabTestId` against `parentService?.service?.LabTest?.id` and either falsely blocks submission (if the comparison fails coincidentally) or falsely allows it (if the comparison happens to pass).
  **Clinical risk:** a clinician clicks "Submit" on a result-entry page where one of the selected microbiology items is mapped to a different lab group than the one it's displayed under. Submission is either blocked with a misleading "X has not been added to the template yet" toast, or — worse — submission goes through and the result is stored against the wrong lab group's reference range. In a hospital lab, that means a result filed under the wrong test code.
  **Fix:**
  - Change `Map<string, string>` to `Map<string, Set<string>>` (or `string[]`).
  - Replace `mappedLabTestId !== currentLabTestId` with `!mappedLabTestIds.has(currentLabTestId)`.
  - If the special-test is unmapped *or* mapped to multiple groups none of which match, surface a *distinct* error ("Special test X is mapped to lab groups A, B but the parent service is in group C — please contact your administrator") instead of the generic "not added to template."
  - Verify the parent query includes `LabTest` on the service (Unverified §7 — if not, every microbiology item fails the check, blocking all submission; that's a critical functional regression).

### High

- **`src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:670-674` — `toast.error({ message: "Failed to submit testing action." + e })` leaks raw error objects to the UI.**
  String-concatenating `e` (an `Error`) into the toast message will produce `"Failed to submit testing action.TypeError: Cannot read properties of undefined (reading 'toLowerCase')"` if any downstream call throws a TypeError. This is the exact anti-pattern the `pr-2788` review flagged. **Fix:** `toast.error({ message: "Failed to submit testing action." })` and `console.error("handleSubmitAction:", e)` for the developer log. The same anti-pattern is present in `lab-test-done/[id]/page.tsx:574-579` and `lab-testing/[id]/page.tsx:548-553` (three sites total — fix all three in this PR or note the others as follow-ups).

- **`src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:583-590` — `router.push` is unguarded by `result.success` and runs even after a thrown error.**
  The new `handleSubmitAction` flow is: (1) validate templates, (2) call `setCheckedResultEntryItems` / `setCheckedSpecialTestResultEntryItems` to populate the Zustand stores, (3) `router.push(...)` to the `/enter-results` page. There is no `if (success)` branch — `router.push` fires regardless of whether the stores were populated correctly. The downstream `/enter-results` page reads from the Zustand stores; if the user closes the tab between `setCheckedResultEntryItems` and `router.push` (or if navigation is interrupted by a hot-reload), the stored state is left populated but the user is on a stale page; on next visit the `/enter-results` page restores the previous selection. This is a **stale-state hazard** that didn't exist in the old code (the old `handleSubmiAction` ran synchronously without splitting state-set from navigation).
  **Fix:** wrap the body in `try/finally` so on thrown error you at least `setCheckedResultEntryItems([])`; better, move the state set into the `/enter-results` page's `useEffect` mount, not the click handler. Also, add an `else { toast.error({ message: "Failed to submit testing action." }) }` branch — the asymmetry with `lab-test-done` and `lab-testing` (which both have an explicit `else { toast.error(...) }`) is a bug-shaped oversight.

- **`src/app/(dashboard)/lab/lab-result-entry/features/api/get-template-items.api.ts:24` — `getTemplateMicrobiologyItems()` may not be tenant-scoped.**
  The lab-group validation block at `lab-result-entry/[id]/page.tsx:297-321` is built from `existingMicrobiologyTemplate` (a global query for *all* microbiology templates) but is keyed on the *selected* service's `specialLabTestId`. A microbiology item belonging to **store A** can be selected on a result-entry page for **store B** (if a doctor is cross-covering), and the lookup will succeed against any microbiology template in *any* store. There is no `storeId`/`tenantId` filter on `getTemplateMicrobiologyItems()`.
  Per the project `CLAUDE.md`, every Prisma query that touches clinical data should be tenant-scoped (the OPD codebase enforces this via the HMS tenant middleware). **Risk:** a clinician in store A sees a microbiology item that is *unmappable in store A but mappable in store B*, the new template check falsely passes, and the result is entered under the wrong group's reference range. **Fix:** confirm `getTemplateMicrobiologyItems()` filters by `tenantId`/`storeId` server-side; if not, this PR is a tenant-leak regression and **must not merge** until the filter is added.

- **`src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:583-590` (and the deleted block at lines 218-219 in the old code) — Zustand store reset on mount is removed.**
  The PR removes the `useRef`-guarded `useEffect` that called `resetCheckedResultEntryItems()` and `resetCheckedSpecialTestResultEntryItems()` once per page mount. After this PR, no such reset exists — the page relies entirely on `clearSelections()` being called from the new `handleSubmitAction` *before* navigating. If the user navigates away without clicking Submit (closes tab, hits back button), the Zustand stores keep the previous selection. Next time the page mounts, `useServiceSelection` reads `selectedServices` from `watch()` of the form's hidden field, which is fine for *new* page loads, but the **store entries persist** and will be picked up by any code path that reads `useLabServiceItemsStore.getState().checkedResultEntryItems`.
  **Risk:** result-entry data leak across sessions in the same browser; on a shared workstation this is a PHI-adjacent hazard. **Fix:** restore the mount-time reset `useEffect`, or move the reset into `useServiceSelection`'s initialization.

- **`src/app/(dashboard)/shared/lab/repositories/lab-test-done.repository.ts:271-283` and `lab-testing.repository.ts:271-283` — co-mutation of `resultEntryStatus` / `testDoneStatus` is unconditional on `labServiceItem.length`, but those tables are the *microbiology* tables.**
  For "normal" lab services (`labServiceItem.length === 0`), there is no `labServiceItem` row at all — the `updateMany` will run and update zero rows. That's harmless on its own, but the bigger problem: the `resultEntryStatus` and `testDoneStatus` fields on `labServiceItem` are *only meaningful* for microbiology items. If the schema has a CHECK constraint that these fields must be one of the lab status enums (per `hms-docs/lab-module/data-model`), then the update is fine. If not, the update will set arbitrary strings. **Risk:** if the field is meant to track only the microbiology flow, mixing it into the unconditional `updateMany` is a denormalization hazard — a future query that filters by `resultEntryStatus = "ENTERED"` will get false positives from non-microbiology items. **Fix:** either (a) move the per-item updates inside an `if (microbiologyServiceIds.length > 0)` check so normal services don't pay the write cost, or (b) confirm the schema enforces that `labServiceItem` only ever contains rows for microbiology services.

- **`src/app/(dashboard)/lab/lab-acknowledge/[id]/page.tsx:265-272` — `action === "collected"` branch calls `handleDeAcknowledge`.**
  ```ts
  if (action === "acknowledged") success = await handleAcknowledge(serviceIds);
  else if (action === "deacknowledged") success = await handleDeAcknowledge(serviceIds);
  else if (action === "collected") success = await handleDeAcknowledge(serviceIds);
  ```
  The third branch is identical to the second. Either `SubmitAction` cannot be `"collected"` (in which case the dead branch should be deleted) or it can and the third branch is a copy-paste bug. **Fix:** either delete the dead branch or call the correct action; add a comment explaining the union.

### Medium

- **`src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:297-321` — O(N×M) `Array.includes` lookups inside the validation block.**
  The validation block does `existingMicrobiologyTemplateWithSpecialLabTestIds.includes(specialLabTestId)` for each selected microbiology item. With 100 template items and 50 selected items, that's 5,000 `.includes` calls. **Fix:** use a `Set<string>` for O(1) lookup:
  ```ts
  const existingMicrobiologyTemplateSet = useMemo(
    () => new Set(existingMicrobiologyTemplateWithSpecialLabTestIds),
    [existingMicrobiologyTemplateWithSpecialLabTestIds],
  );
  // later: existingMicrobiologyTemplateSet.has(specialLabTestId)
  ```
  Same fix applies to the normal-template `existingTemplateWithServiceIds.includes(labTestId)` lookup.

- **`src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:677-678` — `console.error("Error in handleSubmitAction:", e)` is new.**
  The codebase uses `winstonLogger` (per PR #2780 review); `console.error` on a client component renders to the user's browser console only and is invisible to server-side log aggregators. Replace with the project's logger, or just delete the log (the toast already informs the user).

- **`src/app/(dashboard)/lab/lab-result-entry/[id]/enter-results/page.tsx:96-127` — `normalServices` and `microbiologyServices` filter calls are not memoized.**
  `hasEmptyResults` and `isPending` are `useMemo`-wrapped, but they depend on `normalServices.length` and `microbiologyServices.length`, which are recomputed on every render via `.filter()`. The memo recomputes on every render anyway. **Fix:** memoize the filter calls (`useMemo(() => labServices.filter(...), [labServices])`), not the derived booleans.

- **`src/app/(dashboard)/lab/lab-sample-collection/[id]/page.tsx:466-469` — dead-code comment block in production.**
  ```ts
  // Check if service has microbiology items
  // const hasMicrobiologyItems = useCallback((labService: LabService) => {
  //   return labService.labServiceItem && labService.labServiceItem.length > 0;
  // }, []); // check which is microbiology template for lab test for UI (optional)
  ```
  A 5-line comment about a function that was never defined. Not exported, not called, comment says "optional." Serves no documentation purpose (the surrounding code makes the same check inline at the call site). **Fix:** delete the 5 lines.

- **`src/app/(dashboard)/lab/lab-acknowledge/[id]/page.tsx:273-274` — `queryClient.invalidateQueries` key changed from `["lab-sample-collection-by-id"]` to `["lab-acknowledge-by-id"]`.**
  The old code invalidated `lab-sample-collection-by-id` after a successful acknowledge. The new code invalidates `lab-acknowledge-by-id`. Either this is a bug fix (the old invalidation was wrong and refreshed the wrong list) or a regression (the new invalidation no longer refreshes the list-page view that lists pending samples). The list-page query key is not in the diff; the change is unverified without reading `lab-sample-collection/list/page.tsx`. **Fix:** add a comment explaining the change, or check whether both keys should be invalidated.

- **`src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:618` — `isLoadingTemplate` guard with a confusing user-facing message.**
  ```ts
  if (isLoadingTemplate || isLoadingMicrobiologyTemplate) {
    toast.error({ message: "Please wait while templates are loading..." });
    return;
  }
  ```
  The toast message "Please wait while templates are loading..." is misleading on the *second* click (by which point the templates are already loaded; the user will be confused why the toast fired again). The fix is to disable the submit button while loading, not to toast on click.

- **`src/app/(dashboard)/shared/lab/repositories/lab-acknowledge.repository.ts:279` — `updateMany` does not filter `serviceIds` to those that have `labServiceItem` rows.**
  For services without `labServiceItem` (normal services), the `updateMany` returns `{ count: 0 }` and writes `new Date()` / `userId` to zero rows — harmless but wasteful. **Fix:** filter `serviceIds` first, or accept the overhead.

### Low

- **`src/app/(dashboard)/lab/lab-result-entry/features/components/lab-service-item-result-entry-status-form.tsx:223-227` — `useMemo` for `hasEmptyResults` now depends on `formValues` AND `isLoading`.**
  `formValues = watch()` returns a new object reference on every render of the form (React Hook Form's `watch` is not memoized), so the memo recomputes on every keystroke even when the underlying values haven't changed. **Fix:** use `watch("labTestGroups")` to subscribe only to the slice needed.

- **`src/app/(dashboard)/lab/lab-sample-collection/[id]/page.tsx:1705-1712` — `usePageView` fires before any conditional returns.**
  If `useSuspenseQuery` throws, the page-view event has already fired, inflating analytics. Pre-existing but worth flagging now that the page is being rewritten.

- **`src/app/(dashboard)/shared/lab/repositories/lab-test-done.repository.ts:274` — `resultEntryStatus: status === "TESTDONE" ? "TESTDONE" : "TOCOLLECT"`.**
  Is `"TESTDONE"` a valid value of the `resultEntryStatus` enum? The data model per `hms-docs/lab-module` should confirm. If not, this throws at runtime. Worth a static check.

- **`src/app/(dashboard)/lab/lab-sample-collection/[id]/page.tsx` warn-message — does this page's `UnifiedLabServiceStatusForm` get the same `collectStatus !== "CANCELLED"` filter?**
  The diff updates the warn-message filter on 4 pages but doesn't show the sample-collection page's filter. If sample-collection's filter wasn't updated, it will show stale warnings for cancelled items (UX regression).

- **`src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:464-490` — `useServiceSelection.selectedIds` vs `getSelectedServiceIds()`.**
  The new code uses both interchangeably; the rename from "ids" to "services" in the public API is fine but the internal field is also called `selectedIds` which doesn't match. **Fix:** rename to `selectedServiceIds` for clarity.

### Nit

- **`src/app/(dashboard)/lab/lab-result-entry/features/api/get-template-items.api.ts:17-26` — the inline `TemplateMicrobiologyItem` type should be exported.**
  The shape `{ specialLabTestId, specialLabTest: { labTestMappings: { labTestId }[] } }` is now used in three places (the API file, the page's `labGroupMappingMap` build, and the result-entry validation). Hoist it.

- **`src/app/(dashboard)/lab/lab-acknowledge/[id]/page.tsx:723-729` — the warn-message filter is now duplicated across 4 pages.**
  Extract `LabWarnMessage` into a shared component under `src/app/(dashboard)/lab/features/components/`.

- **`src/app/(dashboard)/lab/lab-sample-collection/[id]/page.tsx:1669-1671` — `useDisclosure` imported and destructured.**
  Pre-existing. Not introduced by this PR.

- **`src/app/(dashboard)/lab/lab-testing/[id]/page.tsx:545` — toast success message reads "Lab Test Done Successfully" inside the testing page.**
  Pre-existing copy-paste bug; not introduced by this PR but worth flagging while the file is being rewritten.

## Unverified

The following are conditional on code not in this diff and would shift the verdict if any return "no":

1. **`get-template-items.api.ts:24` — does the server route `/api/lab-template-items/microbiology` filter by `tenantId`/`storeId`?** If not, this PR is a tenant-isolation regression (see High §3). I cannot read the route handler from this diff.
2. **`lab-sample-collection/[id]/page.tsx` warn-message — does this page's filter get the same `collectStatus !== "CANCELLED"` update?** If not, it shows stale warnings for cancelled items. The diff doesn't show that block.
3. **`useServiceSelection.selectedIds` vs `useServiceSelection.getSelectedServiceIds()` — are these the same field or different?** The new code uses both interchangeably; if they diverge, the selected-count and submit-validation paths can disagree.
4. **`lab-acknowledge/[id]/page.tsx:265-272` — does `getButtonConfig(selectedStatus)` ever return `action === "collected"`?** If yes, the third branch is a copy-paste bug; if no, it's dead code (High §6).
5. **`shared/lab/repositories/lab-test-done.repository.ts:274` — `resultEntryStatus: status === "TESTDONE" ? "TESTDONE" : "TOCOLLECT"` — is `"TESTDONE"` a valid value of the `resultEntryStatus` enum?** The data model per `hms-docs/lab-module` should confirm.
6. **`lab-result-entry.repository.ts:874-887`** — the new `getMicrobiologyTemplateItems()` shape includes `specialLabTest.labTestMappings`. Does the Prisma schema allow nested select through a relation, or is `labTestMappings` a JSON field? If it's a relation, the call works; if it's a JSON field, the nested select is wrong and the data won't deserialize.
7. **`lab-result-entry/[id]/page.tsx:312` — `parentService?.service?.LabTest?.id`** — does the query include `LabTest` on the service? Look at the Prisma include for `makeGetLabResultEntryById`. If not, the comparison is `undefined !== mappedLabTestId` and *every* microbiology item fails the check, blocking all submission. This would be a critical functional regression.

If 1 (tenant scoping) is "no," this is a P0 security issue and must not merge.

## Verification needed (Checklist)

- [ ] `getTemplateMicrobiologyItems()` filters by `tenantId`/`storeId` server-side.
- [ ] `lab-sample-collection/[id]/page.tsx` warn-message includes `collectStatus !== "CANCELLED"`.
- [ ] `getButtonConfig()` never returns `action === "collected"`, OR the third branch in `handleSubmitAction` calls the correct action.
- [ ] `lab-resultEntry.ts` Prisma query includes `LabTest` on the parent service.
- [ ] `resultEntryStatus` enum in `hms-docs/lab-module/data-model` allows the value `"TESTDONE"`.
- [ ] Mount-time Zustand reset for `useLabServiceItemsStore` / `useSpecialLabItemsStore` is restored.
- [ ] `console.error` replaced with the project's logger.
- [ ] `Map<string, string>` replaced with `Map<string, Set<string>>` for `labGroupMappingMap`.
- [ ] Dead-code comment block at `lab-sample-collection/[id]/page.tsx:466-469` deleted.
- [ ] Three `toast.error({ message: "..." + e })` sites (lab-result-entry, lab-test-done, lab-testing) replaced with sanitized messages.

## Recommendation

**Block on Critical §1 (microbiology lab-group validation Map collapses many-to-many) and the tenant-scoping check (High §3) if Unverified §1 is "no."**

The critical microbiology validation bug is a clinical-data-integrity issue — a result filed under the wrong lab group's reference range is a real patient-safety hazard. It cannot be fixed by tweaking the page; the underlying `Map.set` design must be replaced with a `Map<string, Set<string>>` (or equivalent) and the parent query must include `LabTest`.

The author should also:
- Split this PR into at minimum: (a) per-item status back-write in repositories, (b) result-entry lab-group validation, (c) UI unification per page, (d) warn-message updates. Each is reviewable on its own; 2100 LOC is a scope-creep red flag.
- Add explicit `else { toast.error(...) }` branches to `lab-result-entry`'s `handleSubmitAction` to match `lab-test-done` and `lab-testing`.
- Restore the mount-time Zustand-store reset.
- Replace `console.error` with the project's logger.
- Fix the three `toast.error` error-leak sites.

Once Critical §1 and the tenant-scoping check are resolved, the verdict moves to **Request changes** for the remaining High/Medium findings. Approve is achievable after two follow-up PRs.

## Verdict (one-line)

**Request changes (Block on tenant-scoping verification)** — Critical clinical-data-integrity regression in `lab-result-entry`'s microbiology lab-group validation (`Map.set` collapses many-to-many); multiple High-severity issues around error-message leakage, stale Zustand state, and tenant-scoping uncertainty in template lookups; 2100 LOC for a "UI fixes" PR is a scope-creep red flag that must be split before re-review.