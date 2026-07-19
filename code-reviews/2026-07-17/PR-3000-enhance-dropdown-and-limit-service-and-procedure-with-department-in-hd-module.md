# Code Review: PR #3000 — Enhance dropdown and limit service and procedure with department in hd module
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-28/hd-module-86ey3pg20-86ey5579g` → `development`
**Files changed:** 6 (+151 / -326)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-17
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3pg20 / https://app.clickup.com/t/9018849685/86ey5579g

## Summary
Replaces the in-component Mantine `Select` + bespoke `getServices` query + manual `useDebouncedValue` + `Loader` pairing in the HD module with the shared `<ServiceSearchSelect>`, `<PatientSearchSelect>`, `<DoctorSearchSelect>`, and `<ClinicSearchSelect>` infinite-scroll components. These wrap `useServiceSearchInfinite` / `usePatientSearchInfinite` / etc., which the search-select toolbar fetches its own data and handles debounce/loading inside. Also wires `moduleDepartment: DepartmentEnum.HD` (and `DepartmentEnum.HD` for services) into the service and procedure component prop to scope the HD dropdown to HD-departmental services, and adds a `MODULE_DEPARTMENT_MAPPING` entry so the user-management department module surfaces HD. Net effect: HD, HD-procedure, HD-team-fee-service, HD-request-form (in both `request-list` and `ipd/service-request/hd` locations) all share the same dropdown UX as the rest of the dashboard, and HD dropdowns are now constrained to HD-departmental services / OPD + EMERGENCY patients / ACTIVE doctors and clinics.

## Verdict
**Request changes**
Score: 64/100
Critical: 0 | High: 2 | Medium: 3 | Low: 4 | Nit: 4

## Issues

### Critical
None

### High

**H1 — Commented-out `Loader` import remains in `hd-service.tsx:42` (and analogous commented blocks in `hd-service.tsx`, `hd-team-fee-service.tsx`, `hd-request-form.tsx`)** *(dead-code severity; cosmetic)*

The diff keeps the *commented-out* legacy `useDebouncedValue` block, `useQuery` block, the `serviceOptions`/`teamFeeServiceOptions`/`patientOpts`/`doctorsInOpts`/`doctorsOutOpts`/`clinicsOpts` `useMemo` blocks, and even the `Loader` import ("`// import { useDebouncedValue ... }`" / "`// const [debounced] = useDebouncedValue(...)`" / "`// const { data, ... } = useQuery(...)`" / etc.) across all four changed components. No reviewer can merge dead code — it rots, drifts out of sync with the new query shape, and advertises a half-finished refactor. The `Loader` was removed from the import list at top-of-file but the `//` block on the old variable name still survives nearby. ~150 LOC of commented code ship in production, falsifying the "deletions" line of the diff.

These are dead *branches* of the same logical dead-code pattern, so they collapse into a single finding for the file-level fix:
- `src/app/(dashboard)/hd/features/components/hd-service.tsx`: commented-out `useDebouncedValue` (L76 / comment), `useQuery` (L115-127), `serviceOptions` (L131-138).
- `src/app/(dashboard)/hd/features/components/hd-team-fee-service.tsx`: same three blocks (L66, L102-130).
- `src/app/(dashboard)/hd/request-list/features/components/hd-request-form.tsx`: deleted `patientOpts`, `doctorsData`/`doctorsInOpts`, `clinicsData`/`clinicsOpts` `useMemo` blocks are gone — but the file still contains ~40 lines of commented-out JSX (`bcr`/`anf`/`writtenBy`/`approvedBy`) (L571-607 diff line range) that survives in the file.
- `src/app/(dashboard)/ipd/features/components/service-request/hd/hd-request-form.tsx`: now clean of commented blocks.

*Fix:* delete the commented blocks; if the legacy behaviour might be revisited, keep one branch in git history, not the source tree.

**H2 — Duplicated HD request form: the IPD copy diverges silently from the dashboard-request-list copy**

This PR edits both `src/app/(dashboard)/hd/request-list/features/components/hd-request-form.tsx` and `src/app/(dashboard)/ipd/features/components/service-request/hd/hd-request-form.tsx` to add `DoctorSearchSelect` / `ClinicSearchSelect`. The IPD copy does **not** receive the `PatientSearchSelect` upgrade (the patient block still uses the legacy `Select` with a manual `getPatients` query and the same `patientOpts` pattern that was just removed from the request-list copy). On the previous shape, the two forms were in sync. After this PR:

- request-list: `PatientSearchSelect` + `DoctorSearchSelect` (IN_SERVICE) + `DoctorSearchSelect` (OUT_SERVICE) + `ClinicSearchSelect`
- ipd: legacy `Select` for patient + `DoctorSearchSelect` (IN_SERVICE) + `DoctorSearchSelect` (OUT_SERVICE) + `ClinicSearchSelect`

That means the same patient-pick experience diverges between entry surfaces. After this lands, a single new bug fix has to be made in two places, exactly the failure mode this PR is trying to eliminate. Look at whether that was scoped intentionally (e.g. the IPD patient path is bound by a different parent flow that hasn't been migrated) — if not, also swap the IPD patient block to `PatientSearchSelect`.

### Medium

**M1 — `referralType=REFERRALOUT & clinic==null` fallback doctor row is no longer guaranteed to appear in the dropdown**

Old code in `hd-request-form.tsx` *manually* added the `hdRequest.referralDoctor` row to `doctorsOutOpts` when `referralType === REFERRALOUT && referralDoctorId && !referralClinicId` (lines 269-279 of the pre-diff file). After the refactor, `DoctorSearchSelect` is driven by `query={{ status: 'ACTIVE' }}` + `referralInOut={DoctorType.OUT_SERVICE}`. If the referring doctor is no longer ACTIVE, or is filtered out for any other reason, the pre-existing referral shows up blank in the form even though it's stored on the request. Patient / DoctorSearchSelect typically exposes a `keepSelectedItem` prop to surface the saved selection even when it falls outside the search-set — the request-list file does set `keepSelectedItem={isEdit}` (good), but the IPD copy doesn't.

*Fix:* confirm the shared `SearchSelect` honours `keepSelectedItem` for the doctor when `value` references an inactive doctor; spot-check an edit-mode render where the original referral doctor is `INACTIVE`.

**M2 — `Labelling`: ServiceSearchSelect default label uses en-dash with spaces; PR changes the legacy placeholders without unifying**

Pre-PR used `${service.serviceId} ${service.name} - ${service.category?.name}` (hyphen-minus with spaces). The shared `ServiceSearchSelect` default label is `${service.serviceId} ${service.name} – ${service.category?.name ?? "Uncategorized"}` (en-dash, different bracket for unknown). Same story for `PatientSearchSelect` `${patient.patientId} – ${patient.name} – ${patient.guardianName}` vs PR's old `${patient.patientId} – ${patient.name} - ${patient.guardianName}` (mixed en-dash/hyphen). Not a bug, but a label inconsistency now lives in HD that doesn't exist in dashboards that already adopted these components. Worth a one-line decision: either align the label utility with the rest of the app, or accept the shared-component's default and remove the inconsistency.

**M3 — `loader icon` and `withAsterisk` props now explicitly typed as `true`**

The diff switches every prop the new components receive to its JSX-attribute `={true}` form (`searchable={true}`, `clearable={true}`, `withAsterisk={true}`). This is cosmetic noise — the bare `searchable` is identical to `searchable={true}` in JSX. Harmonise with the rest of the codebase's style (project prefers explicit boolean attributes or shorthand — be consistent, not both).

### Low / Nit

**L1 — `PatientSearchSelect` already accepts `patientTypesFilter`; the PR passes the same intent via `query={{ patientTypes: [...] }}`**

`PatientSearchSelect`'s prop `patientTypesFilter` merges the filter into the underlying `GetPatientsSchema` `patientTypes` key (per `patient-search-select.tsx:67-81`). The PR passes `query={{ patientTypes: [patientType.EMERGENCY, patientType.OPD] }}` directly, which works because `query` is typed `PatientSearchFilters = Omit<GetPatientsSchema, ...>`, but it bypasses the documented prop name and skips the singular-vs-plural helper. Use `patientTypesFilter={[patientType.EMERGENCY, patientType.OPD]}`.

**L2 — `Search` icon still imported but the `Loader` icon inside `leftSection` is gone**

`hd-service.tsx` keeps `import { Search, Trash2 } from "lucide-react"`, then renders `<ServiceSearchSelect ... iconOptions={{ showIcon: true, position: "left", icon: <Search /> }} />`. The `Search` is now correctly passed in; but now that `isFetchingServices` is gone, the loading spinner is delegated inside the shared component. Worth a quick QA pass that the Search icon does not collapse when the user has a long list and scrolls — infinite-scroll lists sometimes flicker the icon. Pure QA, not a code change.

**L3 — Dropped `data-testid` / ARIA passthrough**

The old `Select` components emitted Mantine-internal `data-*` ids that downstream tests/selectors were likely relying on. `ServiceSearchSelect` / `DoctorSearchSelect` wrap a custom root. Verify any Playwright/Cypress selectors (`getByLabel`, `data-testid`) still resolve. If unsure, run the HD suite once locally before merging.

**L4 — `DepartmentEnum.HD` import: `@prisma/client` import path is fine but raises a tsc concern**

`import { DepartmentEnum } from "@prisma/client"` is the project standard everywhere else in this PR scope (verified in `hd-procedure.tsx` and `hd-service.tsx`). One occurrence is fine, but mention for new files that `@prisma/client` is heavy at compile time — pre-existing patterns, no action.

**N1** — `hd-procedure.tsx` adds `import { DepartmentEnum } from "@prisma/client"` between `useMemo` and `export const`. Other component files in this PR consistently group `@prisma/client` imports near top-of-file. This file's import ordering is a small inconsistency. Fix on next pass.

**N2** — `MODULE_DEPARTMENT_MAPPING` `HD` entry placement is correct alphabetically (after `DAYCARE`, before nothing — there is no OT/OPD-alphabetical ordering). Some teams prefer strict alphabetical; check the convention in the wider `MODULE_DEPARTMENT_MAPPING` block. If `OT/OPD/DAYCARE/HD` is the existing order, this is fine.

**N3** — `useDebouncedCallback` import still present in `hd-service.tsx` and `hd-team-fee-service.tsx` after removing `useDebouncedValue`. Verify the callback is still used (it was used for the discard button handler at the top of the file in pre-diff). If not, drop it. If yes, fine.

**N4** — Diff line 569-607 (`hd-request-form.tsx`) contains ~38 lines of commented-out JSX (an old `bcr` Radio.Group and the older `writtenBy`/`approvedBy`/`bcr` form). This is the dead-code pattern flagged in H1 but is material even on its own: those commented blocks were already stale before this PR, and the PR is the natural moment to delete them.

## Recommendation
1. **Resolve H1 first**: scrub all commented-out `useDebouncedValue`, `useQuery`, `useMemo`, and `Loader` blocks from the four touched components — those are the *real* deletions the PR claims (-326) and they're still sitting in the source. The diff size then becomes honest.
2. **Resolve H2**: confirm with the author that the IPD copy of the HD request form intentionally keeps the legacy patient `Select`. If not, apply the same `PatientSearchSelect` swap there. Goal: one source of truth, not two.
3. **M1**: verify edit-mode keeps the pre-existing referral doctor visible even when that doctor is `INACTIVE` (or whatever current `keepSelectedItem` semantics are — read the SearchSelect implementation if unsure).
4. After (1)-(3), this is a clean refactor: shared component adoption, scope-by-department filter on services, deleted bespoke data loading. Good PR to merge once the dead code is gone.

**Files referenced:**
- `/Users/pyaesonewin/Documents/work/hms-system/hms-app/src/app/(dashboard)/hd/features/components/hd-procedure.tsx`
- `/Users/pyaesonewin/Documents/work/hms-system/hms-app/src/app/(dashboard)/hd/features/components/hd-service.tsx`
- `/Users/pyaesonewin/Documents/work/hms-system/hms-app/src/app/(dashboard)/hd/features/components/hd-team-fee-service.tsx`
- `/Users/pyaesonewin/Documents/work/hms-system/hms-app/src/app/(dashboard)/hd/request-list/features/components/hd-request-form.tsx`
- `/Users/pyaesonewin/Documents/work/hms-system/hms-app/src/app/(dashboard)/ipd/features/components/service-request/hd/hd-request-form.tsx`
- `/Users/pyaesonewin/Documents/work/hms-system/hms-app/src/app/(dashboard)/common/user-management/departments/features/const/index.ts`
- `/Users/pyaesonewin/Documents/work/hms-system/hms-app/src/components/search-bar-select-with-infinite-scroll/patient-search-select.tsx` (referenced; not modified by this PR)
- `/Users/pyaesonewin/Documents/work/hms-system/hms-app/src/components/search-bar-select-with-infinite-scroll/service-search-select.tsx` (referenced; not modified by this PR)
