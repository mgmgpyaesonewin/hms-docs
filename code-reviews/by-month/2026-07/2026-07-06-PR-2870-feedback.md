# PR #2870 — Soft-delete proxy-bill pattern + bill rollback handling

**Verdict:** Changes requested (3 blocking, 8 important, 10 nits).

**Headline:** Correct stale-cache diagnosis and `proxyBillBaseSchema` extraction are right; the implementation leaks soft-delete semantics out of the repository, has one in-transaction snake_case/camelCase drift bug, and ships ~300-400 lines of duplicated `onDeleted` / mapper boilerplate that should be hoisted into a shared hook.

## Summary

Fixes the long-standing "soft-delete then hard-delete then soft-delete again" saga by settling on a soft-delete-only model. Adds an `isDeleted` field with a default `false`, a `deletedRemark`, and `deletedById` to `ProxyBill` plus a few sibling tables. Plumbs `refetchType` correctly per query role, renames `isFinalBillPaid → isUnpaid`, improves the HD-error path, and adds `departmentType` to the proxy-bill schema. The schema work and root-cause diagnosis are correct; the implementation has too much copy-paste and one in-transaction data bug.

## Strengths

- Correct stale-cache diagnosis — `refetchType: 'all'` is used where cache invalidation should be aggressive, `refetchType: 'none'` where it should not.
- `proxyBillBaseSchema` extraction is the right Zod pattern (base + partial-extends).
- Properly-differentiated `refetchType` per query role.
- `isFinalBillPaid → isUnpaid` rename improves the boolean's actual meaning.
- Better HD error path (cleaner status mapping).
- Sensible `departmentType` schema addition.

## Issues

### Blocking

1. **`deleteProxyBillTransaction` returns the `proxyBillValidator` shape post-update when includes are already soft-deleted** — footgun for any caller. After soft-delete, the returned `proxyBill` shape (with all `include`d relations) carries the deleted flag, but if any relation was already soft-deleted before the cascade, the returned shape is internally inconsistent. Either filter includes for `isDeleted: false` before returning, or document the returned shape's "as-of" semantics.
2. **`trx.pharmacySale.updateMany` data block uses `deleted_remark` (snake_case JS) while sibling updates in the same tx use `deletedRemark` (camelCase)** — works only because the Prisma field was already snake_case in that one table. Mixed casing inside a single transaction is a smell and a future-proofing trap: a Prisma client rename would break only the snake_case keys silently.
3. **`proxyMainProcedure` hard-deletes inside an otherwise-audited soft-delete transaction with the justifying comment "no audit trail needed"** — either extend soft-delete there or cite the compliance reason. Mixing hard and soft delete in the same atomic operation undermines the whole "soft delete is our safety net" premise.

### Important

1. **Five near-identical `onDeleted` blocks across EMR tabs (~150 lines of copy-paste)** — extract a `useBillDelete` hook taking `{ entityName, redirectPath, successMessage, onSuccess }` and the five sites become single-line calls.
2. **Three near-identical mappers in 5 `use-bind-form.tsx` hooks (~80 lines)** — extract `mapServicePackageBillItem` / `mapProcedureBillItem` and consume from each hook.
3. **`existingProxyBillId` race vs `isDeletedLocally` reset effect** — when the effect runs after a soft-delete, the local id is reset but the URL still references the deleted id; the next mount reads stale state.
4. **Other `findUnique` callsites across the repo not yet audited for soft-delete semantic leak** — the same bug class may exist on `opd-emr.service.ts`, `ipd.service.ts`, and `pharmacy.service.ts`. Worth a repo-wide grep.
5. **OPD EMR `edEmrProxyBillJoints` length silently changes** — a count-driven UI badge that previously counted "all" now counts "not-deleted"; confirm the dashboard surface.
6. **No partial indexes on the new `isDeleted: false` predicates** — every CFI query with `where: { isDeleted: false }` will full-seq-scan as soft-deletes accumulate. Add `(department_id) WHERE NOT is_deleted` partial indexes on the hot tables.
7. **`hdRequestLink` `findFirst` gate doubles the query count for a record already uniquely addressable** — replace with `findUnique({ where: { id } })`.
8. **Resolver selection keyed on `existingProxyBillId` snapshot rather than current mode** — when the user toggles between modes the cached resolver fires.

### Nit

- Whitespace churn in effect deps.
- `console.error` PHI leakage in HD.
- HD toast exposes patient name (PII over the wire log).
- `isCancel: false` silently drops cancelled items from total computations.
- Prisma formatting whitespace drift on `OTRequest.roomId`.
- Mount-flash window for `isDeletedLocally` (state visible before effect runs).
- `onDeleted` await race with `router.refresh()`.
- `useEffect` deps include a derived object literal.
- `redirect` after delete uses `router.push` when `router.replace` is intended (back-button trap).
- Schema validation: `proxyBillBaseSchema` lacks `.strict()` — extra keys silently accepted.

## Recommendations

1. **Fix the three blocking items before merge.** Especially #2 (camelCase/snake_case in-transaction drift) — that's a correctness bug waiting for the next Prisma rename.
2. **Hoist the `useBillDelete` hook and the two mapper helpers** — collapses ~230 lines of copy-paste to ~30.
3. **Add partial indexes** on `(department_id) WHERE NOT is_deleted` for the hot tables.
4. **Audit sibling services** for soft-delete semantic leaks (`opd-emr`, `ipd`, `pharmacy`).
5. **Strip PHI from `console.error`** in the HD error path.

## Reviewer notes

- Flag missing lab/imaging/pharmacy-only tabs — the soft-delete pattern should apply there too.
- Scope creep: ~1100 LOC for a soft-delete fix is a lot. The author may have used this PR to land adjacent cleanups; consider splitting.
- 3 sequential migrations (`*_add_is_deleted_*`, `*_rename_is_final_bill_paid`, `*_add_department_type_*`) carry partial-deploy risk if applied out of order.
- Confirms the previous "we tried soft delete then hard delete then soft delete again" comment saga is finally closed — good.

**Ponytail net estimate:** -300 to -400 lines possible via shared hook + shared mappers.