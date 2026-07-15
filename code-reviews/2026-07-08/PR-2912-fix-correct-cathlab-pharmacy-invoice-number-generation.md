# Code Review: PR #2912 — Fix: correct CathLab pharmacy invoice number generation
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `issue/ppz/sprint-26/cathlab-module-86ey2rjb6` → `development`
**Files changed:** 1 (+2 / -92)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-08
**ClickUp:** https://app.clickup.com/t/9018849685/86ey2rjb6

## Summary
Deletes CathLab's private `generatePharmacyInvoice(tx)` helper (89 LOC) and the corresponding call from `cathlab.service.ts`. Replaces the locally-computed full invoice-number string passed as `invoicePrefix` to `pharmacySaleService.createPharmacySale(...)` with the literal prefix constant `this.pharmacyBillInvoicePrefix` (`"CATHLAB"`). This aligns CathLab with the four sibling services (`daycare`, `hd`, `ot`, `endo`), which all let `pharmacy-sale-repository.generateInvoiceNo()` build the full number. The duplicate generator was the root cause of malformed invoice numbers (e.g. `CATHLAB-07-26-000042-07-26-000001`).

## Verdict
**Approve with suggestions**
Score: 96/100
Critical: 0 | High: 0 | Medium: 1 | Low: 1 | Nit: 0

## Issues

### Critical
None

### High
None (confirmed: the `SELECT ... FOR UPDATE` row lock is preserved by the repository's own `generateInvoiceNo`, so the deletion is correct, not a regression).

### Medium
- **Pre-existing fragility in `invoice_no` parser.** Both the deleted `generatePharmacyInvoice` and the repository's `generateInvoiceNo` parse `parts = invoice_no.split("-")` and require `parts.length === 4`. Any invoice number whose prefix or month happens to contain `-` (e.g. `CATH-LAB-07-26-000001`) would silently fall through to `nextSerialNumber = 1` and re-use an existing serial. Not introduced by this PR and out of scope, but worth a ticket: constrain the prefix format or key the serial off a derived column/sequence.

### Low / Nit
- **Sanity-check the `Logger` import.** The diff already drops `capitalize`, `getTimezone`, and `dayjs`. The class still declares `private logger = winstonLogger.child(...)` — verify it is still referenced by `this.logger.info` calls (it appears to be). No change requested; just confirm before merge.
- *(Nit captured in the agent's notes but not material — no further action.)*

## Recommendation
Ship as-is. The fix is deletion-heavy, correct, and brings CathLab in line with the four sibling services. File a separate ticket for the `parts.length === 4` parser fragility so it can be addressed at the repository level (one place, all callers benefit).