# Code Review: PR #2972 — fix(opd): sync appointment data when updating OT request
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/28/fix-sync-appointment` → `development`
**Files changed:** 2 (+203 / -17)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-17
**ClickUp:** https://app.clickup.com/t/9018849685/86ey344y0

## Summary
This PR wraps the linked appointment update and OPD OT-request update in one Prisma transaction. It synchronizes the patient, appointment type, and referral fields and adds unit coverage for the successful update and the missing-appointment guard.

## Verdict
**Request changes**
Score: 92/100
Critical: 0 | High: 1 | Medium: 0 | Low: 0 | Nit: 0

## Issues

### Critical
None

### High
1. **Updating four appointment fields through `updateAppointmentById` destructively clears unrelated appointment data** (`src/app/(dashboard)/shared/opd/services/opd-ot-request.service.ts:202`). The repository method is a full appointment editor: before updating, it deletes every `appointmentService`, then recreates services from `payload.appointmentServices ?? []`; because this call omits `appointmentServices`, every linked service is deleted. It also derives `isOthers` from the omitted `appointmentCategory`, so it writes `doctorId`, `appointmentDate`, `start`, `end`, and `timeslotId` as `undefined`, and similarly omits `isFollowUp`. This makes a narrowly scoped OT edit invoke destructive full-replacement behavior. Add a dedicated partial repository update (or direct transaction-scoped Prisma update) for `patientId`, `appointmentTypeId`, and `updatedById`, plus the referral synchronization, without deleting appointment services or rewriting unrelated fields. Add a regression test with existing appointment services and unrelated appointment fields to prove they remain unchanged.

### Medium
None

### Low / Nit
None

## Recommendation
Do not reuse the full appointment-edit repository method for this partial synchronization. Introduce the smallest transaction-aware partial update that changes only the intended appointment and referral fields, then add a regression test asserting existing appointment services and unrelated scheduling fields are preserved. Keep the outer transaction so appointment and OT-request changes remain atomic.
