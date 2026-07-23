# Code Review: PR #3036 — OPD appt only in consultation appt
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `mpt/opd-appt-only-consultation-appt` → `development`
**Files changed:** 1 (+1 / -1)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86ey936zg

## Summary
This PR advances the appointment-module submodule from `607251d` to `1c1eaef`. The referenced module change filters the consultation appointment-type selector to OPD-enabled types while retaining the currently selected type during edits. The implementation is small and readable, but the OPD-only rule currently exists only in the UI and can be bypassed by sending a request directly.

## Verdict
**Request changes**
Score: 92/100
Critical: 0 | High: 1 | Medium: 0 | Low: 0 | Nit: 0

## Issues

### Critical
None

### High
- **The OPD-only consultation rule is enforced only by the select component.** In `book-appointment/features/components/appointment-types-select.tsx`, filtering the options improves the UI but does not validate submitted data. `appointmentFormSchema` only checks that `appointmentTypeId` is a UUID, and `AppointmentService.bookAppointment` / `editAppointment` persist it without verifying that a consultation appointment type includes `ModuleEnum.OPD`. A direct or stale client can therefore create or edit a consultation appointment with a non-OPD type, defeating the stated business rule. Enforce the invariant in the server-side appointment service or repository lookup and reject invalid combinations; keep the UI filter for usability.

### Medium
None

### Low / Nit
None

## Recommendation
Add server-side validation for both booking and editing: when `appointmentCategory === "CONSULTATION"`, load the selected appointment type and require its `modules` to contain `ModuleEnum.OPD`. Add focused tests covering acceptance of an OPD type and rejection of a non-OPD type. The client-side filtering can remain unchanged. The ponytail pass found no unnecessary abstraction or dependency to remove.
