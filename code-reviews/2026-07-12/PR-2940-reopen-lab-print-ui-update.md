# Code Review: PR #2940 — Reopen - lab print ui update
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-27/lab-print-ui-86ey4c3qp` → `development`
**Files changed:** 10 (+545 / -387)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-12
**ClickUp:** https://app.clickup.com/t/9018849685/86ey4c3qp

## Summary
Centralizes the standard lab-report preview for EMR and IPD, adds microbiology previews, and updates printable lab layouts and report dates.

## Verdict
**Request changes**
Score: 92/100
Critical: 0 | High: 1 | Medium: 0 | Low: 0 | Nit: 0

## Issues

### Critical
None

### High
- `src/app/(dashboard)/ipd/features/components/service-request/lab/view-lab-report-modal.tsx:52`: `{isLoading || (isLoadingMicroBiologyTemplate && <Stack>...)}` evaluates to the boolean `true` whenever either of the first two queries is loading, so React renders no loader. Replace it with `{isLoading && (<Stack>...</Stack>)}`; `isLoading` already includes the microbiology query.

### Medium
None

### Low / Nit
None

## Recommendation
Fix the IPD loading conditional and verify the modal displays its loader while each of the three requests is pending. The shared preview move and microbiology rendering otherwise need no extra abstraction.
