# Code Review: PR #2976 — fix: ed bill service
**Repository:** MyanCare/Ycare-HMS
**Author:** @Xkill119966
**Branch:** `fix/ed-bill-service` → `development`
**Files changed:** 4 (+208 / -197)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3c8xf

## Summary
Refactors `EdBillService` into a thin `EdProxyBillService` subclass of `ProxyBillTemplateService`, replacing ~120 lines of stock / pharmacy-sale / movement wiring with `super.createProxyBill` / `super.updateProxyBill` / `super.deleteProxyBill` calls. The old wiring in `ed-bill-init.service.ts` is reduced to a single re-export line. Adds an auto-select-single-batch `useEffect` in `ed-billing-pharmacy-sales.tsx` so newly-added pharmacy line items with exactly one available batch are pre-selected. Bumps the `opd` submodule.

The refactor centralizes billing logic into one template service — good direction — but loses the explicit activity-logger audit trail, duplicates the EMR joint upsert verbatim between create and update, and leaves a thin re-export shim and a near-empty subclass in place.

## Verdict
**Request changes**
Score: 69/100
Critical: 0 | High: 2 | Medium: 3 | Low: 1 | Nit: 1

## Issues

### Critical
None

### High

1. **Activity logging silently removed — audit regression.** The old `createEdBill` / `updateEdBill` / `deleteEdBill` each called `activityLogger.log(...)` with `entity: DepartmentEnum.ED` and the bill id, producing audit-log rows for every ED bill lifecycle event. The new implementation drops these calls and does not call anything equivalent on the parent class. Either `ProxyBillTemplateService.createProxyBill` / `updateProxyBill` / `deleteProxyBill` log on the caller's behalf (then `entity` will be `PROXY_BILL`, not `ED` — verify), or audit rows are simply missing. Add explicit `activityLogger.log(...)` calls back, or confirm the parent logs the right entity.
   - Location: `src/app/(dashboard)/shared/ed/services/ed-bill.service.ts:99-145`

2. **EMR joint upsert duplicated verbatim between `createEdBill` and `updateEdBill`.** The `tx.eDEMRProxyBillJoint.upsert({ where: { opdEmrId_proxyBillId: ... }, update: {}, create: { ... } })` block appears twice with the exact same fields, only the surrounding context differs. Extract a single `upsertEdEmrJoint(tx, opdEmrId, proxyBillId)` helper in the same file (or in the joint's own module) and call it from both paths. Same logic, fewer lines, one place to fix if the upsert shape changes (e.g. adding a `createdAt`).
   - Location: `src/app/(dashboard)/shared/ed/services/ed-bill.service.ts:107-122` and `:148-163`

### Medium

1. **`EdProxyBillService` carries zero ED-specific behavior.** The only fields it adds are `department = DepartmentEnum.ED` and `pharmacyBillInvoicePrefix = "ED"`, and every method is a one-line forward to `super`. This is a YAGNI subclass — a factory call `createProxyBillServiceForDepartment(DepartmentEnum.ED, { invoicePrefix: "ED" })` (or a `proxyBillService.withConfig(...)`) reads better and avoids a per-file singleton that hides where the real work lives. Today, ED is the only consumer; if the same class starts appearing for every department, the time to convert is now, not after there are five empty subclasses.
   - Location: `src/app/(dashboard)/shared/ed/services/ed-bill.service.ts:18-100`

2. **`payload as unknown as UpdateProxyBillSchema` discards type safety.** The cast hides any schema drift between `CreateEdBillSchema` / `UpdateEdBillSchema` and `CreateProxyBillSchema` / `UpdateProxyBillSchema`. If a field is renamed in one schema, the parent class will start silently receiving `undefined`. Prefer a structural narrowing helper (e.g. `toProxyBillPayload(edPayload)`) that maps ED's schema to the proxy schema with explicit fields, or ensure both schemas share a base type and `satisfies` it.
   - Location: `src/app/(dashboard)/shared/ed/services/ed-bill.service.ts:105` and `:144`

3. **`EdBillService` alias may be dead code.** `export const EdBillService = EdProxyBillService;` is a `const` assigned to a class value but the class itself is not `export`ed and the alias is named like the type, not the instance. Either grep for `new EdBillService(` in callers or delete the alias. Right now it suggests a type or class export that does not exist and will mislead readers.
   - Location: `src/app/(dashboard)/shared/ed/services/ed-bill.service.ts:223`

### Low / Nit

- **Low:** `src/app/(dashboard)/shared/ed/services/ed-bill-init.service.ts` now exists solely to re-export `edProxyBillService` under its old name. Either keep the original import surface and delete the file's contents (and update importers), or remove the file and update the importers. Keeping a 4-line re-export file parked next to the real service invites future drift.
  - Location: `src/app/(dashboard)/shared/ed/services/ed-bill-init.service.ts` (entire file)

- **Nit:** The new auto-select-single-batch `useEffect` in `ed-billing-pharmacy-sales.tsx` mutates five form fields and could be a small `autoSelectSingleBatch({ filteredBatches, index, getValues, setValue })` helper. Same pattern will likely appear on the OPD / IPD billing screens; extracting now makes the next screen a 1-line import.
  - Location: `src/app/(dashboard)/ed/features/components/ed-billing-pharmacy-sales.tsx:678-727`

## Recommendation

1. Either restore the `activityLogger.log(...)` calls (with `entity: DepartmentEnum.ED`) or confirm that `ProxyBillTemplateService` produces equivalent audit rows.
2. Extract the EMR joint upsert into one helper and call it from both `createEdBill` and `updateEdBill`.
3. Replace the empty `EdProxyBillService` subclass with a factory/config call unless there is a concrete plan to put ED-specific behavior in it (deleting the alias `EdBillService` at the same time).
4. Replace the `as unknown as ...` casts with explicit mapping helpers.
5. Delete `ed-bill-init.service.ts` and update importers to import `{ edProxyBillService }` from `ed-bill.service.ts`.
6. Re-run the existing ED create / update / delete paths end-to-end (Postgres transaction + eDEMRProxyBillJoint row + audit log entry) before merge; this PR is now the only place ED billing writes to those tables and the test surface is implied rather than asserted in the diff.
