# PR #2946 — Add infinty scroll and update search select shared component

**Repo:** MyanCare/Ycare-HMS
**PR:** https://github.com/MyanCare/Ycare-HMS/pull/2946
**Base:** `development` → **Head:** `feat/ppz/sprint-26/cathlab-86ey3pg5q`
**Files changed:** 20 (+950 / -596)
**Author:** Pyae41 (Pyae Phyo Zan) · **Reviewer:** mgmgpyaesonewin
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3pg5q

## Verdict

**Request changes.** Two real bugs (a referral-state mutation gap, a query-prop silent ignore), one wrong error wiring that will silently swallow validation messages, and a giant pile of commented-out code that has to go before merge. Architecture and abstractions are sound — this is a "finish the job" PR, not a "rewrite it" one.

## Summary

Replaces ad-hoc `useSuspenseQuery` lists on the cathlab / IPD-pharmacy / IPD-prescription forms with a shared infinite-scroll `<SearchSelect>` family (`DoctorSearchSelect`, `ClinicSearchSelect`, `UserSearchSelect`, `AnesthesiaTypeSearchSelect`, `ItemSearchSelect` were already present). Adds a `fetchItem` prop so a selected record loads on demand for `keepSelectedItem`. Adds a new `GET /api/users/:id` and `GET /api/anesthesia-type/:id` to support that. Net: -596 / +950, mostly because the cathlab form's referral-out block was rewritten but the dead code is preserved as `//`-comments.

## Findings

### Correctness (bugs)

1. **[bug, High] `ipd/.../cathlab-request-form.tsx:516-528` — REFERRALIN no longer clears `referralOutType`.** The original `useEffect` reset `referralOutType` to its default whenever `watchedReferralType` flipped back to `REFERRALIN`. The new `Radio.Group onChange` clears `referralDoctorId`/`referralClinicId` and clears errors for `referralOutType` but never sets `referralOutType` itself back to `null`. If a user picks `REFERRALOUT → DOCTOR/CLINIC` and then flips back to `REFERRALIN`, the form still thinks `referralOutType` is `"DOCTOR"`, and the `referralOutType` selector stays visible/required. **Same defect in both cathlab forms (`cathlab/.../cathlab-request-form.tsx` and `ipd/.../service-request/cathlab/cathlab-request-form.tsx`).**
   - Fix: `setValue("referralOutType", null)` (or whatever the default is — match the original useEffect) inside the `REFERRALIN` branch. Also re-check whether `referralOutType` should be `undefined` vs `null` per the schema.

2. **[bug, High] `search-select.tsx:103` — `fetchItem` async path has no error surface and no abort.** When `value` is set to an id not in `allItems` and not in the cache, `fetchItem(value)` is fired without cancellation. Race: if `value` changes again before the previous promise resolves, the older promise can still call `setSyntheticItem` and re-render with the stale record. Two problems:
   - No cleanup → if `value` flips A → B → null, and B is a 404, the catch handler logs and `setSyntheticItem(null)` may still land *after* a successful A fetch.
   - No `error` state — a deleted record silently leaves the select showing the previously-displayed value.
   - Fix: stash the in-flight id in a ref and `if (inFlight.current !== value) return;` after the `.then`, plus surface `fetchError` via an `onError` callback or a `notFound` flag the caller can render.

3. **[bug, High] `search-select.tsx:241` — loader wins over user icon, but `rightSection` logic is now tangled.** The new code computes `rightSection = showLoader ? <Loader/> : (right ? sectionContent : undefined)` and `leftSection = left ? sectionContent : undefined`. Net result: when `position === "right"` and `showIcon=true`, `showLoader=false`, `rightSection = <icon>`. When `showLoader=true`, the icon disappears entirely. Two issues:
   - Default changed from `position: "left"` to `position: "right"`. The ItemSearchSelect callers explicitly pass `iconOptions={{ position: right? }}` and rely on `icon: <Search />` showing while loading — it won't.
   - Look at the call site in `ipd-emr-pharmacy-request-form.tsx:371-374` and `ipd-emr-prescription-form.tsx:255-258`: both set `icon: <Search />` and `showLoader: true`. After this PR, while loading the icon disappears.
   - Fix: keep both visible (loader replaces icon is fine, but show one of them), and re-check every caller after the default flip.

4. **[bug, High] `cathlab-request-form.tsx` (both copies) — `form.formState.errors.cardiologists?.[index]?.cardiologistId?.message` wired to the Assistant Doctor select.** The Assistant Doctor `<Select>` now shows the error path for **cardiologists**, not assistant doctors. This was already wrong before this PR (the diff shows the same string in old and new), but the new DoctorSearchSelect surfaces the label/placeholder more visibly so the wrong error will be more confusing. Verify against `assistantDoctors` schema key — almost certainly should read `form.formState.errors.assistantDoctors?.[index]?.assistantDoctorId?.message`.

5. **[bug, Medium] `users-repository.ts:81` — `take: limit === 0 ? undefined : limit * 10`.** The `* 10` was added to fetch enough rows that the in-memory `sortEntitiesBySearch` + `slice(0, limit)` produces a top-N that resembles relevance ranking. But `totalCount` is still the unpaged count, and `slice` only trims after `sortEntitiesBySearch` runs over `limit*10` items — so for any query beyond ~300 matches, `totalCount` lies about "how many match" (it's total users, not matching users). This will break the `hasNextPage` cursor in `useEntitySearchInfinite` and any UI count display. Fix: filter in SQL, sort/rank the top `limit*10` only — i.e. add `search` to the `where` clause, or document that this API now returns an approximate match count and don't use it for pagination.

6. **[bug, Medium] `users-repository.ts:91-104` — `sortEntitiesBySearch` always allocates the full `limit*10` slice even when `search` is empty.** The early-return at `general-utils.ts:842` saves the sort, but `slice(0, limit)` still runs and `rankedResult = limit === 0 ? rankedUsers : rankedUsers.slice(0, limit)` — when `limit === 0` this returns the full `findMany` (no slice). When `limit > 0`, you fetch `limit*10` and slice back to `limit`. For the empty-search path (`limit=10` ⇒ fetch 100, return 10) you round-trip 10× the data every page. Fix: skip the `slice`/`sort` plumbing when `!search`, just `return { data, totalCount }`.

7. **[bug, Medium] `anesthiesia-type-search-select.tsx` — file name typo.** Directory and exports both spell `anesthiesia` (no 'e' before 's'). File: `anesthiesia-type-search-select.tsx`. Either rename the file (and every import) or keep it but lints/tests will keep tripping. Cosmetic — pick one.

8. **[bug, Medium] `search-select.tsx:104` — `fetchedItems.current.clear()` runs on `value === null` but the in-flight fetch is not cancelled.** Same race as #2 but for the "clear all" path: clicking the clear button while a fetch is in flight results in `setSyntheticItem(null)` followed by `setSyntheticItem(item)` from the late promise. Visible to the user as the label flickering back. Add an in-flight ref guard.

9. **[bug, Low] `patient-search-select.tsx:60-79` — `mergedQuery` silently swallows the `query` prop.** When the consumer passes `query={status: 'ACTIVE'}` and `patientTypesFilter='IN'`, the merge result is `{status: 'ACTIVE', patientType: 'IN'}`. When the consumer passes `query={patientTypes: ['A','B']}` AND `patientTypesFilter=['C']`, `mergedQuery.patientTypes` becomes `['C']` (the filter overrides). Probably intentional — but the prop name `patientTypesFilter` reads as "additional filter", not "override". Document or rename.

10. **[bug, Low] `fetch-user-by-id.api.ts:9` — `fetchUserById` returns `res.data.result` directly, not the `ApiResponse<User>` envelope.** Other fetchers (`fetchAnesthesiaTypeById`, `fetchAnesthesiaTypeById`) return the envelope; this one returns the unwrapped payload. Two consumers wrote two different assumptions about the shape — `user-search-select.tsx` does `.then((res) => res!)` (treats it as object, correct for unwrapped), `user-search-select.tsx` consumers in `cathlab-request-form.tsx` read it the same way. Inconsistent across the family. Pick one shape for the whole family.

### Design / code smell

11. **[smell, Medium] Massive commented-out blocks across both cathlab forms.** `cathlab/.../cathlab-request-form.tsx` and `ipd/.../service-request/cathlab/cathlab-request-form.tsx` both keep ~150 lines of dead code as `//`-comments (the old `useEffect` for referral init, the old `AssistantNurseSelect` definition, the old `useSuspenseQuery` blocks). Git has this. Delete the commented-out code in this PR; the diff is currently ~270 lines per file mostly because of comment retention. **This is the single biggest shrink win in the PR.**

12. **[smell, Medium] `AssistantNurseSelect` deleted but its caller pattern is duplicated inline.** The local `AssistantNurseSelect` component was deleted in favour of `UserSearchSelect`. Good. But `UserSearchSelect` is then used at the call site with manual `searchable/clearable/label/placeholder/nothingFoundMessage/keepSelectedItem` repeated 3× in cathlab-request-form.tsx and once elsewhere. Wrap a `AssistantNurseSelect` thin wrapper (10 lines) over `UserSearchSelect` so the call sites don't drift.

13. **[smell, Medium] `sortEntitiesBySearch` is the wrong tool for a 30-item page.** Sorting 300 users in JS after fetching them is fine on a laptop, slow on a phone. The repo path here `users-repository.ts` already has the search token in `where` — move the rank logic to SQL with `ts_rank` or a `pg_trgm` similarity column (already present in HMS via `hms-docs`). The user's `MEMORY.md` mentions the IT role and 50 load-test users; this is a hot path.

14. **[smell, Low] Two new REST endpoints (`/api/anesthesia-type/[id]`, `/api/users/[id]`) that each return a single row by id.** Both bypass the existing list endpoints' pagination/cursor. For users there's a `getUserById` already in the service. For anesthesia-type, ditto. Two endpoints per resource pattern (list + byId) is fine — but please don't add more `_by_id` endpoints without a shared `getById` API route convention.

15. **[smell, Low] `use-search-select-infinite.tsx:318-353` — duplicate hook factory for every new resource.** Each resource is now a 12-line function with the same shape. This is the 5th such hook. A generic `useEntitySearchInfinite<T>` already exists — the resource-specific functions are just `useEntitySearchInfinite` + an extractor. Consider a thin helper that registers extractors by name. (Yagni flag: this is fine until ~3 more resources get added.)

16. **[smell, Low] `search-select.tsx` `getOptionLabel`/`getOptionValue` typing via `Omit<...>` per wrapper is verbose.** Each `*SearchSelect.tsx` repeats the same `Omit<SearchSelectProps<...>, "useSearchHook" | "getItems" | "getOptionLabel" | ...>` boilerplate. The shape of `SearchSelectProps` is fixed by the caller — but the wrappers re-derive it. Could be a single `SearchSelectFor<TData, TFilters>` higher-order that takes `useSearchHook + getItems + getOptionLabel + getOptionValue + fetchItem` and the rest is `as any`. Worth doing once you have ~5 wrappers (you do).

17. **[nit] `search-select.tsx:140` — `useMemo` deps include `getOptionLabel` but `getOptionLabel` is usually a fresh closure each render.** Means the memo recomputes on every parent re-render. Either wrap the default label in `useCallback` inside each wrapper, or use `useEvent`-style ref. Or just drop the memo — for ~30 items the recompute is trivial.

### Performance

18. **[perf, Medium] `search-select.tsx:109-118` — `itemMap = useMemo(() => new Map(...), [allItems, getOptionValue])` plus `fetchedItems.current = new Map<string, T>()`.** Two separate maps. `fetchedItems.current` is a ref so it doesn't trigger re-renders, but the `itemMap` recomputes on every page load and every `getOptionValue` change. For a 30-item page this is fine; for a 300-item page (user list with `limit*10`) every keystroke during search will rebuild the map. Drop `itemMap` and use a single `Map<string, T>` stored in a ref, or just `.find()` — `Array.prototype.find` over 300 is ~3 µs.

19. **[perf, Low] `fetchItem` is called on every `value` change if the value is missing.** If the parent re-renders for any reason and the `value` reference changes (e.g. `field.value ?? null`), the effect refires. The cached check covers repeat hits, but a new `value` that isn't in the map fires `fetchItem`. Add `if (value === prevValueRef.current) return;` (or use `useRef` for the last-seen value) to dedupe.

### Security

20. **[security, Low] `/api/users/[id]/route.ts` — no authorization check on the byId endpoint.** It uses `enhancedApiHandler` with `auth.required: true`, so session is validated, but there's no role/store-scope check. If a nurse can hit this route to fetch any user's record by id, that's an information leak. The list endpoint likely has tenant/store scoping. Apply the same scoping here. (Same review applies to `/api/anesthesia-type/[id]/route.ts` if anesthesia types are tenant-scoped.)

### Tests

21. **[test, Medium] No tests added.** The shared SearchSelect changes are non-trivial: `fetchItem` racing, `keepSelectedItem` semantics, `useEntitySearchInfinite` pagination contract. Minimum:
    - One test that the selected item shows up in the options when `keepSelectedItem=true` and `value` is set.
    - One test for the `fetchItem` race: flip `value` A → B before A resolves, assert the rendered label is B (not A).
    - One Zod-level test for `users-repository.ts` pagination contract: search term "ali" with `limit=10` returns ≤10 results, not all matching users.

## Ponytail pass (over-engineering / shrink)

`net: -260 lines possible.`

- `cathlab/.../cathlab-request-form.tsx` + `ipd/.../service-request/cathlab/cathlab-request-form.tsx` combined: **~150 lines of `//`-commented dead code each.** Delete. Git remembers.
- `anesthiesia-type-search-select.tsx`, `user-search-select.tsx`, `doctor-search-select.tsx`, `clinic-search-select.tsx`, `patient-search-select.tsx` all repeat the same `Omit<SearchSelectProps<...>, "useSearchHook" | ...>` boilerplate. **~15 lines per file × 5 files = 75 lines collapsible.** One factory that takes the dynamic parts and forwards `as any` (or a properly-typed variant) covers it.
- `use-search-select-infinite.tsx:318-353` — `useAnesthesiaTypeSearchInfinite` and `useUserSearchInfinite` are 100% mechanical. If a 3rd such hook lands, factor; for now, leave with a `// ponytail: collapse when a 6th resource lands`.
- `search-select.tsx:137-150` — the `itemMap` is wasted for ≤30 items. Inline `allItems.find(...)`. (~10 lines gone.)
- `search-select.tsx` `useMemo` for `options` has 7 deps; most of those are stable references that should be `useRef`'d or the memo dropped entirely.

## Correctness / quality summary

- **Security:** see #20. Otherwise unchanged. New endpoints inherit the `enhancedApiHandler` auth gate; verify scoping parity with the list endpoints.
- **Design:** SRP holds across the new SearchSelect family. The `fetchItem` + ref cache is the right shape for an "edit-form-with-preloaded-id" UX. The wrapper-per-resource pattern is the conventional approach in this codebase; keep it.
- **Perf:** see #5, #18, #19. The `users-repository.ts` `take: limit * 10` is the biggest risk for a real production workload.
- **Docs:** no ADRs touched. The PR body is just a ClickUp URL — please add a one-paragraph summary of the new search-select contract before merge.

## Test coverage

**Added in this PR:** none.

**Needed before merge:**
- Jest test for `SearchSelect` `keepSelectedItem` + `fetchItem` happy path.
- Jest test for `SearchSelect` `fetchItem` race (cancel/replace in-flight).
- Integration test for `/api/users/[id]` + `/api/anesthesia-type/[id]` (status, body shape, auth).
- Zod test that the two new repo methods round-trip a search without breaking pagination.

## Nits

- `anesthiesia-type-search-select.tsx` filename typo (no `e` before `s`).
- `search-select.tsx:84` — `fetchedItems = useRef(new Map<string, T>())` is fine; consider `useMemo` if you want SSR determinism (probably not worth it).
- `patient-search-select.tsx:60-79` — the `mergedQuery` override behavior is opaque. Add a JSDoc line on the prop.
- `cathlab-request-form.tsx:548` (both copies) — `setValue("referralOutType", "DOCTOR")` is a magic string; import the `referralOutType` enum from `@/app/(dashboard)/common/patients/features/types` (already imported elsewhere in the file).
- `fetch-anesthesia-type.api.ts:14` — `/api/anesthesia-type` (no trailing slash). Consistent with `/api/users/${id}`. Fine — just flag if other endpoints use trailing slashes.

## Recommendation

Address #1, #2, #3, #4 (High) before merge. #5, #6, #11, #13 (Medium) are next-up. The rest can be follow-ups.