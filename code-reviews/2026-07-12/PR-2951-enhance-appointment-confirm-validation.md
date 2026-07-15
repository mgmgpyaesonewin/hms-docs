# Code Review: PR #2951 — Enhance appointment confirm validation
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `enhance/april/sprint27/appointment-confirm-validation` → `development`
**Files changed:** 2 (+31 / -0)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-12
**ClickUp:** https://app.clickup.com/t/9018849685/86ey5kzve

## Summary
Adds a guard that blocks an appointment from transitioning to `CONFIRMED` while the patient has an active admission (`Admission.status === "ACTIVE"`). The check is implemented as a new repository predicate `hasActiveAdmissionForAppointmentPatient(patientId, tx?)` and called from `updateAppointmentStatus` in the appointment service, mirroring the shape of the adjacent `hasActiveServicesForAppointment` block that gates the `CANCELLED` transition. The PR also adds `patientType: true` to the `appointmentValidator` patient-select block.

## Verdict
**Approve with suggestions**
Score: 95/100
Critical: 0 | High: 0 | Medium: 0 | Low: 2 | Nit: 1

## Issues

### Critical
None

### High
None

### Medium
None

### Low

1. **`patientType: true` is added without a tie to this diff.** In `appointment.repository.ts` (inside `appointmentValidator`), the PR appends `patientType: true` to the `patient` select. The new admission guard does not read `patientType`, and `getAppointmentById` callers in this PR do not either. The field does exist in `appointment.types.ts:71` and is selected elsewhere, so this is likely a pre-existing under-fetch being corrected — but the PR description does not mention it. If it's a drive-by needed for an unrelated consumer, keep it; otherwise drop it from this PR and ship the change separately so the diff is reviewable in isolation.

2. **TOCTOU between admission check and status update.** `hasActiveAdmissionForAppointmentPatient` is awaited *before* the `prisma.$transaction` that performs the status update and cascades to `endoRequest` / `otRequest`. A patient could be admitted in the gap and the appointment would still be confirmed. The sibling CANCELLED branch has the same property, so the PR is consistent with the local pattern; flagging because for an "active admission" guard, the natural fix is to fold the count into the transaction (`tx.admission.count({...}, { isolationLevel: ... })` or a `SERIALIZABLE` retry). Low priority because the existing app already accepts this race for the CANCELLED branch.

### Nit

1. **Method name is verbose.** `hasActiveAdmissionForAppointmentPatient` reads awkwardly; the existing sibling is `hasActiveServicesForAppointment`. Rename to `hasActiveAdmissionForPatient` (drops the redundant "Appointment") to match the brevity of the surrounding vocabulary while keeping the contract clear.

## Notes (not findings)

- The new repo method accepts a `tx?` parameter that no caller passes. Keeping it for symmetry with `hasActiveServicesForAppointment(appointmentId, tx?)` is reasonable since this is the local idiom; not flagging as yagni because the pattern is one-method-with-zero-tx-callers today and one-with-one-tx-caller tomorrow is exactly the kind of speculative flexibility the codebase already lives with.
- Placement of the check is correct: it runs after `validateAppointmentStatus`, so a no-op `CONFIRMED → CONFIRMED` re-confirm is rejected by the state-machine validator before reaching the admission query.
- The check correctly does not apply to the `CANCELLED` transition. Whether the clinical workflow should also block cancelling an appointment for an admitted patient is a product decision, not a code defect; if business wants it, mirror the same shape.
- No tests added. The neighbouring CANCELLED branch is also untested at this layer (existing convention is route-level integration coverage), so the PR matches house style.