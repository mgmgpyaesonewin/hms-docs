# Code Review: PR #2946 — Add infinty scroll and update search select shared component
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-26/cathlab-86ey3pg5q` → `development`
**Files changed:** 20 (+950 / -596)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-13
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3pg5q

## Summary

Replaces the eager-load `Select` controls in cathlab and EMR pharmacy/prescription forms with the existing infinite-scroll `SearchSelect` family. Adds `AnesthesiaTypeSearchSelect` and `UserSearchSelect` wrappers, two new `GET /api/{users,anesthesia-type}/:id` endpoints + repo/service glue, two `getUsers` / `fetchAnesthesiaTypes` API helpers under `src/components/api/`, two new hooks (`useAnesthesiaTypeSearchInfinite`, `useUserSearchInfinite`), `fetchUserById` API helper, and moves `getServices`/`getProcedures` into the shared `src/components/api/` namespace. Also adds server-side ranked search (`sortEntitiesBySearch`) to the users repository so the new `UserSearchSelect` can rank a wider pre-fetch.

## Verdict
**Request changes**
Score: 71/100
Critical: 1 | High: 4 | Medium: 5 | Low: 3 | Nit: 2

## Issues

### Critical

- **Bug: `useUserSearchInfinite` ranks an arbitrary slice that is not the searched page.** `src/app/(dashboard)/common/user-management/users/features/users-repository.ts:81` now does `take: limit === 0 ? undefined : limit * 10` and `src/hooks/use-search-select-infinite.tsx` uses `limit: PAGE_SIZE` (30), so the hook fetches 300 rows per page, then `rankedUsers.slice(0, limit)` throws away 270 rows. Worse, the slice happens *after* `sortEntitiesBySearch` ranks by `fullName`/`username`/`phoneNo`/`userId` against `search`, but the underlying query orders by `createdAt: "desc"`. Net effect: a user who searches "aung" gets the 30 most recent users in 300 fetched, then ranked and sliced — the slice is deterministic, but the rankings are computed against an unrelated pre-fetch window, so any user outside the top-300-by-creation-order never appears, even when the search matches them. The previous behavior was at least consistent (limit = the page you got); this is a correctness regression. Either rank in SQL (preferred — `WHERE ... ILIKE '%search%' ... ORDER BY <rank>`), or pass `limit: 0` and paginate from a real text-search-capable index.

### High

- **Bug: `assistantDoctors` row reuses `cardiologists` error path.** Both `cathlab-request-form.tsx` files (cathlab list and IPD service-request) replace the `Select` for `assistantDoctors.*.assistantDoctorId` with `DoctorSearchSelect`, but the `error` prop now reads `form.formState.errors.cardiologists?.[index]?.cardiologistId?.message` instead of `assistantDoctors?.[index]?.assistantDoctorId?.message`. The error message for an empty assistant doctor will never render; if a cardiologist field is also dirty the wrong field's error will appear under assistant doctors. Two files affected.

- **Inconsistency: `ClinicSearchSelect` is the only sibling that still lacks `keepSelectedItem` semantics for `value` set externally.** It wires `fetchItem` (good), but `search-select.tsx`'s new effect to "synthesize" a value when `value` is not in `allItems` only runs if `keepSelectedItem` is also true (the synthetic-item is only injected into `options` under that flag). For `clinic-search-select.tsx` callers that pass a non-null `value` from a previously-saved form (referral clinic on edit) without `keepSelectedItem={true}`, the select will show the value but no label. `DoctorSearchSelect` and the new `UserSearchSelect` / `AnesthesiaTypeSearchSelect` callers all set `keepSelectedItem={true}`; the cathlab call sites that use `ClinicSearchSelect` do not.

- **Behavior change: cathlab `referralDoctorId` `clearErrors("referralClinicId")` lost the `referralOutType` reset.** In the original code, switching to `REFERRALOUT` cleared `referralOutType` errors implicitly because the `useEffect` was the only path that set referral state. The new inline `Radio.Group onChange` clears `referralDoctorId`/`referralClinicId` but never calls `clearErrors("referralOutType")`. Symptom: after submitting once with `referralOutType` missing and the form rejecting, switching to `REFERRALIN` and back to `REFERRALOUT` leaves the stale "Referral Out Type is required" error until you re-touch the radio.

- **Naming: `anesthiesia-type-search-select.tsx`.** Misspelled filename; will surface in code search, IDE autocomplete, and any directory listing. Renaming is a single `git mv` plus one import line update in the two cathlab forms. (The component export name itself is spelled correctly — `AnesthesiaTypeSearchSelect` — but the file name perpetuates the typo and forces the misspelled import path.)

### Medium

- **Dead commented code in three form files.** `cathlab/request-list/features/components/cathlab-request-form.tsx` keeps ~50 lines of commented imports + ~25 lines of commented `useEffect` body + ~60 lines of commented `AssistantNurseSelect` definition. `ipd/features/components/service-request/cathlab/cathlab-request-form.tsx` and `ipd-emr-prescription-form.tsx` keep similar commented-out blocks. None of this code is reachable; comment-as-history should live in the commit message, not the file. Lines 5-58 in cathlab list form, lines 4-12 of the IPD cathlab form, and the entire commented `<Select ... />` block in `ipd-emr-prescription-form.tsx:171-224` should go. The project CLAUDE says "Do what has been asked; nothing more" — this is the opposite.

- **Server route uses `enhancedApiHandler` for an id fetch — but the inner service isn't called via the service pattern consistently.** `src/app/api/(common)/anesthesia-type/[id]/route.ts` instantiates a fresh `AnesthesiaTypeService(new AnesthesiaTypeRepository(prisma))` per request. Every other read endpoint in the repo reuses a singleton (`userService`, etc.). For a one-shot fetch this is harmless today, but it's an outlier; either adopt the same singleton pattern (move the construction to module scope like `userService`) or add a comment explaining why anesthesia needs a per-request instance.

- **`fetchUserById` swallows the `ApiResponse` envelope.** `src/components/api/fetch-user-by-id.api.ts:6` does `.then((res) => res.data.result)` while every other `fetch*ById` in the codebase (e.g. `clinic.api.ts:24`, `fetch-doctor-by-id.ts`) returns `res.data.result` directly or returns `res.data` and unwraps at the call site. Here `UserSearchSelect` then chains `.then((res) => res!)` to fight the unwrap — the user wrapper's `fetchItem` is doing work the helper should do. Pick one shape and stick to it; the inconsistency is what forced the extra `.then((res) => res!)` chain in the wrapper.

- **`PatientSearchSelect.getItems` is now a no-op wrapper.** The new arrow body in `patient-search-select.tsx:62-66` computes `const patient = ...flatMap...; return patient;` — the `const` and the rename add nothing. The previous one-liner was clearer. Minor, but it's the kind of dead-code-left-over-from-a-refactor that compounds.

- **`iconOptions` default position flipped silently.** `search-select.tsx:73` changed the default from `position: "left"` to `position: "right"`. Every existing caller that passed `iconOptions={{ showIcon: true, icon: <Search /> }}` without a position now gets the icon on the right. In the cathlab forms, the assistant-nurse/anesthesia-type fields previously had no icon at all and now have one in the right slot — visually fine, but a behavior change worth a sentence in the PR description or a separate prop, not a default flip.

### Low / Nit

- **ItemSearchSelect uses `value={null}` unconditionally** in both `ipd-emr-pharmacy-request-form.tsx` and `ipd-emr-prescription-form.tsx`. That's correct for an "add new item" picker, but the prop suggests the select is controlled. Either omit `value` or add a comment — `value={null} // uncontrolled, this picker only emits onItemSelect`.

- **`useEffect` in `search-select.tsx` mutates `fetchedItems.current` without a stable dep guard.** Line `fetchedItems.current.clear();` runs on every `value === null`, which is fine, but the dependency array includes `itemMap` (a `useMemo` keyed on `[allItems, getOptionValue]`) — this means as the user scrolls and pages load, the effect re-runs for the *same* `value`, re-`setSyntheticItem(found)` from the freshly-built map, and re-`setSyntheticItem(...)` again from the cache. Each scroll page ratchets one redundant `setState`. The "Already in the loaded pages" branch should `return` *after* setting state and skip the rest; today it does, but the `[value, itemMap, fetchItem]` deps make `value` re-trigger on every map rebuild. Consider `[value, fetchItem]` plus an internal ref of `allItems` if needed.

- **Helper name `sortEntitiesBySearch` does ranking, not sorting.** It computes a search rank and breaks ties with `localeCompare`, but for an empty `search` it returns `[...entities]` (preserves incoming `createdAt desc` order, which is fine). For non-empty `search` it ranks by substring match. "Sort" is technically what it does, but reading the callsite (`data: rankedResult`) the intent is "rank by search relevance." A rename would help future readers.

## Recommendation

Address the critical `useUserSearchInfinite` ranking regression before merging — the current implementation will silently drop users from search results that the previous UI would have shown. Then fix the `assistantDoctors` / `cardiologists` error prop swap, decide on the clinic `keepSelectedItem` consistency, and rename `anesthiesia-type-search-select.tsx`. Delete the commented-out code in the three form files; it should not survive in committed source. The shape of the search-select family and the new `GET /:id` endpoints are otherwise a clean, incremental improvement on top of the existing shared component.