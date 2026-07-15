# Code Review: PR #2929 — feat:opd appointment list
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `feat/april/sprint27/opd-appointment-list` → `development`
**Files changed:** 6 (+12 / -4)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-11
**ClickUp:** https://app.clickup.com/t/9018849685/86ey63k47

## Summary
This PR introduces an OPD Appointment List view. The new UI is implemented inside the `src/app/(dashboard)/opd` and `src/app/(dashboard)/appointment` git submodules (which this diff only shows as pointer bumps, so the actual feature code is not reviewable from this repo). The visible changes in the main repo are pure wiring:

1. A new sidebar entry linking to `/opd-management/appointments`.
2. A new rewrite rule `/appointments` → `/opd-management/appointments` so legacy URLs still resolve.
3. A new permission submodule "OPD Appointment List" inside "OPD Management", restricted to read-only (`excludeActions: ["add", "edit", "delete"]`).
4. A rename of the `AppointmentCard` prop on `PatientAppointmentsTab` from `readOnly` to `mode="viewOnly"`, presumably to align with a new prop signature in the (submodule) `AppointmentCard` component.

## Verdict
**Request changes**
Score: 64/100
Critical: 0 | High: 1 | Medium: 3 | Low: 2 | Nit: 1

## Issues

### Critical
None

### High

**H1 — Submodule code is not reviewable.** Two of the six "files changed" are submodule pointer bumps (`src/app/(dashboard)/opd`, `src/app/(dashboard)/appointment`) where the actual feature — the new list page, any data fetching, any UI components, any filtering/sorting/pagination — lives. Without being able to look at those diffs (submodule repos are separate and out of scope from this PR's URL) we cannot confirm whether the wiring in the main repo matches the contract the submodule assumes. The `mode="viewOnly"` rename in `patient-appointments-tab.tsx` is the only indication of the submodule API surface, and that single rename is what makes or breaks callers in the main repo.

Recommendation: PR description should list the submodule PR numbers (or link to submodule diffs), and the wiring diff here should only land AFTER the submodule PR has been reviewed/merged with a known stable `AppointmentCard` API. If the submodule is still in review, this PR is wiring to a moving target.

### Medium

**M1 — `excludeActions: ["add", "edit", "delete"]` leaves `changeStatus` and `export` enabled.** That is presumably the intent (a read-only appointment list is still useful for status changes and exports), but if the intent is strictly read-only, `changeStatus` and `export` should also be excluded. Conversely, if those are intended to be allowed, the PR description / ticket should say so. As written there is no way to tell whether "view-only" means strict-view or view-with-actions.

Recommendation: confirm with the ticket author and either tighten `excludeActions` or document the deliberate permissions decision.

**M2 — Submodule pointer bump with no visible submodule PR link in the body.** The PR body is only a ClickUp link. There is no link to the corresponding submodule PR(s) (`YCare-HMS-Service-Module` and/or `YCare-HMS-Appointment-Module`). This makes the change impossible to audit end-to-end and leaves the merging reviewer unable to verify the submodule HEAD matches what was reviewed.

Recommendation: add submodule PR numbers and the submodule commit SHAs in the PR description.

**M3 — No tests included.** This is the user-facing feature surface for a new list view. The wiring diff is so small that tests would naturally live in the submodule repos, but if any of the wiring here (route rewrite, permission config, sidebar config) has logic worth covering, none is included.

Recommendation: add at least a smoke test for the route rewrite (legacy `/appointments/...` → `/opd-management/appointments/...`) and a permissions unit test confirming `OPD Appointment List` is read-only.

### Low / Nit

**L1 — `route-mapping.ts` rewrite inserted mid-statement.** The new `.replace(/^\/appointments(\/.*)?$/, "/opd-management/appointments$1")` line was spliced in between the `cathlab-request-list` rewrite and the `opd-list` rewrite, leaving it visually attached to neither group. There is a blank line above `opd-list` that hints at a "opd management group" comment, but the new line sits on the wrong side of that boundary.

Recommendation: place the new line inside the same group as the other `opd-management` rewrites for readability, and ensure ordering doesn't matter semantically (anchored `^/` regexes are independent, so behaviour is correct — this is purely a tidiness issue).

**N1 — Whitespace-only change to `route-mapping.ts`.** Before the PR there was a trailing blank line after the `cathlab-request-list` `.replace(...)`; that is now gone. Harmless, but the touch here is otherwise surgical and this looks like an accidental reformat from editing.

## Recommendation
1. Add the submodule PR links and commit SHAs to the PR body so the feature code can be reviewed in context. Without that, this PR is unverifiable end-to-end (High).
2. Confirm whether "OPD Appointment List" should be strictly read-only or view-with-actions, and adjust `excludeActions` or document the choice (Medium).
3. Insert the route rewrite into the existing opd-management group and re-add the trailing blank line for readability (Low/Nit).
4. Land submodule PR first, get the `AppointmentCard` `mode` API merged, then land this wiring PR on top — do not let both PRs sit in flight with a coupling that crosses repos.
