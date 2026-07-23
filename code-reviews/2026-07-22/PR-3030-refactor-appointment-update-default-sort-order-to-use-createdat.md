# Code Review: PR #3030 — refactor(appointment): update default sort order to use createdAt
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/29/resort-appointment-list` → `development`
**Files changed:** 1 (+7 / -4)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86eybnyye

## Summary
Changes the appointment repository's default `findAppointments` ordering to always sort by `createdAt DESC`, removing the previous branch that switched between `appointmentDate DESC` (for non-OTHERS categories) and `createdAt DESC` (for `AppointmentCategory.OTHERS`). Since OTHERS rows have `appointmentDate = null` (see repo writes at lines 217/323), the old branch was effectively a workaround for null-sort behavior; the new code sorts consistently on a non-null field for every category.

## Verdict
**Approve with suggestions**
Score: 92/100
Critical: 0 | High: 0 | Medium: 1 | Low: 0 | Nit: 1

## Issues

### Critical
None

### High
None

### Medium
- **Behavior change, not just a refactor.** The PR title says "refactor" but the default ordering for non-OTHERS appointments changes from `appointmentDate DESC` to `createdAt DESC`. Any caller relying on the prior "most-recent appointment-date first" list ordering will get a different list. The ClickUp task title (`resort-appointment-list`) and the body wording ("removing the conditional logic") suggest this is intentional, but it should be called out explicitly in the PR body as a behavior change so reviewers and QA don't miss it. Recommend confirming that all UI surfaces consuming this list either already rely on `createdAt`-style ordering or are being updated in a follow-up.

### Low / Nit
- **Dead commented-out code left in place.** The old ternary is preserved as a `//` block comment (lines 758-761 of the file in the diff). Commented-out code is dead weight — it survives in `git blame` and `git log` if anyone wants it back. Just delete it. Net effect on the diff if removed: `+3/-4` instead of `+7/-4`.

## Recommendation
1. Delete the commented-out ternary block in `appointment.repository.ts` — git history is the right place to recover old code, not the source file.
2. Update the PR body to flag the user-visible ordering change for non-OTHERS appointments (the rest of the task title `resort-appointment-list` already hints at this), so the behavior change is reviewable and testable rather than slipping in under a "refactor" label.
3. Once those two are addressed, this is ready to merge.
