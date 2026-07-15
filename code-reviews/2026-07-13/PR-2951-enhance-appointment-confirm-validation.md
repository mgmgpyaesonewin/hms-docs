# Code Review: PR #2951 — Enhance appointment confirm validation
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `enhance/april/sprint27/appointment-confirm-validation` → `development`
**Files changed:** 2 (+31 / -0)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-13
**ClickUp:** https://app.clickup.com/t/9018849685/86ey5kzve

## Summary
Adds a guard in `AppointmentService.updateAppointmentStatus` that blocks the `CONFIRMED` transition when the appointment's patient has an `ACTIVE` admission in IPD. The check is implemented as a new repository method `hasActiveAdmissionForAppointmentPatient` that counts admissions by patient id, and the appointment validator is widened to also select `patient.patientType`.

## Verdict
**Approve with suggestions**
Score: 80/100
Critical: 0 | High: 0 | Medium: 2 | Low: 2 | Nit: 2

## Issues

### Critical
None

### High
None

### Medium

1. **`patientType` field is added but never used by this change.** `appointment.repository.ts:98` adds `patientType: true` to the validator's `patient` select, but the new code path only reads `existingAppt.patientId` (no `patientType`). The commit subject (`wip appointment confirm validation logic`) hints this PR is mid-flight — the field will likely be consumed by a follow-up check, but shipping it now widens the projection (extra DB column on every read that hits this validator) with no caller benefit. Either land the follow-up logic that uses it, or drop the field from this PR.

2. **TOCTOU between admission count and status update.** `appointment.service.ts:253-263` runs the admission count outside the eventual `prisma.$transaction` that performs the status update. A concurrent admission created in the gap will not be seen, and the appointment will still flip to `CONFIRMED`. For most appointment flows this is low risk (admission is a deliberate human action), but if strict consistency is required, move the guard inside the transaction and re-check after the status row is locked. If the eventual volume justifies it, consider adding a partial unique constraint or a DB trigger. At minimum, document the race so the next reader doesn't assume atomicity.

### Low / Nit

1. **`tx?` parameter on the repo method is unused flexibility.** `appointment.repository.ts:507` declares `tx?: Prisma.TransactionClient` but no current caller passes it (the service call at line 256 does not supply a transaction). The signature matches the existing `hasActiveServicesForAppointment` pattern, so this is consistent — but the call site should either pass the transaction (if Medium #2 is taken seriously) or the parameter should be dropped. Right now it's neither.

2. **HTTP status code choice.** `appointment.service.ts:259-263` throws a 400 for "patient is currently admitted". The request itself is syntactically valid; the conflict is with current resource state. A 409 `Conflict` is more semantically correct here, and matches how concurrent state conflicts are typically surfaced.

3. **Method name.** `hasActiveAdmissionForAppointmentPatient` is awkward — the `ForAppointmentPatient` suffix is redundant when the parameter is `patientId`. Rename to `hasActiveAdmissionByPatient` or just `hasActiveAdmission` to mirror the brevity of `hasActiveServicesForAppointment`.

4. **Error message tone.** "Can't confirm: patient is currently admitted (IPD)." mixes a colloquial contraction with an internal acronym in user-facing copy. Prefer "Cannot confirm appointment: patient has an active IPD admission." — or surface this through a localized i18n key if the codebase has one.

## Recommendation
Approve after addressing the unused `patientType` field (drop it from this PR or land the dependent logic) and clarifying the TOCTOU decision. The unused `tx` parameter, naming, and 400-vs-409 are minor and can be folded into a follow-up cleanup.