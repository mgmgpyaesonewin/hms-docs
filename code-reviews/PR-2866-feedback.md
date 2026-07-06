# PR #2866 — Pharmacy Pricing: moving-average cost on GRN approval

## Summary

Adds a configurable per-item pricing method (`AVERAGE_COST` / `HIGHEST_PRICE` / `LATEST_PURCHASE_PRICE`) for pharmacy stock valuation, computes the moving average once per GRN approval inside a transaction with optimistic-lock fallback, and introduces schema for the audit trail. Core design is sound, but the diff ships several blocking issues: debug `console.log`s, dead code blocks, an unconfigured-method silent-zero fallback, behaviour drift between the SQL and service paths on the `HIGHEST_PRICE` filter, and an unintentional rounding precision regression.

**Verdict:** Changes requested.

## Strengths

- Sensible schema additions: `pricingMethod` enum + nullable column, two new tables with correct indexes and FK actions (`onDelete: Cascade` on item-history, `Restrict` on adjustment).
- Moving average computed once per GRN inside a transaction, with `item_unique` race-fallback and a `version` bump for the update path.
- Audit trail captures `oldAverageCost`, `newAverageCost`, `totalQtyAfter`, `qtyDelta`, `unitCost`, `batchId` — full provenance.
- `LEFT JOIN` on the average-cost subquery prevents items being silently dropped when no stock exists.
- `isUniqueFieldError` extracted into a shared helper in `prisma-errors.ts` — reusable.

## Issues

### Blocking

1. **Debug `console.log` left in** — `pharmacy-pricing.service.ts`, around the `AVERAGE` / `HIGHEST` branches (two lines: `console.log("average", averageCostData)` and `console.log("purchasePrice", purchasePrice)`). Remove before merge.
2. **HIGHEST_PRICE SQL subquery omits `WHERE qty > 0`** — `latest-price-repository.ts`, the new `Prisma.sql` block. The rest of the codebase's `getHighestPurchasedPrice` enforces `qty > 0`. Without the filter, batches with negative or zero stock can poison the price. Behaviour drift between this SQL path and the service path is itself a smell.
3. **Unconfigured-method branch silently returns `0`** — every item falls through to `0` when `pricingMethod` is not set. Either default to `HIGHEST_PRICE` in the migration, or refuse to render prices until the item is configured. Do not silently invoice zero.
4. **Dead / commented code blocks** — at least one block in the diff is wrapped in `/* … */` or commented out. Delete it; git keeps history.
5. **Rounding precision regression** — `ROUND(... , 2)` was changed to `ROUND(... , 0)` in the new SQL. Confirm with finance whether this is intentional. Money columns are typically `2dp`; restoring `, 2` is the safer default if not.

### Important

1. **Two HIGHEST_PRICE paths, two sources** — `PharmacyPricingService` uses `getHighestPurchasedPrice` (with `qty > 0` filter), but `latest-price-repository.ts` reads raw `MAX(...) FROM stocks` with no filter. Route both through one named repository method.
2. **Update-path race on `applyStockIn`** — only the create path handles the unique-key race via `isUniqueFieldError`. The update path relies on a `version` bump with no retry. Document whether GRN approvals are serialised per item; if not, add a retry loop on `P2025`.
3. **Decimal arithmetic via native `Number`** — `item-average-cost.service.ts` does `sum / qty` using native `Number`. Use `Prisma.Decimal` end-to-end; only convert at the storage boundary. Native float will lose precision on long sums.
4. **`getStockBatchesByItemId` added but unused** — `stock.repository.ts` gains a method that is unconditionally called inside `Promise.all` but never read by either branch. Delete until needed (YAGNI).
5. **No tests added** — `applyStockIn` and the new SQL paths have no coverage. At minimum, a unit test for the average-cost arithmetic and an integration test for the optimistic-lock retry.
6. **`totalCount[0]?.count?.toString() ?? "0"` swallows a real failure mode** — an empty result from a count query should throw 5xx, not silently return `"0"`.
7. **Behaviour change hidden in side-fix** — the total-count subquery switched from `JOIN` to `LEFT JOIN` on `stocks`, so items with no positive-qty stock now appear in the count. Document this in the PR description; it may be intentional but it changes pagination math.
8. **Two separate migrations in the same PR** (`20260624...` and `20260630...`) — ordering risk vs parallel feature branches. Consolidate into one migration unless both are independently reversible.

### Nit

1. Exhaustiveness check missing on the `pricingMethod` switch — add `const _exhaustive: never = pricingMethod;` to make TS enforce new cases.
2. `withAsterisk` on the radio group without an associated help text — currently implies required but does not explain.
3. `ml={30}` on the second `Radio` — drop in favour of `Group gap="lg"` for consistent spacing.
4. Logger payload dropped the full Zod `result` — keep both `success: false` and the formatted errors for diagnosability.
5. `PharmacyPricingService` constructor reached 5 args — consider a module/container pattern once stabilized (out of scope here, file the issue).

## Recommendations

1. Remove `console.log`s and dead code, fix HIGHEST_PRICE filter parity, and restore `ROUND(..., 2)` (or get finance sign-off on the change) before re-review.
2. Consolidate the HIGHEST_PRICE paths onto a single repository method.
3. Add the missing tests (unit for arithmetic, integration for the optimistic-lock race).
4. Default unconfigured items to `HIGHEST_PRICE` in the migration to avoid the silent-zero trap.
5. Document the `JOIN → LEFT JOIN` side-fix in the PR description.
6. Address the rounding regression explicitly (commit message + finance ack).

## Reviewer notes

- Cross-cutting concern: this PR adds a new code path that touches invoice/totals — recommend a finance-team reviewer in addition to the engineering reviewer before merge.
- The `Decimal` arithmetic issue is worth a separate refactor PR rather than blocking this one, but should be filed before the moving-average logic is used in production invoicing.