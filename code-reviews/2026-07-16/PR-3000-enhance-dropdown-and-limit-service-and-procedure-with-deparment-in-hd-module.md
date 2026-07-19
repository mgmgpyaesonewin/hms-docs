# Code Review: PR #3000 — Enhance dropdown and limit service and procedure with deparment in hd module
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-28/hd-module-86ey3pg20-86ey5579g` → `development`
**Files changed:** 6 (+276 / -255)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-16
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3pg20, https://app.clickup.com/t/9018849685/86ey5579g

## Summary
Swaps Mantine `Select` components for new shared search-select components (`ServiceSearchSelect`, `PatientSearchSelect`, `DoctorSearchSelect`, `ClinicSearchSelect`) across the HD module — services, procedures, and the HD request form (both the standalone HD request form and the IPD-embedded one). Also wires `moduleDepartment: DepartmentEnum.HD` through to the service/procedure selectors so they filter by department, and registers `HD` in the user-management `MODULE_DEPARTMENT_MAPPING`.

## Verdict
**Request changes**
Score: 58/100
Critical: 1 | High: 2 | Medium: 3 | Low: 3 | Nit: 2

## Issues

### Critical
1. **Copy-paste bug: `referralInOut={DoctorType.IN_SERVICE}` on the "Referral Out" doctor selector in the IPD HD form** — `src/app/(dashboard)/ipd/features/components/service-request/hd/hd-request-form.tsx:378`. The sibling file `src/app/(dashboard)/hd/request-list/features/components/hd-request-form.tsx:586` correctly passes `DoctorType.OUT_SERVICE` for the same field. The IPD variant passes `IN_SERVICE`, meaning the "Referral Out" dropdown will silently list only in-service doctors and an out-service referral that is the saved value will not be findable. This is a real user-visible regression for any existing referral-out request viewed or edited through IPD.

### High
2. **Massive dead code left as commented-out blocks instead of deleted** — `hd-service.tsx:75-77,95-104,114-126`, `hd-team-fee-service.tsx:249-251,279-298,305-309`, `hd-request-form.tsx:431-541` region, and `ipd/.../hd-request-form.tsx:124-150`. Roughly 130+ lines of the previous implementation were kept as `//` blocks rather than removed. Git history is the right place for "kept for reference" — leaving them inline triples the diff, confuses the reader, and any future dev will be afraid to delete them. Ponytail rule of thumb: delete on the next commit, not keep-as-comment.

3. **Possible regression of referral extras visibility** — Original `doctorsInOpts` / `doctorsOutOpts` / `clinicsOpts` in `hd-request-form.tsx:479-541` and the IPD twin merged in the current `hdRequest.referralDoctor` / `hdRequest.referralClinic` via `mergeComboboxOptions` so that saved-but-now-inactive referrals still appeared in the dropdown. The new `DoctorSearchSelect` / `ClinicSearchSelect` rely on `keepSelectedItem={isEdit}` to compensate. Verify end-to-end: open an existing HD request whose referral doctor has since been deactivated — does the doctor's name still render in the input after mount? If not, the form is blank but the underlying value is preserved, which is a confusing UX and risks the user clearing it by accident.

### Medium
4. **`Loader` removed from patient dropdown with no replacement** — `hd-request-form.tsx:393-396` (rightSection loader removed in this diff). Patients are still loaded asynchronously via `makeFetchPatientsQuery`, so a slow network now produces a Select with no loading indicator at all. Either the new `PatientSearchSelect` needs an internal `isLoading` indicator or the loader should be re-added via a prop.

5. **`MODULE_DEPARTMENT_MAPPING` adds `HD` — verify the enum value really means the clinical Haemodialysis module** — `src/app/(dashboard)/common/user-management/departments/features/const/index.ts:9`. This constant drives the *user-management* department filter UI (`MODULE_DEPARTMENT_MAPPING`). Confirm `DepartmentEnum.HD` is the same enum the HD clinical module uses elsewhere (e.g. `hd-procedure.tsx:30` uses `DepartmentEnum.HD` for `moduleDepartment` on the service select). If `DepartmentEnum.HD` was previously intended for something else in the user-management UI, this line causes a department called "HD Department" to appear in admin screens where it didn't before. The fact that the HD module is also adding `DepartmentEnum.HD` to its service/procedure queries makes me think it's the same value, but worth a sanity check against Prisma + any seed data.

6. **No tests added or updated** — The PR replaces multiple data-fetching-and-rendering code paths with new components (`PatientSearchSelect`, `DoctorSearchSelect`, `ClinicSearchSelect`, `ServiceSearchSelect`). At minimum, render-smoke tests for `HdService` and `HDRequestForm` would have caught issue #1 (the wrong `referralInOut` value) before review. The test gap is consistent with the existing codebase, but this PR is the right place to set the bar.

### Low / Nit
7. **`useDebouncedValue` left as a dead `//` line** — `hd-service.tsx:75`, `hd-team-fee-service.tsx:249`. The old debounced variable is gone from imports but the old hook call is still there as a comment. Just delete it.

8. **`onSelect` now receives `Service | undefined` but the `if (!service) return` guard checks falsy** — `hd-service.tsx:165` and `hd-team-fee-service.tsx:147`. If the new `ServiceSearchSelect` types `onServiceSelect` as `(s: Service | undefined)`, the guard is fine. If it types as `(s: Service)` (non-optional) then the guard is unreachable but harmless. Worth confirming the component contract so future maintainers don't add a redundant check or remove a needed one.

9. **PR title has a typo: "deparment"** — `Enhance dropdown and limit service and procedure with deparment in hd module` — should be "department". Nit.

## Recommendation
- **Must fix before merge:** Issue #1 (the wrong `referralInOut` enum on the IPD Referral Out field). One-character change.
- **Should fix before merge:** Issue #2 — delete the commented-out dead code rather than carrying it forward. This will also shrink the diff from +276/-255 to something close to +150/-200, which is more honest about the size of the change.
- **Should fix before merge:** Issue #4 — restore a loading indicator on the patient select, either by passing it through to `PatientSearchSelect` or by the component exposing an `isLoading` prop.
- **Should verify before merge:** Issue #3 (referral extras visibility) and Issue #5 (DepartmentEnum.HD semantics in user-management). Both are quick to confirm with one test record each.
- **Nice to have:** Add at least one render test for `HDRequestForm` to lock down the doctor/clinic/patient selectors' integration.

**Net line potential after fixes:** removing all the commented-out blocks in hd-service.tsx, hd-team-fee-service.tsx, hd-request-form.tsx, and ipd/.../hd-request-form.tsx would drop the PR by ~130 lines and bring the score above 80.
