# Code Review: PR #3033 — fix service request form delay 
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `fix/april/sprint29/service-request-form` → `development`
**Files changed:** 3 (+56 / -139)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86ey9wev9

## Summary
This PR removes eager, unbounded doctor and clinic queries from the EMR and IPD service-request forms and replaces them with the existing paginated infinite-search selects. It also removes an unnecessary nested transition from navigation. The change directly addresses initial form delay while reducing duplicated option-building code.

## Verdict
**Approve with suggestions**
Score: 99/100
Critical: 0 | High: 0 | Medium: 0 | Low: 0 | Nit: 1

## Issues

### Critical
None

### High
None

### Medium
None

### Low / Nit
- **Nit — both service-request forms:** Boolean props are written verbosely as `withAsterisk={true}`, `searchable={true}`, and `clearable={true}`. Use the JSX shorthand `withAsterisk`, `searchable`, and `clearable` to match the surrounding style and keep the replacement concise.

## Recommendation
Apply the JSX boolean-prop shorthand cleanup. Otherwise, the focused change is ready to merge; verify create and edit flows for referral-in doctors, referral-out doctors, and referral-out clinics, including preservation of an existing selected value that is not in the first page of results.
