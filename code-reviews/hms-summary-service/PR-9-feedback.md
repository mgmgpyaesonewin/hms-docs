# PR #9 Feedback — Round fees report PR review

| | |
|---|---|
| **Repo** | MyanCare/YCare-HMS-Summary-Service |
| **PR** | [#9](https://github.com/MyanCare/YCare-HMS-Summary-Service/pull/9) |
| **Title** | Round fees report PR review |
| **Author** | myopaingthu |
| **Base** | `development` ← **Head** `mpt/round-fees-report` |
| **Status** | OPEN |
| **Reviewer** | mgmgpyaesonewin (requested) |
| **Additions / deletions** | +100 / -731 |

## TL;DR verdict

**Request changes — multiple blocking issues.**

The audit-log additions are fine in intent (atomic write to `activity_logs` inside the same tx as the status change) but the audit-log code is repeated in 8 places with no shared helper, the `CollectStatus.CANCELLED` enum removal ships with no migration note, and the deletion of `src/services/rf-report.service.ts` is incomplete: at least 9 downstream files (router, server bootstrap, tenant-scope Prisma extension, worker handler, cache, utils, tests, backfill script, types) still reference the deleted module/types. The repo will not typecheck after this merges.

## Summary

This PR does three unrelated things in one branch:

1. Adds an `ActivityLog` model to the summary-service's Prisma subset and inserts an `activityLog.create` row inside the existing `payReports` / `revertReports` transactions of the four fee-report services (cf, ihd, pf, tc). The intent — keep the audit row in the same tx as the finance write — is correct.
2. Removes the unused `CANCELLED` value from the `CollectStatus` enum.
3. Deletes the entire `src/services/rf-report.service.ts` (730 lines), apparently to retire the round-fees (RF) feature.

The first two are reasonable but sloppy. The third is broken at HEAD.

---

## Findings — Blocking

### B1. Deleting `services/rf-report.service.ts` leaves the build broken
**File:** `src/services/rf-report.service.ts` (deleted)
**Why blocking:** The service exports `payReports` and `revertReports`, which are imported by `src/http/routes/rf-report.routes.ts:8` (`import { payReports, revertReports } from "../../services/rf-report.service";`). That route file still exists, and `src/http/server.ts:12,59` still wires it up (`rfReportRouter()`, mounted at `/rf-fee-reports`). After this PR merges, `npm run typecheck` and `npm run build` fail with `Module ... has no exported member 'payReports'`.

Additionally, the following files still reference the deleted symbols and will fail TS in turn:

| File | Line(s) | Reference |
|---|---|---|
| `src/http/routes/rf-report.routes.ts` | 8 | `import { payReports, revertReports } from "../../services/rf-report.service"` |
| `src/http/server.ts` | 12, 59 | `rfReportRouter` import + `app.use("/rf-fee-reports", rfReportRouter())` |
| `src/db/tenant-scope.ts` | 62-69 | `rfFeeReport: { $allOperations ... }` block in the Prisma extension |
| `src/lib/caches/rf-report-cache.ts` | full file | imports `ListRfReportQuery`, exports cache helpers |
| `src/lib/validators/rf-report.ts` | referenced by route | Zod schemas for the deleted endpoint |
| `src/lib/__tests__/rf-report-utils.test.ts` | full file | tests `computeAdjustmentDelta`, `resolvePayout`, `isRoundService` |
| `src/lib/rf-report-utils/index.ts` | full file | utility module |
| `src/workers/handlers/rf-fee-report.ts` | full file | worker handler that calls `reconcileOpdBill`, `reconcileIpdDailyBill`, `syncRefund` |
| `src/scripts/backfill-rf-reports.ts` | full file | one-off backfill script |
| `src/types/rf-report.type.ts` | full file | `RfSource`, `RfPayoutStatus`, `RfAdjustmentType`, `RfAdjustmentMode`, `RfSourceVoidedReason` |

The Prisma schema still defines `RfFeeReport`, `RfFeeReportStatusChange`, and `RfFeeReportAdjustment` (lines 442-538), so the *table* still exists, but no service in the codebase can use it.

**Suggested fix:** Pick one of:

- **(preferred)** Roll back the rf deletion — it's out of scope for an "activity logs on pay/revert" change. Open a separate PR titled "Retire round-fees feature" that removes the route, the router mount in `server.ts`, the Prisma extension entry, the worker handler, the backfill script, the cache, the utils + tests, and the schema models in one atomic diff.
- **Or** land this PR with the rf deletion fully completed: delete all 9 of the files above, drop the `RfFeeReport*` models and the `CollectStatus.CANCELLED` value's column-default consumers, and update `server.ts` / `tenant-scope.ts` to remove every rf reference. That's a separate large PR.

### B2. Untracked Prisma model + missing migration
**File:** `prisma/schema.prisma:743-762` (new `ActivityLog` model)
**Why blocking:** The new `ActivityLog` model is added to the summary-service's `prisma/schema.prisma`, but per `hms-docs/summary-service/README.md` (and `hms-app/CLAUDE.md`): *"The summary-service does not run migrations against the shared DB — the HMS team runs the DDL from `hms-docs/summary-service/data-model/schema.sql`."* The PR neither adds an entry to `hms-docs/summary-service/data-model/schema.sql` nor references a matching HMS migration. If the HMS team hasn't already shipped the column-shape match in their migration set, Prisma client generation on the summary-service side will drift from the live DB on the next `prisma generate`. (Conversely, if the HMS team *did* ship the DDL, the PR should cite the migration file.)

**Suggested fix:** Add a one-line note in the schema header comment linking to the canonical HMS migration (e.g. `// mirrors HMS migration hms-app/prisma/migrations/XXXXXX_add_activity_logs`). If the table isn't yet in HMS-owned DDL, this PR is gated on that migration landing first.

### B3. `ActivityLog.timestamp` will silently default — not transaction time
**File:** `prisma/schema.prisma:750` — `timestamp DateTime @default(now())`
**Why blocking (or at minimum important):** `payReports` and `revertReports` run inside a `prisma.$transaction`. The two prior sibling inserts in the same loop (`cfFeeReportStatusChange.create`, `cfFeeReportAdjustment.create`) both pass an explicit `changedAt: now` where `now` is computed once at the top of the loop, so every audit row in the same tx shares an exact `changedAt`. The new `activityLog.create` instead relies on `@default(now())`, which Postgres evaluates per-insert at commit time — i.e. the audit row's timestamp can drift microseconds-to-seconds from the status-change row in the same transaction. If anyone correlates `activity_logs.description` to `cf_fee_report_status_changes.from_status/to_status`, the timestamps won't match.

**Suggested fix:** Pass `timestamp: now` explicitly (matching the sibling rows in the same transaction), or drop the `@default(now())` from the Prisma model entirely so the app always supplies it.

---

## Findings — Important

### I1. 8× copy-paste of the audit-log insert
**Files:** `cf-report.service.ts:309-317`, `cf-report.service.ts:398-407`, `ihd-report.service.ts:611-619`, `ihd-report.service.ts:730-739`, `pf-report.service.ts:550-558`, `pf-report.service.ts:669-678`, `tc-report.service.ts:311-319`, `tc-report.service.ts:400-409`
**Why:** The same `tx.activityLog.create({ data: { description, action, entity, entityId, userId, additionalData? } })` call is hand-pasted into all four services, twice each. Only two strings (`description`, `entity`) change between sites, plus optional `additionalData`. Future fields (e.g. request ID, IP) require 8 edits.

**Suggested fix:** Extract a tiny helper next to the existing `cfi-payout.ts` pure helpers:

```ts
// src/services/audit-log.ts
export function auditPay(tx: Prisma.TransactionClient, args: {
  reportTable: "ConsultationFeesReport" | "InHouseDoctorFeesReport"
              | "ProcedureFeesReport" | "TeleConsultantFeesReport";
  entityId: string;
  userId: string;
}) { ... }

export function auditRevert(tx: Prisma.TransactionClient, args: {
  reportTable: ...;
  entityId: string;
  userId: string;
  remark?: string | null;
}) { ... }
```

Two 8-line functions beat 8 inline blocks. Both can still be called from inside `tx.activityLog.create` so the row stays in the same transaction.

### I2. `additionalData` shape is inconsistent
**Files:** `cf-report.service.ts:404`, `ihd-report.service.ts:735`, `pf-report.service.ts:674`, `tc-report.service.ts:405`
**Why:** The revert insert uses `additionalData: input.remark ? { remark: input.remark } : undefined`. Pay never sets `additionalData` even though it could carry the payout amount. If a downstream activity-log consumer expects `{ remark }` for reverts, the optional-chaining handling on the read side will silently fail for any non-revert row. Conversely, the absence of a schema/validation around `additionalData` means a future caller can shove arbitrary shapes in and break the audit dashboard.

**Suggested fix:** Define a tiny `additionalData` Zod schema (or two named shapes: `AuditPayData`, `AuditRevertData`) and validate before insert. Or, simpler: store the remark in the existing `cfFeeReportStatusChange.reason` column only and stop using `additionalData` here — `activity_logs` then becomes a pure notification row.

### I3. `CollectStatus.CANCELLED` removal has no migration note
**File:** `prisma/schema.prisma:1117` (deletion of `CANCELLED` enum value)
**Why:** The PR comment doesn't say whether this is removing an unused value, deprecating a flow, or in response to a HMS-side migration. There is no test or code change showing that no caller still writes `CANCELLED`. (I grep'd — none of the app code in `src/` writes to `CollectStatus`, but the column may still accept it from HMS, and removing an enum value is a breaking DB-level change for an HMS table.)

**Suggested fix:** Add a one-line justification in the schema header or PR description: "CANCELLED is unused per HMS migration XXXXX; safe to drop from the subset schema." If the HMS-side enum still has `CANCELLED`, the summary-service subset must match or `prisma generate` will produce types the runtime rejects.

### I4. No tests added for the new audit insert path
**File:** all four services
**Why:** Pay/revert now has a side effect beyond the fee-report state machine. A regression that drops the `activityLog.create` call (or breaks the FK to `userId`) would silently break audit history without any test catching it. The existing `tenant-scope.test.ts` and `rf-report-utils.test.ts` don't cover pay/revert at all.

**Suggested fix:** Add one Jest test per service that calls `payReports` / `revertReports` against a stubbed `tx` and asserts `activityLog.create` was called with the right shape. Five lines of mock setup; no real DB.

---

## Findings — Nit

### N1. Comment on `ActivityLog` describes *why* — keep it, but tighten
**File:** `prisma/schema.prisma:743-749`
The block comment explaining why the summary-service writes to an HMS-owned table is exactly the kind of context that prevents a future drive-by deletion. It's good. Consider adding the HMS migration id and the date of the agreement, otherwise future readers can't tell if the invariant still holds.

### N2. `action: "Pay"` / `action: "Revert"` strings
**File:** all four services
Free-text action strings with no enum or const set. If the activity-log dashboard filters by `action = 'Pay'`, a typo upstream (`'pay'`, `'PAID'`) silently drops rows. Promote to a `const AUDIT_ACTIONS = { Pay: 'Pay', Revert: 'Revert' } as const` (or a Prisma enum if HMS aligns on it).

### N3. `entityId` typed as `String` in the Prisma model but always passed as `row.id`
**File:** `prisma/schema.prisma:746`
The HMS-side column may or may not be a FK — the comment says "Real FK to HMS's users(id)". If `entityId` is also a real FK to the relevant `*_fee_reports.id`, the comment should say so; otherwise a future engineer might add a Prisma `@relation` that the subset schema doesn't actually back.

---

## Ponytail pass summary (over-engineering)

The audit-log shape itself is fine — it's an `INSERT` into an existing table, no premature abstraction. The problems are all about **how** it's added:

- **8× duplication of the same insert call** with only two strings changing — `auditPay` / `auditRevert` helpers replace 8 blocks of 8-10 lines each. Net: **~50 lines possible.**
- **No helper at all** for a shape that's literally a tuple of `(description, action, entity, entityId, userId)` — `I1` above.
- **`additionalData` used as a bag-of-one-field** — `I2`. Pick a column (`reason` already exists on the status-change row) or commit to a typed shape.
- **The rf deletion is the wrong size**: it's a 730-line deletion pretending to be a "remove a service" PR, but it actually exposes the rest of the rf feature as dangling imports. The lazy version is *don't delete rf yet* — ship the audit-log change alone.
- **`@default(now())` on `timestamp`** when every sibling insert in the same tx passes an explicit `now` — `B3`. One line.

No reinvented stdlib, no new dependencies, no speculative interfaces. The duplication is the only real over-engineering signal here.

**Net**: `-50 lines possible` if `I1` is applied; `+0 lines possible` from the rest of the PR (it's already lean once you ignore the rf deletion mess).

---

## Test coverage gap

- **No tests for the new `activityLog.create` insert** in any of cf/ihd/pf/tc services. The existing test suite only covers `tenant-scope.test.ts` and `rf-report-utils.test.ts`. Pay/revert has been untested in this repo since Phase 2 — this PR widens that gap.
- **The rf deletion removes no tests**, but it leaves `lib/__tests__/rf-report-utils.test.ts` (50+ lines of `isRoundService`/`resolvePayout` tests) referencing a module whose only consumer (`rf-report.service.ts`) no longer exists. After this PR merges, `npm test` fails.

---

## Final recommendation

**Request changes. Do not merge.**

1. **Drop the rf deletion from this PR.** File it separately. If rf retirement is the goal, do it as one atomic diff that removes the service, the route, the server mount, the Prisma extension entry, the worker handler, the backfill script, the cache, the utils + tests, and the schema models together. As-is, the branch is unreviewable as a single change.
2. **Add a tiny `auditPay` / `auditRevert` helper** (`I1`) so the four services don't carry 8 copies of the same insert.
3. **Cite the HMS migration** for the `ActivityLog` table (`B2`) and pass `timestamp: now` explicitly (`B3`).
4. **Add at least one Jest test** that asserts the `activityLog.create` is called inside the `payReports` transaction (`I4`). Without it, the audit-log path is one bad rebase away from silent deletion.

Once those four land — and the rf deletion is split out — this is a clean, narrow change.
