# PR #6 — Reading fees report PR review

- **Repo**: MyanCare/YCare-HMS-Summary-Service
- **PR**: https://github.com/MyanCare/YCare-HMS-Summary-Service/pull/6
- **Title**: Reading fees report PR review
- **Author**: myopaingthu
- **Base / Head**: `development` ← `mpt/reading-fees-report`
- **Status**: OPEN
- **Diff**: +119 / -731 (7 files)
- **ClickUp**: https://app.clickup.com/t/9018849685/86exqc3a1

---

## TL;DR

**Verdict: REQUEST CHANGES.**

Two unrelated changes are bundled in one PR: (1) deleting the entire round-fee report feature (`rf-report.service.ts`, -731 lines) and (2) adding transactional `activity_logs` writes inside the pay/revert paths of the five remaining fee-report services. The audit-log work itself is mostly fine but is duplicated 10× across 5 files with no shared helper, hides the `CollectStatus.CANCELLED` enum removal in a separate concern, and lacks a tenant-id guard on the new audit row (the rest of the service treats tenant as a first-class boundary per ADR 0007). The rf-feature deletion deserves its own PR with a real ADR/migration note. As-is, splitting and one shared helper would make this clean.

---

## What the PR does

1. **Deletes** `src/services/rf-report.service.ts` wholesale (730 lines) — the round-fee report's worker-side reconciler, refund sync, and pay/revert services. Implies the round-fee report feature is being retired.
2. **Adds** a derived `ActivityLog` model in `prisma/schema.prisma` (mirrors the HMS-owned `activity_logs` table for write-only access).
3. **Writes** one `tx.activityLog.create(...)` row inside the pay and revert transaction blocks of `cf`, `ihd`, `pf`, `reading`, and `tc` report services — 10 inserts total, audit-pair for each finance action.
4. **Removes** the unused `CANCELLED` value from the `CollectStatus` enum (no callers found in the diff).

---

## Findings

### Blocking

- **`prisma/schema.prisma:18-31` — `ActivityLog` has no `tenantId`.**
  Every other model this service touches is tenant-scoped (ADR 0007 + tenant-scope Prisma extension in `db/tenant-scope.ts`). `activity_logs` is HMS-wide; the tenant is implicit in `entityId`. But every other audit-relevant column on the source rows is tenant-scoped, so two tenants paying the same report id would produce cross-tenant-visible audit rows. Either (a) add `tenantId String` and write it from the call site, or (b) document explicitly in the comment that this table is intentionally global and the HMS UI filters by `entityId`. The current comment glosses over it.

- **`src/services/cf-report.service.ts:309-316` (+ same in ihd/pf/reading/tc pay+revert) — audit row is best-effort *inside* the tx, but no failure path is logged.**
  If `tx.activityLog.create` rejects (constraint violation on a future FK, e.g. `userId` no longer exists in HMS's `users` table), the whole pay/revert tx rolls back and the user sees a 500 — yet the audit intent was "commit in the same tx so the audit entry is atomic with the status change." That is the right design, but then the FK must be real and the failing user-id must be guarded. Either add an explicit FK relation to a local `User` model, or validate `userId` existence at the route boundary before opening the tx. Today an HMS-side user deletion mid-session breaks pay silently from the user's POV.

- **`src/services/rf-report.service.ts` — entire file deleted, but no replacement handler / no ADR / no migration note.**
  This is a -730-line feature deletion bundled into an audit-log PR. If anything in `event_outbox` or any worker still calls `reconcileOpdBill` / `reconcileIpdDailyBill` / `syncRefund` / `payReports` / `revertReports` from this module, the binary will not build or will throw at runtime. Confirm `grep -R "rf-report" src/` (and tests, routes, the worker entry) returns zero hits, then land this deletion in its own PR with an ADR note describing what replaced the round-fee payout workflow (per `hms-docs/summary-service/README.md` §"Future work", the v2 doctor-payout workflow was planned to supersede it).

### Important

- **All 5 services — copy-pasted 9-line `activityLog.create` block, ×10 call sites.**
  `pay` action and `revert` action each have nearly-identical 9-line inserts differing only in `description`, `action`, and `entity`. This is the "single change in many places" failure mode: adding the next fee-report service (OPD Income / IPD Discharge, both flagged as TODOs in the deleted `rf-report.service.ts`) will require copying this block yet again. Extract one helper, e.g.
  ```ts
  // src/lib/activity-log.ts
  export async function recordActivity(
    tx: Prisma.TransactionClient,
    input: { action: "Pay" | "Revert"; entity: string; description: string; entityId: string; userId: string; remark?: string | null }
  ): Promise<void> { ... }
  ```
  and call it from all 5 services. Drops the diff to ~5 lines per call site and centralises the `additionalData` ternary.

- **`prisma/schema.prisma:1116-1119` — `CANCELLED` enum value removed; unrelated to audit-log work.**
  Bundling schema drift with a feature PR is exactly what the project's `CLAUDE.md` warns against ("When source code and `hms-docs/` disagree, the docs win"). If `CANCELLED` is genuinely unused, fine — but show the grep in the PR description proving it. If it isn't, this is a hidden breaking change for downstream readers.

- **`prisma/schema.prisma:23-24` — comment claims `userId` is a real FK "enforced at the DB level."**
  Prisma will not know about it (no `@relation`), so type-level queries cannot traverse to the user, and an FK violation at runtime only surfaces as a Prisma error rather than a typed compile-time error. Either add `@relation` to a local `User` model (recommended — even a thin subset gives typesafety) or downgrade the comment from "real FK" to "DB-side constraint, not modelled."

- **No test coverage added for the new audit-log writes.**
  The repo already has `src/db/__tests__/tenant-scope.test.ts` (per the project CLAUDE.md). The same Jest harness should cover at minimum:
  1. `payReports` writes one `activity_logs` row per paid report.
  2. `revertReports` writes one row per reverted report, including the `additionalData.remark` when supplied.
  3. Activity-log write failure rolls back the status change (atomicity proof).
  This is the smoke check for the whole point of the PR.

- **String keys for `action` and `entity` are typo-prone.**
  `"Pay"`, `"Revert"`, `"ConsultationFeesReport"`, `"InHouseDoctorFeesReport"`, etc. are raw strings scattered across 5 files. A single typo (e.g. `"InhouseDoctorFeesReport"`) silently breaks HMS-side filtering forever — there's no DB constraint, and there's no compile-time check. Hoist into a const map (`const FEE_REPORT_ENTITIES = { CF: "ConsultationFeesReport", ... } as const`) or a Zod enum, and use it in the helper above.

### Nit

- **`prisma/schema.prisma:21-23` — `entityId`, `action`, `entity` are all nullable.**
  Nullable FK + nullable action label on an audit row is suspect: an `activity_logs` row with no `entity` and no `action` is just a free-text description with a userId and timestamp. If the HMS schema marks these nullable, fine — but document why, because the summary-service never writes nulls in these positions.

- **`prisma/schema.prisma:19` — `@default(uuid(7))` on an audit row.**
  `uuid(7)` is fine for primary keys, but for an audit log a `timestamp`-first primary key (or a `(timestamp, id)` composite index) usually serves read patterns better. Not a blocker — the HMS schema dictates the column type.

- **`src/services/cf-report.service.ts:317-318` (+ all 5 pay sites) — `paid.push(...)` happens after the audit insert.**
  If the audit insert throws, the row is already updated and the adjustment rows already inserted — but the outer `prisma.$transaction` rolls it all back. That's correct, but it's worth a one-line comment ("audit insert intentionally inside tx; rolls back on failure") because the order is otherwise non-obvious to future readers.

- **Description strings are hard-coded English (`"Paid Consultation Fees"`).**
  No i18n in this service today, so fine. But these strings land in the HMS UI — confirm with the HMS team that this locale matches their existing `activity_logs` convention so the PR doesn't introduce a third tone.

- **No `changelog` / `hms-docs` update.**
  The summary-service's `CLAUDE.md` lists 14 ADRs in `hms-docs/summary-service/adrs/`; nothing here references them. If the audit-log integration is a real cross-service contract change (HMS writes, summary-service writes, both must agree on shape), there should be at least an ADR pointing at `hms-docs/summary-service/api/` or `data-model/`.

---

## Ponytail pass — what to delete / simplify

```
src/services/{cf,ihd,pf,reading,tc}-report.service.ts: pay+revert blocks — yagni: 10 copies of the same 9-line activityLog.create. Replace with one helper in src/lib/activity-log.ts (recordActivity(tx, action, entity, entityId, userId, remark?)). Net: ~70 lines deleted, 5 files touched in 1 place each going forward.
prisma/schema.prisma:23-24 — yagni: comment "Real FK… not modeled as a Prisma relation" hand-waves a design gap. Either model the relation or remove the comment.
src/services/cf-report.service.ts:317 (and 4 siblings) — shrink: paid.push(...) is fine but the audit insert above it should not duplicate the entity-name mapping inline — let the helper own it.
```

`net: -70 lines possible from the audit-log work; the rf-report.service.ts deletion (-730) is unrelated cleanup that should ship in its own PR.`

---

## Test coverage gap

- No new tests added.
- Existing `src/db/__tests__/tenant-scope.test.ts` harness covers tenant scoping but not the audit-log writes.
- Missing coverage (must add before merge):
  1. `payReports` writes exactly one `activity_logs` row per paid report, with the correct `entity`, `action="Pay"`, `description` matching the fee type.
  2. `revertReports` writes one row with `action="Revert"` and `additionalData.remark` set when supplied, absent when not.
  3. Tx atomicity — an `activityLog.create` failure rolls back the `*FeeReport` status update and the `*StatusChange` insert.
  4. If `ActivityLog` is given a `tenantId`, ensure the tenant-scoped Prisma client enforces it (otherwise the tenant-scope extension test fails on this table).

---

## Final recommendation

**Request changes.** Three concrete asks before merge:

1. **Split the PR.** Land the `rf-report.service.ts` deletion in its own PR with an ADR/grep proof that nothing imports from it. Keep this PR focused on audit logging.
2. **Extract `recordActivity(tx, ...)`** in `src/lib/activity-log.ts` and replace the 10 inline blocks. Single change point, easier to test.
3. **Add the three tests above.** The atomicity test in particular is the one that proves the PR's headline claim ("audit entry commits in the same transaction as the status change").

Nice-to-have, not blocking: define `action`/`entity` as a typed enum (or Zod schema), and clarify the `tenantId` story on `ActivityLog` — either add the column or document explicitly that this table is intentionally global and HMS-side filtering handles it.

Once split + helper + tests land, this is an easy approve.