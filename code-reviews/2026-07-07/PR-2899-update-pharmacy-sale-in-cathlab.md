# Code Review: PR #2899 — Update pharmacy sale in cathlab
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `issue/ppz/sprint-26/cathlab-module-86ey2rjb6` → `development`
**Files changed:** 4 (+110 / -8)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07
**ClickUp:** https://app.clickup.com/t/9018849685/86ey2rjb6

## Summary
The PR threads a Prisma client into `CathLabService` and adds a `generatePharmacyInvoice()` method that computes the next monthly invoice number for the CATHLAB department (format `CATHLAB-MM-YY-000001`). It then passes that `invoicePrefix` and `departmentType: "CATHLAB"` into `pharmacySaleService.createPharmacySale`. A separate guard in `pharmacy-sale.service.ts` is widened so that only `PHARMACY`-department PAID sales are immutable (CATHLAB sales can still be modified after payment). The `PharmacySale` type gains a `departmentType` field, and `CathLabIPDEMRTransactionService` now passes `prisma` into the cathlab service constructor.

## Verdict
**Request changes**
Score: 60/100
Critical: 0 | High: 3 | Medium: 4 | Low: 3 | Nit: 1

## Issues

### Critical
None.

### High

1. **`FOR UPDATE` provides no real race-condition protection.** `generatePharmacyInvoice()` is called *before* `createPharmacySale()` opens its own transaction (the `tx` argument here is the outer cathlab transaction, not a fresh one wrapping the pharmacy insert). The `SELECT … FOR UPDATE` row lock is released the moment that raw query returns; a sibling request can read the same `lastInvoice` and compute the same `nextSerialNumber` before either insert lands. Two cathlab procedures running concurrently can produce duplicate invoice numbers. The comment in the diff ("This is the locking clause that prevents the race condition") is incorrect. Fix: either (a) compute and reserve the invoice number inside the same transaction that inserts the `pharmacy_sales` row, with the lock held until commit; or (b) add a UNIQUE constraint on `(department_type, invoice_no)` so a duplicate insert fails the second writer instead of silently producing two rows with the same invoice.

2. **`PharmacySaleService` immutability guard is widened without justification.** The previous condition `paymentStatus === PAID` blocked any modification of a paid pharmacy sale. The new condition `paymentStatus === PAID && departmentType === "PHARMACY"` allows CATHLAB-paid sales to be edited. The PR description doesn't explain the intent. If a CATHLAB pharmacy sale is settled through the OPD billing / IPD bill the same way PHARMACY sales are, allowing edits afterward is a data-integrity regression (amounts can drift, payouts can change after the doctor has been notified, etc.). Confirm the intent; if the change is real, document it in the ClickUp ticket.

3. **Constructor signature change is a hard breaking change for any other direct caller.** `CathLabService` now requires `new CathLabService(prisma)` instead of `new CathLabService()`. Only two call sites were updated in this PR (the module-level singleton and `CathLabIPDEMRTransactionService`). Other constructors in the same file or in test/dev scripts that wire this service may break at runtime. Either audit all `new CathLabService(` usages across the repo and update them, or keep the parameter optional (default to the shared singleton `prisma`) so existing callers keep compiling.

### Medium

4. **Invoice number is generated and then passed in, but the function can fail mid-way.** If `createPharmacySale` throws after `generatePharmacyInvoice` succeeded, that invoice number is "burned" (the next call sees the previous one as the last and skips a number). For monthly-sequence invoices this is usually acceptable, but combined with the lack of a unique constraint on `(department_type, invoice_no)` it also allows a sibling request to race in and consume the same number. See also issue #1.

5. **`protected prisma` on a singleton is misleading.** `protected` access only matters if subclasses override the field; nothing in the diff indicates subclassing. Use `private`, or omit the modifier (TS default). Also: the parameter is typed `TPrismaClient` but the field is never used inside the class — `generatePharmacyInvoice` uses `tx || this.prisma` but `this.prisma` was never previously a member; verify it's actually needed and that the type alias is correct (`PrismaClient` is more conventional).

6. **Hand-typed enum duplicates risk drift.** `private department = "CATHLAB"` and `private pharmacyBillInvoicePrefix = "CATHLAB"` are both string literals. `departmentType: "CATHLAB" as DepartmentEnum` is cast at the call site. If `DepartmentEnum.CATHLAB` exists (the cast strongly suggests it does), use the enum value everywhere; otherwise drop the cast and accept that `departmentType` is a free-form string. The duplicate `"CATHLAB"` literals will drift the first time someone renames one and forgets the others.

7. **Invoice format check silently swallows malformed data.** `parts.length === 4 && parts[3]` falls through to `nextSerialNumber = 1` if the existing invoice number doesn't match the expected shape. No log, no alert. If the data was ever seeded by hand or migrated from a different prefix, every cathlab invoice after that point collides at `CATHLAB-MM-YY-000001`. Log a warning when the format check fails; better, surface it as an error so the next caller doesn't silently clobber an existing invoice.

### Low / Nit

8. **Invoice suffix format vs. comparison format inconsistency.** The invoice number uses `MM-YY` (e.g. `07-26`) but the comparison `previous_datePart === current_datePart` uses the same format, so they're consistent — *today*. If anyone changes `format("MM-YY")` to `format("MM-YYYY")` in one of the two calls and not the other, every comparison will silently return false and the serial will reset to 1 every month. Compute the formatted string once and reuse.

9. **`getTimezone()` is called on every invoice generation.** If it's a DB lookup, that's a wasted round-trip on a hot path. Cache it on the instance.

10. **`dayjs.utc().tz(timezone).startOf("month")` is computed twice** — once for the current month bounds and once inside the loop for the previous invoice's date. Compute the previous invoice's `MM-YY` from `lastInvoice.created_at` directly; you don't need to re-anchor to month boundaries there.

11. **Nit:** `cathlab.service.ts` line ~1555 — `if (!pharmacySaleInvoice) throw …` is unreachable. `generatePharmacyInvoice` always returns a `Promise<string>` (either a string or a thrown error), so the falsy check is dead code. Either narrow the return type to `Promise<string>` and delete the check, or have the function return `string | undefined` and justify when undefined is possible.

## Ponytail pass (over-engineering only)

- `cathlab.service.ts:41-42` — `yagni`: `department = "CATHLAB"` and `pharmacyBillInvoicePrefix = "CATHLAB"` are two fields with the same value. One constant or one field.
- `cathlab.service.ts:1853-1948` — `yagni`: `try { … } catch (e) { logger.error; throw e; }` is `log + rethrow` boilerplate. Log inside the throw site or at the call site; the function body itself doesn't need a wrapper.
- `cathlab.service.ts:1899-1918` — `shrink`: the `parts.length === 4 && parts[3]` + `parseInt(lastSerial)` + `previous_datePart === current_datePart` block is one helper: `nextSerial(lastInvoice, currentMMYY) → number`.
- `cathlab.service.ts:1525-1532` — `yagni`: the `if (!pharmacySaleInvoice) throw new AppError(…, 400)` is dead code — see Nit #11.
- `cathlab.service.ts:1541` — `yagni`: `"CATHLAB" as DepartmentEnum` cast on a string literal. If `DepartmentEnum.CATHLAB` exists, use it; if not, drop the cast.
- `cathlab.service.ts:1858-1860` — `native`: `tx || this.prisma` defaults. The whole `tx?` argument may be unnecessary if every caller already passes a transaction.

**Ponytail net**: ~20 lines of boilerplate removable without behavior change; the real over-engineering is `generatePharmacyInvoice` being a 78-line inline implementation when an existing invoice-generation helper likely exists in `pharmacy-sale-service.ts` or similar — find and reuse it.

## Recommendation

1. **Address High #1 first.** Move invoice-number generation inside the same transaction that inserts the `pharmacy_sales` row, and add a UNIQUE constraint on `(department_type, invoice_no)` as a backstop. Without this, concurrent cathlab procedures can produce duplicate invoice numbers in production.
2. **Clarify High #2 with the author.** Is CATHLAB-paid sale editability intentional? If yes, document why CATHLAB differs from PHARMACY. If no, revert that guard.
3. **Audit and fix other `new CathLabService()` callers** (High #3), or make the new parameter optional.
4. **After correctness fixes land**, sweep the Medium / Low / Nit items in a follow-up — none block merge on its own, but #6 (drift-prone literals) and #7 (silent malformed-data fallthrough) are worth fixing in the same PR.
5. **Ponytail pass:** a 20-line follow-up that deletes the dead `try/catch`, the dead `!invoice` check, and the duplicate `"CATHLAB"` literal is cheap and improves the file.