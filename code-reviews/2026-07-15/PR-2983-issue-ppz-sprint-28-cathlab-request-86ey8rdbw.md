# Code Review: PR #2983 — Issue/ppz/sprint 28/cathlab request 86ey8rdbw
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `issue/ppz/sprint-28/cathlab-request-86ey8rdbw` → `development`
**Files changed:** 2 (+12 / -7)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-15
**ClickUp:** https://app.clickup.com/t/9018849685/86ey8rdbw

## Summary
The PR moves `DoctorSearchSelect`'s doctor-type filtering from client-side (`getItems` `filter` on the result list) to server-side by forwarding `doctorType: referralInOut` through `query`, exposing the existing `query` prop on the wrapper, and dropping the post-fetch filter. It also adds three UX affordances to `IpdEmrStandardServiceRequestForm`: `key={`doctor-in-${watchedReferralType}`}` / ``key={`doctor-out-${watchedReferralType}`}` to force remount of the doctor select when the referral direction toggles, `keepSelectedItem={isEditMode}` so an already-bound doctor/clinic still renders its label when its page is not loaded, and the same flag on the clinic select. The callers wire `referralInOut={DoctorType.IN_SERVICE}` / `OUT_SERVICE`; `fetchDoctors` forwards the filter as query params, and `getDoctorsSchema` declares `doctorType` as optional, so server-side filtering is contract-correct.

## Verdict
**Approve**
Score: 100/100
Critical: 0 | High: 0 | Medium: 0 | Low: 0 | Nit: 0

## Issues

### Critical
None

### High
None

### Medium
None

### Low / Nit
None

## Recommendation
Merge as is. The refactor correctly shifts the `doctorType` filter to the API layer (server-side filtering is the right home — avoids over-fetching and stale pages when switching referral direction), and the `key={...watchedReferralType}` plus `keepSelectedItem={isEditMode}` pair solves the stale-clone problem when toggling referral type in edit mode without affecting create mode. No follow-up required.
