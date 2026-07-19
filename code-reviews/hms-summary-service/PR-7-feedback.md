# PR #7 — Inhouse doctor fees report PR review

- **Repo**: MyanCare/YCare-HMS-Summary-Service
- **Base / Head**: `development` ← `feat/in-house-doctor-fees-report`
- **Author**: myopaingthu
- **Status**: OPEN
- **Additions / Deletions**: +81 / -1
- **Files**: `prisma/schema.prisma`, `src/services/cf-report.service.ts`, `src/services/ihd-report.service.ts`, `src/services/tc-report.service.ts`
- **Link**: https://github.com/MyanCare/YCare-HMS-Summary-Service/pull/7

## TL;DR verdict

**Request changes.** The change adds an audit write into `activity_logs` for `pay`/`revert` in the three fee-report services — that's the right idea (same tx as the status change is correct), but it crosses a service boundary by writing an HMS-owned table from this service, duplicates the insert six times across three files, and contains an unrelated schema drop (`CollectStatus.CANCELLED`) that should be in its own PR.

## Summary

Adds an `ActivityLog` model to the summary-service's hand-maintained Prisma subset and inserts one row per paid/reverted fee report in `cf-report`, `ihd-report`, and `tc-report` services, so the audit entry commits in the same transaction as the CFI status change rather than being a separate best-effort write from the BFF. Also drops the unused `CANCELLED` enum value from `CollectStatus`.

## Findings

### Blocking

**1. `prisma/schema.prisma:743-767` — Service boundary violation: writing an HMS-owned table**
The summary-service CLAUDE.md is explicit: this service uses a "hand-maintained Prisma subset" of HMS tables it *reads*, and the canonical DDL for new tables lives in `hms-docs/summary-service/data-model/schema.sql`. `activity_logs` is a write-heavy HMS table; letting this service insert into it directly means:
- Schema drift risk if HMS changes `activity_logs` columns/types (no enum on `action`, no FK, optional everything).
- Two writers (BFF + summary-service) racing for the same audit table with no coordination.
- A direct contradiction of the "HMS team runs the DDL" invariant in the design brief.

**Fix:** Either (a) keep the activity_log insert in the BFF and pass it as part of the same outbox event so this service stays read-mostly on HMS tables, or (b) promote this to an ADR + add the canonical DDL into `hms-docs/summary-service/data-model/schema.sql` and confirm with HMS team that adding a second writer is acceptable. Pick one; the current diff does neither.

**2. `prisma/schema.prisma:1119` — Unrelated schema change bundled in**
Dropping `CollectStatus.CANCELLED` has no connection to fee-report audit logging. If `CANCELLED` is genuinely dead, fine — but mixed with a cross-service write change, it muddies the review and the rollback unit. **Fix:** split into a separate PR (or at minimum a separate commit) with the grep evidence that `CANCELLED` is unreferenced anywhere in this repo.

### Important

**3. `src/services/{cf,ihd,tc}-report.service.ts` — Six near-identical inserts should be one helper**
The three `payReports` blocks and the three `revertReports` blocks differ only by `description`, `entity`, and (for revert) the optional remark. That's a textbook duplication. Extract one helper:

```ts
function recordAudit(
  tx: Tx,
  args: { action: "Pay" | "Revert"; entity: string; description: string; rowId: string; userId: string; remark?: string }
): Promise<void> {
  return tx.activityLog.create({
    data: {
      action: args.action,
      entity: args.entity,
      description: args.description,
      entityId: args.rowId,
      userId: args.userId,
      ...(args.remark ? { additionalData: { remark: args.remark } } : {}),
    },
  });
}
```

Then each call site is one line. Six 9-line blocks collapse to six 1-line calls plus one 14-line helper.

**4. `prisma/schema.prisma:746-758` — Schema subset pattern partially violated**
Per the existing convention, the model header comment block describes whether the table is HMS-owned and the constraint posture. The new `ActivityLog` model has the comment but:
- `entityId`, `action`, `entity`, `description` are all **nullable** in the new schema. If the canonical HMS table has these as `NOT NULL`, this service's `tx.activityLog.create(...)` will succeed locally but the HMS-side canonical DDL might not. Confirm against `hms-docs/summary-service/data-model/schema.sql`.
- `userId` is declared non-null but described as "Real FK to HMS's users(id), enforced at the DB level". If the HMS users table is tenant-scoped and the summary-service has no tenant guard on this insert, a future tenant-context bug will write audit rows under the wrong tenant. See finding #6.

**5. `src/services/{cf,ihd,tc}-report.service.ts` revert blocks — `additionalData: { remark }` shape inconsistency**
`payReports` writes no `additionalData`; `revertReports` writes `{ remark: string }` only when `input.remark` is truthy. The HMS-side `activity_logs.additional_data` JSON column consumers will see three possible shapes (`null`, `undefined`, `{ remark: "..." }`). Confirm the downstream audit viewer expects exactly this contract; otherwise consumers have to handle "missing remark" vs "null remark" vs "additionalData is null" differently. Suggested fix: always write `additionalData: { remark: input.remark ?? null }` for a stable shape, or always `null` when absent — pick one and document it.

**6. ActivityLog is not tenant-scoped**
CLAUDE.md ADR 0007 establishes "defense-in-depth" multi-tenancy: HMAC → Prisma `tenant-scope` extension forces `tenantId` on every CFI query → Redis keys are tenant-prefixed → logs carry `tenantId`. The new `ActivityLog` model has no `tenantId` and the inserts go through `tx` (which, in `payReports`/`revertReports`, is the unscoped `prisma.$transaction` client, not `req.prisma`). For the activity_log rows to be partitionable per tenant (and to honor the invariant "logs carry tenantId"), `tenantId` needs to flow into the audit row. **Fix:** add `tenantId String @map("tenant_id") @db.Uuid` to the model and pass `req.tenantId` (or the equivalent context) down to the service. If the HMS activity_logs table genuinely has no tenant_id column, that itself is an ADR-worthy decision.

**7. `src/services/{cf,ihd,tc}-report.service.ts` — No tests**
There is zero test coverage for the new audit insert in any of the three services. At minimum one Jest test per service asserting:
- `tx.activityLog.create` is called once per row in the transaction
- `tx.activityLog.create` happens *inside* the same transaction (rolls back when the status update fails)
- `revertReports` writes `additionalData.remark` when provided, omits it when not

Given the project already has a `tenant-scope.test.ts` precedent, the bar is not zero.

### Nit

**8. `prisma/schema.prisma:740-742` — Overlong banner comment**
The 7-line banner block could be one line: `// activity_logs: HMS-owned; this service writes audit rows in the same tx as fee-report status changes.` The current prose is documentation about the motivation, which belongs in the commit message / ADR, not the schema file.

**9. `src/services/{cf,ihd,tc}-report.service.ts` — `description` strings should be constants**
"Paid Consultation Fees", "Paid In-house Doctor Fees", "Paid Tele Consultant Fees" and their revert counterparts are user-facing audit text. Put them next to the `entity` constants so an i18n or product copy change is one diff, not three.

**10. Field ordering inconsistency**
`cf-report` orders `description` first; `ihd-report` and `tc-report` order it identically to `cf-report` only by coincidence (the literal block is copy-pasted). If you keep the duplication instead of extracting the helper from finding #3, at least order fields the same way so future diffs are cleaner.

## Ponytail pass (what to delete / simplify)

```
prisma/schema.prisma:740-742: shrink: 7-line banner comment about the rationale. One-line comment + ADR reference.
prisma/schema.prisma:746-758: yagni: nullable entityId/action/entity/description "for HMS-side flexibility". Match HMS schema exactly; if they're nullable there, document it; otherwise make non-null.
src/services/cf-report.service.ts:309-319: delete: inline 9-line tx.activityLog.create. extract once into recordAudit(tx, {...}).
src/services/cf-report.service.ts:398-408: delete: same.
src/services/ihd-report.service.ts:611-621: delete: same.
src/services/ihd-report.service.ts:730-740: delete: same.
src/services/tc-report.service.ts:311-321: delete: same.
src/services/tc-report.service.ts:400-410: delete: same.
```

Six call sites × ~9 lines = ~54 lines of literal duplication. One `recordAudit` helper of ~10 lines replaces it. **net: -44 lines possible.** Plus the banner comment (-6 lines) for a total of **-50 lines** without losing a single behavior.

The dropped `CANCELLED` enum value is genuine deletion — keep it.

## Test coverage gap

| Service | Existing tests for `payReports`/`revertReports`? | New tests for activity_log write? |
| --- | --- | --- |
| `cf-report.service.ts` | Unknown — confirm against `tests/` or `__tests__/` | None |
| `ihd-report.service.ts` | Unknown | None |
| `tc-report.service.ts` | Unknown | None |

Required new tests:
1. `payReports` writes one `activityLog` row per paid row inside the tx.
2. `revertReports` writes one `activityLog` row per reverted row, with `additionalData.remark` set only when remark is provided.
3. Tx rollback: if the status update fails, no `activityLog` row is written (transactional guarantee).
4. Tenant isolation (post finding #6): `tenantId` flows through to the audit row.

## Final recommendation

**Request changes.** Resolve the blocking items first:

1. Decide the service-boundary question: either move the audit insert back to the BFF, or promote this to a coordinated cross-service change with an ADR and canonical DDL. Current diff does neither.
2. Split the `CollectStatus.CANCELLED` removal into its own PR.
3. Extract the duplicated audit insert into one helper.
4. Add `tenantId` to `ActivityLog` (or document why it isn't needed) — this is the most consequential missing invariant.
5. Add tests covering the new audit writes, at least one per service.

The audit-in-same-transaction idea is correct and worth merging, but not in this shape and not bundled with an unrelated enum drop.