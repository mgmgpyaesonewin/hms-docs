# Code Review: PR #2821 — Fix Lab activities not showing nothing issue

**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41 (Pyae Phyo Zan)
**Branch:** `issue/ppz/sprint-25/lab-module-activity-modal-86exzryg1-86exzrjvz-86exzr705-86ey01n4x` → `development`
**Files changed:** 1 (+1 / -3)
**Reviewer:** code-reviewer skill (independent re-review)
**Date:** 2026-06-26
**ClickUp tickets:** [9018849685/86ey01n4x](https://app.clickup.com/t/9018849685/86ey01n4x), [86exzryg1](https://app.clickup.com/t/9018849685/86exzryg1), [86exzrjvz](https://app.clickup.com/t/9018849685/86exzrjvz), [86exzr705](https://app.clickup.com/t/9018849685/86exzr705)
**PR URL:** https://github.com/MyanCare/Ycare-HMS/pull/2821

## Summary

The PR changes a single URL in the lab-activities client wrapper. `getLabServiceActivities` previously called `GET /api/lab-service-items/{id}/activities` (an endpoint that exists and is used by the per-`labServiceItem` flow), and now calls `GET /api/lab-service-activities/{id}` (a different endpoint that exists at `src/app/api/(lab)/lab-service-activities/[id]/route.ts` and is backed by `LabActivityService.getLabServiceActvities`).

The diff also collapses the multi-line generic into a single line (cosmetic).

**Root cause hypothesis (high confidence).** The old route returned `ActivityLog[]` (per-entity activity logs) shaped as `ApiResponse<ActivityLog[]>` server-side, but the caller typed its response as `ApiResponse<LabServiceActivity>` (a single object with `serviceName` + `labServiceAudits[]`) and the consumer at `lab-acitvities.tsx:103` dereferences `typedActivities?.labServiceAudits` and `typedActivities?.serviceName`. With the old route, `res.data.result` would have been an `ActivityLog[]` array, so `typedActivities?.labServiceAudits` was `undefined` and `typedActivities?.serviceName` was `undefined` — the modal rendered the "No activities found." row. The PR title's "not showing nothing" appears to be a typo for "not showing anything," which matches this symptom.

The new route calls `labActivityService.getLabServiceActvities(labServiceId)` → `labActivityRepository.getLabServiceActvities(labServiceId)`, which returns `{ serviceName, labServiceAudits }` (the `LabServiceActivity` shape the caller actually wants). The `serviceId` prop in the caller is sourced from `labService.service.id` (a `LabService` id, not a `LabServiceItem` id), which is what the new route expects. So the new call site is correct end-to-end.

The most important remaining risk: **the old endpoint `/api/lab-service-items/{id}/activities` is still present and is still called by `getLabServiceItemActivities`** (per-`labServiceItem` modal flow). The fix does not remove the old endpoint, and the two endpoints have similar but not identical URLs — this is a sharp edge for the next maintainer. There is also a naming-collision risk: a future endpoint added under `lab-service-items/{id}/activities` that does return the `LabServiceActivity` shape would silently re-introduce the original bug (or the inverse). This is not a blocker, but it is the structural root cause that this PR doesn't address.

## Verdict

**Approve with suggestions**

Score: 72/100
Critical: 0 | High: 1 | Medium: 3 | Low: 3 | Nit: 3

The one-line fix is correct in the narrow sense — the new endpoint exists, accepts the id the caller is passing, and returns the shape the caller expects. The High issue is about the lack of test coverage for a function that already broke silently in production. The Medium issues are structural (naming, two near-identical endpoints) rather than functional.

## Strengths

- **`get-lab-service-activities.api.ts:8-11` — the URL change is the right call.** The new endpoint `/api/lab-service-activities/[id]` is the one that returns the `LabServiceActivity` shape the caller expects (`{ serviceName, labServiceAudits }`). The old URL was returning an array of `ActivityLog` objects, which the consumer at `lab-acitvities.tsx:103` was treating as a single object — that is the actual bug, and the new URL aligns client and server contracts.
- **`lab-acitvities.tsx:67-68, 74` — the `enabled` gating is correct.** `shouldFetchServiceActivities` requires both `serviceId` and `!labServiceItemId`, so this query only runs when the modal was opened in the "by service" mode. The `shouldFetchItemActivities` branch goes to the other (correct) endpoint, so the two paths do not collide at the network level. The fix preserves that separation.
- **`lab-activity.repository.ts:15-73` — the repository is well-structured for the new use case.** `getLabServiceActvities` returns `{ serviceName, labServiceAudits }` and uses `Promise.all` for the service name lookup and audit fetch, so the new endpoint does not introduce an N+1.
- **The author caught a real user-facing bug.** The "not showing nothing" symptom (modal always says "No activities found") is a silent failure with no error in the UI — exactly the kind of issue that's hard to triage without a tight type contract, and exactly the kind a one-line URL change can fix.
- **The branch name includes the four ClickUp tickets**, which keeps the work traceable to the sprint board.

## Issues

### High

- **No test for the new URL.** `getLabServiceActivities` had no test before this PR and still has none. This is the function that silently broke in production (the modal rendered "No activities found." for every service) and that the PR is fixing. A regression here would be invisible — the modal would simply show the empty-state row again. **Fix:** add a unit test (with `msw` or equivalent mock) that asserts `getLabServiceActivities(serviceId)` calls `GET /api/lab-service-activities/{serviceId}` and unwraps `res.data.result` into the `LabServiceActivity` shape. The same fix should be applied to `getLabServiceItemActivities` (`get-lab-service-item-activities.api.ts:6-10`) which has the same shape — `ActivityLog[]` not `ActivityLog` — and the same lack of test. Two thin wrapper functions, two missing tests, one of which has already broken once. If the project already has an `apiClient` mock pattern (e.g. in `src/lib/api-client` tests), the test is a five-line file.

### Medium

- **`get-lab-service-activities.api.ts:6-12` — the `.then((res) => res.data.result)` silently swallows HTTP errors.** The current call site does `apiClient.get(...).then((res) => res.data.result)` with no `.catch` and no `await`. A 404 (e.g. the `labServiceId` has been deleted) becomes `undefined`, and the consumer at `lab-acitvities.tsx:94-96` happily types it as `LabServiceActivity | undefined` and renders the empty state — same symptom as the original bug. The author may want to consider:
  - whether a deleted-service case should be surfaced as an error to the user (currently it's indistinguishable from "no activities"),
  - whether `enabled: !!serviceId` is enough (it isn't — it only checks the *string is truthy*, not that the service still exists).
  Note: this is pre-existing behavior, not introduced by the PR. Flagging because the PR is the right place to address it now that the function is being touched.

- **The two endpoints `/api/lab-service-items/[id]/activities` and `/api/lab-service-activities/[id]` exist side-by-side and have dangerously similar URLs.** One returns `ActivityLog[]` (per `labServiceItem`); the other returns `{ serviceName, labServiceAudits[] }` (per `labService`). The difference between `items/{id}/activities` (singular `/activities` suffix, child of a service item) and `service-activities/{id}` (the noun is "activity", not a sub-resource of an item) is not obvious from the URL alone. A future maintainer writing a new client wrapper is one mistyped character away from re-introducing this exact bug. **Fix (not blocking, but worth a follow-up ticket):** rename one of the two paths so the noun distinction is obvious — e.g. `/api/lab-service-items/{id}/activity-logs` (mirrors "ActivityLog" model name) vs. `/api/lab-services/{id}/service-audits` (mirrors "LabServiceAudit" model name). This is a refactor that touches multiple files and the sprint plan; flag it for a follow-up.

- **Branch name references four ClickUp tickets; the diff addresses one symptom in one function.** The branch name is `.../lab-module-activity-modal-86exzryg1-86exzrjvz-86exzr705-86ey01n4x`, and the PR body presumably lists all four tickets. The diff is a single URL change. The other three tickets (whatever they are) are not addressed by this diff. **Action:** the author should confirm whether the other three tickets are independent, or whether they were intended to be bundled. If they are independent, splitting into one branch per ticket is cleaner; if they were supposed to be in this PR, the diff is incomplete.

### Low

- **`get-lab-service-activities.api.ts:6` — function name is plural but the endpoint returns a single object.** `getLabServiceActivities` returns one `LabServiceActivity` (with `labServiceAudits` as the only plural part). The old URL was per-`labServiceItem` and returned a list, so the plural made more sense. Now that the function returns a single object, `getLabServiceActivity` (singular) would be more accurate. The React Query key `["lab-service-activities", id]` is also plural; consider renaming to `["lab-service-activity", id]`. Note: this is a public name in the caller (`lab-acitvities.tsx:73` uses `makeGetLabServiceActivities(serviceId!)`), so the rename is a 2-file change.

- **`lab-activity.service.ts:11,18` and `lab-activity.repository.ts:15,75` — backend uses the misspelling `Actvities` (missing 'i').** `getLabServiceActvities` and `getLabServiceItemActvities` (the new endpoint also has it: `route.ts:11`). The frontend function is correctly spelled `getLabServiceActivities`. This typo has now been carried into a new API route. **Fix:** the file-level rename is mechanical (find/replace, check for any test that imports the name), and would prevent the typo from being copied into the next endpoint added in the same area.

- **The `.then((res) => res.data.result)` returns `LabServiceActivity | undefined`, but the type signature is `Promise<LabServiceActivity>`.** Because `ApiResponse.result` is typed as `T` (not `T | undefined` — see `api-response.ts:3`), TypeScript currently believes the function always returns a `LabServiceActivity`. If the server ever returns a 200 with `result: null` (or the field is missing), the runtime value is `undefined` and `lab-acitvities.tsx:103, 156` will throw on `.labServiceAudits` / `.serviceName`. This is pre-existing; flagging because the PR is the right place to tighten it. **Fix:** either change `ApiResponse.result` to `T | null` and update the consumer, or change `getLabServiceActivities` to `Promise<LabServiceActivity | undefined>` and add `?? null` in the consumer.

### Nit

- **`get-lab-service-activities.api.ts:8-10` — single-line generic.** The diff collapses
  ```ts
  .get<
    ApiResponse<LabServiceActivity>
  >(`/api/lab-service-items/${id}/activities`)
  ```
  into
  ```ts
  .get<ApiResponse<LabServiceActivity>>(`/api/lab-service-activities/${id}`)
  ```
  Prettier `printWidth: 80` would have kept the original multi-line break (the line is over 80 chars at `printWidth: 80` only if the URL is included — let me count: `.get<ApiResponse<LabServiceActivity>>(\`/api/lab-service-activities/${id}\`)` = 12 + 1 + 17 + 1 + 32 + 1 = ~64 chars, well under 80). The collapse is correct; this is just confirming it's not a manual violation of project style. The other wrapper `get-lab-service-item-activities.api.ts:8` still uses the same single-line style for the same reason, so the project is consistent on this.

- **`lab-acitvities.tsx:2` — import name is `getLabServiceActivities` but the file the function lives in is `get-lab-service-activities.api.ts` (consistent) and the file the import is in is `lab-acitvities.tsx` (note the typo: `acitvities` not `activities`).** The misspelled file name is pre-existing; flagging because the typo is now in two files. Worth fixing when the file is next edited (rename the file, update the import).

- **The PR title "Fix Lab activities not showing nothing issue" has a typo.** "nothing" should be "anything." Not a blocker, but it's a public commit message and a typo in the only user-visible string in the PR.

## Unverified

- **The new endpoint's behavior under `labServiceId = undefined` or an empty string.** `lab-acitvities.tsx:74` gates the query on `shouldFetchServiceActivities && opened`, and `shouldFetchServiceActivities` is `!!serviceId && !labServiceItemId` (line 67). So the query is skipped when `serviceId` is falsy. But `lab-acitvities.tsx:73` does `makeGetLabServiceActivities(serviceId!)` — the `!` non-null assertion is true at this point, but TypeScript doesn't know that. The runtime is safe; the type is loose. Not blocking.
- **Whether the new endpoint was added in this PR or in a previous one.** I traced the file at `src/app/api/(lab)/lab-service-activities/[id]/route.ts` and the function `labActivityService.getLabServiceActvities` in the service; both are present, but I did not check git blame for either. The PR title says "Fix" (not "Add endpoint"), so I assume the endpoint was added in a prior commit. If the endpoint and the fix were introduced in the same PR, the diff is incomplete (the route file is missing from the change list).
- **The other three ClickUp tickets.** I did not fetch any of them. The branch name lists four ticket IDs; the diff addresses one. Whether the other three are related, sequential, or independent is not visible from the diff alone.
- **`/api/lab-service-items/[id]/activities` returns `ActivityLog[]` server-side.** I read the route file at `src/app/api/(lab)/lab-service-items/[id]/activities/route.ts` and it calls `labActivityService.getLabServiceItemActvities`, which calls `findLabServiceItemIdActivitiesByEntityIds`, which returns `ActivityLog[]`. The old client code typed the response as `ApiResponse<LabServiceActivity>` and the new one types it the same way. The mismatch is the bug. Confirmed by code reading, not by running the API.

## Verification needed (Checklist)

- [ ] **Add a unit test for `getLabServiceActivities`** that asserts the URL is `/api/lab-service-activities/{id}` and the response is unwrapped from `res.data.result`. (This is the High issue; the function has now broken once and remains untested.)
- [ ] **Confirm whether the new endpoint `lab-service-activities/[id]/route.ts` was added in this PR or a prior one.** If it was added in this PR, the diff is incomplete (the route file is not in the change list). If it was added in a prior PR, the PR description should cite that PR for traceability.
- [ ] **Address the other three ClickUp tickets** (`86exzryg1`, `86exzrjvz`, `86exzr705`). Either bundle the work into this PR (if the changes are in flight) or split the branch into one branch per ticket (if they are independent).
- [ ] **Decide whether to rename one of the two near-duplicate endpoints** to make the noun distinction obvious (Medium issue, follow-up ticket).
- [ ] **Decide whether the `.then((res) => res.data.result)` should propagate HTTP errors** (Medium issue). The current behavior is that a 404 renders the empty state, which is indistinguishable from "no activities."
- [ ] **Tighten the return type** of `getLabServiceActivities` to `LabServiceActivity | undefined` (Low issue), so the consumer can be audited for missing null-checks.
- [ ] **Fix the typo in the PR title** ("not showing nothing" → "not showing anything"). Optional but it's a public string.
- [ ] **Fix the typo in the file name** `lab-acitvities.tsx` → `lab-activities.tsx` (Nit). Pre-existing; the PR is a good moment to clean it up.

## Recommendation

**Approve with suggestions.** The fix is correct in the narrow sense — the new endpoint exists, accepts the id the caller is passing, and returns the shape the caller expects. The High issue is the missing test (which is what would have caught this bug the first time). The Medium issues are structural and would benefit from a follow-up ticket rather than blocking this PR.

The one-line URL change should land. A test for the wrapper should be added either in this PR or as an immediate follow-up before the next refactor of the lab-activities modal.
