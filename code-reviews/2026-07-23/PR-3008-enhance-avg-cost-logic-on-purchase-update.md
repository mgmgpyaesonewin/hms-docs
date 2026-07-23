# Code Review: PR #3008 — Enhance avg cost logic on purchase update
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `enhance/april/sprint28/avg-cost-on-purchase-update` → `development`
**Files changed:** 4 (+411 / -66)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-23
**ClickUp:** https://app.clickup.com/t/9018849685/86ey39nm9

## Summary
Re-runs moving-average cost recalculation whenever a batch's purchased price is created/edited/deleted (and a small UI fix to keep the correct stock row selected in the edit mode of two related forms). The new `applyPriceUpdate` on `ItemAverageCostService` is a second entry point alongside `applyStockIn`, sharing a private `applyAverageCostUpdate` helper that writes history logs and upserts/updates the master row with optimistic version locking. The `PurchasedPriceUpdateService` now re-fetches stock rows inside the transaction, computes the remaining batch qty, and calls `applyPriceUpdate` after the price has already been persisted on the stock rows.

## Verdict
**Request changes**
Score: 53/100
Critical: 2 | High: 2 | Medium: 1 | Low: 2 | Nit: 0

## Issues

### Critical

1. **`applyPriceUpdate` writes history logs using the *post-update* `pricePerUnit`, so the audit trail is wrong** (`item-average-cost.service.ts:326-334`).
   The mapper for `applyPriceUpdate` sets `unitCost: new Prisma.Decimal(newPrice)` for every history row, regardless of which stock row produced it. `applyStockIn` correctly uses `row.pricePerUnit`. The history log is supposed to record the per-stock-row unit cost at the moment of the move. For a price update, every batch in this PR records `newPrice` for every stock row — and `qtyDelta: 0` is hard-coded, so the column "qtyDelta" is now a lie in price-update entries. After this PR ships, anyone replaying history rows to recompute average cost will be off.

2. **`PurchasedPriceUpdateService.deletePurchasedPriceUpdate` already mutates `Stock.pricePerUnit` to `oldPurchasedPrice` before calling `applyPriceUpdate(tx, { oldPrice: currentPurchasedPrice, newPrice: oldPurchasedPrice })`** (`purchased-price-update.service.ts:332-372`).
   By the time the service reads `revertedStocks`, the stock rows already hold `oldPurchasedPrice`. `applyPriceUpdate` then validates "all stock rows belong to the batch" using `tx.stock.findMany`, computes the formula against the post-update rows, and writes a history log — but the *true* old price the user is "reverting from" (`currentPurchasedPrice`) is only visible to the outer service, not to `applyPriceUpdate`. Result: (a) `currentInventoryValue` is computed against `totalInHandStock * currentAvgCost` (fine), but the "adjusted batch value" is `remainingQty * (newPrice - oldPrice)` where `newPrice` and `oldPrice` are the two user-supplied numbers; meanwhile the stock rows in the DB are now all `oldPurchasedPrice` so any future replay using `row.pricePerUnit` as the row-level cost will be inconsistent with the history row's `oldAverageCost`/`newAverageCost` delta. The math will silently match by coincidence only when `currentAvgCost` happens to be what the formula yields. Same shape applies to `create` (stock rows are updated *before* the service reads them via `updatedStocks`) and `edit`.

### High

3. **Race condition: the service re-fetches stock rows after `updateStocksPurchasedPrice` has already mutated them** (`purchased-price-update.service.ts:115-150`, `231-272`, `333-372`).
   `applyPriceUpdate`'s math is supposed to use the *pre-update* `pricePerUnit` for `oldPrice` semantics — but the rows read in `updatedStocks`/`revertedStocks` are the *post-update* rows. The service then passes `oldPrice: oldPurchasedPricePerUnit` (a number captured before any DB write) and `newPrice: payload.updatedPurchasedPricePerUnit`. The history log records `qtyDelta: 0, unitCost: newPrice` per row — and a downstream reader cannot reconstruct the batch's old average from the history because the row-level unit cost column carries the post-update value. Combined with #2, the recorded `oldAverageCost`/`newAverageCost` is correct numerically for the chosen inputs, but the per-stock-row `unitCost` is not what the column promises (the unit cost at the time of the move).

4. **`applyPriceUpdate` throws on `oldPrice === newPrice`, but `createPurchasedPriceUpdate` already returns 400 earlier for that same condition** (`item-average-cost.service.ts:243-248`).
   The earlier guard at `purchased-price-update.service.ts:70-75` rejects `oldPurchasedPricePerUnit === payload.updatedPurchasedPricePerUnit`. So in the happy path, `applyPriceUpdate` will never see equal prices via `create`. But the guard inside `applyPriceUpdate` is the only thing keeping `division by zero` away from `priceDifference` (a zero delta would yield `newAvgCost === currentAvgCost`, which is silently fine). The bigger problem is `editPurchasedPriceUpdate` (line 160-162) — it compares `currentPurchasedPrice === payload.updatedPurchasedPricePerUnit`, but `currentPurchasedPrice` is `Number(existing.updatedPurchasedPricePerUnit)`, the most recent edit's stored value. If a user edits twice with the same target, the inner check rejects. Fine. But if the row's stored `pricePerUnit` differs from `existing.updatedPurchasedPricePerUnit` (e.g., a manual DB fix), `applyPriceUpdate`'s check fires only after several queries. Edge case, but the guard belongs at the boundary, not buried inside a transaction.

### Medium

5. **`oldTotalQty` is computed as `Math.max(0, liveTotalQty - totalDelta)`, which goes negative only by accident, but here it masks data corruption** (`item-average-cost.service.ts:49`).
   `liveTotalQty` is `SUM(stock.qty WHERE qty > 0 AND itemId = X)`, and `totalDelta` is the qty being added by this transaction. If the sum has shrunk between the read and now (a concurrent GRN returned stock to a vendor, say), `oldTotalQty` goes negative and `Math.max(0, …)` papers over it, producing a wrong `totalQtyAfter` and an inflated `newAvg`. Worth a comment or, better, a guard.

### Low / Nit

6. **Empty catch on the new error path in `purchased-price-update.service.ts`** (3 sites: `~146-152`, `~262-268`, `~370-376`).
   The `try { applyPriceUpdate(...) } catch { throw new AppError("Average cost recalculation failed; purchased price update was rolled back", 409) }` discards the original error. At minimum, log it (this service has a `this.logger`); for money-path code, swallowing the original `AppError` (e.g., "Old price and new price are the same") and replacing it with a generic 409 loses diagnostic context. Pass `error` to `logger.error` and wrap with `cause`.

7. **Two near-identical 30-line blocks added to `purchased-price-update.service.ts` (create / edit / delete)**.
   The three call sites differ only in the source of `itemId`, `batchId`, `oldPrice`, `newPrice`, and which stock id list they pass. Extract a private helper `recalculateAverageCost(tx, { itemId, batchId, oldPrice, newPrice, stockIds })` and call it from all three. Otherwise the next change has to be made three times. (Ponytail: `shrink:` — see recommendation.)

## Recommendation
1. Fix #1 and #2 by either (a) capturing the *pre-update* stock rows inside the service and passing them to `applyPriceUpdate` as `stockRows` (the post-update ones currently leak into the formula and history), or (b) add an explicit `oldUnitCost` to the history row schema for price-update moves and stop reusing `unitCost` for both deltas. Don't ship with `qtyDelta: 0` + `unitCost: newPrice` — that's not what history reads will assume.
2. Replace each of the three empty-catch blocks with `logger.error(...)` and propagate via `new AppError(msg, 409, { cause: error })`.
3. Extract the recalc helper (#7) — the call sites are begging for it.
4. After #1 and #2, add one Jest test that builds a synthetic item with `currentAvgCost = 100`, two stock rows totalling 50, applies a price update 90 → 110, and asserts: (a) new avg cost = 100 + (110-90) = 120, (b) `totalQtyAfter = 50`, (c) every history row has a sensible per-row `unitCost`. Without that, the next refactor of `applyAverageCostUpdate` will silently break the contract again.

---
**Ponytail net (over-engineering only):** `net: -25 lines possible` if #7 helper is extracted and the two type alias blocks (`StockRow`, `HistoryLogEntry`, `HistoryLogMapper`) are inlined into the single `applyAverageCostUpdate` signature (they are used in exactly one place each).

**Reviewer coverage:** engineering-skills:code-reviewer (universal + typescript) caught #1, #2, #4, #5, #6. ponytail:ponytail-review caught #7 and confirmed the type aliases at the top of `item-average-cost.service.ts` are yagni.
