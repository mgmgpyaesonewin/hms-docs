# Code Review: PR #2929 — feat:opd appointment list
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `feat/april/sprint27/opd-appointment-list` → `development`
**Files changed:** 4 (+11 / -1)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-10
**ClickUp:** https://app.clickup.com/t/9018849685/86ey63k47

## Summary
Wires up an "OPD Appointment List" entry across the UI shell: registers it as a new submodule under "OPD Management" in `permission-ui-config.ts`, adds it as a child of the OPD Management group in `sidebar-link-config.ts`, and adds it to the routing remap inside `use-submodule-sidebar-links.ts` (the hook that rewrites OPD Billing children into the OPD Management branch). Also swaps a previously-dangling `readOnly` prop on `<AppointmentCard>` for `mode="viewOnly"`.

## Verdict
**Request changes**
Score: 60/100
Critical: 1 | High: 2 | Medium: 2 | Low: 0 | Nit: 2

## Issues

### Critical

1. **The `/opd/appointments` route does not exist.** Both `src/components/sidebar-link-config.ts` and `src/hooks/use-submodule-sidebar-links.ts` point the new sidebar entry at `href: "/opd/appointments"`, but `src/app/(dashboard)/opd/` only contains `opd-billing/`, `opd-refund/`, and `services/` — there is no `appointments/` segment under it. Clicking the new menu item will 404. Either the route was supposed to land in a sibling PR or this PR is incomplete as shipped. (Compare with the sibling request modules — e.g. HD/ENDO/OT/CathLab — which live under `/opd/opd-billing/<x>-request-list` and are routed from there. If "OPD Appointment List" is meant to follow the same pattern, the href should be `/opd/opd-billing/appointment-list` or similar; if it is a brand-new top-level route, the page tree is missing.)

### High

1. **`mode="viewOnly"` is silently ignored.** `AppointmentCard` (`src/app/(dashboard)/appointment/appointment-list/features/components/appointment-card.tsx`) is typed as `{ appointment: Appointment }` — it has no `mode`, `viewOnly`, or `readOnly` prop, and its internal render is unconditional (`PermissionGuard action="Edit"` and the `AppointmentStatusSelect` both render unconditionally on booked/confirmed). The previous `readOnly` was already silently dropped (so this is a no-op "rename"), but the rename suggests an intent — hide edit/status controls on the patient profile view — that is not implemented. Either the prop needs to be added to `AppointmentCard` and consumed (wrapping the edit action and status select) or this line should be removed entirely. As written, the patient profile still surfaces editable controls the author appears to want hidden.

2. **`opdSidebarLinks` is not updated.** The hook in `use-submodule-sidebar-links.ts` adds `"OPD Appointment List"` to the list of OPD-Billing children that get remapped onto `OPD Management`, but `src/app/(dashboard)/shared/opd/sidebars/opd-sidebar-links.ts` (the actual source of `opdSidebarLinks`) does not contain a child with that label. The conditional `if ([...].includes(label))` will never match, so the sidebar hook adds nothing. The link only appears because `sidebar-link-config.ts` adds it directly — meaning the permission-aware branch (the whole reason this hook exists) is bypassed for this entry. Add the child to `opdSidebarLinks` with its canonical `/opd/opd-billing/...` href, then let the hook remap it.

### Medium

1. **`opdManagementLink?.children` order list is incomplete.** The hook at line 245 sorts the OPD Management children using `opdManagementOrder = ["ENDO Requests", "OT Requests", "HD Requests", "CathLab Requests"]`. The new entry "OPD Appointment List" is not in that order, so it falls into the `indexOf === -1` branch and is sorted to the end via the `return 1` / `return -1` asymmetry. That is fine by accident, but the implicit sort should be made explicit: either include "OPD Appointment List" in `opdManagementOrder` with the intended position, or add a comment noting alphabetical fallback. Today a future contributor adding another child will hit the same trap.

2. **No icon on the new sidebar entry.** Every other entry added via this hook has an `icon` mapped through `lucidIconMap` (`FileTextIcon`, `HandHeart`, `CalendarClock`). The new "OPD Appointment List" entry has no icon field at all and the hook does not set one, so it will render with the default/blank sidebar icon — visually inconsistent with the other OPD Management entries (HD/ENDO/OT/CathLab all have icons). Add an icon (or document why this one is intentionally iconless — e.g. if the CalendarClock from `appointmentSidebarLinks` is meant to be reused, thread it through the same way the existing `lucidIconMap` is used).

### Low / Nit

1. **Permission list `excludeActions: ["add", "edit", "delete"]` is unusual but legitimate** — the rest of `permission-ui-config.ts` mostly uses `["delete"]` or `["changeStatus"]`. Worth a one-line comment explaining that "OPD Appointment List" is read-only by design so a future reviewer doesn't "fix" the excludes.

2. **Diff comment hygiene.** The `mode="viewOnly"` rename reads as if the author was chasing a working API that doesn't exist. A `// ponytail: AppointmentCard ignores unknown props today; remove this line or implement the prop` comment would prevent the next reader from assuming it does something.

## Recommendation
Two blocking items before merge:

1. Either add the `/opd/appointments` page tree (Next.js route + list + permission) in this PR, or point the sidebar at the existing appointment list under `/opd/opd-billing/<x>-request-list` / `/reception/appointments` (the right home depends on what the ticket actually wants — worth clarifying against the ClickUp ticket before shipping).
2. Either implement a `mode` / `viewOnly` prop on `AppointmentCard` that hides the `AppointmentStatusSelect` and the Edit `ActionIcon` inside `PermissionGuard action="Edit"`, or drop the new prop line entirely. As-is it is dead code that future readers will misinterpret.

Once those two are addressed, the two Medium items (sort-order array + icon) are quick follow-ups. Low/Nit items can be addressed in a separate polish PR.