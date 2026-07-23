# Code Review: PR #3019 — Add appointment ID in appointment search
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-29/appointment-search-86eyar7zt` → `development`
**Files changed:** 1 (+6 / -0)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86eyar7zt

## Summary
This PR intends to add appointment-ID matching to the existing appointment search. However, the same `appointmentId` condition is already present later in the search OR-list, so the change only duplicates an existing predicate and does not alter search behavior.

## Verdict
**Approve with suggestions**
Score: 98/100
Critical: 0 | High: 0 | Medium: 0 | Low: 1 | Nit: 0

## Issues

### Critical
None

### High
None

### Medium
None

### Low / Nit
- **Low — `src/app/(dashboard)/shared/appointment/repositories/appointment.repository.ts:661`:** The newly added `appointmentId` predicate duplicates the identical predicate already present in the same `OR` array around line 688. The generated query gains a redundant condition, while the advertised feature was already implemented before this PR; remove the duplicate and verify whether the ticket targets a different search path or behavior.

## Recommendation
Remove the newly duplicated predicate. Reproduce the reported appointment-ID search problem against the existing condition, identify the actual failing search path or expected behavior, and add a focused test that demonstrates the required change before updating the implementation.
