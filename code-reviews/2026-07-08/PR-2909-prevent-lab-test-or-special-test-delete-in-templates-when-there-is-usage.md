# Code Review: PR #2909 — Prevent lab test or special test delete in templates when there is usage
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-27/lab-template-ui-86ey0602u` → `development`
**Files changed:** 5 (+83 / -2)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-08
**ClickUp:** https://app.clickup.com/t/9018849685/86ey0602u

## Summary
Adds a "delete-blocked when in use" guard to the lab template editor for both regular lab tests and microbiology (special) lab tests.

- `LabTemplateRepository.findCategoriesByTemplateId` now also selects `labTest.serviceId` and builds a `testUsageMap: Record<labTestId, boolean>` by checking whether any `LabService` row exists with the same `serviceId` (`LabTest.serviceId` is `@unique`, so this is effectively a 1:1 lookup).
- `findMicrobiologyByTemplateId` builds an analogous `specialTestUsageMap` by looking up `LabServiceItem.specialLabTestId`.
- The category services form (`lab-template-category-services.tsx`) plumbs `testUsageMap` through `LabTemplateCategories` into `handleRemoveItem` and toasts an error when the removed item's `labTestId` is flagged as in use.
- The microbiology form (`lab-template-microbiology-template-form.tsx`) destructures `specialTestUsageMap` from `initialData` and adds the same guard at the top of `handleItemRemove`.
- Types `LabTemplateWithCategories` and `LabTemplateWithMicrobiologies` gain the new map fields (`specialTestUsageMap` is optional on the latter, `testUsageMap` is required on the former).

## Verdict
**Request changes**
Score: 66/100
Critical: 0 | High: 1 | Medium: 2 | Low: 3 | Nit: 2

## Issues

### Critical
None

### High

**H1. Client-only check, no server-side enforcement — the guard is bypassable.**
The block lives entirely in the React handler; `LabTemplateRepository.upsertLabTemplate` and `upsertMicrobiologyLabTemplate` still delete `LabTemplateItem` / `LabTemplateMicrobiologyItem` rows whenever they are absent from the incoming payload, regardless of whether the underlying test is in use. The `testUsageMap` is also a single snapshot taken at initial render (`useQuery` result), so:
- Any non-React caller (server action, future API, an offline-then-online scenario, a race between two operators) goes straight through.
- Stale snapshots: a user who keeps the page open while a colleague orders the test can still remove it.
- The toast says "pending process" but the count includes every LabService/LabServiceItem ever (see M1), which compounds the staleness.

Minimum to be defensible: re-run the same `groupBy` against `labService` / `labServiceItem` inside the upsert transaction (or as a pre-check that throws `AppError`), and either 409 from the server action or pass an explicit `409 LAB_TEST_IN_USE` through. The UI guard then becomes a UX nicety, not a load-bearing check.

### Medium

**M1. "Pending process" check counts completed and cancelled lab services.**
`testUsageMap` is built as `labService.groupBy({ by: ["serviceId"], where: { serviceId: { in: serviceIdList } }, _count: true })` with no status filter. The error toast tells the user there is a "pending process" even when the only matching `LabService` rows are fully `DELIVERED` (or `CANCELLED` — note `cancelRemark` exists in the model). This blocks legitimate template edits whenever a test has ever been ordered.

Same issue for `specialTestUsageMap` (`LabServiceItem` likewise has status fields including `verificationStatus` and `labReeportStatus`).

The matching intent of the ticket is "in flight" only. Filter on at least one non-terminal status, e.g. `collectStatus != CANCELLED AND labReportStatus IN (TOCOLLECT, VERIFIED, PRINTED)` — or whichever subset the business treats as blocking. Confirm the exact definition of "pending" with the ticket author before merging.

**M2. Type asymmetry between the two usage maps.**
`LabTemplateWithCategories.testUsageMap` is required (`Record<string, boolean>`); `LabTemplateWithMicrobiologies.specialTestUsageMap` is optional (`Record<string, boolean>`). The microbiology form works around this with `const { specialTestUsageMap = {} } = initialData || {};`, but the category form does not — if the server ever returns a `LabTemplateWithCategories` without a `testUsageMap` (older API consumer, or a typing regression), `handleRemoveItem` would throw on `testUsageMap[labTestId]`.

Pick one: either make both required at the server boundary and drop the `= {}` default, or make both optional with consistent defaults.

### Low / Nit

**L1. Two near-identical "build a usage map" branches in the repository can collapse.**
`findCategoriesByTemplateId` and `findMicrobiologyByTemplateId` both contain the same two-branch pattern: empty list → empty map, non-empty list → groupBy → Set → Object.fromEntries. A 6-line helper (`buildUsageMap(ids, table, fk)`) would remove ~25 lines of duplication. Not required, but worth noting given the second copy is brand-new in this PR.

**L2. The microbiology `handleItemRemove` reads `currentItems[fieldIndex]` before the `fieldIndex === -1` guard.**
`fields.findIndex(...)` can return `-1` if the sectionItem has been removed out-of-band; `currentItems[-1]` is `undefined`, the optional chain saves us, and `remove(-1)` is a no-op — but the new pre-guard still runs and toasts nothing. Pre-existing minor issue, surfaced by this PR; consider asserting `fieldIndex >= 0` once and returning early.

**L3. `Object.fromEntries(labTests.map(...))` then re-walking it to read `serviceId` is doing two passes where one would do.**
The first loop builds the map; the second loop (`labTests.map((test) => [test.id, usedServiceIds.has(test.serviceId)])`) already has access to the same `labTests` array. You can build the usage map in the same `labTests.map` that builds `labTestMap`, or simply not materialise `testUsageMap` at all and look up `usedServiceIds.has(test.serviceId)` on the client (one Map sent instead of N keys). Either is fine; the current shape just ships N keys where 0–1 would suffice.

**N1. The diff comment says "Check if this specific test is used" and "Block deletion if the test is used" — both are pure narration of the next line.** Safe to drop; the function name and the toast already say it.

**N2. Filename typo carried forward (not in diff).** `lab-template.reporitory.ts` — repository is misspelled in the file name. Out of scope for this PR, but worth a one-line follow-up rename PR so future greps don't fail.

## Recommendation
1. Decide with the ticket author what "in use" / "pending process" means precisely (which status fields, which combinations) and apply that filter to both `groupBy` queries — fix M1.
2. Move the enforcement server-side into `upsertLabTemplate` / `upsertMicrobiologyLabTemplate` (or a shared `assertNotInUse` helper called from both) and return a typed error the action layer maps to a 409. The UI guard then becomes a fast-path UX layer, not the only line of defence — fix H1.
3. Align the two usage-map types (both required at the boundary, with consistent defaults at the call site) — fix M2.
4. Optional cleanup: extract the `buildUsageMap` helper and collapse the double pass in the lab-tests branch (L1/L3).