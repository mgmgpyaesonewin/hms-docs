# Code Review: PR #3008 — Enhance avg cost logic on purchase update
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `enhance/april/sprint28/avg-cost-on-purchase-update` → `development`
**Files changed:** 4 (+339 / -66)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-21
**ClickUp:** https://app.clickup.com/t/9018849685/86ey39nm9

## Summary
This PR extends the moving-average cost (WAC) machinery so that a change in purchased price (create, edit, or delete of a `PurchasedPriceUpdatedStock`) recalculates and persists a new `ItemAverageCost` row plus history entries, rather than only adjusting the underlying `Stock.pricePerUnit`. It also fixes a form-level UX bug in the expiry-update and purchased-price-update forms where, in edit mode, the batch `<Select>` would default to `batch.stockIds[0]` (the first stock of the batch) instead of the actually-edited stock ID, producing a mismatch between the displayed value and the bound `batchStockId`.

The core change is the introduction of `ItemAverageCostService.applyPriceUpdate()` (~145 lines) and a new private helper `applyAverageCostUpdate()` that the existing `applyStockIn` and the new `applyPriceUpdate` both delegate to (deduplicating the read-existing → write-history → upsert/update-master pipeline with optimistic versioning). The three new call sites in `purchased-price-update.service.ts` wire the price update into the create, edit, and delete paths of the purchased-price-update flow.

## Verdict
**Request changes**
Score: 66/100
Critical: 1 | High: 1 | Medium: 2 | Low: 1 | Nit: 2

## Issues

### Critical

1. **Edit path is wired but never re-fetches stocks after the in-tx price revert — `purchased-price-update.service.ts:210-235`.**
   The new `editPurchasedPriceUpdate` block computes `remainingQty` from `existing.stocks.reduce(...)` (loaded *before* the transaction) and then calls `applyPriceUpdate` with `remainingQty`, `oldPrice: currentPurchasedPrice`, and `newPrice: payload.updatedPurchasedPricePerUnit`. The `existing.stocks` snapshot is stale relative to the in-tx `updateStocksPurchasedPrice` call, so the `pricePerUnit` values passed in via `stockRows` are pre-edit values, not the post-edit ones. The WAC formula is `newAvg = (currentInventoryValue + adjustedBatchValue) / totalInHandStock`, and `adjustedBatchValue = remainingQty * priceDifference` where `priceDifference = newPrice - oldPrice`. The `priceDifference` uses the explicit `oldPrice`/`newPrice` arguments (correct), but `remainingQty` is computed from a potentially stale snapshot and the mapper's `unitCost` is overwritten by `newPrice` regardless of the snapshot — so the math is correct in *this* call site by happy accident. **Failure scenario:** if a future refactor changes the mapper to read `unitCost` from `stockRow.pricePerUnit` (e.g. to log "price the row was at when the WAC was recomputed"), the bug appears silently for edits. **Fix:** re-fetch the stock rows inside the tx after `updateStocksPurchasedPrice`, or pass `stockRows: existing.stocks.map(s => ({ id: s.id, qty: s.qty }))` and let the mapper own the `unitCost` field.

2. **`deletePurchasedPriceUpdate` reverts WAC using `existing.stocks` that still hold the *updated* price in-flight — `purchased-price-update.service.ts:293-313`.**
   At the point of the new `applyPriceUpdate` call, `updateStocksPurchasedPrice(existing.stocks.map(s => s.id), null, oldPurchasedPrice, tx)` has *just* been issued in the same `tx`, but `existing.stocks` was loaded *before* the transaction so `stock.pricePerUnit` still reflects the *updated* (pre-revert) price even though the row in the DB now holds `oldPurchasedPrice`. The `applyPriceUpdate` call passes `oldPrice: currentPurchasedPrice` and `newPrice: oldPurchasedPrice`, so the price delta is correct; the `stockRows: existing.stocks.map(stock => ({ id, qty, pricePerUnit }))` payload feeds `pricePerUnit` into the mapper, but the mapper overwrites it with `new Prisma.Decimal(newPrice)`, so the history log value is correct. The bug is dormant in this PR but the snapshot is misleading and any future mapper change (e.g. recording the *reverted* price as `unitCost` for an "undo" view) will silently break. **Fix:** re-fetch the stock rows inside the tx after the in-tx `updateStocksPurchasedPrice`, or pass `stockRows: existing.stocks.map(s => ({ id: s.id, qty: s.qty }))` and let the mapper own `unitCost`.

### High

3. **No `batchId` precondition on `stockRows` in `applyPriceUpdate` — `item-average-cost.service.ts:210-220` and the three call sites in `purchased-price-update.service.ts:122-128, :224-230, :301-308`.** The mapper blindly writes `batchId` and `stockId` into the history log. If a caller passes stock rows from a different batch (e.g. the edit/delete paths reuse a stale `existing.stocks` snapshot whose rows no longer match `existing.batchId` after a re-link), the history log will be inconsistent. **Fix:** add a `tx.stock.findMany({ where: { id: { in: stockRows.map(r => r.id) }, batchId } })` precondition check (cheap, inside the tx) and throw on mismatch. This is the kind of silent-data-corruption bug that shows up six months later as "why does the WAC history have rows pointing to a different batch than the purchased-price-update it claims to be for?".

4. **WAC recompute failure surfaces a generic 409 — `item-average-cost.service.ts:133-138`.** If `applyPriceUpdate` throws `"Concurrent modification on item average cost occurred. The transaction will now safely roll back."`, the user sees a low-level 409 even though they triggered a *purchased-price update*. The rollback is correct (the whole `tx` rolls back), but the error message gives no hint that their price change was the original intent. **Fix:** wrap the `applyPriceUpdate` call in `purchased-price-update.service.ts` in a `try/catch` and re-throw with a domain-level message like "Average cost recalculation failed; purchased price update was rolled back". This is also where the silent-data-corruption risk from #3 would surface first.

### Medium

5. **Form-level redundant check — `purchased-price-update-form.tsx:123-130` re-implements logic the `useMemo` already provides.** `filteredBatches` is already memoised to the single batch containing `watchBatchStockId` in edit mode (lines 111-121), so the `batch.stockIds.includes(watchBatchStockId ?? "")` branch inside `batchesOpts` is only reachable when `isEdit && batch.stockIds.includes(watchBatchStockId)`, which by definition is true for the entire memoised array. Functionally fine, but the comment ("In edit mode, use the stock ID that matches the edited stock / Otherwise, use the first stock ID") suggests behaviour the `useMemo` has already guaranteed. A one-line comment explaining the memo dependency is enough.

6. **Three near-identical call sites to `applyPriceUpdate` — `purchased-price-update.service.ts:112-135, :210-235, :293-313`.** Each is `const remainingQty = X.reduce(...); if (remainingQty > 0) { await this.itemAverageCostService.applyPriceUpdate(tx, { itemId, batchId, oldPrice, newPrice, remainingQty, userId, stockRows: ... }) }`. Extract a single `private async recalcWacForBatch({ tx, itemId, batchId, oldPrice, newPrice, stockRows, userId })` helper to centralise the `remainingQty > 0` gate and the shape of the `stockRows` map. The current copy-paste is what makes Critical #1 and #2 possible — one of the three call sites is subtly different from the others (the delete path uses a different `oldPrice`/`newPrice` ordering and a different `stockRows` source), and the next change will likely break exactly one of them.

### Low / Nit

7. **Low: `purchased-price-update.service.ts:122, :224, :301` — `pricePerUnit: stock.pricePerUnit` is passed into `stockRows` but the mapper in `item-average-cost.service.ts:240, :315` overwrites it with `newPrice` (applyStockIn path uses `row.pricePerUnit`, applyPriceUpdate path uses `newPrice`).** The shape is inconsistent across the two mapper implementations, and the `StockRow` type contract is fuzzy. Pick one — either the mapper reads `pricePerUnit` from the row and the caller decides what it means, or the mapper receives `unitCost` as a separate arg.

8. **Nit: `item-average-cost.service.ts:14-25` — the `HistoryLogMapper` type alias is declared as a top-level type but is only used within this file.** Inline the mapper type into the `applyAverageCostUpdate` parameter signature as an inline structural type, and keep the `StockRow` and `HistoryLogEntry` types as before. TypeScript types are erased — lifting them is a YAGNI move.

9. **Nit: `purchased-price-update.service.ts:118, :222, :300` — the comment "Recalculate WAC using remaining stock only" is duplicated at all three sites.** If the helper from Medium #6 is extracted, the comment lives in one place.

## Recommendation
1. **Address Critical #1 and #2** before merge. Re-fetch `existing.stocks` inside the tx after `updateStocksPurchasedPrice` so the `pricePerUnit` passed to the WAC recompute is the post-update value (or, more cleanly, pass `{ id, qty }` only and let the mapper set `unitCost` from `newPrice`).
2. **Address High #3 and #4** in the same iteration: add a `batchId`-membership precondition in `applyPriceUpdate`, and surface a coherent domain-level error for WAC rollback.
3. **Refactor the three call sites in `purchased-price-update.service.ts`** (Medium #6) into one private helper, then collapse the inline `mapStockRowToHistoryLog` callback into a single declaration shared by all paths.
4. **Remove the form-level redundancy** (Medium #5) by either adding a one-line comment explaining the `useMemo` invariant or removing the redundant `isEdit && batch.stockIds.includes(...)` check (it can never be false under the memo).
5. **Pick a single `StockRow` contract** (Low #7) and inline the `HistoryLogMapper` type (Nit #8).
6. **Add at least one Jest test** for `applyPriceUpdate` covering: positive qty with newAvg increase, positive qty with newAvg decrease, `oldPrice === newPrice` rejection, `remainingQty === 0` rejection, and `totalInHandStock === 0` rejection. The existing `applyStockIn` has no tests; do not let this PR add a second untested code path.
