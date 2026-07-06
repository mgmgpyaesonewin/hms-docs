# Code Review: PR #2783 — Fix admission book room race conditions

**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `april-fix/admission-room-book` → `development`
**Files changed:** 3 (+81 / -13)
**Reviewer:** code-reviewer skill (automated, independent re-review)
**Date:** 2026-06-24
**ClickUp ticket:** https://app.clickup.com/t/9018849685/86ey0p50c

## Summary

This PR attempts to fix two distinct concurrency hazards in `createAdmission`:

1. **Duplicate `admissionId` collisions** — `Admission.admissionId` is `String @unique` (see `prisma/schema.prisma:2461`), but `countForAdmission` (a month-bounded `prisma.admission.count`) was used outside any transaction, so two concurrent `createAdmission` calls could compute the same next-serial and race on the UNIQUE constraint. The PR's fix is to acquire `pg_advisory_xact_lock(12345)` inside the transaction before re-querying the latest monthly `admission_id` and parsing the trailing serial from it. The function's name (`countForAdmission`) no longer matches its behavior — it now returns the parsed trailing serial of the latest `admission_id`, not a `count(*)`.
2. **Concurrent `rooms` row double-booking** — `handleRoomAllocation` updates `rooms.roomStatus` from `AVAILABLE` to `REQUESTED`/`PREREQUESTED` without any row-level lock, so two concurrent admissions targeting the same room could both observe `AVAILABLE` and both transition the room. The PR adds a `SELECT ... FOR UPDATE NOWAIT` over `rooms` to serialize this, with a fallback to a user-readable error.

The intent is right and the bugs are real and reproducible. But the PR has **two real correctness regressions** in the code it ships, a claim that doesn't match the diff, and several hygiene issues that should be addressed before merge:

- The `countForAdmission` rewrite is a **silent behavior change**, not just a locking change. The function used to return a real `count(*)`; it now returns the *last segment* of the most recent `admission_id` in the month (i.e. the highest existing serial). These two are not equivalent under any of: (a) gaps in the serial sequence (e.g. failed/cancelled admission inserts that still consumed an ID), (b) clock-skew / month boundary changes, or (c) an `admission_id` with a non-`-{serial}` suffix. The function's callers in `generateAdmissionId` use it as `count + 1` — under the new semantics, `count + 1` produces the *next* serial after the highest *seen* one, which is what the author wants, but the function is no longer doing what its name says, and the contract drift will bite the next caller.
- **Claim (d) in the PR body is false.** The PR body says "Replaced concurrent `Promise.all` database updates with sequential loops to safeguard the transaction client connection pool." But the diff contains no `Promise.all` → `for` rewrites. The pre-existing `Promise.all` calls at `admission.service.ts:116` (predeposits), `:138` (newborn babies), and `:247` (editAdmission newborn create) are unchanged. Either the author meant to do this work and forgot to commit it, or the description is aspirational. The ClickUp ticket and the PR diff need to agree before merge.
- **Claim (b) in the PR body is inverted.** The PR body says "Removed `NOWAIT` from raw room queries to let simultaneous threads wait sequentially instead of failing immediately." The diff actually **adds** `FOR UPDATE NOWAIT` to a new raw query in `handleRoomAllocation`. The count query (in the repo) never had `NOWAIT` — it had no lock at all. The diff is consistent with the intent (queue the second booker) only if you read "Removed NOWAIT" as "Removed the *absence* of NOWAIT" — but the description is misleading.
- **Magic advisory-lock key `12345`** with no documentation, no namespacing, and no collision check. The codebase already has a related pattern in `ct-add-on-billing.service.ts:910-934` that uses row-level `FOR UPDATE` for the same purpose (generating a monthly serial inside a transaction) — and that pattern is the conventional one for this codebase. The PR introduces a second approach.
- **The advisory lock is taken outside any retry/backoff logic.** A long-running `prisma.$transaction` (e.g. one stuck on a network call inside `createNewBornBaby` or `editPatientData`) will hold the lock for as long as it takes, blocking every other `createAdmission` request in the system. The pre-PR code held no lock; the new code can serialize *all* admissions to a single bottleneck. For a 24×7 hospital IPD flow this is a meaningful availability regression.

There is no Jest test in the diff. The two race conditions are exactly the kind of thing that needs a deterministic test (e.g. `Promise.all([createAdmission(A), createAdmission(B)])` with the same payload) to prove the fix works.

## Verdict

**Request changes**

Score: 38/100
Critical: 2 | High: 4 | Medium: 3 | Low: 2 | Nit: 1

## Strengths

- **`admission.service.ts:332-352` (post-PR) — `FOR UPDATE NOWAIT` over `rooms` is the right primitive for the double-booking hazard.** The lock is taken inside the same `prisma.$transaction` as the `roomLog.create` and `room.update`, so the lock is released on commit/rollback, and the user sees a clear error if a concurrent booker holds the row. Good defense.
- **`admission.service.ts:358-362` — Post-lock re-check of `roomStatus !== "AVAILABLE"`** is the textbook "double-checked locking" pattern. Even if the UI showed `AVAILABLE` and the user clicked `Book`, a transaction that committed between the read and the SELECT FOR UPDATE would now be caught by this re-read. Good catch.
- **`admission.service.ts:340-348` — `isRoomLockConflictError` is the right error-classification approach** for translating `SQLSTATE 55P03` (`lock_not_available`) into a user-friendly message instead of a 500. The implementation uses the Prisma `P2010` wrapper correctly.
- **`admission.repository.ts:153` — `pg_advisory_xact_lock` (vs `pg_advisory_lock`)** is the right choice for a transaction-scoped critical section: the lock is auto-released on commit/rollback, so a process crash mid-transaction won't leave a dangling lock. Good.
- **`admission.service.ts:92-93` — `generateAdmissionId(tx)` is moved *inside* the `prisma.$transaction`.** The previous code generated the ID outside the transaction (`admission.service.ts:91` in the pre-PR file), which was a *separate* bug — the generated ID could be assigned to a transaction that rolled back, leaving an "admission ID gap" or, worse, an ID that was reused on retry. The PR fixes this by construction. Good.

## Issues

### Critical

- **`admission.repository.ts:146-184` — `countForAdmission` is no longer a `count`; the name lies, and the change in semantics is not flagged in the PR body or commit message**

  Before: `prisma.admission.count({ where: { createdAt: { gte, lt } } })` — returns the number of admissions created in the calendar month.
  After: queries the row with the highest `created_at` in the month, splits its `admission_id` on `-`, and returns `parseInt(parts[parts.length - 1], 10)`.

  The two are not equivalent. Concrete failure modes:

  1. **Gaps in the serial sequence.** If an admission insert fails for any reason *after* `countForAdmission` runs (e.g. a `patients.update` constraint failure, a `newBornBaby` UNIQUE collision, a `roomLog` write failure), the `count` was already consumed but no `admission_id` was committed. Pre-PR: the next call still returns the *true* count of committed rows, so the new serial equals `count + 1` and the gap is closed. Post-PR: the next call returns the *highest parsed serial* from the latest *committed* row, so the next serial is `highest_seen + 1` — the gap is **preserved**, and the count drifts upward forever. Over a year of operation, `ADM-06-26-000127` may not be the 127th admission of June 2026; it could be the 130th, or higher.
  2. **`admission_id` format assumptions.** The function assumes the suffix is a serial integer. The format in `generateAdmissionId` is `ADM-${month}-${year}-${String(count + 1).padStart(6, "0")}` — so under the new code, the next serial is parsed from the latest row and incremented. This is fine *for inserts that go through `generateAdmissionId`*. But the function does no format validation: if any row has a non-matching `admission_id` (e.g. imported from another system, hand-edited by an admin via SQL, or assigned a non-numeric suffix), `parseInt(parts[parts.length - 1], 10)` returns `NaN` and the function falls back to `0` (line 178 of the post-PR diff). Under the pre-PR code, a non-matching `admission_id` had no effect on the count.
  3. **Month-boundary race during DST or `getTimezone()` change.** `date.startOf("month").toDate()` and `date.endOf("month").toDate()` use the *current* `date` (constructed from `dayjs.utc().tz(timezone)` in `generateAdmissionId`) for the bounds, and `createdAt` is `now()` at the DB. If `getTimezone()` returns a different timezone on the second call (e.g. the cache expired and the system re-queried), the window slides. Pre-PR had the same hazard, but it was masked by the fact that `count` over a wider/narrower window is still monotonically increasing. Post-PR, a window slide could return the previous month's highest row and assign a serial in the new month that is *lower* than the previous month's, breaking the format `MM-YY-######`.

  **Fix:** keep the function name honest. Either rename it to `getLastAdmissionSerialForMonth` and have `generateAdmissionId` use it correctly (and document the gap behavior explicitly), or revert to the `prisma.admission.count` approach inside the same advisory lock (the lock is still needed because `count` is also racy under concurrent commits). The latter is the more conservative fix and matches the `ct-add-on-billing.service.ts:910-934` pattern.

  Evidence: `admission.repository.ts:146-184` (new function body); pre-PR `admission.repository.ts:148-158` (old `count`). `admission.service.ts:524` (caller: `String(count + 1).padStart(6, "0")`). `prisma/schema.prisma:2461` (`admissionId String @unique`).

- **PR body claim (d) does not match the diff. The pre-existing `Promise.all` calls in `createAdmission` are unchanged.**

  The PR body states: "Replaced concurrent `Promise.all` database updates with sequential loops to safeguard the transaction client connection pool."

  The diff contains **zero** `Promise.all` → `for (… of …)` rewrites. The pre-existing `Promise.all` calls remain at:
  - `admission.service.ts:116` (predeposit `update` loop in `createAdmission`)
  - `admission.service.ts:138` (newborn-baby `create` loop in `createAdmission`)
  - `admission.service.ts:247` (newborn-baby `create` loop in `editAdmission`)

  These are all `tx.*` calls inside `prisma.$transaction` — they do *not* "safeguard the transaction client connection pool"; a transaction callback runs on a single dedicated connection (Prisma guarantees this), and `Promise.all` over a single connection still serializes the queries (the JS Promise resolves on the first read but each `await` yields the connection). So the claim's premise is wrong: `Promise.all` over a single Prisma `tx` client is already sequential at the wire level. The "connection pool exhaustion" risk the author is worried about is only real if these `Promise.all`s were firing against `prisma` (the unscoped client) inside a transaction — they aren't, they're on `tx`.

  This is a **critical** documentation bug because it suggests the author committed a PR under a false rationale. Two possible underlying causes:

  1. The author intended to do the `Promise.all` → `for` rewrite and forgot to commit it. In that case the diff is incomplete and the merge will leave the `Promise.all`s in place (no behavior change from main, but the description is a lie).
  2. The author copy-pasted the description from another PR. In that case the description should be removed and the PR retitled to "Fix admission book room race conditions via advisory lock + FOR UPDATE NOWAIT".

  Either way, **the PR cannot be reviewed against its own description**. Update the description to match the diff, or update the diff to match the description, before merge.

  Evidence: PR body (claim d). Diff (no `Promise.all` → `for` change present). `admission.service.ts:116, :138, :247` in the pre-PR file (unchanged in the post-PR diff).

### High

- **`admission.repository.ts:155` — `pg_advisory_xact_lock(12345)` is a magic number with no comment, no namespacing, and no collision check**

  The lock key `12345` is hardcoded inline. There is no:
  - Comment explaining what this key is for.
  - Check that no other code in the codebase uses the same key.
  - Namespacing scheme (e.g. `123450000 + 1` for "admission ID generation") that would prevent a future code path from accidentally using `12345` for an unrelated lock and causing cross-feature contention.

  A repo-wide search for `pg_advisory` returns no prior uses (`grep` was clean before this PR), so the immediate collision risk is zero, but the key needs a named constant with a comment. Something like:

  ```ts
  // Namespaced key for "admission-id generation". Last 4 digits are the feature
  // code; the upper 28 bits are reserved for cross-tenant partitioning if added
  // in the future. Do not reuse for any other critical section.
  const ADMISSION_ID_LOCK_KEY = 12345;
  ```

  Even better, since the function operates on a *month* (and two concurrent `createAdmission`s in different months don't actually contend on each other's serial generation), namespace the key by month: `pg_advisory_xact_lock(hashtext('admission_id:' || $1), $2)` keyed on `MM-YY`. This reduces contention to a single month at a time.

  Evidence: `admission.repository.ts:155` — `await client.$executeRaw\`SELECT pg_advisory_xact_lock(12345);\``.

- **`admission.service.ts:340-346` — `isRoomLockConflictError` matches on the *Prisma error message string* as a fallback, which is fragile**

  ```ts
  (error.meta?.database_error_code === POSTGRES_LOCK_NOT_AVAILABLE_CODE ||
    error.message?.includes(POSTGRES_LOCK_NOT_AVAILABLE_CODE))
  ```

  The `meta.database_error_code` check is fine (Prisma surfaces it on `P2010` raw-query errors). The `error.message?.includes(POSTGRES_LOCK_NOT_AVAILABLE_CODE)` fallback is fragile:
  1. Prisma's error-message format is not part of its stable contract and has changed across versions. Today it includes `database_error_code: 55P03` in the structured `meta`; tomorrow it may not, and the message may be reformatted (e.g. `lock not available (SQLSTATE 55P03)` → `55P03: lock_not_available`).
  2. A different Prisma error (e.g. a connection reset) could include the string `55P03` in its message by coincidence and be misclassified as a room-lock conflict — surfacing the misleading "this room is being processed by another user" error to the user when the real problem is a transient network failure.

  Drop the `error.message?.includes` branch and rely on the structured `meta.database_error_code` check only. If Prisma ever stops surfacing that field, write a unit test for the new format and update the matcher.

  Evidence: `prisma-errors.ts:62-71` — `isRoomLockConflictError` definition; `admission.service.ts:346` — call site.

- **`admission.service.ts:332-352` (post-PR) — The advisory-lock and `FOR UPDATE NOWAIT` paths are not in the same critical section, so the two locks can be acquired in either order and a deadlock is possible under load**

  The new code acquires *two* locks per `createAdmission`:
  1. `pg_advisory_xact_lock(12345)` in `countForAdmission` (advisory, transaction-scoped, blocks rather than failing).
  2. `SELECT ... FROM rooms FOR UPDATE NOWAIT` in `handleRoomAllocation` (row-level, fails fast).

  Two concurrent transactions A and B can interleave to produce a deadlock-like stall:
  - A acquires the advisory lock (in `countForAdmission`).
  - B fails-fast on `FOR UPDATE NOWAIT` if it reaches the `rooms` lock first; the user sees the friendly error. Good.
  - But if A holds the advisory lock for, say, 200 ms (because of a slow `tx.editPatientData` or `tx.findFirst` in the caller chain), and B reaches `handleRoomAllocation` first and acquires the `rooms` row lock, A will then **wait indefinitely** for the `rooms` row lock (no `NOWAIT` on the A side). The two locks form a wait-for cycle: A waits for B's `rooms` row, B waits for A's advisory lock. Standard deadlock.
  - Postgres will detect and abort one of them after `deadlock_timeout` (default 1 s), but the abort will surface as a generic `40P01` error to the user, not the friendly "this room is being processed" message.

  **Fix:** either (a) use `FOR UPDATE` (not `NOWAIT`) on the rooms query so the second booker queues, mirroring the advisory lock's "wait sequentially" semantics, or (b) use `FOR UPDATE NOWAIT` consistently and accept the fail-fast UX (in which case drop the advisory lock — the `FOR UPDATE NOWAIT` + post-lock re-check is sufficient for both hazards, because the `admission_id` UNIQUE constraint will catch any remaining race as a `P2002` error).

  Evidence: `admission.repository.ts:155` (advisory lock, blocking); `admission.service.ts:343` (`FOR UPDATE NOWAIT`, fail-fast). Postgres docs: `deadlock_timeout` default = 1s.

- **No test for either race condition. Both fixes are exactly the kind of change that breaks under refactor without a regression test.**

  The diff includes zero test files. For a race-condition fix, a deterministic Jest test is the *minimum* evidence the fix works. At minimum, add:

  1. A test that calls `Promise.all([service.createAdmission(payloadA), service.createAdmission(payloadB)])` with the same `roomId` and verifies that one succeeds, the other throws the `isRoomLockConflictError`-classified error, and the final `rooms.roomStatus === "REQUESTED"` (not "double-set" or "double-inserted into `roomLogs`").
  2. A test that calls `Promise.all([service.createAdmission(payloadA), service.createAdmission(payloadB)])` with **different** rooms but back-to-back calls in the same month, and verifies the two `admission_id`s are sequential and unique (i.e. no `P2002` from the `admissionId` UNIQUE constraint).
  3. A test that an `admission` insert failure *after* `countForAdmission` consumes a serial does not cause the next month to inherit a duplicate serial (this is the gap-closing property the new code loses; the test will fail under the new code and pass under the old `count` code, which is the desired evidence to drive the fix).

  Evidence: `hms-summary-service/src/**/__tests__/*.test.ts` shows the team uses Jest; `hms-app/` may not have a parallel pattern (verify), but adding a `__tests__/` directory in `admission.service.ts`'s parent is consistent with the project conventions.

### Medium

- **`admission.repository.ts:155` — Advisory lock is taken *outside* the `month` window, so it serializes all admissions globally, not per-month**

  `countForAdmission` is month-bounded (the `WHERE created_at >= startOfMonth AND created_at < endOfMonth` filter), but the advisory lock is taken with a global key `12345`. This means:
  - An admission for **June 2026** blocks an admission for **July 2026** even though the two cannot collide on serial numbers.
  - A high-volume day in any month will queue admissions across the entire system, including months that have nothing to do with the current one.

  Per-month namespacing of the lock key (see High issue above) fixes this and is a 2-line change: `pg_advisory_xact_lock(hashtext($1)::int, $2::int)` with arguments `('admission_id:' || $1, 1)` for the month string. (Two-argument form: `pg_advisory_xact_lock(int, int)` keys on the *pair*, not the sum.)

  Evidence: `admission.repository.ts:155-163` — single global key, month window enforced only in the SELECT.

- **`admission.service.ts:341-343` — `SELECT id, "roomStatus" FROM rooms WHERE id = ${roomId}::uuid FOR UPDATE NOWAIT` does not check the room's `buildingId` / `wardId` against the payload**

  The post-lock re-check at `:359-363` verifies only `roomStatus === "AVAILABLE"`. It does not verify that the room belongs to the `buildingId` / `wardId` from the payload. If a concurrent edit (e.g. a room re-assignment) changes the room's `buildingId` between the payload validation and the `handleRoomAllocation` call, the admission would be assigned to a room in a different building/ward. This is a low-likelihood race (rooms are not normally re-assigned mid-admission), but it's the same shape of bug the rest of the PR is trying to prevent.

  Fix: extend the `SELECT` and the re-check to include `buildingId` and `wardId`, and `throw new AppError("Room assignment changed mid-transaction", 409)` if they don't match.

  Evidence: `admission.service.ts:341-343` (SELECT), `:359-363` (re-check). `prisma/schema.prisma:2347-2364` (Room model has `buildingId`, `wardId`).

- **`admission.service.ts:343-345` — `FOR UPDATE NOWAIT` followed by a JavaScript `throw new Error(...)` is not transactionally consistent with the rest of the work in `prisma.$transaction`**

  When the `FOR UPDATE NOWAIT` fails, the PR throws a plain `new Error("This room is currently being processed by another user. Please try again.")`. The other error paths in this service throw `new AppError("…", 400)` or `new AppError("…", 404)` (e.g. `:434-437` for "Patient not found"). The current service's `tRPC` / `server action` layer expects `AppError` so it can map to the right HTTP status and shape — a plain `Error` will surface as a 500 to the user, not the user-friendly 409 the author intends.

  Fix: `throw new AppError("This room is currently being processed by another user. Please try again.", 409)`. Same fix for the "room does not exist" branch at `:355-357` (use `AppError("The requested room does not exist.", 404)`) and the "just booked by another user" branch at `:359-363` (use `AppError(…, 409)`).

  Evidence: `admission.service.ts:346-349` (plain `Error` thrown for lock conflict); `:356-358` (plain `Error` for missing room); `:360-363` (plain `Error` for re-check failure). `admission.service.ts:434-437` (existing `AppError` pattern for the analogous patient-not-found case).

### Low

- **`admission.repository.ts:148` — `countForAdmission`'s parameter is now optional (`tx?: Prisma.TransactionClient`), but the call site that passes no `tx` is a behavior change waiting to happen**

  The signature is `async countForAdmission(date: dayjs.Dayjs, tx?: Prisma.TransactionClient)`. The current caller in `admission.service.ts:519` always passes `tx` (the post-PR change), so the optional is justified. But: a future caller who forgets to pass `tx` and calls `countForAdmission(date)` will acquire the advisory lock on the global `prisma` client, *outside any transaction*. The `pg_advisory_xact_lock` requires a transaction (it's a no-op without one — Postgres issues a warning), and the raw `SELECT` runs against the connection pool. The race condition the lock is meant to prevent is *not* prevented in this case.

  Fix: drop the optional and make `tx` required. The function is only called from `generateAdmissionId`, which only runs inside `prisma.$transaction`. Force the caller to be explicit.

  Evidence: `admission.repository.ts:148-150` (signature); `admission.service.ts:519` (only caller, always passes `tx`).

- **`prisma-errors.ts:6` — `POSTGRES_LOCK_NOT_AVAILABLE_CODE = "55P03"` is a magic string with no Postgres-doc cross-reference**

  The literal `"55P03"` is correct (Postgres SQLSTATE for `lock_not_available`), but a future maintainer reading this file will have to look it up. Add a one-line comment: `// Postgres SQLSTATE for lock_not_available. See https://www.postgresql.org/docs/current/errcodes-appendix.html.`

  Evidence: `prisma-errors.ts:6`.

### Nit

- **`admission.service.ts:350-352` — The new `try/catch` wraps a single `$queryRaw` call. Move the `isRoomLockConflictError` check inline**

  ```ts
  try {
    [currentDbRoom] = await tx.$queryRaw<…>`…`;
  } catch (error) {
    if (isRoomLockConflictError(error)) {
      throw new Error("…");
    }
    throw error;
  }
  ```

  Can be flattened to:

  ```ts
  let currentDbRoom: { id: string; roomStatus: string }[];
  try {
    [currentDbRoom] = await tx.$queryRaw<…>`… FOR UPDATE NOWAIT`;
  } catch (error) {
    if (isRoomLockConflictError(error)) throw new AppError("…", 409);
    throw error;
  }
  currentDbRoom = currentDbRoom;
  ```

  …or, better, use a discriminated error class and a single error-translation middleware. Not a blocker; style.

  Evidence: `admission.service.ts:334-352`.

## Scope creep / file placement

The PR is small (3 files, +81/-13) and the scope is appropriately tight: a single bug class (admission create race conditions), two interlocked fixes (admission ID generation + room allocation), and one error helper. **No scope creep** in the file-coverage sense. The two correctness regressions flagged in Critical are within the same conceptual surface.

The architectural choice to use an *advisory lock* (rather than the `FOR UPDATE` row-lock pattern already established at `ct-add-on-billing.service.ts:910-934` for the same purpose) is the one structural concern: the codebase now has two different concurrency-control idioms for "monthly serial generation", and the next engineer to add a third (e.g. for IPD daily-bill numbers) will be tempted to copy whichever is closest, and will likely pick the wrong one.

**Recommendation:** in a follow-up PR, refactor `ct-add-on-billing.service.ts:910-934` to use the same advisory-lock pattern (or vice-versa), and extract a shared `getNextMonthlySerial(tableName, prefixColumn, monthColumn)` helper. That refactor is out of scope here.

## Type safety & schema issues

- `admission.repository.ts:151` — `const client = tx || this.prisma;` widens the type to `TPrismaClient | Prisma.TransactionClient`. Both have `$executeRaw` and `$queryRaw`, so the calls are safe, but the return type of `$queryRaw<Array<{ admission_id: string }>>` is fine. No type regression.
- `prisma-errors.ts:66-67` — `isRoomLockConflictError` returns `error is Prisma.PrismaClientKnownRequestError`. This is a *narrowing* return type — the caller still needs to handle the `else` branch (the function's return value is `false` for non-matching errors, but the type guard is only consulted in the `if`). The current call site at `admission.service.ts:346-349` does this correctly. No issue, but worth a one-line comment that the type guard is *advisory*, not *exhaustive*.
- `admission.service.ts:332` — `let currentDbRoom: { id: string; roomStatus: string } | undefined;` is declared but assigned only inside the `try` block. The TypeScript narrowing will not see the assignment if the `try` block throws. The pattern works (the subsequent `if (!currentDbRoom)` check is at function scope and runs regardless of the try/catch outcome), but a reader might be confused. Consider declaring the `let` inside the `try` and using a `try/catch/finally` or hoisting the type guard with `let result: … | null = null;`.

## Transaction & data integrity

- **Advisory lock is auto-released on commit/rollback** (because `pg_advisory_xact_lock`, not `pg_advisory_lock`). Confirmed correct.
- **`FOR UPDATE NOWAIT` is held until commit/rollback** of the surrounding `prisma.$transaction`. The lock is acquired in `handleRoomAllocation` (inside the transaction callback) and held until the transaction commits (after the `roomLog.create`, `room.update`, and `activityLogger.log` calls). Lock-hold time is bounded by the transaction's total latency, which is bounded by the slowest of the per-row inserts. This is acceptable for the `rooms` row but a high contention hazard for the advisory lock (see High issue).
- **The new `FOR UPDATE NOWAIT` is the first use of `FOR UPDATE` in the IPD module.** `grep` confirms no other IPD code path uses row-level locking. Future IPD work that introduces concurrent writes to the same row (e.g. room checkout, bed transfers) will need to follow this pattern. Worth a one-line ADR or comment in the file noting "this is the canonical pattern for room-row concurrency in the IPD module".
- **The PR does not change the `Admission` schema** — the UNIQUE constraint on `admissionId` (`prisma/schema.prisma:2461`) remains the last line of defense. If both the advisory lock and the new `countForAdmission` semantics fail, the `P2002` error from the UNIQUE constraint will surface to the user as `prismaErrorHandler`'s `"Value with admission_id field already existed!"` message — a clear and user-actionable error. No additional safety net is needed, but the `isUniqueFieldError` path should be verified to cover this case (it does: `prisma-errors.ts:21-32`).
- **The pre-PR code path generated `admissionId` *outside* the transaction** (pre-PR `admission.service.ts:91`), which was a separate bug: a rolled-back transaction would still consume an ID. The PR fixes this by construction. Good.

## Performance

- The advisory lock + raw `SELECT` adds one round-trip per `createAdmission`. Negligible.
- The `FOR UPDATE NOWAIT` adds one round-trip per `createAdmission` *that has a room* (the lock is in `handleRoomAllocation`, gated by `payload.buildingId && payload.roomStatus && payload.roomId`). Negligible.
- The advisory lock serializes *all* admissions globally, not per-month (see Medium issue). At 1 admission/sec, the advisory lock adds 1 ms of average wait. At 10 admissions/sec, the advisory lock adds 10 ms of average wait and creates a queue depth of ~1. At 100 admissions/sec (busy day, 24×7 hospital), the advisory lock becomes the throughput bottleneck. The per-month namespacing fix in Medium reduces this to "serialization within a month", which is acceptable.
- `ct-add-on-billing.service.ts:910-934`'s `FOR UPDATE` (row-level) does not have this throughput hazard because the row lock is per-target, not global. If the advisory lock's throughput cost is a concern, the right architectural fix is to switch to the row-lock pattern (matching the existing `ct-add-on-billing.service.ts` approach). Out of scope for this PR; flag for follow-up.

## Accessibility & UX

- The "This room is currently being processed by another user. Please try again." and "This room was just booked by another user. Please select a different room." messages are user-readable and actionable. Good.
- The "Please try again." suggestion is not paired with a retry mechanism. A 1–2 second auto-retry on the client side would resolve most "currently being processed" cases without user friction. Out of scope, but worth a follow-up ticket.
- The "The requested room does not exist." message is correct but should probably trigger a refetch of the room list so the user sees the current set of rooms, not the cached set. Out of scope, but worth a follow-up.

## Error handling

- `isRoomLockConflictError`'s message-string fallback (High issue above) is the only error-handling concern. The structured `meta.database_error_code` check is correct.
- The new `throw new Error(...)` in `handleRoomAllocation` (Medium issue above) is the only error-translation concern. All three error paths should throw `AppError` with the correct status code.
- The pre-existing `prismaErrorHandler` covers the UNIQUE-constraint fallback (`P2002` on `admissionId`) and will surface a clear error to the user if the advisory lock fails. The defense-in-depth is sound.

## Style & consistency

- The new advisory-lock pattern diverges from the existing `FOR UPDATE` pattern at `ct-add-on-billing.service.ts:910-934` for the same purpose. Future engineers will face a choice; the right fix is to align the two patterns (follow-up PR, out of scope).
- The new `isRoomLockConflictError` function name is descriptive and follows the existing `isForeignKeyConstraintViolationError` / `isUniqueFieldError` naming convention. Good.
- The post-lock re-check (`admission.service.ts:359-363`) is a `throw new Error`, while the analogous "patient not found" check at `:434-437` is `throw new AppError("…", 404)`. Same pattern, different error class. Inconsistent. Fix: use `AppError` everywhere (Medium issue above).
- The new code at `admission.service.ts:332-352` introduces a `let` declaration followed by destructuring assignment (`[currentDbRoom] = await …`). This is a TypeScript pattern that often lints as `prefer-destructuring` or `no-array-destructuring-property`; verify the project's `eslint` config allows it. If not, switch to `const result = await …; const currentDbRoom = result[0];`.

## Questions for the author

1. The PR body claims `Promise.all` was replaced with `for` loops. The diff contains no such change. Which is correct — the description, or the diff? If the diff, please update the description. If the description, please push the missing changes.
2. The PR body says "Removed `NOWAIT` from raw room queries" — but the diff *adds* `FOR UPDATE NOWAIT` to a new raw query. Was there a prior `NOWAIT` somewhere that's now removed (and not in this diff)? If so, point to it.
3. `countForAdmission`'s behavior change from `count(*)` to "parse the latest `admission_id`" preserves the gap-closing property only if every admission in the month has a sequential serial. If an `admission` insert fails after `countForAdmission` runs (e.g. due to a downstream constraint), the next month's serial will be `highest_seen + 1`, not `count + 1`, and the count will drift upward forever. Is this acceptable, or should the function be reverted to `count(*)` inside the advisory lock?
4. The advisory lock key is `12345` — a magic number. Is there a documented naming scheme, or should the PR introduce a `constants/lock-keys.ts` file with a named constant?
5. The pre-PR code generated `admissionId` *outside* the `prisma.$transaction`. The PR moves it inside. This is a real bug fix — was it intentional, or an accidental consequence of the lock change? Either way, it should be called out in the commit message and the PR description.
6. Is there a follow-up ticket for the inconsistency between this PR's advisory-lock approach and the `FOR UPDATE` pattern at `ct-add-on-billing.service.ts:910-934`?

## Cross-references

- **`/Users/pyaesonewin/CLAUDE.md` §Rules** — "Keep files under 500 lines" — the modified `admission.service.ts` and `admission.repository.ts` are both over 500 lines (the local files are 499+ and 470+ lines respectively; the PR pushes the service over 500). The PR's changes are concentrated enough that the rule is not actively violated, but the file is at the cap.
- **`/Users/pyaesonewin/CLAUDE.md` §Rules** — "Validate input at system boundaries" — the post-lock re-check at `admission.service.ts:359-363` validates `roomStatus` only; not `buildingId` or `wardId` (see Medium issue). A small follow-up.
- **`hms-app/CLAUDE.md`** — `enhancedApiHandler`, `verifyApiAuth`, `permission-ui-config.ts` rules are *not* relevant to this PR (no API route is changed; this is a service-layer change). No ADR cross-checks needed.
- **`hms-docs/` (project root CLAUDE.md)** — No outbox / summary-service implications; this PR is purely a service-layer change to the IPD module.
- **`ct-add-on-billing.service.ts:908-934`** — The established pattern for "monthly serial inside a transaction" in this codebase. The PR should follow the same pattern (`FOR UPDATE` on the relevant row, advisory lock only if a global lock is *actually* required).
- **No summary-service, outbox, HMAC, or tenant-scope implications.**

## Verification needed

Things that cannot be verified from the diff alone:

1. **Does the new `countForAdmission` produce the same serial sequence as the old `count(*)` approach, in the common case?** Manual test: insert 5 admissions in a month, delete the 3rd, and ask `countForAdmission` for the next month. Old code: returns `5` (count of committed rows). New code: returns `5` (the highest existing serial is 5; the gap is preserved). If the team's intent is "fill the gap", the new code is wrong; if the team's intent is "never reuse a serial", the new code is right. The ClickUp ticket and the team should agree.
2. **Does the `FOR UPDATE NOWAIT` actually fire?** Manual test: open two browser tabs to the admission form, pick the same room, click "Book" within 50 ms of each other. One should succeed, the other should show the friendly error. If both succeed (or both fail with 500), the lock is not firing.
3. **Does the advisory lock's throughput bound match the hospital's admission rate?** If the hospital books more than ~50 admissions/minute in a single month, the global advisory lock will become the bottleneck. Per-month namespacing fixes this; switch to `FOR UPDATE` if per-month namespacing is insufficient.
4. **Does the `isRoomLockConflictError` match correctly under Prisma's current error format?** Manual test: simulate a lock conflict and inspect the `error.meta` and `error.message`. If `meta.database_error_code !== "55P03"`, the matcher is silently falling back to the `error.message.includes` branch.
5. **Does the deadlock (advisory + `FOR UPDATE NOWAIT` in different orders) actually manifest in production?** It's a low-probability event but a real one. Postgres's `deadlock_timeout` will eventually abort one of the transactions, but the user will see a generic `40P01` error, not the friendly "this room is being processed" message. Recommend a load test that fires 100 concurrent admissions and counts how many 500s leak through.
6. **SonarQube analysis is "failed" (per the bot comment on the PR).** Confirm whether this is a known infra issue or a new finding from the linter. The `throw new Error` (vs `AppError`) usage will likely trigger a "raw errors" rule; fix before re-push.

## Checklist results

- [ ] PR description matches diff — **FAIL**: claim (d) is false (no `Promise.all` → `for` change), claim (b) is inverted (`NOWAIT` is added, not removed). See Critical #2.
- [ ] `countForAdmission` semantics preserved — **FAIL**: the function changed from `count(*)` to "parse the latest `admission_id`". See Critical #1.
- [ ] Advisory lock key documented — **FAIL**: magic number `12345` with no comment. See High #1.
- [ ] `isRoomLockConflictError` reliable — **FAIL**: depends on Prisma's error-message format. See High #2.
- [ ] Lock-order deadlock — **FAIL**: advisory + `FOR UPDATE NOWAIT` can deadlock. See High #3.
- [ ] Tests — **FAIL**: no tests. See High #4.
- [ ] Advisory lock per-month — **FAIL**: global key. See Medium #1.
- [ ] `AppError` vs `Error` consistency — **FAIL**: three new `Error` throws should be `AppError`. See Medium #3.
- [x] Hardcoded secrets — None.
- [x] SQL/Prisma injection — `$queryRaw` uses parameterized queries; safe.
- [x] `console.log` / `console.error` — None in the diff.
- [x] `@ts-ignore` / `@ts-expect-error` / `eslint-disable` — None.
- [x] `any` type annotations — None.
- [x] Non-null assertion (`!`) — None.
- [x] Missing `await` inside transaction callbacks — N/A (no transactions modified beyond what's already there).
- [x] Tenant-scope — N/A.
- [x] Permission checks — N/A.
- [x] Missing Zod validation at boundary — N/A.
- [x] Transaction scope correctness — The advisory lock is correctly transaction-scoped (`pg_advisory_xact_lock`).
- [x] `FOR UPDATE NOWAIT` lock-scope correctness — The `FOR UPDATE` row lock is correctly held until the transaction commits.
- [ ] Architectural consistency with `ct-add-on-billing.service.ts:910-934` — Diverge. See Scope creep.

## Recommendation

Block merge until the two **Critical** issues are addressed:

1. Restore the `count(*)` semantics of `countForAdmission` (or rename the function to make the behavior change explicit and update the PR description). The advisory lock is still valuable for serializing the read+write, but the function should still do what its name says.
2. Reconcile the PR body with the diff. Either remove the false `Promise.all` → `for` claim, or commit the missing changes.

The **High** issues (advisory-key documentation, `isRoomLockConflictError` fragility, lock-order deadlock risk, missing tests) should also be addressed before merge. The **Medium** issues (per-month namespacing, room re-check completeness, `AppError` vs `Error` consistency) can land in this PR or as a follow-up; the author should pick.

The **Low** and **Nit** items are cleanup; not blocking.

The single biggest recommendation is to **align this PR's approach with the existing `ct-add-on-billing.service.ts:910-934` pattern** for monthly-serial generation. The codebase now has two concurrency idioms for the same task; one should win, and the row-level `FOR UPDATE` pattern is the simpler one to reason about. If the author insists on the advisory lock (e.g. for a future cross-tenant use case), document the rationale in a one-line comment in both files.
