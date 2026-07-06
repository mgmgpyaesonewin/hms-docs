# hms-app IPD Admission Cancellation — Code Review Findings (2026-06-17)

**Scope.** Two findings in the IPD admission cancellation flow, both centered on the daily-bill close path triggered by `updateAdmissionStatus → handleAdmissionCancellation`.

---

## H1. Missing status filter on `ipddailyBills` can overwrite a previously-closed bill

**Where:** `admission.repository.ts:136-144`

```ts
ipddailyBills: {
  take: 1,
  orderBy: { createdAt: "desc" },
  select: { id: true },
},
```

`handleAdmissionCancellation` then unconditionally calls `closeDailyBillStatus` on whichever bill is "latest by `createdAt`":

**Where:** `admission.service.ts:385-388`

```ts
const dailyBill = admission.ipddailyBills[0];
if (dailyBill) {
  await this.processCloseDailyBill(dailyBill.id, userId, tx);
}
```

There is no `where: { dailyBillStatus: "OPEN" }` on the include. The system creates a new bill each day via `openDailyBillBySystem`, so the intended case is exactly one `OPEN` bill per admission — but the query doesn't enforce it. If a daily bill was closed manually earlier (e.g. partial bill close) and a new one hasn't been opened yet, "latest" is the old `CLOSED` bill, and `closeDailyBillStatus` will:

- Reset `billCloseAt` to `new Date()` (overwriting the original close timestamp)
- Reset `updatedById` to the current user
- Remain in `CLOSED` status (idempotent on the enum, but corrupting the audit fields)

**Fix:** filter to `OPEN` only:

```ts
ipddailyBills: {
  take: 1,
  where: { dailyBillStatus: "OPEN" },
  orderBy: { createdAt: "desc" },
  select: { id: true },
},
```

(And on the service side, you may also want to confirm the bill is still `OPEN` at the time of close — `closeDailyBillStatus` could check and no-op if it's already closed.)

---

## H2. `admissionValidator` is used by list endpoints — adding `ipddailyBills` to the shared validator hits every list query

**Where:** `admission.repository.ts:223-238, 270-285` — `findAdmissions` and `findAdmissionsWithDoctorNotes` both spread `...admissionValidator` and run on every list call. With this change, every list row now triggers a sub-query to fetch its latest daily bill.

This new data is only consumed by the cancellation flow (`updateAdmissionStatus → handleAdmissionCancellation`). A 1-row extra `LEFT JOIN LATERAL` per admission across the entire admissions list (potentially paginated, but with `take`/`skip` still fetching extras) is wasted load on every list screen and report.

**Fix options (any one is acceptable):**

- Add a dedicated repository method, e.g. `findLatestOpenDailyBillId(admissionId, tx)`, and call it only inside `handleAdmissionCancellation` (passing `tx`).
- Or stop using the shared validator inside `handleAdmissionCancellation` — fetch the admission with a focused include.

This also makes the related service-level data flow clearer (the cancellation path doesn't need the rest of `admissionValidator`'s include set either, but that's a bigger refactor).
