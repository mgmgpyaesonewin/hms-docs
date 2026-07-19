# Code Review: PR #3008 — Enhance avg cost logic on purchase update
**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `enhance/april/sprint28/avg-cost-on-purchase-update` → `development`
**Files changed:** 4 (+248 / -10)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-17
**ClickUp:** https://app.clickup.com/t/9018849685/86ey39nm9

## Summary
Wires the weighted-average-cost (WAC) recomputation into the three purchased-price-update flows (`create`, `edit`, `delete`) via a new `ItemAverageCostService.applyPriceUpdate` method, and fixes the batch-stock dropdown in edit mode for both the purchased-price-update form and the expiry-update-stocks form so the existing stock selection is preserved.

The new formula is the standard WAC-delta approach for a one-batch price change:

```
newAvg = (totalInHandStock × currentAvgCost + remainingQty × (newPrice − oldPrice)) / totalInHandStock
```

It correctly uses only the batch's **remaining** quantity (not original), so sold units do not affect the adjustment.

## Verdict
**Approve with suggestions**
Score: 88/100
Critical: 0 | High: 1 | Medium: 3 | Low: 2 | Nit: 2

## Issues

### Critical
None

### High
1. **`editPurchasedPriceUpdate` double-counts WAC drift over time** — `purchased-price-update.service.ts:177-201`. Each edit recomputes WAC from `currentPurchasedPrice → newPrice`, which is correct only if every previous edit's WAC adjustment was itself correctly committed. If a prior edit ever got partially applied (e.g. master-row update succeeded but caller 409'd, or the new flow hadn't yet shipped when an old edit ran), each subsequent edit compounds the drift silently. The fix is to recompute WAC against the **actual** current batch stock price (`existing.stocks[0].pricePerUnit`), not the persisted `updatedPurchasedPricePerUnit`, so the delta always represents the latest ground truth. Same observation applies less acutely to the `delete` flow (which trusts `currentPurchasedPrice → oldPurchasedPrice` to net to zero).

### Medium
1. **`applyPriceUpdate` is a near-mirror of `applyStockIn`** — `item-average-cost.service.ts:139-283`. ~145 new lines that re-implement the same read-existing → write-history → upsert/update-master pipeline already in `applyStockIn`. The only meaningful difference is how the "delta" is expressed (qty change vs price change on a fixed qty). A shared internal helper that takes `{ itemId, userId, stockRows, totalInHandStock, computeNewAvg }` would collapse both methods and make the optimistic-version/unique-fallback logic live in one place. The duplication is acceptable for now, but the next change to either method will likely have to touch both — flag before that happens.

2. **History-log written before master-row resolution** — `item-average-cost.service.ts:203-220`. `createHistoryLogs` runs before the unique-constraint fallthrough inside `applyPriceUpdate`. If `existingRecord` is null and the `createInitialAverageCost` fails on a race, we re-fetch and proceed — but the history row is already persisted and tied to a `totalQtyAfter` that may no longer match the master row at commit time. This is the same ordering used by `applyStockIn` (so consistent with the existing pattern), but it means the history log is best-effort relative to the master row — acceptable for an audit trail, but worth a one-line comment so future readers know history is written speculatively.

3. **`purchased-price-update-form.tsx:123-130` re-implements logic the `useMemo` already provides** — `filteredBatches` is already memoised to the single batch containing `watchBatchStockId` in edit mode (lines 111-121), so the `batch.stockIds.includes(watchBatchStockId ?? "")` branch inside `batchesOpts` is only reachable when `isEdit && batch.stockIds.includes(watchBatchStockId)`, which by definition is true for the entire memoised array. Functionally fine, but the comment ("In edit mode, use the stock ID that matches the edited stock / Otherwise, use the first stock ID") suggests behaviour the `useMemo` has already guaranteed. A one-line comment explaining the memo dependency is enough.

### Low / Nit
1. **`Number(newAvgCost.toFixed(2))` then `new Prisma.Decimal(...)`** — `item-average-cost.service.ts:199`. Going through `Number` for a money value silently loses precision above ~2^53 cents (which is unreachable in practice but is a code smell). The Prisma-native `Prisma.Decimal#toDecimalPlaces(2, "round")` would keep the full-precision intermediate and round only the persisted value. Matches the existing `applyStockIn` pattern though, so flag as Nit, not Medium.

2. **`watchBatchStockId ?? ""` repeated three times across the two form files** — `expiry-update-form.tsx:104,117` and `purchased-price-update-form.tsx:123`. Tiny shared helper (`getBatchStockId(batch, fallback)`) would remove the duplication, but the call sites are clear enough on their own. Pure stylistic.

3. **(Ponytail) `applyPriceUpdate` and `applyStockIn` are two parallel implementations of the same reconciliation pipeline.** If a third trigger type lands (return, write-off, transfer-out), the third copy will appear. Worth a note in the file or a follow-up ticket to extract the shared core.

4. **(Ponytail) `if (remainingQty > 0)` guard at all three call sites** — `purchased-price-update.service.ts:115, 213, 296`. The guard is correct (a sold-out batch should not move WAC), but the same guard exists inside `applyPriceUpdate` as `if (remainingQty <= 0) throw AppError`. Three layered checks for the same condition — the outermost could just rely on the inner one to throw, keeping the call sites one-liner-clean.

## Recommendation
1. **Before merge:** confirm the formula is correct against a worked example with sold units (the comment in `applyPriceUpdate` is clear, but a one-line test or a sanity note in the PR description helps reviewers verify).
2. **Follow-up ticket:** switch the `editPurchasedPriceUpdate` WAC base from `currentPurchasedPrice` to the live `stock.pricePerUnit` so historical drift cannot compound.
3. **Follow-up ticket:** extract the read-existing → write-history → upsert/update-master pipeline into a shared helper used by `applyStockIn` and `applyPriceUpdate`. The next event source (returns, write-offs) will need the same plumbing.
4. **Optional:** drop the outer `if (remainingQty > 0)` guards at the call sites and rely on `applyPriceUpdate`'s own validation.
