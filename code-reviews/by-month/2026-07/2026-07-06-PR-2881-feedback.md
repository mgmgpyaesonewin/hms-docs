# PR #2881 — fix: doctor dynamic doctor search

**Repo:** MyanCare/Ycare-HMS
**PR:** https://github.com/MyanCare/Ycare-HMS/pull/2881
**Author:** Xkill119966
**Branch:** `fix/dynamic-doctor-search-in-emr` → `development`
**Changed files:** 2 (+288 / -42)
**State:** OPEN
**ClickUp:** https://app.clickup.com/t/9018849685/86ey2a4vw
**Verdict:** Changes requested

## Summary

Replaces the static "pick-one-of-one" Doctor `<Select>` in the EMR patient/appointment flow with a real searchable, paginated, debounced doctor picker that fetches via the existing `makeFetchDoctorsQuery`. Both files affected — `emr/features/patient-appointment-remark.tsx` (OPD EMR) and `emr/ipd/features/components/patient-selection.tsx` (IPD module list, used by HD/Endo/OT) — get the same feature: 500 ms debounced search, `includeDoctorId` plumbed through so the appointment's default doctor never disappears from the dropdown after a search/filter, a ref-guarded auto-sync so the appointment's doctor only auto-fills once per `appointmentId`, and a `rightSection` `<Loader size={12} />` while the doctors query is in flight.

The feature itself is needed (the previous `<Select searchable={false} disabled={...}>` was unworkable once you needed to override the appointment's doctor) and the chosen primitives are the right ones — the existing `fetchDoctors` / `makeFetchDoctorsQuery`, the same debounce + memoize pattern already used for patient search in the same file, and a tiny Mantine-specific ref hack to distinguish a real clear from Mantine's post-selection `searchValue` reset. But the diff ships the same ~70-line block twice (one per file) and the Mantine-interlock dance is heavier than it needs to be because the implementation is fighting the controlled API rather than switching to Mantine's `Autocomplete` / `Combobox` primitives designed for this exact case. Both issues are local, but together they double the surface area for a feature the team is going to copy into more EMR forms.

## Strengths

- Correct use of the existing `makeFetchDoctorsQuery` / `GetDoctorsSchema` plumbing — `includeDoctorId`, `page`, `limit`, `search` are all first-class on the schema and the team did not introduce a parallel query.
- Plumbs `includeDoctorId` through so the appointment's default doctor is guaranteed to stay in the dropdown after a search — without this, typing a single character would evict the selected doctor and the user would lose track of the auto-fill.
- The auto-sync effect is gated on `appointmentLoading`, which prevents the classic "set doctor to null before the appointment's doctor has loaded" flicker when a user picks an appointment from the dropdown above.
- The `rightSection={isDoctorLoading && <Loader size={12} />}` is a one-line UX win that matches the patient `<Select>` right above it in the same form.
- `value={doctorId ?? null}` is the right coercion; Mantine's `Select` rejects `undefined`.
- Field is no longer disabled when an appointment is selected — the previous `disabled={!!selectedAppointmentDoctor}` forced users to remove the appointment before they could change the doctor, which is the bug this PR is fixing.

## Issues

### Important

1. **The same ~70-line block is duplicated verbatim across two files** — `patient-appointment-remark.tsx:209-274` and `patient-selection.tsx:83-103, 333-382`. The two implementations diverge in three trivial ways (a default-export name, an extra `useEffect` reset on patient clear in IPD, and a dep-order reshuffle) but are otherwise identical: same `useRef` reset trick, same `setDoctorsQuery` reset object, same `onDoctorChange` / `handleDoctorSearchChange` pair. This is the patient-search pattern from `patient-appointment-remark.tsx:44-67` scaled to doctors — and it already lived in one place. With doctors it now needs to live in both, and the IPD file has 600+ lines so the next caller is going to copy-paste a third time. Extract a `useDoctorSelect({ doctorId, setDoctorId, clearError, appointmentId, appointmentLoading, selectedAppointmentDoctor, isEditPage, isDetailPage })` hook that owns the search state, the debounce, the `onChange` / `onSearchChange` callbacks, and the auto-sync effect. Both files reduce to one hook call + the `<Select>` JSX. Net: -90 lines, one place to fix the next Mantine quirk.

2. **The `justPickedDoctorRef` + `handleDoctorSearchChange` interlock is fighting Mantine's controlled API** — `patient-appointment-remark.tsx:254-272` and `patient-selection.tsx:364-380`. The whole block exists because Mantine's `<Select searchable>` fires `onSearchChange("")` right after `onChange(value)` to reset the visible search text. The current fix is to flag it with a ref, swallow the empty `onSearchChange`, and only clear the doctor on a "real" empty string. This works, but:
   - It is a symptom of treating `<Select searchable controlled>` as a stateful input when Mantine's higher-level `useCombobox` + `Combobox.Option` / `Autocomplete` primitives are built for this case (`Autocomplete` especially: it accepts a controlled `value` and an `onOptionSubmit`, and does not reset the search text on selection).
   - It silently drops the empty `onSearchChange` and then checks `doctorId` to decide whether to clear — which means a race where the user picks a doctor, then Mantine fires the empty `onSearchChange`, then the user backspaces the visible text before any other render, will clear the doctor. That window is small but real, and there is no test guarding it.
   - The ref + the comment that explains the ref is longer than the fix would be if the primitive were switched. If `Autocomplete` does not work for the multi-option + value-is-not-search-text shape, keep `<Select>` but use `searchValue` only as a display hint and split the onChange chain — `value` is the doctor id, `searchValue` is a one-way display. That removes the reset-detection branch entirely.

3. **`limit: 10` is a behavior change in the IPD file** — `patient-selection.tsx:331` swaps `limit: 0` (which fetched every doctor) for `limit: 10`. For the previous single-option UX this did not matter; for a real search it does — but `limit: 10` means a doctor whose name is at position 11 in the alphabet is invisible until the user types enough to filter them in. The previous patient-search block in the same file uses the same `limit: 10` and the same `includePatientId` escape hatch, so this is consistent with the existing pattern, but it is worth a sentence in the PR body: "Doctors in IPD HD/Endo/OT are now paginated 10/page; `includeDoctorId` keeps the auto-filled doctor visible." If a hospital has a roster of >10 doctors who all need to be reachable by an empty-search dropdown, this is a regression. Consider `limit: 25` for empty search and `limit: 10` for non-empty, or rely on the same backend cursor pattern the patient search uses.

4. **`doctorsForSelect` memo depends on `selectedAppointmentDoctor` (object reference)** — `patient-appointment-remark.tsx:315-320` and `patient-selection.tsx:419-423`. Every refetch of `appointmentResult` produces a new `selectedAppointmentDoctor` object reference (the `useMemo` is keyed on `selectedAppointmentRecord`, which itself is keyed on `appointmentResult?.result`), which means the memo recomputes on every appointment refetch even when the doctor has not changed. Cheap, but the auto-sync effect downstream is then in a position where it has to defend itself with `syncedAppointmentIdRef` to avoid re-applying the default — which is the entire reason `syncedAppointmentIdRef` exists. Root-cause fix: memoize `selectedAppointmentDoctor` by `value` (the doctor id), not by `selectedAppointmentRecord`. With a stable id-keyed object, the memo does not recompute on refetch, the auto-sync effect does not need the ref, and the comment block at `patient-appointment-remark.tsx:344-360` goes away.

5. **The standalone `useEffect(() => { if (doctorId) setDoctorsQuery(prev => ({ ...prev, includeDoctorId: doctorId })) }, [doctorId])` duplicates work the other effect already did** — `patient-appointment-remark.tsx:382-388` and `patient-selection.tsx:489-496`. The auto-sync effect at lines 360-371 / 465-477 already sets `includeDoctorId` on the initial sync, and `onDoctorChange` sets it (via the `setDoctorsQuery` reset object) on every selection. The standalone effect covers exactly one path: a user picks a doctor via a method that bypasses `onDoctorChange` — which does not exist. Delete the effect, or merge it into `onDoctorChange` and the auto-sync effect (the current code sets `includeDoctorId` from `doctorId` in two places, which is a smell).

### Nit

6. **`setDoctorId` call chain is hard to follow** — `patient-appointment-remark.tsx:225-228, 271` and `patient-selection.tsx:347-350, 378-381`. On a real selection `onDoctorChange(value)` calls `setDoctorId(value)` once. On a clear `handleDoctorSearchChange("")` → `onDoctorChange(null)` → `setDoctorId(null)`. The null-branch logic lives inside `onDoctorChange` while the value-branch logic also lives inside `onDoctorChange` — the asymmetry makes it look like a duplicate. Rename the null branch to `clearDoctor()` so the call sites read as intent, not as two `setDoctorId` calls stacked.

7. **Comments are doing the work of names** — `patient-appointment-remark.tsx:209-211, 344-350`. The "Guards against Mantine's own post-selection searchValue reset" comment and the "Only auto-fill the doctor ONCE per appointment selection" comment are correct but each is longer than the logic it documents. If the helper from finding #1 is extracted, both comments collapse to one-line inline comments inside the hook where they live next to the branch that consumes them.

8. **Possible duplicate `Loader` import in `patient-appointment-remark.tsx`** — the diff shows `Loader` already imported on line 7 (kept) and added again in the merged import block on line 6. Verify the file compiles after merge — `next.config.ts` ignores ESLint/TS errors at build time so it will silently ship. Run `npm run tsc` and `npm run lint` locally before approving.

9. **No tests for the auto-sync logic** — the `syncedAppointmentIdRef` guard, the `justPickedDoctorRef` guard, and the `includeDoctorId` propagation are all unobservable from the diff. Pure-UI logic is hard to unit-test without a full render harness, but the three pieces are state machines: `pick → search reset (consumed) → next pick` / `clear → null → search empty → no-op` / `appointment change → load → apply default → never re-apply`. A 30-line `@testing-library/react` test that renders the component with a mocked `useAppointmentsForOpdEmr` and asserts the three transitions would lock in the behavior the comments are describing.

10. **PR title is grammatically off** — `fix: doctor dynamic doctor search`. Reads as if "dynamic" modifies "doctor search" but the intent is "dynamic doctor search" (a doctor search that is dynamic, vs the old static one). `fix(emr): dynamic doctor search in patient/appointment flows` is clearer.

11. **PR body is just a ClickUp link.** The behavior change is non-trivial (the IPD file goes from "fetch all doctors, render one" to "paginate 10, debounced search, multi-select"), and a reviewer cannot tell from the diff whether `limit: 10` on a hospital with 50 doctors is intentional. One-paragraph body: which flows are affected, what the UX is now, why the IPD `limit: 10` is fine here, would help.

## Recommendations

- Extract `useDoctorSelect` hook (finding #1) — single source of truth, ~90 lines removed, both files become ~15 lines per file.
- Fix `selectedAppointmentDoctor` memoization by id (finding #4) — removes `syncedAppointmentIdRef` and the comment block that justifies it.
- Pick one of: switch to Mantine `Autocomplete`, or use `<Select>` with `searchValue` as a one-way display hint (finding #2) — removes the `justPickedDoctorRef` interlock.
- Delete the standalone `useEffect(() => { if (doctorId) ... }, [doctorId])` (finding #5) — its work is already done in the two other places that mutate `doctorsQuery`.
- Run `npm run tsc && npm run lint` before merge to catch the duplicate `Loader` import (finding #8).
- Add a one-line PR description explaining the `limit: 10` choice in IPD and which flows are now searchable.
- Lock the auto-sync behavior with a small render test (finding #9).

## Reviewer notes

- The OPD file (`patient-appointment-remark.tsx`) is also used by `ED` and `DAYCARE` via the `moduleType` prop. The diff does not change that, but the doctor search is now enabled in those flows too — confirm with the author that this is intended (ClickUp ticket mentions EMR, not "all module types").
- The IPD `patient-selection.tsx` is shared by HD, Endo, OT, and Cathlab via `getModuleHooks`. The diff is local to the doctor section so it propagates everywhere the doctor `<Select>` renders — verify on the dev stack that each of those modules' forms still render the new picker correctly (especially Cathlab which has its own consultation-doctor semantics).
- Net diff is +288/-42 across two files that were never going to be cheap to touch, so the headline "size" is fine. With the four refactors above the same feature ships at roughly +120/-30, but more importantly it ships once — the next EMR form that needs a doctor picker imports the hook instead of copy-pasting 70 lines.
- This is a pure-frontend, no-DB, no-auth change. Lowest-risk PR category. The issues are all about whether the team wants to land the feature in two places or one.

**Ponytail net estimate:** -90 lines possible with the hook extraction and the memoization fix; -120 lines if `Autocomplete` replaces `<Select searchable>` and the interlock dance disappears entirely.
