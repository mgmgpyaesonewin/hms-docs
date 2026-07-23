# Code Review: PR #3037 — Incorrect Overall Status when Lab Test is Cancelled
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `issue/ppz/sprint-29/lab-module-86ey8xqgh` → `development`
**Files changed:** 7 (+47 / -22)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86ey8xqgh

## Summary
This PR updates aggregate lab workflow statuses so cancelled lab services no longer prevent remaining active services from determining the overall acknowledge, report, result-entry, verification, testing, and test-done statuses. It also makes an entirely cancelled sample collection display as cancelled. The intended mixed active/cancelled cases are handled, but filtering leaves an empty active list when every service is cancelled, and JavaScript treats `every(...)` on that list as true.

## Verdict
**Request changes**
Score: 92/100
Critical: 0 | High: 1 | Medium: 0 | Low: 0 | Nit: 0

## Issues

### Critical
None

### High
- All-cancelled records are reported as completed in six downstream workflows. In `lab-acknowledge-columns.tsx`, `lab-report/features/utils/index.ts`, `lab-result-entry-columns.tsx`, `lab-result-verification-columns.tsx`, `lab-test-done-columns.tsx`, and `lab-testing-columns.tsx`, filtering out every cancelled service produces `[]`; `[].every(...)` is `true`, so an entirely cancelled order displays as `ACKNOWLEDGED`, `DELIVERED`, `ENTERED`, `VERIFIED`, `TESTDONE`, or `TESTING`. Add an explicit non-empty guard before each completion check, and define the intended all-cancelled fallback status rather than relying on vacuous truth.

### Medium
None

### Low / Nit
None

## Recommendation
Add `allActiveStatuses.length > 0` to every `every(...)` completion condition and confirm the product-defined display for orders with no active services. Add focused tests covering all-cancelled, mixed cancelled/completed, and mixed cancelled/pending inputs for each aggregate status function before merging.
