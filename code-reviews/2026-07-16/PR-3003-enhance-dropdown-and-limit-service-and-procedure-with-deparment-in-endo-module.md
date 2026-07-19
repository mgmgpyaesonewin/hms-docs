# Code Review: PR #3003 — Enhance dropdown and limit service and procedure with deparment in endo module
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-28/endo-86ey3pfzu-86ey5578m` → `development`
**Files changed:** 6 (+175 / -336)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-16
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3pfzu
**ClickUp:** https://app.clickup.com/t/9018849685/86ey5578m

## Summary
Replaces hand-rolled Mantine `Select` dropdowns in three endo files with a family of server-paginated search-select components (`PatientSearchSelect`, `DoctorSearchSelect`, `ClinicSearchSelect`, `AnesthesiaTypeSearchSelect`, `UserSearchSelect`, `ServiceSearchSelect`). Threads a new `moduleDepartment: DepartmentEnum.ENDO` filter through the service/procedure queries and adds the matching entry in `MODULE_DEPARTMENT_MAPPING` so the filter actually narrows results to endo-scoped rows. Also rewires the `EndoMainServicesSection`/`EndoTeamFeesSection` `onSelect`/`onSelectTeamFee` handlers in the service-bill context to take a full `Service` object instead of an id, dropping the lookup-by-id step. Net effect: significant code deletion (-336 lines) and consistent UX across endo forms.

## Verdict
**Request changes**
Score: 80/100
Critical: 0 | High: 1 | Medium: 2 | Low: 1 | Nit: 2

## Issues

### Critical
None

### High
- **`onSelectTeamFee` signature mismatch — `endo-services.tsx:194-214` + `endo-service-bill.context.tsx:234`.** The team-fee dropdown was migrated to `ServiceSearchSelect` but is wired with `onChange={onSelectTeamFee}`, and `SearchSelect` fires `onChange` with a `Service` object (the same path used by `onItemSelect`). Meanwhile `onSelectTeamFee` is still typed `(value: string | null) => {...}` and starts with `if (!value) return;` followed by `data?.result?.services?.find((s) => s.id === value)` — so when a user picks a team-fee service, the lookup receives a `Service` object as `value`, no match is found, and the row is silently dropped. **Fix:** mirror what was done for `onSelect`: change the signature to `(curr: Service) => {...}` and drop the id-lookup. Bonus: the entire `onSelectTeamFee` body can be modelled after the new `onSelect` since `prepend(...)` is the same shape; the existing function is correct in shape but stale in plumbing.

### Medium
- **Commented-out `patientOpts` block left behind — `endo/request-list/features/components/endo-request-form.tsx:370-383`.** The diff already removed the analogous blocks for `anesthesiaTypeOpts`/`doctorsOpts`/`doctorsInOpts`/`doctorsOutOpts`/`nurseOpts`/`clinicsOpts`, but the `patientOpts` block was only commented out, not deleted. The companion IPD endo form (`ipd/features/components/service-request/endo/endo-request-form.tsx`) was cleaned properly. Delete the dead block; it's a future footgun for grep.

- **`query.moduleDepartment` filter relies on a coupled Prisma string constant — `service.repository.ts:188-198` and `procedure.repository.ts:83-86`.** The new wiring only filters endo services/procedures if `MODULE_DEPARTMENT_MAPPING[DepartmentEnum.ENDO]` resolves to `"Endo Department"` (case-insensitive `mode: "insensitive"` match against `service.department.name` / similar). This is correct as written but tightly couples a frontend enum to a backend department name string — any future rename of the "Endo Department" row silently breaks filtering for the entire module with no compile-time signal. Worth noting in an ADR (one already exists at `MODULE_DEPARTMENT_MAPPING` — please update its comment to flag this brittleness) so the next reviewer knows not to rename the row.

### Low / Nit
- **Redundant explicit `={true}` — both endo request forms.** Migrated `Select` props are written `withAsterisk={true}`, `searchable={true}`, `clearable={true}`. The Mantine types already default these to `true` via `boolean | undefined`; drop the `={true}` and let TS infer (the existing codebase elsewhere uses the bare prop form). ~40 occurrences across the two form files. Mechanical fix; does not change behavior.

- **Minor: the duplication between `endo/request-list/.../endo-request-form.tsx` and `ipd/features/components/service-request/endo/endo-request-form.tsx` is now even more obvious.** Both files carry near-identical field-array wiring, debounced searches, and query plumbing for doctors/clinics/anesthesia/users. The PR consolidates well within each file but does not address the cross-file duplication. Out of scope for this ticket — flagging for a future ticket; the right fix is to extract a shared `EndoRequestFormFields` (or move the search-select wrappers into the shared module so the page-level files only render and wire).

## Recommendation
1. **Fix the team-fee dropdown wiring first** — apply the same `(curr: Service) =>` refactor to `onSelectTeamFee` and switch to `onServiceSelect={onSelectTeamFee}` in the team-fee `<ServiceSearchSelect>` at `endo-services.tsx:198-214`. Without this, team-fee selection silently no-ops.
2. Delete the commented-out `patientOpts` block at `endo/request-list/.../endo-request-form.tsx:370-383`.
3. While you're in the file, drop the `={true}` on the boolean props.
4. Update the `MODULE_DEPARTMENT_MAPPING` JSDoc to call out the name-string coupling so the next person who edits the department seed data is warned.
5. After the fix, smoke-test: add an endo service to a bill, then add a team-fee service — confirm both rows appear in the table.
