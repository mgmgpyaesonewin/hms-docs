# Code Review: PR #320 — Add infinity scroll in cathlab request
**Repository:** MyanCare/YCare-HMS-Service-Module
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-26/cathlab-86ey3pg5q` → `development`
**Files changed:** 1 (+183 / -232)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3pg5q

## Summary
Refactors `cathlab-request-form.tsx` to replace five bulk-loaded Mantine `Select` components (doctors, clinics, anesthesia types, patients, users) with paginated `*SearchSelect` infinite-scroll variants from `@/components/search-bar-select-with-infinite-scroll/`. Also deletes the now-redundant local `AssistantNurseSelect` helper, removes the unused `useSuspenseQuery` import, and cleans up the `referralType` Radio.Group onChange to clear stale doctor/clinic ids when switching between Referral In / Referral Out. Net diff is -49 lines.

## Verdict
**Request changes**
Score: 56/100
Critical: 1 | High: 3 | Medium: 4 | Low: 3 | Nit: 2

## Issues

### Critical

1. **Wrong `referralInOut` on the Referral-Out `DoctorSearchSelect`** (lines ~770-776). The component is labeled "Doctor (Referral Out)" but `referralInOut={doctorTypes.IN_SERVICE}` is passed — the same prop used by the Referral-In dropdown. `DoctorSearchSelect` forwards this prop as the `doctorType` query filter (`query={{ ...query, doctorType: referralInOut }}`), so the Referral-Out dropdown will fetch the **in-service** doctor pool instead of the **out-service** pool that the original `doctorsOutOpts.filter((d) => d.doctorType === "OUT_SERVICE")` produced. This is a functional regression for the Referral-Out flow — fix to `referralInOut={doctorTypes.OUT_SERVICE}`.

### High

2. **`PatientSearchSelect` duplicates search-state plumbing with `useQuery(makeFetchPatientsQuery(...))`** (lines ~1480-1515). The form keeps `patientsQuery`, `patientsDebouncedSearch`, `handlePatientSearch`, and an external `useQuery` for `patientData` purely to populate the Age/Gender/Patient-Type side card (`selectedPatient` memo). But `PatientSearchSelect` runs its own infinite fetch internally; the `searchValue`/`onSearchChange` props passed to it now drive a second, parallel search path. The two are kept loosely in sync via the wrapper, which is fragile — a stale selection in the dropdown no longer means the side card has data for that patient. Either pass the patient id directly to a `fetchPatientById` hook, or have `PatientSearchSelect` expose the current selection (via `onItemSelect` / `onChange`) so the form can resolve display data once, not twice.

3. **Inconsistent `referralClinicId` reset between REFERRALIN vs REFERRALOUT branches** (lines ~654-672). On `REFERRALIN`, both `referralDoctorId` and `referralClinicId` are reset to `null` and both are `clearErrors`-ed. On `REFERRALOUT`, only `referralDoctorId` is `setValue`-reset; `referralClinicId` is left at its previous value and only its error is cleared. If the user previously selected a clinic, switched to REFERRALOUT-DOCTOR, then came back, the stale `referralClinicId` may still be in form state. Set both fields to `null` in both branches (the form already has `referralOutType` defaulting to `DOCTOR` so the stale clinic is unreachable in the UI but stays in the submission payload).

4. **`referralOutType` Radio.Group still uses `""` for resets while the `referralType` group uses `null`** (lines ~22360-22390 in the head file). After this PR, the same form has two Radio.Groups resetting the same shape of fields with two different "empty" sentinels: `setValue("referralClinicId", "")` here vs `setValue("referralClinicId", null)` in the parent. Pick one — `null` is correct since the Zod schema accepts `nullable()` and the Mantine `Select`-style components are typed as `string | null`. The `""` paths leak through to the submit payload and may violate the schema or fail equality checks server-side.

### Medium

5. **Dead code shipped: the entire old `useSuspenseQuery` block is commented out, not deleted.** The diff turns ~80 lines of commented-out doctor/clinic/anesthesia query setup, the commented-out `useEffect` that synced `referralType`/`referralOutType`, and the commented-out `patientOpts` memo into dead weight in the file. None of these can be re-enabled by uncommenting anymore — `useSuspenseQuery` was removed from the imports, and the commented code references the removed `Loader`, `patientType.OPD`, etc. Ponytail: `delete:` — the file is cleaner without them, and git history has them if anyone needs to look. Keep the import-side cleanup (good); delete the body.

6. **`AssistantNurseSelect` deleted, but its callers now pass a slightly different value contract.** The old helper rendered a `Select` with `value={value}` (uncoerced) and the original `<Select>` for the assistant nurse used `value={value || null}`. The new `UserSearchSelect` block passes `value={value}` (uncoerced) and `onChange={(newValue) => onChange(newValue ?? "")}` (always coerces to `""`). When the user clears the dropdown, the form field is set to `""` while all the default values use `""` too, which is internally consistent — but the other select blocks (`DoctorSearchSelect`, `PatientSearchSelect`) pass `value ?? null` and expect `null`. Standardize on `null` for cleared fields across all five new selects; matches the new `referralType` group's behavior and the rest of the form.

7. **External `useQuery(makeFetchPatientsQuery(...))` is re-fetched on every keystroke even though `PatientSearchSelect` already searches internally.** The `patientsDebouncedSearch` callback updates `patientsQuery.search`, which triggers the external query (limit 50, `includePatientId`). With an empty `includePatientId`, this returns the first 50 patients of the org on mount and on every search keystroke — which is the exact payload the infinite-scroll component already fetches. Likely safe but wasteful; the result is only used to display the selected patient's demographics. Replace the bulk list with `fetchPatientById(id)` once `patientId` is set.

8. **The new `console.log("Form Error", errors)` was removed (good), but a `console.log` of the cathlab request data / form values may still exist elsewhere.** This is a stylistic note: the previous code clearly had debug logs (the diff removes one). Confirm via `grep -n "console\."` against the file before merge — the diff doesn't touch any other logs but the file is large and not visible end-to-end in the review.

### Low / Nit

9. **Nit: `withAsterisk={true}`, `searchable={true}`, `clearable={true}` are redundant explicit-true props.** Mantine's `Select` types these as `boolean` with sensible defaults (`searchable: true`, `clearable: false`, `withAsterisk: false`). Drop the `={true}` on the three that already default to true. Ponytail: `shrink:` — five new call sites pass the same three booleans, becomes one `=`-less form.

10. **Nit: hard-coded `referralInOut={doctorTypes.IN_SERVICE}` for the Referral-In branch and `referralInOut={doctorTypes.OUT_SERVICE}` for the Referral-Out branch should arguably be derived from `watchedReferralType`.** Not strictly a bug since the controls are conditionally rendered by `watchedReferralType`, but the prop is hand-set per branch and could drift if the type enum grows. Consider a small `const referralDoctorType = watchedReferralType === ReferralType.REFERRALOUT ? doctorTypes.OUT_SERVICE : doctorTypes.IN_SERVICE;` and pass it to both `<DoctorSearchSelect>`s.

11. **Low: `Loader` was removed from the import but `isPatientLoading` is still used for the side-card skeleton text.** Functionally fine (`<Text>Loading...</Text>` instead of `<Loader />`). Note in case the design wants a spinner back later.

12. **Low: key prop `key={`assistant-nurse-${field.id}`}` is preserved on `UserSearchSelect`** — good (avoids remount on reorder), but `UserSearchSelect` is doing the search internally now, so the key is no longer load-bearing for state reset. Keep it for safety.

13. **Nit: `import { useEffect, useRef, useMemo, useState } from "react";`** — react-hook order changed (`useMemo` moved before `useState`). Style-only; ESLint may flag it depending on config, but `react/hook-order` only checks call order inside the component, not the import order. Cosmetic.

## Recommendation

1. **Block merge** until the `referralInOut` for the Referral-Out dropdown is fixed (Critical #1) — this is a one-line behavioral fix.
2. After merge-blocking fix, sweep the file with a final `grep -n "console\."` and `git diff` of just the commented blocks; delete the commented-out blocks (Medium #5) in a follow-up commit so the file lands clean.
3. Pick `null` as the canonical "empty" sentinel for all referral-id form fields and audit the `referralOutType` radio onChange accordingly (High #4).
4. Decide whether the side card's patient demographics should come from a single `fetchPatientById` (Medium #2/#7) — recommended, since it removes the second `useQuery` and the parallel-search concern.
5. Re-test the cathlab request creation flow end-to-end (add + edit) once the doctor-pool regression is fixed; the form has six inputs that all changed contracts and a regression test would lock the search-select selection logic in place. No automated test exists for this file (`opd-billing/cathlab-request-list/__tests__/` is absent in the repo tree).