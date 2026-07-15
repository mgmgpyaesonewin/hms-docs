# Code Review: PR #2996 — enhance(po):add average cost logic on purchase order import
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `enhance/april/sprint28/po-import-avg-cost-logic` → `development`
**Files changed:** 1 (+69 / -0)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-15
**ClickUp:** https://app.clickup.com/t/9018849685/86ey5654p

## Summary
The importer now collects stocks created during both regular and opening-stock purchase-order imports, groups them by item, and applies weighted-average-cost updates through `ItemAverageCostService` inside the existing transaction. The same grouping and service-call block is duplicated in both import paths.

## Verdict
**Approve with suggestions**
Score: 84/100
Critical: 0 | High: 0 | Medium: 4 | Low: 0 | Nit: 0

## Issues

### Critical
None

### High
None

### Medium

1. **Duplicate stocks can be omitted from WAC calculation in the opening-stock path.** In `src/app/(dashboard)/shared/pharmacy/services/purchase-orders-importer.service.ts:647-665`, `createdStocks.push(...)` is inside the `if (itemBatchNo)` branch, while the stock is created in the surrounding loop. When `resolveOpeningStockItemBatchNo` returns no batch number, the stock still exists but is never added to `createdStocks`, so its quantity and cost are excluded from the average-cost update. Record every successfully created stock immediately after `tx.stock.create`, regardless of batch-number resolution.

2. **Average-cost updates are performed with a potentially stale transaction client.** `ItemAverageCostService` and `ItemAverageCostRepository` are instantiated once on the importer with the global `prisma` client (`:137-140`), then `applyStockIn` receives `tx`. Unless the service/repository consistently uses only the supplied transaction client, this construction can read/write outside the import transaction and can observe uncommitted stock inconsistently. Prefer constructing/injecting the repository with the transaction client for each import transaction, or make the transaction client an explicit dependency throughout the service API and verify all queries use it.

3. **The WAC call is not atomic with the stock import if the service performs independent writes.** Both new blocks (`:337-355` and `:693-711`) call the service repeatedly after stock and movement creation. If `applyStockIn` issues writes through its repository's global client, a later failure can roll back the importer transaction while leaving average-cost rows committed, producing mismatched inventory and costs. Ensure all WAC reads and writes use `tx` and are part of the same transaction, and add a rollback test that forces an average-cost failure.

4. **The grouping algorithm performs repeated full scans and has no test coverage for duplicate item rows.** Each unique item filters the complete `createdStocks` array (`:339-346`, `:695-702`), giving O(items × stocks) work and making correctness harder to verify. More importantly, the duplicated code is untested for multiple lines of the same item and for zero/decimal quantities. Accumulate `Map<string, StockRow[]>` while creating stocks and add tests covering same-item weighting, no-batch opening stock, and transaction rollback.

### Low / Nit
None

## Recommendation
Address the transaction-client/atomicity issue before merging; it can leave stock and average-cost data inconsistent. Move stock collection to immediately follow every successful stock insert, then consolidate the repeated per-item grouping/update logic into a small helper that is called by both import paths (or maintain a `Map` during each loop). Add focused tests for same-item rows, missing opening-stock batches, Decimal quantities/prices, and rollback behavior. Consider a keyed accumulator rather than repeated `filter` calls.
