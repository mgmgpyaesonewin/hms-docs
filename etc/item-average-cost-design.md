# Item Average Cost — Design

**Date:** 2026-06-29
**Status:** Accepted (v1)
**Scope:** HMS pharmacy — moving average cost per item, used for COGS snapshotting on sales / damage / transfers.

## Context

Today, COGS is reconstructed at query time as `SUM(Stock.qty × Stock.pricePerUnit)`. Two problems:

1. **Price drift.** `Stock.pricePerUnit` changes retroactively via `purchased-price-update`. After a price correction, every cost-bearing row (`StockDamage.totalCost`, `UsedItem.totalCost`, `StockTransferItem.totalCost`) silently uses the new price for past events. Old `totalCost` values no longer match the cost at the time the event happened.
2. **No "average" exists.** The codebase has `MAX(pricePerUnit)` per item (`StockRepository.getHighestPurchasedPrice`), but no weighted or moving average. Future design proposals (see Related) want `AVERAGE_WEIGHTED` as an option. v1 lays the storage down; the formula is intentionally simple.

Goal: a per-item average cost that is **stable across retroactive price changes** and can be **snapshotted at the moment stock leaves** (sale, damage, transfer, return), so COGS reports reflect the cost at the time of the event, not the cost today.

## Goals

- One row per item holding the current moving average cost.
- Audit log of every event that changed the avg.
- Sales / damage / transfers snapshot `unitCost` at write time; the snapshot does not change after.
- No raw SQL — Prisma-typed queries only. The team's strength is TS, not SQL.

## Non-goals (v1)

- Per-store averages. v1 is item-level only.
- Per-event-type averages (`PRICE_UPDATE`, `GRN_RETURN`, `STOCK_ADJUSTMENT` writing history). v1 writes history on **stock-in only** — periodic moving average.
- True weighted average. v1 uses `MAX(pricePerUnit)` per event, matching the `HIGHEST` method proposed in `selling-price-cost-method-impact.md`.
- Backfilling COGS for past sales. v1 is a forward-looking cutover; past sales keep their `pricePerUnit`-based costs.

## Decision

### Schema (2 tables)

```prisma
model ItemAverageCost {
  id            String   @id @default(uuid(7)) @db.Uuid
  createdAt     DateTime @default(now()) @map("created_at")
  updatedAt     DateTime @updatedAt @map("updated_at")
  createdById   String   @map("created_by_id") @db.Uuid
  updatedById   String   @map("updated_by_id") @db.Uuid
  itemId        String   @unique @map("item_id") @db.Uuid
  averageCost   Decimal  @map("average_cost") @db.Decimal(12, 2)
  version       Int      @default(0)

  item          Item     @relation(fields: [itemId], references: [id], onDelete: Cascade)

  @@map("item_average_cost")
}

model ItemAverageCostHistory {
  id              String   @id @default(uuid(7)) @db.Uuid
  createdAt       DateTime @default(now()) @map("created_at")
  itemId          String   @map("item_id") @db.Uuid
  stockId         String   @map("stock_id") @db.Uuid
  batchId         String?  @map("batch_id") @db.Uuid
  unitCost        Decimal  @map("unit_cost") @db.Decimal(12, 2)
  qtyDelta        Int      @map("qty_delta")
  oldAverageCost  Decimal  @map("old_average_cost") @db.Decimal(12, 2)
  newAverageCost  Decimal  @map("new_average_cost") @db.Decimal(12, 2)
  totalQtyAfter   Int      @map("total_qty_after")
  createdById     String   @map("created_by_id") @db.Uuid

  item            Item     @relation(fields: [itemId], references: [id], onDelete: Cascade)
  stock           Stock    @relation(fields: [stockId], references: [id], onDelete: Restrict)

  @@index([itemId, createdAt])
  @@index([stockId])
  @@map("item_average_cost_histories")
}
```

### Design choices

- **2 tables.** No junction table. One history row per stock affected by an event; `stockId` is a direct FK. For a stock-in creating N stock rows for the same item, N history rows are written (one per stock), all carrying the same event-level `unitCost`, `newAverageCost`, `totalQtyAfter`, with per-stock `qtyDelta`.
- **`unitCost = MAX(Stock.pricePerUnit)` across affected stocks.** Matches the `HIGHEST` cost method in `selling-price-cost-method-impact.md`. Deviates from textbook weighted average. See Deferrals.
- **`stockId ON DELETE RESTRICT`.** Stocks are soft-deleted in this codebase (`Stock.isFOCItemDelete`); a hard delete should fail loudly if history references the stock.
- **`batchId` nullable.** Stock-in always has a batch; future event types (returns, adjustments) may not.
- **`version` on cache for optimistic concurrency.** No raw SQL; uses Prisma's `updateMany + count`.
- **Item-level scope.** Transfers between stores move qty around but do not update the cache.

### Writer flow

A new helper service `item-average-cost.service.ts` exposes `applyStockIn(tx, args)`. Called from `grn.service.ts` inside the existing GRN transaction, after Stock inserts and before commit.

```
1. BEGIN tx
2. Insert Stock rows (one per GRN item × store)
3. Call applyStockIn(tx, { itemId, stockRows, batchId, userId })
   a. Compute totalDelta = SUM(stockRows.qty)
   b. Compute unitCost = MAX(stockRows.pricePerUnit)
   c. Compute oldTotalQty = SUM(Stock.qty WHERE itemId) - totalDelta
      (live sum, excludes this event's stocks already inserted)
   d. Compute oldAvg from cache row (0 if absent)
   e. Compute newAvg:
      - oldAvg = 0: newAvg = unitCost
      - else: newAvg = (oldAvg × oldTotalQty + unitCost × totalDelta) / (oldTotalQty + totalDelta)
   f. Insert N history rows (one per stock)
   g. Upsert cache row with version check
4. COMMIT
```

### Concurrency (no raw SQL)

Optimistic lock via `version` + `updateMany.count`:

```ts
const existing = await tx.itemAverageCost.findUnique({ where: { itemId } })

if (!existing) {
  try {
    await tx.itemAverageCost.create({ data: { ..., version: 1 } })
    return
  } catch (e) {
    if (!isPrismaUniqueConstraintError(e)) throw e
    // Another tx inserted between our read and create. Fall through to update path.
  }
}

const target = (await tx.itemAverageCost.findUnique({ where: { itemId } }))!
const updated = await tx.itemAverageCost.updateMany({
  where: { itemId, version: target.version },
  data: { averageCost: newAvg, version: target.version + 1, updatedById: args.userId },
})
if (updated.count !== 1) throw new ConcurrentAvgUpdateError()
```

`grn.service.ts` wraps the whole tx in a retry loop (3 attempts, 10/30/90 ms backoff). On conflict, the tx rolls back entirely (Stock inserts + history rows + cache update all undone); the retry re-reads `Stock.qty` (now includes the other GRN's committed stocks) and recomputes.

**Why this works without raw SQL:** Prisma's `updateMany WHERE version = ?` is the optimistic-lock primitive. `count === 0` means the version was stale. No `SELECT … FOR UPDATE`, no advisory locks.

**Why this is enough:** pharmacy GRNs are human-driven, low-frequency. Two concurrent GRNs for the same item is rare; the retry budget absorbs it. If contention becomes real, the conversation reopens.

### Reader flow (COGS snapshot)

At write time, sales / damage / transfers snapshot `unitCost` and `totalCost` onto the event-source row, reading from `ItemAverageCost.averageCost` for the item:

| Table | New column | Population site |
|---|---|---|
| `PharmacySaleItem` | `unitCost Decimal(12,2)?`, `totalCost Decimal(12,2)?` | `pharmacy-sale.service.ts` (sale write) |
| `StockDamage` | (existing `totalCost` — repopulate from avg) | `stock-damage.service.ts` |
| `UsedItem` | (existing `totalCost` — repopulate from avg) | `used-item.service.ts` |
| `StockTransferItem` | (existing `totalCost` — repopulate from avg) | `stock-transfer.service.ts` |

The snapshot does not recompute on edit. Sale qty / price corrections after write time do not change the snapshotted `unitCost`.

## Migration order

1. **Schema migration** — add `ItemAverageCost` and `ItemAverageCostHistory` models; create Prisma migration; apply via the standard HMS migration flow.
2. **`item-average-cost.service.ts`** — new helper with `applyStockIn` + `ConcurrentAvgUpdateError`. Unit test covers the formula (single stock, multi-stock same-price, multi-stock mixed-price, concurrent-insert race).
3. **Wire into `grn.service.ts`** — call `applyStockIn` inside the existing GRN tx; wrap in retry loop.
4. **Patch the four COGS tables** — switch from `Stock.pricePerUnit × qty` to `ItemAverageCost.averageCost × qty` in `pharmacy-sale.service.ts`, `stock-damage.service.ts`, `used-item.service.ts`, `stock-transfer.service.ts`. Add the new `unitCost` / `totalCost` columns on `PharmacySaleItem` (other three already have `totalCost`).
5. **Backfill script** — separate Node.js script that populates `ItemAverageCost` for all items with stock. Cache only (no synthetic history). Idempotent on re-run.

### Backfill behaviour

```ts
// scripts/backfill-item-average-cost.ts (sketch)
const items = await prisma.item.findMany({
  where: { stocks: { some: {} } },
  include: { stocks: { select: { qty: true, pricePerUnit: true } } },
})

for (const item of items) {
  const maxPrice = item.stocks.reduce((m, s) =>
    s.pricePerUnit.gt(m) ? s.pricePerUnit : m,
    item.stocks[0].pricePerUnit,
  )
  await prisma.itemAverageCost.upsert({
    where: { itemId: item.id },
    create: { itemId: item.id, averageCost: maxPrice, version: 1, createdById: SYSTEM_USER_ID },
    update: {},  // don't overwrite; idempotent
  })
}
```

Batch via `createMany` chunks of 500. The script does not write history rows — history grows organically from the first real stock-in after migration.

Past sales keep their `pricePerUnit`-based `totalCost`. This is a one-time cutover; document in release notes.

## Deferrals (explicit ponytails)

Two deliberate simplifications, named so they don't rot into "later means never":

1. **`PRICE_UPDATE` does not move the avg.** After `purchased-price-update`, `Stock.pricePerUnit` changes but `ItemAverageCost.averageCost` does not — until the next stock-in. Drift is accepted. **Upgrade path:** add `applyPriceUpdate(tx, args)` to the helper; call from `purchased-price-update.service.ts` inside its tx. ~20 lines, one new call site.
2. **`unitCost = MAX` deviates from textbook weighted average.** Matches the `HIGHEST` cost method in `selling-price-cost-method-impact.md`. **Upgrade path:** when the `CostMethod` enum ships (per the same doc), swap the calculation in `applyStockIn` for the weighted formula and store `costMethod` on `Item` for per-item control. One-line change in the helper.

Both deferrals are recorded here so the next person hitting the design understands "this is deliberate, here's the upgrade path."

## Consequences

- **Two new tables** in the HMS Postgres schema. Index on `(itemId, createdAt)` for "history of this item" queries; index on `(stockId)` for "history of this stock" queries.
- **`grn.service.ts` gains a retry wrapper.** Bounded at 3 attempts; failure beyond that surfaces as a generic GRN error (the operator retries manually).
- **Four COGS tables change their cost source.** `Stock.pricePerUnit × qty` → `ItemAverageCost.averageCost × qty`. Backwards-incompatible for any report that depended on the buggy reconstruction.
- **Past sales remain on the old system.** Document in release notes; finance reports covering the cutover date need to note that pre-cutover COGS uses `pricePerUnit`, post-cutover uses the average.
- **No foreign-key coupling between this and `hms-summary-service`.** The summary-service consumes `PharmacySaleItem.unitCost` / `totalCost` if/when CFI invoicing references pharmacy costs; this ADR does not change the summary-service.

## Open items

- **`@unique` on `item_average_cost.item_id`** is required for the concurrent-insert race (Q14). Confirm the migration includes it; `prisma` will infer it from `@unique` on the Prisma model.
- **System user for backfill** — needs a constant `SYSTEM_USER_ID` (or a sentinel UUID) that the migration script uses for `createdById` on backfilled rows. Confirm whether one exists in the codebase or whether the script should create a one-off system user.
- **Multi-tenancy** — `Item` was not confirmed as tenant-scoped in the schema slice read for this design. If `Item` gains `tenantId` later, both new tables need it too. Reassess before any tenant-related migration.

## Related

- `hms-docs/etc/selling-price-cost-method-impact.md` — proposes the `CostMethod` enum and the `HIGHEST` default. The `unitCost = MAX` choice in this ADR aligns with that proposal.
- `hms-docs/summary-service/adrs/0005-state-machine.md` — pattern for a status/transition design that this ADR mirrors in shape (Context / Decision / Consequences).
- `hms-docs/summary-service/adrs/0006-concurrent-status-updates.md` — optimistic-lock pattern that informed the concurrency design here (no `If-Match` header in this case because the writer is internal to the service, not an HTTP consumer).
- `hms-app/src/app/(dashboard)/shared/pharmacy/services/grn.service.ts` — the call site for `applyStockIn`.
- `hms-app/src/app/(dashboard)/shared/pharmacy/services/purchased-price-update.service.ts` — the eventual call site for `applyPriceUpdate` (deferral #1).