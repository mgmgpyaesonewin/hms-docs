# PR #2882 — appointment check in admission

**Repo:** MyanCare/Ycare-HMS
**PR:** https://github.com/MyanCare/Ycare-HMS/pull/2882
**Author:** April-Naing
**Branch:** `enhance/april/sprint-26/appt-check-in-admission` → `development`
**State:** OPEN
**Changed files:** 4 (+36 / -4)
**ClickUp:** https://app.clickup.com/t/9018849685/86ey5kut0
**Verdict:** Approve with suggestions

## Summary

Two related changes sit in this PR:

1. **Patient-level "has confirmed appointment" guard at admission time** (`patients-repository.ts` + `admission-form.tsx` + `types/index.ts`). The patient-list `_count` now also counts `appointments` filtered to `status: CONFIRMED` and no `ProxyBill`/`OPDBilling`; the form rejects any patient with such an appointment via toast `"This patient has Confirmed appointment."` The other `_count` filters (`pharmacySales`, `ProxyBill`) are widened from `patientType: "OPD"` to `["OPD", "EMERGENCY"]` and gain `isConsignment: false`, matching the convention already used by OPD/EMR bookings (`book-appointment`, `cathlab-request-table-columns`, etc.). The intent is right: an ED/EMG patient with an open confirmed appointment shouldn't silently disappear into IPD admission without their appointment being checked in first.

2. **`HOUSEKEEPING` is now bookable in `AdmissionService.handleRoomAllocation`** (`admission.service.ts:358-362`). The fail-safe previously only accepted `roomStatus === "AVAILABLE"`; it now accepts `AVAILABLE || HOUSEKEEPING`. This aligns the service-layer check with the already-present `roomStatus: "AVAILABLE_AND_HOUSEKEEPING"` filter in `select-room-modal.tsx:55` (the UI has been offering HOUSEKEEPING rooms as bookable; the service was rejecting them — a click landed on a 500). Real bug fix.

Net +32 lines for two real behavior changes. Approve, with a few follow-ups.

## Strengths

- `patients-repository.ts:208-241` — consistent widening to `["OPD", "EMERGENCY"]` and `isConsignment: false` filter (matches convention in `opd-form.tsx:278`, `opdBilling-select.tsx:272-293`, `appointment-select.tsx:65`).
- `admission.service.ts:358-362` — `HOUSEKEEPING` as bookable closes the UI/service inconsistency. Locking discipline (`SELECT ... FOR UPDATE NOWAIT` + post-lock re-read) is unchanged and correct (see PR #2783).
- No scope creep; repository-only addition (new `_count.appointments` is computed in the same `prisma.patient.findMany` round trip — no extra query, no N+1).
- `flattenPatientsData` exposes the new flag under a well-named field (`hasConfirmedAppointments`) matching `hasPendingBills`.

## Issues (Important)

1. **`admission-form.tsx:543-549` — `appointmentDate` is not bounded**, and `Appointment.status` has no `NO_SHOW`/auto-cancel transition. `_count?.appointments > 0` therefore fires forever on any historical `CONFIRMED` appointment that was never manually checked in. The codebase elsewhere relies on `status: CONFIRMED` meaning "today or future" — but the appointment lifecycle has no cleanup. Add `appointmentDate: { gte: <today> }` (or whatever the team considers "current") to the new `_count` filter, or rename the field `hasUnbilledConfirmedAppointments` so the next reader doesn't assume it's about today. This is the bug-grade fix; symptom will be routine "I can't admit this patient" tickets as old confirmed-but-no-show appointments pile up.

2. **`patients-repository.ts:225-235` — same point from the repository side.** Add the `appointmentDate` bound here; without it the gate will fire on stale confirmations.

3. **`admission.service.ts:355-362` — comment is now misleading.** It implies the race is *only* against a committed-between-read-and-lock transition. With `HOUSEKEEPING` accepted, the post-lock read can return `HOUSEKEEPING` legitimately and the throw below is unreachable on that branch. Update the comment to clarify "AVAILABLE = freshly bookable; HOUSEKEEPING = bookable but pre-flagged for housekeeping post-check-in; everything else = someone else has it". Also: all three room-related throws in `handleRoomAllocation` should be `throw new AppError(..., 409)` to surface the friendly error to the client (a plain `Error` is mapped to 500); same `AppError` vs `Error` inconsistency flagged in the PR #2783 review (Medium #3). Out of scope for this PR; flag for a follow-up.

4. **`admission-form.tsx:543-549` — stray capital "Confirmed" + grammar:** `"This patient has Confirmed appointment."` doesn't match the sibling sentence-case convention in this branch. Sibling messages are "This patient has an Active admission status..." / "This patient has an existing OPD bill". Fix to `"This patient has a confirmed appointment."`.

## Issues (Nit)

5. **`patients-repository.ts:20` — possible import cycle.** `appointmentStatus` is imported from `shared/appointment/types/appointment.types`, which itself imports `Patient` from `common/patients/features/types`. Verify with `npm run tsc` (the source of truth, since `next.config.ts` ignores TS errors at build). If it cycles, extract `appointmentStatus` to a leaf module.

6. **`admission-form.tsx:543-549` — no `setHasBillError(false) / setActiveAdmissionPatientError(false)` reset before the toast.** The success branch at `:552-555` explicitly resets both; the rejection branches (`hasPendingBills`, new `hasConfirmedAppointments`) do not. Consistent tightening: every "reject this patient" branch should run the same three resets.

7. **PR title is vague.** "appointment check in admission" is ambiguous. Suggest: `fix(ipd): block admission on unbilled CONFIRMED appointment; allow HOUSEKEEPING rooms`.

8. **PR body is just a ClickUp link.** Two behavior changes — one a real bug fix (HOUSEKEEPING) and one a new business rule (confirmed-appointment guard) — both worth one-line summaries for future archaeologists.

9. **`admission.service.ts:359-362` — bare string literals** (`"AVAILABLE"`, `"HOUSEKEEPING"`). The rest of the file uses `RoomStatus` enum (e.g. `RoomStatus.AVAILABLE` at `:365`, `:410`). Grep-replace to the enum for consistency.

10. **No asymmetry note for the *baby* path.** `admission-form.tsx:1434` already gates newborns on `hasPendingBills` but not on `hasConfirmedAppointments`. Probably correct (newborns are checked in via mother), but the PR description should call it out.

## Security / Privacy

- No secrets, PII handling, or permission boundary changes. The `_count.appointments` reads from a join the caller already has access to. No issues.

## Recommendations

1. Add `appointmentDate >= today` (or rename the field to clarify intent) — Important #1, #2.
2. Tighten the toast wording — Important #4.
3. Update the `handleRoomAllocation` post-lock fail-safe comment; consider `RoomStatus` enum constants — Important #3.
4. Verify import cycle with `npm run tsc` — Nit #5.
5. Add the PR description and a clearer PR title.
6. Optional follow-up: convert `throw new Error(...)` in `handleRoomAllocation` to `throw new AppError(..., 409)`.

## Reviewer notes

- **The HEAD commit message and the diff agree.** Two real behavior changes; the body should describe both.
- **The HOUSEKEEPING change is the headline bug fix.** Without it, an admin booking a just-discharged-cleaning room hits a 500 even though the UI offered it as available. Locking discipline unchanged from PR #2783.
- **The confirmed-appointment gate is the larger in scope** because of the stale-appointment trap. The `appointmentDate` follow-up is the one I'd be most confident shipping in this PR or as an immediate follow-up.
- **No summary-service, outbox, HMAC, or tenant-scope implications** — purely HMS module changes.

## Verification needed

1. Insert an `Appointment` with `status: CONFIRMED`, `appointmentDate` two weeks ago, no bills; the new gate should NOT fire — confirm whether #1 above is a real risk in this codebase.
2. `npm run tsc` cleanly after import added.
3. Housekeeping fail-safe: set a room to `HOUSEKEEPING`, book it via the admission form, verify success and the `REQUESTED` / `PREREQUESTED` transition.
4. Edge: patient with both pending pharmacySale and confirmed appointment — confirms pre-PR ordering (pharmacySale wins) is preserved.

## Checklist results

- [x] Hardcoded secrets / SQL injection / no console-log / no `any` / no `!` — clean.
- [ ] `appointmentDate` filter added to gate — FAIL (see Important #1, #2).
- [ ] Fail-safe comment updated for HOUSEKEEPING — minor (Important #3).
- [x] Domain consistency (`["OPD", "EMERGENCY"]`, `isConsignment: false`) — adopted.
- [ ] Import-cycle check between `common/patients` ↔ `shared/appointment` — not run.

## Recommendation

**Approve with suggestions.** Ship the HOUSEKEEPING bug fix now. Gate the confirmed-appointment check on either a follow-up adding `appointmentDate >= today` or a rename to `hasUnbilledConfirmedAppointments` to avoid the stale-confirmed-appointment trap. The other items are comment/wording/AppError follow-ups.

**Ponytail net estimate:** diff is lean — only candidate for compression is collapsing the two rejection branches (`hasPendingBills` + `hasConfirmedAppointments`) into one guard expression with a computed message (~5 lines saved). Otherwise the diff is the minimum that works for two real changes; no over-engineering.
