# Code Review: PR #3008 — Enhance avg cost logic on purchase update
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `enhance/april/sprint28/avg-cost-on-purchase-update` → `development`
**Files changed:** 4 (+411 / -66)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86ey39nm9

## Summary
Adds a new `applyPriceUpdate` path on `ItemAverageCostService` so that purchased-price edits (and price-driven revert flows) recompute the weighted-average cost of the affected item using only the **remaining** in-hand stock of the batch being re-priced. The shared pipeline (read-existing → write-history → upsert-or-update-master with optimistic version) was extracted into a private `applyAverageCostUpdate` helper that both `applyStockIn` and the new `applyPriceUpdate` route through via a small `mapStockRowToHistoryLog` callback. The three call sites in `PurchasedPriceUpdateService` (initial edit, save, revert) now re-fetch the affected stocks inside the transaction and call the new helper. Two form components (`expiry-update-form.tsx`, `purchased-price-update-form.tsx`) also fix a select-value bug where editing a record with multiple stock IDs per batch could not round-trip the right stock ID.

## Verdict
**Request changes**
Score: 49/100
Critical: 0 | High: 4 | Medium: 3 | Low: 3 | Nit: 1

## Issues

### Critical
None

### High
1. **`try { … } catch { throw new AppError(…) }` swallows the underlying error in all three call sites** (`purchased-price-update.service.ts` ~L117, ~L233, ~L335). The original `AppError` (with code 400/409 and message) is replaced by a generic 409 "Average cost recalculation failed". Operators investigating production failures lose the original cause. Fix: drop the wrapper (the helper already throws `AppError`), or pass `cause: e` if you must re-wrap.

2. **30-line block duplicated three times** in `purchased-price-update.service.ts` for "re-fetch stocks + reduce remaining qty + call `applyPriceUpdate` + swallow errors". Violates DRY and is the dominant source of the +411 line count. Extract one private `recalculateWacForPriceChange(tx, { itemId, batchId, oldPrice, newPrice, stockIds, userId })` and call it from all three branches.

3. **`mapStockRowToHistoryLog` is dead flexibility on `applyAverageCostUpdate`** (`item-average-cost.service.ts`). The two inline mappers differ only in `unitCost` (`pricePerUnit` vs `newPrice`) and `qtyDelta` (`row.qty` vs `0`) — both derivable from the caller's intent. The generic parameter lets future callers invent new mappers that produce inconsistent history shapes. Replace with a small inline branch or an `enum CostEventType { StockIn, PriceUpdate }` and a switch inside the helper.

4. **No idempotency / re-entry guard on price-update history logs**. `applyPriceUpdate` writes a history log row per stock row, but if the surrounding transaction retries (or if `updateStocksPurchasedPrice` is run twice against the same batch) there is no `eventId` UNIQUE — unlike the outbox/CFI pattern used elsewhere. Combined with `qtyDelta = 0` on every history row, replay storms will inflate history count with no way to dedupe. Recommend an event-id column or a checksum guard on `(stockId, oldPrice, newPrice, createdAt-minute)`.

### Medium
1. **WAC formula assumes `totalInHandStock` is post-update quantity** (`item-average-cost.service.ts` ~L274). Correct for the math but the comment says "Current Inventory Value = Existing units x Current Avg Cost" — `existing units` here is post-update live qty, not pre-update. A future reader will mis-trace the formula during a partial-update bug. Add a comment pinning which qty the aggregation reads, or compute `oldTotalQty = totalInHandStock - deltaQty` explicitly so the formula mirrors `applyStockIn`'s shape.

2. **`applyPriceUpdate` re-reads `pricePerUnit` after the update even though the caller just wrote `payload.updatedPurchasedPricePerUnit`** (`purchased-price-update.service.ts` ~L115, ~L229, ~L331). The DB round-trip adds latency and obscures intent. Only `qty` is needed from the re-fetch; build `stockRows` with `pricePerUnit: newPrice` directly.

3. **Optional-chaining inconsistency between the two forms**: `purchased-price-update-form.tsx` adds `filteredBatches?.map(...)` but `filteredBatches` comes from a `useMemo` whose final step is `.map(...)` (always an array). `expiry-update-form.tsx` keeps the `?.` on the same array consistently because `filteredBatches` is the result of `batchesData?.filter(...)` and CAN be undefined. Decide per-source and drop the spurious `?.`.

### Low / Nit
1. **Stale JSDoc on `applyStockIn`**: comment still says "Periodically updates moving average costs on stock-in events (GRN Approval)" but `applyStockIn` is called from inside a transaction (not periodically). Drop the "Periodically" wording.

2. **`unitCost = newPrice` with `qtyDelta = 0` in price-update history rows** is semantically misleading — readers filtering by `qtyDelta > 0` will silently skip these. Either keep `qtyDelta = remainingQty` (with a note in the row), or rename `qtyDelta` to a more generic field.

3. **No negative-price guard in `applyPriceUpdate`**. `newPrice - oldPrice` is computed without validation; negative inputs are accepted and produce negative `adjustedBatchValue`. Add `if (newPrice < 0 || oldPrice < 0) throw new AppError(...)`.

4. **Nit: `filteredBatches?.map` followed by `.find`** in `purchased-price-update-form.tsx` runs two passes over the same array. Combine into one loop or precompute a map.

## Recommendation
1. **Dedupe the three call sites** into one helper method (`recalculateWacForPriceChange`) — biggest line-count win and removes three identical `try/catch` blocks.
2. **Drop the `try/catch`** wrappers — `applyPriceUpdate` already throws `AppError`. If you keep them for the `remainingQty > 0` path, at minimum forward `cause: e`.
3. **Inline the `mapStockRowToHistoryLog` parameter** or replace it with a small discriminated union / event-type enum. The current callback is single-implementation flexibility.
4. **Add an idempotency key** to history log writes for price-update events (event-id or hash), or accept that retries will double-log and document it.
5. **Re-fetch only `qty`** from `tx.stock.findMany`, not `pricePerUnit` — caller already knows `newPrice`.
6. **Tighten types**: drop `?.` on `filteredBatches` where the source is always-array; add negative-price guard.

Most-impactful single change: extract the helper in step 1. That alone brings this PR well under 200 lines added.
