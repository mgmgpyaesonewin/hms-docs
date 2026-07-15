# Spec — Capture "Complete" status change in the Appointment Activity Log

**Owner:** TBD
	**Status:** Draft
**Date:** 2026-07-10
**ClickUp:** TBD (link when ticket lands)
**Source bug:** "In the Appointment List >> Activity Log, when an appointment
status is updated to 'Complete', this specific event is not tracked or
recorded."

> **Related:** [[INDEX]] · [[hms-app/README]] · [[hms-app/SPEC]] · [[hms-app/TODO]] · [[code-reviews/2026-07-10/PR-2929-feat-opd-appointment-list]]

---

## 1. Problem

When a user transitions an appointment to status `COMPLETED` from the
Appointment List page, the audit row that every other state change writes
into `activity_logs` is **missing** — or is written but never surfaces in
the Activity Log view. The reporter expects "every status change —
including transitioning to Complete — captured and logged accurately with
the proper timestamp and user details."

This is not a single bug. Tracing the code surfaces **four** independent
gaps along the path. Each gap is its own root cause; fixing only the
symptom (e.g. un-commenting a dropdown row) leaves three sibling paths
still broken.

---

## 2. Code trace — where the audit row should be written

The state-change entry point is a server action in
`src/app/(dashboard)/appointment/book-appointment/features/appointment.actions.ts`:

```ts
export const updateAppointmentStatus = authActionClient
  .schema(updateAppointmentStatusSchema)
  .action(async ({ parsedInput, ctx }) => {
    return appointmentService.updateAppointmentStatus({
      status: parsedInput.status,
      cancelledRemark: parsedInput.cancelledRemark,
      id: parsedInput.id,
      userId: ctx.session.user.id,
    });
  });
```

It routes to
`src/app/(dashboard)/shared/appointment/services/appointment.service.ts`
(`AppointmentService.updateAppointmentStatus`, lines 234–313). The
relevant slice:

```ts
return await prisma.$transaction(async (tx) => {
  const appointment = await this.appointmentRepository.updateAppointmentStatusById(
    { status, cancelledRemark, id, userId }, tx,
  );

  // ... cascade to EndoRequest / OTRequest ...

  activityLogger.log({                                  // line 303
    description: `Updated Appointment Status from ${existingAppt.status} to ${status}`,
    userId,
    action: "Update",
    entity: "Appointment",
    entityId: appointment.id,
  });

  return appointment;
});
```

The `activityLogger.log(...)` call **is** status-agnostic — every
`status` value (including `COMPLETED`) flows through the same code path.
So the server-side writer is not the cause; the gaps are elsewhere.

---

## 3. Root causes

### R1 — UI dropdown for "Completed" is commented out

`src/app/(dashboard)/appointment/appointment-list/features/components/appointment-status-select.tsx`,
lines 40–54:

```ts
const dropdownDataForStatusConfirmed = [
  { label: "Confirmed", value: appointmentStatus.CONFIRMED, disabled: true },
  // {
  //   label: "Completed",
  //   value: appointmentStatus.COMPLETED,
  // },
  { label: "Cancelled", value: appointmentStatus.CANCELLED },
];
```

Effect: a user looking at a `CONFIRMED` appointment can choose
`Cancelled` but **not** `Completed` from the dropdown. The
`CompletedAppointmentModal` exists and the `handleOnStatusChange` switch
already handles `COMPLETED` (lines 102–104), so the backend path is
complete — only the UI surface is missing. Without the option, no user
can drive the `CONFIRMED → COMPLETED` transition through the page today;
any rows that do appear must come from elsewhere (another module, a
backfill script, or someone un-commenting this locally).

### R2 — Activity log writer is an in-memory batched queue

`src/app/(dashboard)/common/reports/activity-logs/features/activity-logger.ts`:

```ts
constructor(config?: ActivityLoggerConfig) {
  const {
    prismaClient = prisma,
    batchSize = 50,
    commitInterval = 10000,                     // 10 seconds
  } = config || {};
  // ...
  this.scheduleCommitting();                    // setInterval(this.commit, 10000)
}

public log(activity: Activity) {
  this.logsQueue.push(activity);                // in-memory only
  if (this.logsQueue.length >= this.batchSize) {
    this.commit();
  }
}

private async commit() {
  // ... prisma.activityLog.createMany({ data: this.logsQueue.slice(...) }) ...
}
```

`activityLogger` is a **module-level singleton** holding an in-memory
queue, flushed either every 10s or every 50 entries, whichever comes
first. The actual `prisma.activityLog.createMany` call happens **outside**
the calling Prisma transaction (it fires from a `setInterval` callback
later). Consequences:

- **Process death drops queued rows.** HMR in dev, container restart in
  prod, OOM kill — any of these before the next tick loses the row.
  `AppointmentService.updateAppointmentStatus` is fire-and-forget from
  the txn's POV, so the surrounding Prisma transaction commits without
  any guarantee that the audit row will land.
- **The audit row is not part of the appointment write's atomicity.**
  Even when it does land, it lands in a *separate* statement from a
  *later* `setInterval` tick. There is a window during which the
  appointment has been mutated but the audit row has not yet been
  inserted; readers in that window see "status changed but no log entry".
- **The 10s default is silent.** There is no instrumentation on
  queue depth, no log line at the moment `log()` is called, no flush hook
  on process exit. The failure mode is invisible.

The repo confirms the design: `activity-logger.test.ts` only asserts the
two trigger paths (interval + batch-size) and the no-trigger path — there
is no test that says "if the process dies mid-window, the row is
persisted."

### R3 — No per-appointment Activity Log view in the UI

The Appointment List page wires its detail modal to
`AppointmentDetailModal`
(`src/app/(dashboard)/appointment/appointment-list/features/components/modals/appointment-detail-modal.tsx`),
which renders a single `<Card>` of static fields and **no audit history**.

Contrast with sibling modules that have an audit modal already wired
into their detail/card view:

```
src/app/(dashboard)/daycare/features/components/daycare-activity-log-modal.tsx
src/app/(dashboard)/hd/features/components/hd-activity-log-modal.tsx
src/app/(dashboard)/ed/features/components/ed-billing-activity-log-modal.tsx
src/app/(dashboard)/ot/features/components/ot-activity-log-modal.tsx
src/app/(dashboard)/endo/features/components/endo-activity-log-modal.tsx
src/app/(dashboard)/emr/features/clinical-document/clinical-document-activity-log-modal.tsx
```

There is **no** `appointment-activity-log-modal.tsx`. Whatever rows do
get written to `activity_logs` for `entity = "Appointment"` are
invisible inside the appointment page itself.

### R4 — Global Activity Logs API cannot filter by entity

`src/app/(dashboard)/common/reports/activity-logs/features/activity-logs.service.ts`,
`ActivityLogsService.findAndCount`:

```ts
const where: Prisma.ActivityLogWhereInput = {};
if (query.search) {
  where.OR = [
    { user: { username:     { contains: query.search, mode: "insensitive" } } },
    { user: { fullName:     { contains: query.search, mode: "insensitive" } } },
    { user: { role: { name: { contains: query.search, mode: "insensitive" } } } },
  ];
}
if (query.start && query.end) {
  where.timestamp = { gte: new Date(query.start), lte: new Date(query.end) };
}
// ...
const logsPromise = prisma.activityLog.findMany({ where, ... });
```

`where` only accepts `search` (user/role) and a `timestamp` range. There
is **no** `entity` or `entityId` filter, and the Prisma model
`ActivityLog` (schema line 1860) has no compound index on
`(entity, entityId, timestamp)` — only separate indexes on `userId`,
`action`, and `entity`. To find every audit row for a single appointment
in production today you `SELECT * WHERE entity = 'Appointment' AND
entity_id = $1`, which is **not expressible through the existing API** and
falls off the indexed path.

---

## 4. Fix

### Fix order

Fix the root cause first (R2), then surface what it actually wrote (R3 +
R4), then unblock the UI driver (R1). Doing it in any other order will
either lose rows or surface noise from the half-fixed paths.

### 4.1 — R2: Make the audit write synchronous and atomic with the appointment update

**Change:** drop the in-memory batched queue for status changes; use the
transactional Prisma client directly.

`src/app/(dashboard)/shared/appointment/services/appointment.service.ts`:

```ts
return await prisma.$transaction(async (tx) => {
  const appointment =
    await this.appointmentRepository.updateAppointmentStatusById(
      { status, cancelledRemark, id, userId }, tx,
    );

  // ... cascade to EndoRequest / OTRequest using `tx` ...

  // REPLACE the batched call with a synchronous, transactional write:
  await tx.activityLog.create({
    data: {
      userId,
      action: "Update",
      entity: "Appointment",
      entityId: appointment.id,
      description: `Updated Appointment Status from ${existingAppt.status} to ${status}`,
    },
  });

  return appointment;
});
```

Keep the `ActivityLogger` class for the **non-transactional** callers
that exist today (page views via `page-view-logger.ts`, fire-and-forget
admin actions). Add a new function `logInTransaction(tx, activity)` that
takes a Prisma transaction client and writes directly via
`tx.activityLog.create`. The two paths share the row shape; only the
flushing model differs. Document this in a comment block at the top of
`activity-logger.ts` so future readers understand which path to pick:

> Use `activityLogger.log(...)` for fire-and-forget audit rows that do
> not need to be atomic with a state change (page views, admin updates
> that are best-effort). Use `activityLogger.logInTransaction(tx, ...)`
> when the audit row MUST commit with the same transaction as the
> mutation — appointment status, billing state, prescription, anything
> where a missing audit row breaks compliance.

This is the root-cause fix. With this in place:

- Rows survive process death.
- Audit row commits atomically with the appointment row.
- No 10-second read window where the row is missing.

### 4.2 — R3: Add a per-appointment Activity Log modal

Mirror the pattern used by `daycare-activity-log-modal.tsx` and
`ed-billing-activity-log-modal.tsx`. New file:

```
src/app/(dashboard)/appointment/appointment-list/features/components/modals/appointment-activity-log-modal.tsx
```

- Mantine `<Modal>` titled "Appointment Activity Log"
- Body: list of audit rows for this appointment (description, timestamp,
  user fullName + role, action)
- Trigger: a new `<ActionIcon>` on the `AppointmentCard` (line ~265
  onwards in `appointment-card.tsx`) labelled "Activity Log", placed
  next to the existing Edit / View icons, gated by
  `<PermissionGuard action="View" subject="Appointment List">`.

The data fetch goes through the new entity-filtered endpoint added in
4.3.

### 4.3 — R4: Extend the Activity Logs API with `entity` / `entityId` filters

`src/app/(dashboard)/common/reports/activity-logs/features/schemas/get-activity-logs.ts`:

```ts
export const getActivityLogsSchema = z.object({
  search:   z.string().optional(),
  start:    z.string().datetime().optional(),
  end:      z.string().datetime().optional(),
  entity:   z.string().optional(),         // NEW: e.g. "Appointment"
  entityId: z.string().uuid().optional(),  // NEW: e.g. appointment.id
  limit:    z.number().int().min(1).max(100).default(10),
  offset:   z.number().int().min(0).default(0),
});
```

`activity-logs.service.ts`, in `findAndCount`:

```ts
if (query.entity)   where.entity   = query.entity;
if (query.entityId) where.entityId = query.entityId;
```

`prisma/schema.prisma`, on `ActivityLog`:

```prisma
@@index([entity, entityId, timestamp])
@@index([entityId, timestamp])
```

Migration: forward-only per SPEC §7. The HMS team runs DDL; this index
add is a one-liner, no data backfill needed.

### 4.4 — R1: Un-comment the "Completed" dropdown option

`appointment-status-select.tsx`, lines 46–49:

```ts
{
  label: "Completed",
  value: appointmentStatus.COMPLETED,
},
```

The backend (`validateAppointmentStatus`, `appointment.service.ts:402-414`)
already allows `CONFIRMED → COMPLETED`; the modal
(`completed-appointment-modal.tsx`) is already wired; the action and
permission (`Change Status` on `Appointment List`) are already there.
This is the missing UI surface — one entry, three lines.

---

## 5. Data model — no schema changes

- **No new tables.** All four fixes use the existing `activity_logs`
  table.
- **One new index** on `ActivityLog(entity, entityId, timestamp)` (4.3).
  Forward-only migration; no backfill required.
- **No new permissions.** "Change Status" + "View" on "Appointment List"
  already cover the action and the new modal.

---

## 6. Out of scope

- Replacing the in-memory `ActivityLogger` queue everywhere (4.1 only
  touches the appointment path). Other call sites continue to use the
  batched logger; converting them is a separate change once the new
  `logInTransaction` helper proves out.
- Migrating `activity_logs` retention onto a Pruner (TODO §2 last
  bullet). Same as above.
- Surfacing Activity Logs in the membership portal.

---

## 7. Test plan

### 7.1 — Unit (no DB)

- `appointment.service.node.test.ts` (already exists under
  `appointment/book-appointment/__tests__/`): add a case that drives
  `updateAppointmentStatus({ status: COMPLETED })` against a mocked
  `tx` and asserts:
  1. `tx.activityLog.create` is called once.
  2. `entity === "Appointment"`, `entityId === expected.id`.
  3. `description` starts with `"Updated Appointment Status from CONFIRMED to COMPLETED"`.

### 7.2 — Integration

- Spin up dev stack: `docker compose -f infra/docker-compose.yml up -d`
  then `cd hms-app && npm run dev` (per CLAUDE.md).
- Walk-through: book → confirm → complete an appointment.
  - Open the new `AppointmentActivityLogModal` on the card.
  - Assert two rows: `... BOOKED to CONFIRMED ...`, `... CONFIRMED to COMPLETED ...`.
  - Each row shows fullName + role of the user who performed the
    transition and a UTC timestamp matching the appointment's
    `updatedAt` ±1s.
- Restart the `hms-app` Next process *between* a Complete action and
  the modal open. Re-open the modal. The Complete row MUST still be
  present (proves R2 fix).
- Hit `GET /api/activity-logs?entity=Appointment&entityId=<id>` directly.
  Assert 200 + paginated rows.

### 7.3 — Regression

- Book → cancel flow still writes a single audit row.
- Cancelled → any transition still throws `AppError 400` and writes no
  row.
- `activityLogger.log(...)` non-transactional path still flushes on the
  10s timer (existing test in `activity-logger.test.ts` stays green).

---

## 8. Rollout

1. Land 4.1 + 4.4 + the test in 7.1 in one PR. This is the smallest diff
   that fixes the bug at the server boundary and removes the UI gating.
   Pair-reviewer must trace every `activityLogger.log(...)` call inside
   a `prisma.$transaction` block in the codebase and confirm none are
   left in the appointment service after this PR.
2. Land 4.2 + 4.3 + the new index in a follow-up PR. Add the modal to
   the AppointmentCard behind `PermissionGuard View`. UAT passes when
   the integration scenario in 7.2 passes end-to-end.
3. Monitor `activity_logs` write rate for one week post-deploy; the
   conversion of one call site from batched to synchronous should not
   move the needle.

---

## 9. Acceptance criteria

The ticket is "done" when **all** of the following hold against the dev
stack:

- [ ] A user can pick "Completed" from the Appointment Status select
      on a Confirmed appointment (R1).
- [ ] Opening the appointment's Activity Log shows a row with
      `description` beginning "Updated Appointment Status from
      CONFIRMED to COMPLETED", the performing user's fullName + role,
      and a timestamp matching `appointment.updatedAt` ±1s (R2, R3).
- [ ] Restarting the dev server between the Complete action and opening
      the modal does **not** drop the row (R2).
- [ ] `GET /api/activity-logs?entity=Appointment&entityId=<id>` returns
      the row with no full-table scan (verify with `EXPLAIN ANALYZE` on
      the dev DB; R4).
- [ ] `npm run tsc && npm run lint` clean. `npm test` green.

---

## 10. Related work / pointers

- [[hms-app/SPEC]] §6.5 (`common-activity-logs`), §7 (audit
  requirements), §11.3 (state machines — appointment status transitions
  are not enumerated today; consider adding after this lands).
- [[hms-app/TODO]] §2 — last bullet on `_logs` retention; relevant if
  `activity_logs` ever follows the same pattern.
- [[code-reviews/2026-07-10/PR-2929-feat-opd-appointment-list]]
  — review of the sibling sidebar/permission wiring for the OPD
  Appointment List. The sidebar link still does not route to a live page
  today (PR was shipped with `href: /opd/appointments` but no matching
  route); this spec does not depend on that route, but the in-page
  Activity Log modal does need the appointment list page to be reachable
  for the bug to be reproducible end-to-end.
- [[hms-app/onboarding/solution-architect-plan|SA plan]] Phase 2
  ADR-0001 (tRPC vs server actions) — orthogonal; this fix uses
  server-action already in place.