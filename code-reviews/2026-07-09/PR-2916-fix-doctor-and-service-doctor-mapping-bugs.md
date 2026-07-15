# Code Review: PR #2916 — fix doctor and service doctor mapping bugs
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `fix/april/sprint-27/servie-and-doctor-issues` → `development`
**Files changed:** 1 (+2 / -0)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-09
**ClickUp:** https://app.clickup.com/t/9018849685/86ey740uy

## Summary
A 2-line UX fix that adds `searchable` to the `Specialization` and `Department` `Select` inputs inside `DoctorsFilterModal`. No mapping/business-logic changes — purely enables type-ahead on two filter dropdowns.

## Verdict
**Approve with suggestions**
Score: 96/100
Critical: 0 | High: 0 | Medium: 1 | Low: 0 | Nit: 0

## Issues

### Critical
None

### High
None

### Medium

**1. PR title/description doesn't match the diff (semantic-noise)**
- Title claims "fix doctor and service doctor mapping bugs" — readers (and `git log` grep) will expect changes in doctor↔service mapping code (e.g., join tables, APIs, form save logic).
- Actual diff: only the `DoctorsFilterModal` `Select`s gain `searchable`. The two changes are unrelated to "mapping".
- Branch name `servie-and-doctor-issues` (note the typo "servie") reinforces the mismatch.
- Suggest: rename the PR to something accurate (e.g., `fix(doctors): make filter modal specialization and department selects searchable`) so future archeology via `git log --grep` lands on the right change. If the ticket also covers separate mapping bugs, push those as separate PRs — one bug, one PR.

### Low / Nit
None

## Recommendation
- Land as-is. The code change itself is correct and minimal.
- Rename the PR title and branch to match the actual scope before merging (or split into separate PRs if mapping bugs are still pending).
- Ponytail note: diff is already as small as it can be. Nothing to delete. Ship.