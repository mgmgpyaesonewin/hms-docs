# Code Review: PR #2956 — Psk/27/ot dropdown enhance
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/27/ot-dropdown-enhance` → `development`
**Files changed:** 39 (+1365 / -905)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-12
**ClickUp:** https://app.clickup.com/t/9018849685/86ey557a6

## Summary
Replaces eager OT/CathLab patient, doctor, clinic, user, anesthesia, service, procedure, item, and main-procedure dropdowns with reusable infinite-scroll selectors, adds selected-record lookup endpoints, and introduces module-department filtering for OT/CathLab services and procedures.

## Verdict
**Request changes**
Score: 82/100
Critical: 0 | High: 2 | Medium: 0 | Low: 1 | Nit: 0

## Issues

### Critical
None

### High
- `src/components/search-bar-select-with-infinite-scroll/patient-search-select.tsx:62`: `fetchPatientById` already resolves to `Patient | null`, but it is cast to `Promise<Patient>`; a missing/deleted ID can set `syntheticItem` to `null` and then `getOptionValue(syntheticItem)` throws while rendering. Remove the cast, make `fetchItem` nullable, and only store a non-null result.
- `src/app/(dashboard)/cathlab/request-list/features/components/cathlab-request-form.tsx:883` and `src/app/(dashboard)/ipd/features/components/service-request/cathlab/cathlab-request-form.tsx:905`: assistant-doctor validation now reads `errors.cardiologists[index].cardiologistId`, so assistant-doctor errors are hidden or a cardiologist error appears on the wrong field. Restore `errors.assistantDoctors?.[index]?.assistantDoctorId?.message` in both forms.

### Medium
None

### Low / Nit
- `src/app/(dashboard)/emr/ipd/features/components/pharmacy-request/ipd-emr-pharmacy-request-form.tsx:267` and `src/app/(dashboard)/emr/ipd/features/components/prescription/ipd-emr-prescription-form.tsx:168`: large blocks of obsolete imports, queries, handlers, and JSX were commented out instead of removed. Delete the commented code; version control already preserves it.

## Recommendation
Fix the nullable selected-patient lookup and both miswired assistant-doctor error paths, add focused tests for an unavailable selected ID and assistant-doctor validation rendering, then remove the commented legacy dropdown implementations.
