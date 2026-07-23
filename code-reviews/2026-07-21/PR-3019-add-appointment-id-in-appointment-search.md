# Code Review: PR #3019 — Add appointment ID in appointment search
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-29/appointment-search-86eyar7zt` → `development`
**Files changed:** 1 (+6 / -0)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-21
**ClickUp:** https://app.clickup.com/t/9018849685/86eyar7zt

## Summary
Adds `appointment.appointmentId` (the human-readable `APT-YYYYMM-NNN` style code, stored in the TEXT column `appointments.appointment_id`) to the `OR` block of the appointment-list search terms, alongside the existing `patient.name`, `patient.patientId`, `patient.phoneNo`, `doctor.doctorId`, `doctor.title`, and `doctor.user.fullName` predicates. The change reuses the existing `terms` array (whitespace-split from `query.search`), so a multi-word search still AND-s across terms.

## Verdict
**Approve with suggestions**
Score: 95/100
Critical: 0 | High: 0 | Medium: 0 | Low: 2 | Nit: 1

## Issues

### Critical
None

### High
None

### Medium
None

### Low / Nit

1. **[Low] UI placeholder is now stale** — `src/app/(dashboard)/appointment/appointment-list/features/components/appointments.tsx:73` and `src/app/(dashboard)/opd/appointments/page.tsx:110` advertise `"Search Patient ID, Patient Name, Patient Phone No, Doctor Name"` (and the OPD variant additionally `..., Referral Doctor, Referral Clinic`). The backend now also matches `appointmentId`, but neither placeholder mentions it, so the new search dimension is invisible to the operator. This is the exact gap the prior analogous PR #2570 (`Search appointment id in ed list`) closed for the ED list — it updated both the placeholder (`ed-billing-list-table.tsx:116`) and the `where.OR`. Recommend matching that pattern: add `, Appointment ID` to both placeholders in this PR, otherwise users won't know they can search by it.

2. **[Low] No DB index on `appointments.appointment_id`** — the `appointmentId` search is a `contains` (PG `ILIKE '%term%'`) on a TEXT column without a btree or trigram index. With the existing unindexed TEXT column (`migrations/20251027045025_add_appt_id_in_appt_table_and_appt_service_table/migration.sql:2` — `ADD COLUMN "appointment_id" TEXT`, no `CREATE INDEX`), this becomes a sequential scan per search hit. Volumes in OPD appointment lists are modest, so it's not a defect today, but a follow-up `CREATE INDEX … ON appointments USING gin (appointment_id gin_trgm_ops)` (the trigram index used elsewhere in this codebase per `hms-docs/summary-service/data-model/schema.sql`) would make the new code path scale. Out of scope for this PR; flagging as a follow-up ticket.

3. **[Nit] `mode: "insensitive"` is a no-op for the APT ID format** — `appointmentId` values look like `APT-202506-001` and `APT-202506-001-OTH-…` (uppercase letters/digits/dashes only). The case-insensitive collation is harmless but redundant; a normal `contains` would be equivalent for the actual data. Leave it as-is for consistency with the surrounding predicates (which all use `mode: "insensitive"`); flagged as cosmetic only.

## Recommendation
Land the change. Two small follow-ups to consider in the same PR or as a tiny companion commit:

1. Update the two `DataTableSearchbox` placeholders (`appointments.tsx:73`, `opd/appointments/page.tsx:110`) to include `, Appointment ID`, mirroring PR #2570's pattern. Without this, the new search column is functionally invisible to operators and is the most likely reason a tester would file a "can't find by APT code" ticket.
2. Add a single unit test under `__tests__/repositories/appointment.repository.node.test.ts` that asserts the new `appointmentId: { contains: term, mode: "insensitive" }` predicate appears in the generated `where.AND[*].OR` array when `query.search` is set (mocking `prisma.appointment.findMany` and `prisma.referral.findMany`). The existing test file already has the `findMany` mocks wired up; only one new `it(...)` block is needed.

No correctness bugs, no security issues, no over-engineering — this is the smallest possible diff (one OR-branch, six lines) and it reuses the existing `terms`/`mode: "insensitive"` shape from neighboring predicates. The only real gap is the missing placeholder update; everything else is polish.
