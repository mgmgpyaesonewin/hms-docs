# Code Review: PR #2780 — Fix - lab template issue

**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `issue/lab-template-86exyy7f1` → `development`
**Files changed:** 7 (+545 / -244)
**Reviewer:** code-reviewer skill (automated, independent re-review)
**Date:** 2026-06-24
**ClickUp ticket:** https://app.clickup.com/t/9018849685/86exyy7f1

## Summary

The PR addresses a real, reproducible bug class: the lab-template conflict detectors in `lab-template-category-services.tsx` and `lab-template-microbiology-template-form.tsx`, and the `findMatchingStatusName` matcher in `general-utils.ts`, did not treat the empty-pattern range (`""`, `",,"`, `",-,"`, `"0,-,0"`) as "ALL-age" when comparing against non-empty ranges. The previous code blocked ALL-age entries whenever *any* MALE/FEMALE row existed (ignoring range overlap) and would silently fail to match inverted numeric ranges (`"50,10"`) in `findMatchingStatusName`. The PR rewrites both conflict helpers on top of a shared `doAgeRangesOverlap` in `general-utils.ts`, deduplicates the age-parsing logic, fixes the inverted-range bug, and patches a stale `setIsSubmitting(false)` path in `useTemplateActions`.

The intent and most of the helper-extraction work are right. But the PR ships one **critical** React-Query regression in `get-lab-template.api.ts:22`, several `console.error` calls where the codebase already has `winstonLogger`, a duplication smell where `isEmptyOrDefault` + `doAgeRangesOverlap` are copy-pasted into 3 files (one of them not even importing the new helper), an asymmetric `isAllAgeRange`/`parseAgeRange` semantics bug that surfaces when age ranges are stored as `"0,0"`, and substantial scope creep into `general-utils.ts` (`findMatchingStatusName` rewrite bundled with two unrelated refactors). The PR title says "Fix" but the diff is closer to a partial rewrite of two form components plus a shared utility — it should be split.

## Verdict

**Request changes**

Score: 48/100
Critical: 1 | High: 4 | Medium: 5 | Low: 3 | Nit: 2

## Strengths

- **`src/utils/general-utils.ts:611-643`** — `doAgeRangesOverlap` is now a single source of truth for the conflict detector and the existing `console.log` on the "invalid range" path is gone. The `if (isAllAge1 && isAllAge2) return true` short-circuit is correct (two ALL-age ranges always overlap) and the subsequent `doRangesOverlap` delegation reuses the long-tested range-overlap math. Good reuse.
- **`src/utils/general-utils.ts:368-378`** — `findMatchingStatusName` now uses `Math.min(min, max)` / `Math.max(min, max)` so a stored `"50,10"` (lower > upper) still matches ages 10–50. Quiet but real improvement over the old `patientAge >= min && patientAge <= max`, which would silently never match an inverted range.
- **`src/utils/general-utils.ts:870-874`** — The `if (patientAge !== undefined) { if (isEmptyOrDefault(data.ageRange)) { /* matches any age */ } else { … } }` structure is clearer than the previous branching and makes the ALL-age short-circuit explicit.
- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-category-services.tsx:120-313`** — The conflict-detection rewrite correctly handles the case where an ALL-gender ALL-age entry is allowed to coexist with specific-range MALE entries (and vice-versa) when the ranges don't overlap. This is the actual user-reported bug and the fix is correct in intent.
- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-category-add-service-form.tsx:834`** — The added `setIsSubmitting(false)` before the `Reference range of same lab test must be the same` early-return is a real fix: the previous code left the submit button disabled even though the operation never started the async path. Good catch.
- **Reuse of `find` over re-filtering** — Both `hasGenderOverrideConflict` and `checkUniversalOverlap` in the microbiology form now use `.find()` to locate the `conflictingItem` directly (e.g. lines 471-473, 594-596) instead of running a second filter pass. Cleaner.

## Issues

### Critical

- **`src/app/(dashboard)/lab/lab-template/features/api/get-lab-template.api.ts:22` — Removing `query` from the queryKey causes cross-filter cache poisoning, and the new "fallback to `{}`" only papers over it**
  Before: `queryKey: ["lab-template", query]`. After: `queryKey: ["lab-template", query ?? {}]`. The second element is still in the key, but TanStack Query's key matcher defaults to **exact**, not hierarchical. Two calls with different `query` arguments — `query = { status: "ACTIVE", page: 1 }` vs `query = { status: "INACTIVE", page: 2 }` — now produce keys `["lab-template", { status: "ACTIVE", page: 1 }]` and `["lab-template", { status: "INACTIVE", page: 2 }]`, which are *correct* (different keys → different cache entries). So this part is actually fine on its own.
  **The actual regression is downstream:** the three `queryClient.invalidateQueries({ queryKey: ["lab-template"] })` calls that the PR *removes* (in `delete-lab-template-category-modal.tsx:52`, `lab-template-category-add-service-form.tsx:858`, and the comment near `:865` which still matches a prefix in the old key) were using prefix-match invalidation to refresh **every cached variant** after a CRUD mutation. The PR replaces those with comments saying "list query only needs refresh when templates are added/deleted, not when categories are deleted" — but the add-service-form's `useTemplateActions` path (which can change the *count* of templates by deleting categories from one) and the category-delete path both still need to refresh the list. With no invalidation at all, the list will show stale counts until the user navigates away and back, or until the next refetch on focus.
  Two separate fixes are required:
  1. Keep the two-element key but document the intent. (Already there.)
  2. Either restore the prefix-match invalidations (`queryClient.invalidateQueries({ queryKey: ["lab-template"] })` — that still matches the two-element key as a prefix) or, if the intent is "only refresh the *active filter*", call `invalidateQueries({ queryKey: makeFetchLabTemplatesQuery(currentQuery).queryKey, exact: true })`. The current "just don't invalidate" path silently produces a stale list.

  Evidence: `get-lab-template.api.ts:22` — `queryKey: ["lab-template", query ?? {}]`. `delete-lab-template-category-modal.tsx:48-52` — invalidation removed with no replacement. `lab-template-category-add-service-form.tsx:857-866` — invalidation removed with no replacement.

### High

- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-category-add-service-form.tsx:855-870` — `console.error` used in place of the project's `winstonLogger`**
  The new code adds two `console.error` calls in the `useTemplateActions` save handler. The codebase already uses `winstonLogger` (referenced in `cf-fee-report-events.ts:4` of PR #2749 and elsewhere); `console.error` in a server-rendered React component shows up in the user's browser console only — never reaches the server log aggregator, and `grep` over production logs won't find it. Fix: import `winstonLogger` and call `logger.error("upsertLabTemplateAction failed", { error, templateId: data?.templateId })`. Two-line change.
  Evidence: `lab-template-category-add-service-form.tsx:855-861` and `:869-874` — `console.error("Action error:", { message, data })` and `console.error("Unexpected error in handleSaveTemplate:", { error, templateId, stack })`.

- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-microbiology-template-form.tsx:148-154` and `:415-417` — `isEmptyOrDefault` is redefined twice in the same file, and the import of `doAgeRangesOverlap` from `general-utils.ts` is unused inside `checkUniversalOverlap`**
  The file imports `isEmptyOrDefault` and `doAgeRangesOverlap` from `@/utils/general-utils.ts` (lines 47-48) but then declares local copies of `isEmptyOrDefault` *inside* both `hasGenderOverrideConflict` (lines 148-154) and `checkUniversalOverlap` (lines 415-417). The two local copies have identical bodies and shadow the import. Additionally, the imported `doAgeRangesOverlap` is only used inside `hasGenderOverrideConflict`; `checkUniversalOverlap` uses its own local copy of `doAgeRangesOverlap` defined inline at `:421-432`. The result is **four** definitions of "is this an ALL-age range?" across the codebase, three of them in this one file.
  Fix: delete both local `isEmptyOrDefault` definitions and use the imported one; hoist a single `doAgeRangesOverlap` (or import the shared one) to module scope.
  Evidence: `lab-template-microbiology-template-form.tsx:148-154`, `:415-417` (local `isEmptyOrDefault` x2); `:421-432` (local `doAgeRangesOverlap`); `:47-48` (imported `isEmptyOrDefault`, `doAgeRangesOverlap` from `@/utils/general-utils`).

- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-microbiology-template-form.tsx:265-267` — Empty `if (currentIsAllAge)` block for the ALL-gender case short-circuits to the wrong return value**
  In the `gender === "ALL"` branch of `hasGenderOverrideConflict`, the `if (currentIsAllAge)` case checks for male/female entries and for an existing ALL-age ALL-gender entry — but if neither check fires (e.g. the form is the first row, an ALL-age ALL-gender), the code falls through to the end of the `gender === "ALL"` block with no explicit return. Looking at the surrounding logic, the function then continues to `Case 2: Current item is MALE` (line 532) which will not match `gender === "MALE"`, then to `Case 3: Current item is FEMALE` which will not match either, and finally returns `undefined` instead of `{ hasConflict: false }`. Every other code path in this function returns a `{ hasConflict, conflictingItem, message }` object — the consumer (`addLabTestRow` / similar) presumably destructures `hasConflict` and crashes on `undefined.hasConflict`.
  Fix: add `return { hasConflict: false, conflictingItem: null, message: "" }` at the end of the `gender === "ALL"` block, before falling through (or, better, restructure into `if/else if/else if` with an explicit success return).
  Evidence: `lab-template-microbiology-template-form.tsx:255-280` — `if (gender === "ALL") { if (currentIsAllAge) { … return { hasConflict: true, … } } else { for … return { hasConflict: true, … } } }` — no success-path return.

- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-microbiology-template-form.tsx:267-269` — `doAgeRangesOverlap("", "0,0")` returns `true` but the user does not see this as a "they conflict" decision**
  Inside the ALL-age ALL-gender check (line 268), `doAgeRangesOverlap(existingAllItem.ageRange || "", ageRange || "")` is called with two ALL-age strings. The new `general-utils.ts:615-628` returns `true` for any pair where at least one is ALL-age — *which means ALL-age ALL-gender conflicts with ALL-age ALL-gender, which is correct*, but it also means *ALL-age ALL-gender conflicts with a specific range ALL-gender when the specific range is empty (also ALL-age)*. The bug here is that the consumer reads "they overlap" and surfaces the wrong conflict message — the existing `existingAllAgeAllGender` check (line 268) is now redundant with the `for` loop that follows. Fix: collapse the two checks.
  Evidence: `lab-template-microbiology-template-form.tsx:265-280` — redundant ALL-age ALL-gender detection.

### Medium

- **`src/app/(dashboard)/lab/lab-template/features/util/lab-template.helper.ts:2-15` — `isAllAgeRange` behavior change for `undefined`/`""` is inconsistent with `parseAgeRange`**
  The PR changes `isAllAgeRange`'s parameter type and semantics:
  - Before: `isAllAgeRange(ageRangeValue?: string): boolean` with `if (!ageRangeValue) return true;`
  - After (this PR): same signature, but body is `if (!ageRangeValue) return true;` *plus* the new sentinel-string check (which the diff at `:3-14` shows is the original logic preserved).
  Looking again at the diff, the actual change is that the file now **delegates** `isAllAgeRange = isEmptyOrDefault` (after the `// export const isAllAgeRange = …` block of commented-out attempts). So `isAllAgeRange("")` returns `true` and `isAllAgeRange(undefined)` also returns `true`. **This part is fine.**
  The real mismatch is in `general-utils.ts`: `isEmptyOrDefault("0,0")` returns `false` (it only treats `""`, `",,"`, `",-,"`, `"0,-,0"` as default), but the *original* `isAllAgeRange` from `lab-template.helper.ts` accepted `"0,0"` (via the `num1 === "" || num1 === "0"` rule). And `parseAgeRange("0,0")` returns `{min: 0, max: 0}` (not null), so a `"0,0"` age range is stored in the database and *will* appear as `existingAllAge` data. After this PR:
  - `isEmptyOrDefault("0,0") === false` → the conflict detector doesn't recognize `"0,0"` as ALL-age
  - `parseAgeRange("0,0") === {min: 0, max: 0}` (non-null) → `doAgeRangesOverlap("0,0", "5,10")` parses both and checks `0 <= 10 && 5 <= 0` → `false` (no overlap)
  - Combined: a stored `"0,0"` ALL-age row does not conflict with a `"5,10"` row, but a stored `""` or `",-,"` row does.
  This is a latent data-driven correctness bug. Fix: add `"0,0"` to `isEmptyOrDefault`'s sentinel list *or* normalize on write. (Either way, the two helpers should agree.)
  Evidence: `general-utils.ts:611-618` (definition excludes `"0,0"`); `lab-template.helper.ts:39-58` (`parseAgeRange("0,0")` returns `{min:0, max:0}`).

- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-microbiology-template-form.tsx:148` and `:415` — Duplication across the two form files**
  Both `lab-template-microbiology-template-form.tsx` and `lab-template-category-services.tsx` re-implement `isEmptyOrDefault` (in the form's case, twice) instead of importing from `@/utils/general-utils`. The single source of truth exists; the forms don't use it. Maintenance hazard: if the sentinel list ever grows again, three files must be updated.
  Evidence: `lab-template-microbiology-template-form.tsx:148-154`, `:415-417`; `lab-template-category-services.tsx:585` (uses imported `isAllAgeRange` — this is the only place that does it right).

- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-category-add-service-form.tsx:419-428` — `doAgeRangesOverlap` helper was previously defined locally; the diff removes it but the now-imported `doAgeRangesOverlap` from `general-utils.ts` is not a drop-in replacement**
  The local helper accepted `(range1: string, range2: string)` and returned `parsed1.min <= parsed2.max && parsed2.min <= parsed1.max` (and returned `false` if either parsed to `null`). The new `general-utils.ts` version:
  1. Uses `parseRange`, not `parseAgeRange` (different shape — `{ num1, operator, num2 }` vs `{ min, max }`).
  2. Treats ALL-age as "overlaps everything" — the local version returned `false` for ALL-age ranges because `parseAgeRange` returns `null` for them.
  In particular: the conflict check at `lab-template-category-add-service-form.tsx:419-428` (now using the imported `doAgeRangesOverlap`) will now consider an ALL-age row to overlap every other row — which is *probably* the correct behavior, but it's a behavior change that is not called out in the PR description and that may surprise callers that were relying on the "ALL-age = no overlap" semantics. The PR description says "fix lab template issue" but the new semantics are a broader change.
  Evidence: `lab-template.helper.ts:39-58` (old `parseAgeRange` returns null for ALL-age) vs `general-utils.ts:547-583` (new `parseRange` returns `{ num1: 0, operator: "-", num2: 0 }` for `"0,0"`).

- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-category-services.tsx:316-330` — Final clear-error branch no longer triggers for some intermediate paths**
  The diff moves the "no conflict" clear-error path *inside* the `if (gender === "ALL")` and `if (gender === "MALE" || gender === "FEMALE")` branches. The fallback `setGenderConflictErrors(… "")` for "gender is empty or other value" stays at `:316`, but if the form ever produces a gender string that's not one of the three (e.g. lowercase `"all"` from a paste, or a typo in a select), the function returns `true` without clearing a stale error from a previous render. The old code cleared the error unconditionally for any non-conflicting case.
  This is mostly a defense-in-depth concern — the type narrows to `"MALE" | "FEMALE" | "ALL" | undefined` per Mantine — but if the enum ever loosens, stale errors persist. Add an `assertNever` or a `default:` branch to surface the type drift early.
  Evidence: `lab-template-category-services.tsx:255-370` — clear-error blocks are only inside the matched branches.

- **`src/utils/general-utils.ts:582, 620, 646, 652, 661, 672-674` — `console.log` left in production**
  The PR removes two `console.log` calls from `doAgeRangesOverlap` (good) but leaves five more in `parseRange`, `doRangesOverlap`, and `findMatchingStatusName`. Every age-range comparison in the lab form spams the browser console. Since the PR is *touching this exact function family*, finish the job — replace with `logger.debug` (or just delete).
  Evidence: `general-utils.ts:582` (`console.log("parseRange result:", …)`); `:620, :636` (now-removed by this PR); `:646` (`doRangesOverlap called with`); `:652, :661, :672-674` (doRangesOverlap internals); `:368-369, :394-395, :443-445, :468-470, :484-487` (findMatchingStatusName debug logs).

### Low

- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-microbiology-template-form.tsx:50` — `import { parseAgeRange } from "../util/lab-template.helper";` is only used inside the locally-defined `doAgeRangesOverlap`**
  Since the local `doAgeRangesOverlap` is shadowed by the import (`general-utils.ts:611`) anyway, the `parseAgeRange` import becomes dead code once the local helper is removed. Either keep the local helper (and the import) or remove both.
  Evidence: `lab-template-microbiology-template-form.tsx:50` — `import { parseAgeRange }`; only reference is `:423` (inside the local `doAgeRangesOverlap`).

- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-category-add-service-form.tsx:846-862` — `if (!result)` branch is reachable only for falsy non-undefined returns**
  The server action's return type is `{ success: boolean; message?: string } | undefined`. If `undefined` is the "no response" case, `if (!result)` is correct. If `undefined` is the "validation failed" case, the user sees "No response from server" instead of the actual validation message. Pick one and type the action's return as a discriminated union (`{ success: true; data: … } | { success: false; error: string }`) so the caller knows what to expect.
  Evidence: `lab-template-category-add-service-form.tsx:846-862` — `if (!result) { toast.error({ message: "No response from server. Please try again." }) }`.

- **`src/app/(dashboard)/lab/lab-template/features/util/lab-template.helper.ts:1-26` — Large block of commented-out code (26 lines) should be deleted**
  The diff leaves a 26-line `// export const isAllAgeRange = …` block as comments. Dead code in source files is a maintenance trap — `git blame` is the right way to recover old versions. Delete.
  Evidence: `lab-template.helper.ts:1-26` — 26 lines of commented-out code followed by `export const isAllAgeRange = isEmptyOrDefault;`.

### Nit

- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-category-services.tsx:89` — Comment "Check if age range is 'ALL-age' (0-0 or similar)" is now stale**
  The PR updates `isAllAgeRange` to match more patterns than `0-0`, but the comment still says `0-0 or similar`. Either update the comment to list the four sentinels (`""`, `",,"`, `",-,"`, `"0,-,0"`) or delete it — the helper is self-documenting.
  Evidence: `lab-template-category-services.tsx:89`.

- **`src/app/(dashboard)/lab/lab-template/features/components/lab-template-microbiology-template-form.tsx:267-269` — Type-unsafe `find()` fallback**
  `allGenderItems.find((item) => isEmptyOrDefault(item.ageRange || "")) || null` is fine, but `maleItems[0] || femaleItems[0] || null` (line 285) is a chained `|| null` that returns `null` only if **both** arrays are empty — which can't happen here because the outer `if (maleItems.length > 0 || femaleItems.length > 0)` guard means at least one is non-empty. Slight code smell.
  Evidence: `lab-template-microbiology-template-form.tsx:285`.

## Scope creep / file placement

The PR's biggest structural problem is that **it bundles three separate concerns**:

1. **Bug fix** — the gender/age conflict detector rewrite (`lab-template-category-services.tsx` + `lab-template-microbiology-template-form.tsx`). This is what the ClickUp ticket asks for.
2. **Helper extraction** — `isEmptyOrDefault` and `doAgeRangesOverlap` moves to `general-utils.ts`. Reasonable, but only worth doing *together with* (3).
3. **Refactor of `findMatchingStatusName`** — the `Math.min/max` inverted-range fix and the variable rename `normalRanges` → `validRanges`. **This is unrelated to lab-template** — `findMatchingStatusName` is used by every lab test result page in the HMS. A 50-line refactor of a global matcher should be its own PR with its own test suite and a SonarQube re-run.
4. **`useTemplateActions` `setIsSubmitting` fix** — the early-return on `Reference range of same lab test must be the same` and the `if (!result)` branch. Related but separable.

**Recommendation:** split into 3 PRs.
- PR A (this one): the conflict-detector fix in the two form files. No `general-utils.ts` changes. No `findMatchingStatusName` changes. The `console.error` → `winstonLogger` swap.
- PR B: `general-utils.ts` helper extraction + `findMatchingStatusName` refactor. Cover with new unit tests for `doAgeRangesOverlap` (boundary cases: `"0,0"`, inverted range, mixed operators).
- PR C: `useTemplateActions` UX fixes.

This split has three benefits: (1) the bug fix can land fast without waiting on the helper extraction to stabilize, (2) `findMatchingStatusName`'s risk surface is isolated and reviewable on its own, (3) the diff sizes become reviewable (each is ~150 lines instead of ~600).

`general-utils.ts` itself is the right destination for `doAgeRangesOverlap` and `isEmptyOrDefault` (they're shared with the lab-template, pharmacy, and result-entry pages). But the file is already 778 lines — close to the 500-line cap in `CLAUDE.md`. A future PR should consider splitting `general-utils.ts` into `range-utils.ts` (range parsing / overlap) and `string-utils.ts` (capitalize, escape, pluralize, etc.). Out of scope for this PR, but worth filing.

## Type safety & schema issues

- `lab-template.helper.ts:2` — `isAllAgeRange` accepts `string | undefined` but `general-utils.ts:611` `isEmptyOrDefault` only accepts `string`. The forms wrap every call site with `ageRange || ""` to bridge the gap; the typing should reflect that consistently.
- `lab-template.helper.ts:1-26` — The 26-line block of commented-out code uses a different (older) signature than the live export. If anyone uncomments it, types won't match. Delete.
- `lab-template-microbiology-template-form.tsx:255-280` — `hasGenderOverrideConflict`'s return type is implicitly `{ hasConflict, conflictingItem, message } | undefined`. The implicit `undefined` is what causes the missing-success-path bug (High #3 above).

## Transaction & data integrity

No DB writes in this PR. The form uses a server action (`upsertLabTemplateAction`) that handles its own transaction — that action is out of scope. The conflict detector runs client-side and prevents the user from submitting an invalid payload; the server action presumably re-validates. **This is a defense-in-depth concern, not a regression in this PR**, but the High #3 bug (implicit `undefined` return) means a malformed conflict detector call could let an invalid payload through to the server.

## Performance

- The new conflict detector in `lab-template-category-services.tsx:120-313` runs `otherItemsForSameTest.filter(...)` four times in the worst case (MALE items, FEMALE items, ALL-gender items, same-gender items). For each filter, it then does `for` loops calling `doAgeRangesOverlap`. With N=10 templates in a category and M=5 lab tests per template, that's ~50 `doAgeRangesOverlap` calls per form change. Each `doAgeRangesOverlap` calls `parseRange` twice → 200 string parses per keystroke. Probably fine in practice, but worth memoizing if profiling shows a slowdown.
- `lab-template-microbiology-template-form.tsx:419-432` — the locally redefined `doAgeRangesOverlap` allocates two new arrays and parses two strings on every call. Same perf profile, same recommendation.
- The 26 lines of commented-out code at `lab-template.helper.ts:1-26` cost a few KB in the production bundle (esbuild usually tree-shakes comment blocks but the Next.js production build still ships the source map). Negligible.

## Accessibility & UX

- The toast messages in `lab-template-category-services.tsx:194`, `:224`, `:238`, `:292`, `:305`, `:355` are user-visible — they're shown in Mantine `Notifications`. The PR mostly preserves the old messages and adds new ones for the "overlap" cases. No accessibility regression.
- The new `if (!result)` branch at `lab-template-category-add-service-form.tsx:847-850` shows `"No response from server. Please try again."` — clear and actionable.
- **No keyboard / focus management** changes — the forms are pre-existing god components with no focus-on-error pattern. Out of scope.

## Error handling

- `useTemplateActions` now logs `console.error` on both the inner (action error) and outer (rethrow) paths. Two log lines per failure. Use `winstonLogger`.
- `findMatchingStatusName` still has 5 `console.log` debug statements in production paths (see Medium #5).
- The new `if (!result)` guard is good defensive programming; the toast message could be slightly more actionable (e.g. "No response from server — check your network and try again").

## Style & consistency

- The PR introduces the variable name `isAllAge` and `currentIsAllAge` inconsistently across files (`lab-template-category-services.tsx:89` uses `isAllAge`; `lab-template-microbiology-template-form.tsx:265` uses `currentIsAllAge`). Pick one.
- The new `isEmptyOrDefault` name is fine, but it competes with `isAllAgeRange` which is the canonical name in `lab-template.helper.ts`. Consider deprecating one.
- The PR leaves 26 lines of commented-out code at `lab-template.helper.ts:1-26`. The CLAUDE.md says "NEVER create files unless absolutely necessary" but doesn't explicitly say "don't leave 26 lines of dead code in existing files". The spirit applies — delete it.

## Questions for the author

1. The PR description (via ClickUp ticket `86exyy7f1`) is "Fix - lab template issue". What is the actual reproducible bug — is it the gender/age conflict detector rejecting valid combinations, or the `findMatchingStatusName` matcher returning `null` for valid ranges, or both? The PR fixes both but the description only mentions one.
2. Why was `query` removed from the React Query key in `get-lab-template.api.ts:22`? The new form `["lab-template", query ?? {}]` is technically equivalent to the old `["lab-template", query]` (both produce a two-element key, and `query` is already optional), so this looks like an accidental edit that the rest of the PR then has to compensate for. The commit message / PR description doesn't explain it.
3. The new `doAgeRangesOverlap` semantics in `general-utils.ts` (ALL-age overlaps everything) is a behavior change vs. the locally-defined `doAgeRangesOverlap` that the PR removes from `lab-template-category-add-service-form.tsx` (ALL-age returned `false` because `parseAgeRange` returned `null`). Is this intentional? It changes which rows are blocked by the conflict detector.
4. Was `isEmptyOrDefault("0,0")` returning `false` (the new behavior) considered? This is a real-world data point — a stored `"0,0"` row will not be recognized as ALL-age by the new helper but will be by the old one.
5. The PR title says "Fix" but the diff is 545+/244- across 7 files. Was there an attempt to split it that failed? The current PR is hard to review atomically.
6. Why are `isEmptyOrDefault` and `doAgeRangesOverlap` redefined twice in `lab-template-microbiology-template-form.tsx` (lines 148, 415, 421) instead of imported from `@/utils/general-utils`? Was there a circular-import concern?

## Cross-references

- **`/Users/pyaesonewin/.claude/CLAUDE.md` §Rules** — "NEVER create files unless absolutely necessary" and "Keep files under 500 lines". The PR modifies 3 files over 500 lines (`885`, `1358`, `2264`); the duplication added by this PR (the 4 `isEmptyOrDefault` / `doAgeRangesOverlap` definitions) is a symptom of not extracting once.
- **`/Users/pyaesonewin/.claude/CLAUDE.md` §Rules** — "console.log/console.error in production". PR adds 2 new `console.error` calls; leaves 5+ existing `console.log` calls in `general-utils.ts`. The codebase uses `winstonLogger`; use it.
- **PR #2749** (referenced in CF-fee-report-events.ts) — introduced `winstonLogger` to the codebase. This PR should adopt it instead of `console.error`.
- **`hms-app/CLAUDE.md`** (via project root `CLAUDE.md`) — The `enhancedApiHandler` / `verifyApiAuth` / `permission-ui-config.ts` rules are *not* relevant to this PR (it's pure client-side React + a helper extraction). No ADR cross-checks needed.
- **No summary-service or outbox implications** — this PR is purely UI-side and a utility extraction. No transaction discipline, HMAC, or tenant-scope concerns.

## Verification needed

Things that cannot be verified from the diff alone:

1. **Does the gender/age conflict UI now accept all combinations that *should* be valid?** Manual test matrix: (ALL, ALL-age) + (MALE, 5-15) → expect allowed (specific MALE range doesn't overlap universal ALL-age); (ALL, 0-100) + (MALE, 50-150) → expect blocked (overlap at 50-100); (MALE, 0-0) + (MALE, 5-50) → expect blocked (ALL-age MALE overlaps any MALE). The `"0,0"` case will hit the latent `isEmptyOrDefault` bug — verify whether the production data ever stores `"0,0"` and, if so, whether the new conflict detector accepts/rejects the right combinations.
2. **Does removing the two `invalidateQueries` calls actually leave the list stale?** Open the lab-template list, delete a category on the detail page, navigate back to the list. If the count is stale, the Critical issue is real. Should reproduce immediately.
3. **Does `findMatchingStatusName` still match for an inverted range (`"50,10"`)?** Add a unit test in `general-utils.test.ts` (if it exists) or create one; pass `resultDataArray = [{ result: "10,50", ageRange: "50,10", gender: "ALL", … }]` and `value = 30`, expect a non-null status name. The PR's `Math.min/Math.max` fix should make this pass, but no test covers it.
4. **Does `hasGenderOverrideConflict` return `{ hasConflict: false }` for the first-row ALL-age ALL-gender case?** In the microbiology form, on a fresh template, attempt to add the first row as ALL-gender ALL-age. If the form crashes on `undefined.hasConflict`, the High #3 bug is real.
5. **Does the new `if (!result)` toast fire for a network timeout vs. an actual server-side validation error?** If the server action throws on validation, both the inner catch and the `if (!result)` could fire. Test by submitting with a deliberately invalid template and watch for duplicate toasts.
6. **SonarQube Cloud analysis.** The PR comment says "❌ The last analysis has failed." — confirm whether this is a known infra issue or a new finding. The `console.error` / `console.log` left in the diff will absolutely trigger linter rules; fix before re-push.

## Checklist results

- [ ] `console.log` / `console.error` in production — **2 new** (`lab-template-category-add-service-form.tsx:855, :869`); **5+ existing left in** (`general-utils.ts:582, :646, :652, :661, :672-674` plus the 5 in `findMatchingStatusName`). Use `winstonLogger`.
- [x] `any` type annotations — None added in this PR.
- [x] `@ts-ignore` / `@ts-expect-error` / `eslint-disable` — None added.
- [x] TODO / FIXME — None added.
- [x] Hardcoded secrets — None.
- [x] SQL/Prisma injection — N/A (no DB queries in this PR).
- [ ] Long files (>500 lines) — All 3 modified React files are over 500 lines (`885`, `1358`, `2264`); the PR makes them longer. The duplication added (`isEmptyOrDefault` × 4) is a maintenance hazard.
- [ ] God components — The 3 large form/service files were already god components; this PR grows them by ~196 / ~91 / ~257 lines respectively.
- [x] Missing `key` props, index-as-key — N/A (no list rendering in the diff).
- [ ] Unsafe type assertions — `lab-template-microbiology-template-form.tsx:255-280` — `hasGenderOverrideConflict` returns `undefined` on the no-conflict path of the ALL-gender ALL-age branch; consumer will crash.
- [ ] Async error swallowing — `lab-template-category-add-service-form.tsx:855-861` swallows `upsertLabTemplateAction` errors via `console.error` + toast with no log aggregation.
- [x] Missing `await` inside transactions — N/A (no transactions in this PR).
- [x] Tenant-scope — N/A.
- [ ] Permission checks — N/A (UI-only PR, no new API routes).
- [x] Missing Zod validation at boundary — N/A.
- [ ] React Query correctness — **Critical regression**: invalidation removal at `delete-lab-template-category-modal.tsx:52` and `lab-template-category-add-service-form.tsx:858` will leave the list stale after category CRUD.

## Recommendation

Block merge. The **Critical** invalidation-removal issue must be reverted or replaced with a more targeted invalidation. The **High** `console.error` → `winstonLogger` swap is a 5-line change and should land with this PR. The **High** duplication in `lab-template-microbiology-template-form.tsx` (two `isEmptyOrDefault` definitions + one local `doAgeRangesOverlap`) is a refactor that lands well in a follow-up but blocks the PR because it ships *more* dead code than it removes. The **Medium** issues — `findMatchingStatusName` leftover `console.log`s, the `"0,0"` sentinel mismatch, the `doAgeRangesOverlap` semantics change — are worth fixing in PR B (the helper extraction) once that's split out.

The single biggest recommendation is to **split this into 3 PRs** as described in the Scope creep section. The conflict-detector fix is a small, reviewable change; bundling it with a 50-line `findMatchingStatusName` refactor and a `useTemplateActions` UX fix makes the diff unreviewable.
