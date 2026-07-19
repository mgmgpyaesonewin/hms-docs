# Code Review: PR #3007 — Fix - Persistent Slow Loading and High Latency in Doctor Selection Dropdown / Menu (Registration & Book Appointment)
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `issue/ppz/sprint-28/patient-registration-86ey9yhwh` → `development`
**Files changed:** 7 (+382 / -147)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-16
**ClickUp:** https://app.clickup.com/t/9018849685/86ey9yhwh

## Summary
Replaces a deeply-nested `doctor.findMany` with a three-query approach (doctors + schedules + timeslot `groupBy`) so the doctor dropdown no longer fans out appointments per timeslot per schedule per doctor — the cause of the 10s latency. Splits the `Doctor` search select from `DoctorWithSchedules` so the heavier-with-schedules variant is only used where actually needed, and swaps `patient-form.tsx` plus the existing `DoctorSearchSelect` / `ClinicSearchSelect` components onto the pre-existing `SearchSelect` infinite-scroll pattern (24 → 7-files touched). Adds a `GET /api/doctors/[id]/schedules` route + matching fetch wrapper so the patient form's "selected doctor" can be re-fetched for `keepSelectedItem`. Repeated `useEntitySearchInfinite` wrappers (12 already exist) get a 13th.

## Verdict
**Approve with suggestions**
Score: 88/100
Critical: 0 | High: 1 | Medium: 3 | Low: 3 | Nit: 2

The fix is real, well-scoped, and reuses the existing `SearchSelect`/`useEntitySearchInfinite` infrastructure — the right pattern. The High item is one dropped `where` clause that changes the public contract of `findDoctorsWithSchedules`; the UI masks the effect in the one screen the PR touches, but other consumers (and `totalCount`) silently see different behavior.

## Issues

### Critical
None.

### High

1. **`doctorWhere` filter regression: doctors with no matching dayOfWeek are now returned.** In `doctors.repository.ts` the original `doctorWhere` was `{ schedules: { some: scheduleWhere }, user: { status: UserStatus.ACTIVE } }`. The PR drops `schedules: { some: scheduleWhere }` (and removes `scheduleWhere.dayOfWeek` from any subquery), so when `query.dayOfWeek` is set the doctor list now includes doctors whose only schedules are on other days. `DoctorCard` (`appointment/.../daily-tab/doctor-card.tsx:23`) happens to render those as `disabled={doctor.schedules.length === 0}`, so the affected screen still looks fine, but:
   - `totalCount` returned to the BFF is now inflated.
   - Other consumers (e.g. the `patient-form.tsx` infinite-scroll path, the pagination offset math) will silently use the inflated count.
   - `withAvailableTimeslots` no longer narrows the doctor set — it now only filters timeslot *counts*, not membership.
   
   **Fix:** either re-add `schedules: { some: scheduleWhere }` to `doctorWhere`, or — since the goal is to avoid the nested JOIN — pass the same shape via `doctorId: { in: <ids-of-doctors-with-matching-schedule> }` resolved in a subquery (`prisma.doctor.findMany({ where: { ..., schedules: { some: scheduleWhere } } })` for the count, and `select: { id: true }` for the membership). The fetch-then-filter approach the PR took should be symmetric — both query paths should narrow the same way.

### Medium

2. **`fetchLimit = query.limit * 10` is undocumented magic.** `doctors.repository.ts:413` — multiplier is heuristic; if more than 90% of ranked results are filtered out (e.g. search broad + dayOfWeek narrow) you under-fetch and `totalCount` loses fidelity (page comes back partial). One-line `// ponytail: 10x overshoot compensates for post-rank filtering; bump if paged results undershoot` would harden this without bloating the diff.

3. **`DoctorWithSchedules.schedules[]` type contract widens silently.** The repository attaches a `timeslotsCount` field to each `schedule` object in the new code (`scheduleMap` build). `doctors.types.ts:66` declares `schedules: DoctorSchedule[]` (the strict `@prisma/client` type). The current consumer `DoctorSchedules.tsx` only reads `schedule.id/startTime/endTime`, so it works, but any future consumer that strictly types `schedule` will either see a type error or — if using `as` — will receive `undefined` at runtime. Either:
   - Add `timeslotsCount` to the `DoctorWithSchedules` type (cleaner), or
   - Stop baking it into the schedule — return a parallel `scheduleTimeslotsCount: Record<scheduleId, number>` from the repo and let the caller join.

4. **`findByIdWithSchedule` returns null when doctor is missing/deleted, but `fetchDoctorByIdWithSchedule` does `.then((res) => res.result!)`.** `doctor-with-schedule-search-select.tsx:74` — non-null assertion. A select that points to a since-deleted doctor will throw `"Cannot read properties of null (reading 'timeslotsCount')"` on the next render of `<SearchSelect>`'s `useEffect`. Either handle `null` (treat as "no selected item, clear value") or throw a typed error the form can catch.

### Low / Nit

5. **`user.status` resolved via `??` chain after initial assignment.** `doctors.repository.ts:341` — `status: query.status ?? UserStatus.ACTIVE`. Functionally fine but the original code branched with `if (query.status) doctorWhere.user = { status: query.status }` to override the default. The `??` keeps the same behavior but only because Prisma coerces `undefined` to "no filter" — fine, just slightly less explicit than the old branch. No fix needed.

6. **New `/api/doctors/[id]/schedules` route skips tenant scoping.** `src/app/api/(common)/doctors/[id]/schedules/route.ts:11` — no `tenantId` filter applied to the underlying query. Same caveat applies to `findById` (the existing endpoint), and the repo as a whole does not implement tenant scoping, so this is consistent with the existing pattern, not a regression. Flagging because it's worth noting in the team's tenant-isolation review if there is one. (Confirmed by reading `DoctorsRepository` — no tenant filter anywhere.)

7. **`onDoctorWithScheduleSelect` callback signature is unusual.** `patient-form.tsx:824` — caller writes `onDoctorWithScheduleSelect={(value) => { checkDoctorAvailability(value); field.onChange(value.id); ... }}`. The callback receives the full `DoctorWithSchedules`, but the form's value wants the id. Compared to `onChange` (which passes `string | null`), this is heavier. Could just be `onChange(doctor: DoctorWithSchedules) => void` returning the doctor, and let the form extract id. Pre-existing pattern in the codebase (`DoctorSearchSelect.onDoctorSelect`) does the same, so this is just convention. No fix needed.

**Nit:**

8. **`useDoctorWithScheduleSearchInfinite` is the 13th near-duplicate wrapper** around `useEntitySearchInfinite` (`use-search-select-infinite.tsx:382`). The pattern is established by 12 predecessors, so this fits the codebase, but the ladder says "stdlib / native platform / already-installed dependency / one-liner before fifty". The whole file is 50-line copy-paste 13 times for a 5-line core. Not blocking — would require a refactor of the whole pattern to fix.

9. **`stableStringify` lives next to the hook and is its only consumer.** Fine as-is; just noting that it's unexported. No fix.

## Recommendation

The PR is good to merge with two small follow-ups:

- **Must-fix (recommend a follow-up commit, do not block merge):** the `doctorWhere` regression in `findDoctorsWithSchedules`. Re-add day-of-week filtering at the doctor level, ideally with a `pizza-log` style "find ids of doctors with matching schedule, then feed into the doctor query" shape so the perf wins stay. Verify with a screenshot of the book-appointment daily tab and the patient-form doctor select on a day with sparse coverage.
- **Nice-to-have:** add a `// ponytail:` comment next to `fetchLimit * 10`; widen `DoctorWithSchedules.schedules` type to include `timeslotsCount`; defend `fetchDoctorByIdWithSchedule` against `null`.

Everything else is style or pre-existing patterns the codebase has already accepted. Performance improvement (10s → 76ms) is plausible and worth shipping; the only correctness risk is the doctor-membership filter regression.
