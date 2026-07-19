# PR #8 — Procedure fees report PR review

- **Repo:** MyanCare/YCare-HMS-Summary-Service
- **PR:** [#8](https://github.com/MyanCare/YCare-HMS-Summary-Service/pull/8)
- **Title:** Procedure fees report PR review
- **Author:** myopaingthu
- **Reviewer:** mgmgpyaesonewin (requested)
- **State:** OPEN
- **Diff size:** +100 / -1 across 5 files
- **ClickUp:** https://app.clickup.com/t/9018849685/86exqc0u6

## TL;DR

**Request changes — blocking.** This PR moves audit-log writes for fee-report `pay`/`revert` from the HMS BFF (which already owns `activity_logs` via `hms-app/.../activity-logger.ts`) into the summary service. That's an architectural inversion: a downstream, read-mostly worker is now writing to an HMS-owned table inside its own transaction, bypassing the tenant-scope extension and the outbox pattern this service is built around. Even if the team wants the audit row to commit with the status change, the current shape is wrong on its own — no `tenant_id`, no FK enforcement on `user_id`, 8 duplicated string literals, dead nullability, and a drive-by enum deletion. Minimum-acceptable path: either revert and emit a `fee_report.pay|revert` outbox event the BFF consumes, or fix the blockers below.

## What the PR does

Adds an `ActivityLog` model to the hand-maintained Prisma subset and inserts one audit row per fee-report `pay`/`revert` action across four services (`cf`, `ihd`, `pf`, `tc`). Also removes the unused `CANCELLED` member of the `CollectStatus` enum in the same diff.

## Findings

### Blocking

- **B1 — Wrong writer / architectural inversion.** `prisma/schema.prisma:743-762`, plus all 8 `tx.activityLog.create` call sites in `cf/ihd/pf/tc-report.service.ts`. The HMS BFF already owns `activity_logs` via `hms-app/.../activity-logger.ts` (queued batched `createMany`, same `{description, userId, entityId, entity, action, additionalData}` shape). The summary service is explicitly *not* trusted to mutate HMS-owned tables (ADRs 0001 / 0007). Adding an `ActivityLog` model here creates a second writer for the same table the BFF already writes, with no compensation path, no read-back, and a schema fork to reconcile. **Fix:** Revert all 8 inserts + drop the model. If atomicity with the status change is the real requirement, emit a `fee_report.pay|revert` outbox event in the same `tx` (mirroring the existing `opd_invoice.created` handler) and let a BFF-side worker materialize the audit row.

- **B2 — Multi-tenant bypass.** `prisma/schema.prisma:750-760`. `ActivityLog` has no `tenant_id` column and the tenant-scope Prisma extension in `src/db/tenant-scope.ts` only injects `tenantId` into the six `*FeeReport` models — not `activityLog`. Writes go through the unscoped `tx` in services. Cross-tenant audit rows are trivially possible and undetectable. **Fix:** Add `tenantId` to the model AND extend `tenant-scope.ts` to cover `activityLog`, OR (preferred per B1) delete this code path.

- **B3 — Unenforced FK on `user_id`.** `prisma/schema.prisma:757`, plus the 8 insert sites. The inline comment claims the DB enforces an FK to `users(id)`. The hand-maintained Prisma subset carries no DDL — the canonical `hms-docs/summary-service/data-model/schema.sql` does not include `activity_logs`, so there is no FK in the shared DB. A malformed or stale `paidById` / `changedById` from the BFF aborts the whole pay/revert transaction; a valid-but-wrong user id silently writes a bogus audit row. **Fix:** Validate `userId` is a UUID at the route boundary (Zod), and have the HMS team add the DDL for `activity_logs` with the FK + `tenant_id` + indexes before this lands.

- **B4 — Drive-by enum deletion.** `prisma/schema.prisma:1095`. `CollectStatus.CANCELLED` is removed with no paired DDL in `hms-docs/.../schema.sql`, no migration file, no coordination note. If any `opd_billing_services` row still holds `'CANCELLED'`, the HMS reconcile path will start failing on the next read. **Fix:** Split into a separate PR, coordinate with the HMS team, and confirm zero rows before merge.

### Important

- **I1 — Eight near-identical insert blocks, 32 duplicated string literals.** `cf/ihd/pf/tc-report.service.ts` × `{payReports, revertReports}` × 4 string fields = 8 call sites and 32 magic strings (`"ConsultationFeesReport"`, `"InHouseDoctorFeesReport"`, `"ProcedureFeesReport"`, `"TeleConsultantFeesReport"` × 2 each, plus 4 description prefixes × 2 each). One typo silently breaks audit aggregation across services. **Fix:** If the team rejects B1, at minimum extract `src/services/_audit.ts` with `logActivity(tx, kind, action, rowId, userId, remark?)` and a `REPORT_KIND` const per service so the 8 sites become 8 one-liners.

- **I2 — Dead nullability.** `prisma/schema.prisma:752-754`. `entityId`, `action`, `entity` are nullable in the model, but every one of the 8 inserts provides non-null values. Dead flexibility that invites garbage rows. **Fix:** Drop `?` on those three columns. Make `action` an enum (`Pay | Revert`).

- **I3 — Missing read indexes on a write-only audit table.** No `@@index([entity, entityId])`, no `@@index([userId])`, no `@@index([tenantId, timestamp])`. The whole point of audit is being able to query it back. **Fix:** Add the three indexes above (and the matching DDL).

- **I4 — Audit insert on the critical path with no idempotency.** A failed audit row rolls back the payment + status change + adjustment. The previous BFF best-effort write was recoverable; this is not. Retry of a partial pay (e.g. transient tx error after a future audit row is written) will create duplicate audit rows. **Fix:** Either (a) keep audit off the critical path (per B1 — emit an outbox event instead), or (b) add a unique constraint on `(entity, entityId, action)` to dedupe retries.

- **I5 — `additionalData` JSON shape untyped.** `cf-report.service.ts:404-407` and the three siblings. `additionalData: input.remark ? { remark: input.remark } : undefined` is the only consumer and there is no Zod schema for what lives in this column. **Fix:** Add a Zod schema for `additionalData` and document the expected keys per action.

- **I6 — UUID input not validated at the API boundary.** `PayInput.paidById: string` and `RevertInput.changedById: string` go directly into a `@db.Uuid` column. A non-UUID value from a future BFF bug surfaces as a Prisma `P2010` / `22P02` mid-transaction, rolling back the whole pay operation. **Fix:** Add `z.string().uuid()` at the route boundary.

### Nit

- **N1 — English-only `description` strings.** Other audit-log consumers (HMS BFF) localize these. Decide and document.
- **N2 — Schema comment claims `uuid(7)` matches HMS.** Verify against HMS's actual default before this lands; a mismatch makes joining across services painful.
- **N3 — No test files changed.** Zero coverage for the new audit-write path. At minimum one test per service asserting the audit row exists with the right `userId`, `entity`, `action`, and `additionalData`.
- **N4 — `tx.activityLog.create` runs through the unscoped `prisma.$transaction`.** Even after B1/B2 land, the write path bypasses the tenant-scope extension. Follow-up: route the call through `req.prisma.$transaction` so the extension runs.

## Ponytail pass summary

What to delete / simplify:

1. **Delete the entire `ActivityLog` model + comment block** (`prisma/schema.prisma:743-762`) and **all 8 `tx.activityLog.create` blocks** — the BFF already owns the writer.
2. **If the team insists on the feature here**, replace the 8 inserts with one helper (`src/services/_audit.ts`) parameterized by `{entityName, action, tx, rowId, userId, remark?}`. Eight one-liners, one home for the 4 entity strings.
3. **Drop `?` from `entityId`/`action`/`entity`** — every insert is non-null; nullability is dead.
4. **Split the `CANCELLED` removal** into its own PR. Unrelated to the audit feature.
5. **Skip the "we own this but only write it" justification comment** — the comment exists *because* the writer is misplaced; deleting the writer deletes the comment.

## Test coverage gap

- No tests added or updated. Eight new write paths, zero coverage.
- Recommended: one test per service asserting
  - audit row exists with the right `userId`, `entity`, `entityId`, `action`, `description`;
  - a failed audit insert rolls back the status change (current behavior);
  - `additionalData` is `undefined` when `remark` is empty and `{remark}` when set;
  - a `tenantId` mismatch is impossible (will pass trivially because `tenantId` is missing on the model — see B2).

## Final recommendation

**Request changes.** Address B1–B4 before merge. B1 alone (wrong writer) is enough to block on its own; B2 (cross-tenant audit) and B3 (no FK, no UUID validation) compound it. If the team wants the audit row committed in the same tx as the status change, route it through the existing outbox pattern — that's what `event_outbox` is for, and it's already wired.