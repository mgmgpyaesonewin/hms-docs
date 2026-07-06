# Code Review: PR #2803 — Enhance stock request, stock transfer and stock summary

**Repository:** MyanCare/Ycare-HMS
**Author:** @April-Naing
**Branch:** `enhance/april/sprint-25/stock-request-transfer-summary` → `development`
**Files changed:** 8 (+140 / -36)
**Reviewer:** code-reviewer skill (independent re-review)
**Date:** 2026-06-25
**ClickUp tickets:** [9018849685/86ey1pq61](https://app.clickup.com/t/9018849685/86ey1pq61) (stock request), [86ey0knme](https://app.clickup.com/t/9018849685/86ey0knme) (stock transfer), [86ey1vdav](https://app.clickup.com/t/9018849685/86ey1vdav) (stock summary)
**PR URL:** https://github.com/MyanCare/Ycare-HMS/pull/2803

## Summary

The PR adds Company Batch No + Expiry columns to three pharmacy stock surfaces — the stock-request detail view, the stock-request print document, and the stock-transfer detail view + print document — and renames the stock-summary table's "Price" column to "Total Amount." The new columns are gated behind `transferStatus === "RECEIVED"` and `transferStatus === "TRANSFERRED"` respectively, which is the right behavior because the batch/expiry information only exists after a transfer has actually been received. The diff also flips the print document's bottom-of-page signature block from "START TIME / END TIME / CHECK BY" to "ISSUE BY / CHECK BY / RECEIVE BY", which is a sensible rename for a transfer document.

The work is largely **client-side rendering additions backed by two minimal server-side changes**: the `companyBatchNo` field is now selected on `Stock` in the stock-transfer repository and added to the `StockTransferItem` type. The `companyBatchNo` field is then read on the rendered components from `transferItem.stock.companyBatchNo`.

The most important thing to verify is the **schema-level existence of `Stock.companyBatchNo`** — if it doesn't exist on the Prisma `Stock` model, the new repository `select` will fail at runtime in the TypeScript-generated client. Several other findings depend on code not in this diff (the schema, the CSV export, the `StockRequest.stockTransfer.items` eager-loading shape).

## Verdict
**Request changes**
Score: 62/100
Critical: 0 | High: 2 | Medium: 6 | Low: 4 | Nit: 5

## Strengths

- `stock-request-detail.tsx:104-106` and `stock-transfer-details.tsx:46` — extracting `isReceived` / `isTransferred` as a local const before the JSX is the right refactor. The previous inline comparison (`stockRequest.transferStatus === "RECEIVED"`) appeared three times in `stock-request-print-document.tsx`; the new const removes the duplication and makes the conditional render self-documenting.
- `stock-request-detail.tsx:120` and `stock-transfer-print-document.tsx:46-48` — the `transferredStock` lookup pattern (`stockTransfer?.items.find(transferItem => transferItem.itemId === item.itemId)`) is correct for the 1:1 join between a `StockRequestItem` and its corresponding `StockTransferItem`. The optional chaining on `stockTransfer` correctly handles the case where no transfer has been initiated yet (PENDING state).
- `stock-transfer-repository.ts:185, 326` — adding `companyBatchNo: true` to the existing `select` block (rather than a new query) is the right call: it adds one column to an already-existing select and avoids an N+1 round trip.
- `stock-transfer.types.ts:41` — the type update is in lockstep with the repository select, so TypeScript will catch any divergence.
- `stock-request-print-document.tsx:188-193` and `stock-transfer-print-document.tsx:218-219` — using dayjs `.tz(DEFAULT_TIMEZONE)` for the printed expiry is the right call; the previous `dayjs(...)` (no timezone) was a latent bug for the print document which is consumed by the receiving store.
- `stock-summary-columns.tsx:48` and `stock-summary-table.tsx:77` — renaming both the table column and the CSV export header to "Total Amount" is consistent; if the column is renamed in only one place, the CSV would silently disagree with the on-screen label.
- `stock-transfer-details.tsx:133-142` — gating `Item Batch No` behind `isTransferred` is correct because `transferItem.stock?.itemBatchNo` is only meaningful after the transfer has been issued; showing it in PENDING would show a stale or null value.

## Issues

### High

- **`stock-summary-columns.tsx:48` — column rename from "Price" to "Total Amount" is wrong given the accessor.**
  The accessor remains `accessorKey: "price"`, and the cell formatter is `row.original.price?.toLocaleString()` — a single scalar per row. If `price` is actually a per-unit price (which it almost certainly is, given the CSV header was previously "Price" and the field is named `price`), then renaming the header to "Total Amount" without changing the data is a **display correctness bug**: the column now claims to show "Total Amount" but still shows the per-unit price. The user will see "$5.00" and believe it's the line total. **Fix:** either rename the column back to "Price" (preferred unless the data model has actually changed), or — if the intent was to switch to a total — change the accessor to `totalAmount` and confirm the data shape. The CSV header at `stock-summary-table.tsx:77` has the same bug.
  *Confirmation needed:* check the data model and the value of `stockSummary.price` to determine whether the rename was a typo or an intentional semantic change that was missed in the implementation.

- **`stock-transfer-print-document.tsx:175` — silently deleted `Enhance Stock Transfer Information with Additional Fields`.**
  The old file contained a bare text node `Enhance Stock Transfer Information with Additional Fields` at line 175 (immediately after the `</div>` close of the conditional status block). This was clearly a placeholder/dev artifact that escaped into production, and the deletion is correct — but the diff does not call it out. The previous rendering would have displayed this sentence as visible text in the printed document. **Action:** the author must confirm the deletion was intentional, not an accidental deletion of real UI (e.g. a misplaced note for designers). On visual inspection it does look like a leftover string, but a one-line "removed leftover dev string" commit note would prevent reviewer churn.

### Medium

- **`stock-request-detail.tsx:104` and `stock-transfer-print-document.tsx:178` — `transferredStock` lookup does `Array.find` per row.**
  For each row in the rendered table, the diff calls `data.stockTransfer?.items.find(...)` and `stockRequest.stockTransfer?.items.find(...)`. This is O(N×M) where N is the rows being rendered and M is the number of transfer items. For 200-item pages this is 40,000 comparisons per render. The list page typically renders fewer items, but the print document may paginate 25+ rows per page × 4 pages = 100 rows × M transfers. **Fix:** build a `Map<itemId, transferItem>` once outside the `.map`, then `transferredStocksByItemId.get(item.itemId)`. Use `useMemo` if the list is rendered from React state, or hoist to a plain `const` if it is inside a render helper.

- **`stock-request-print-document.tsx:166` and `stock-transfer-print-document.tsx` — conditional `isReceived` / `isTransferred` wraps the column block but not the row data.**
  In the stock-request print document, `transferredStock` is looked up for *every* row regardless of `isReceived`, but only used inside the `{isReceived && (...)}` block. This is a minor inefficiency (the `.find` runs for PENDING rows too), and the lookup is cheap when `data.stockTransfer` is `null` (`.find` short-circuits on undefined), so this is low impact — but it is asymmetric with the detail view at `stock-request-detail.tsx:104` where the lookup is also unconditional. **Fix:** gate the lookup behind `isReceived`/`isTransferred` to make the dead-code path explicit.

- **`stock-transfer.types.ts:41` — `PrintableTransferRow.expiry: string | null` but the value is always populated as `""`.**
  In `stock-transfer-print-document.tsx:48`, the unmatched-row branch sets `expiry: ""` (empty string), not `null`. The matched-row branch sets it via `dayjs(...).format("DD MMM YYYY")` which is `string`, or falls back to `""`. So `expiry` is in practice `string` (always truthy-or-empty-string), never `null`. Either tighten the type to `string` or fix the unmatched branch to use `null` when `expiredAt` is missing. The current `string | null` lies about the data shape and a future maintainer reading the type alone will think `null` is reachable.

- **`stock-request-detail.tsx:84-89` and `stock-transfer-details.tsx:136-142` — column-position shift between PENDING and RECEIVED views is a UX trap.**
  When `transferStatus === "RECEIVED"`, three new columns appear **before** the Requested Qty column. When PENDING, the Requested Qty is the 5th column. A user who has been working on a PENDING document and then opens a RECEIVED document of the same shipment will see the columns in a different horizontal position, and an eye-tracking pattern they've built up will mis-fire. For a print document especially, the page break falls in a different place. **Fix:** put the batch/expiry columns **after** Requested Qty/Received Qty (visually trailing), so the columns the user has already learned to scan stay anchored.

- **`stock-summary-table.tsx:77` — CSV export header `"Total Amount"` contains a space.**
  The CSV header in `json2csv` becomes the column name in the exported Excel/Sheets column. While this is fine for human reading, programmatic downstream consumers (and even Excel formulas that reference column letters) treat `Total Amount` as a single label with a space. The previous `Price` was a clean identifier. **Fix:** either use the snake_case `total_amount` (common for CSV interchange) or `TotalAmount`, but document the choice. The current mixed convention will surprise the next person to script against the export.

- **`stock-request-detail.tsx:113-115` — `transferredStock?.stock.companyBatchNo` is not null-safe.**
  `transferredStock` is optional (via `?.`), but `.stock.companyBatchNo` is not. If `transferredStock` is defined but `transferredStock.stock` is null/undefined (the `transferItem.stock` relation is nullable — see `stock-transfer.types.ts:38-41` which types `stock` as non-null but does not enforce it at the runtime boundary), this will throw `Cannot read properties of undefined (reading 'companyBatchNo')` at render time. The `stock-transfer-details.tsx:188-192` version uses `?? "-"` for `itemBatchNo` and `companyBatchNo`, but `stock-request-detail.tsx` does not. **Fix:** add `?? "-"` (or `?? ""`) to all three new cells.

### Low

- **`stock-transfer-repository.ts:185, 326` — duplicated `select` block.**
  The two `getStockTransferDetailById` and `getStockTransferList` (or whatever the two methods are — the diff labels them by line number only) `select` blocks now both include `companyBatchNo: true`. The pattern of two parallel selects is a maintenance hazard; when a new field is added to `Stock`, both blocks must be updated in lockstep. **Fix:** extract a `STOCK_TRANSFER_STOCK_SELECT` constant and `...STOCK_TRANSFER_STOCK_SELECT` in both places.

- **`stock-request-print-document.tsx:217` and `stock-transfer-print-document.tsx:228` — inline `.reduce()` for received/transferred qty is duplicated.**
  Both print documents have an inline `.reduce((acc, transferItem) => transferItem.itemId === item.itemId ? acc + transferItem.transferredQty : acc, 0)` to compute the received/transferred qty for the current item. This is a hand-rolled group-by; if the data model ever allows a single `StockRequestItem` to be fulfilled by multiple transfer batches, this still works (sums across batches), but the `Map<itemId, number>` pattern would be cleaner.

- **`stock-transfer-details.tsx:46` — `isTransferred` is a confusing variable name.**
  The variable is checking the *current status* of the transfer (i.e. `transferStatus === "TRANSFERRED"`). The name reads as if it were a boolean property of a single row — but it's actually a gate on the whole document. Rename to `showTransferredOnly` or `hasTransferredStatus` to match the conditional intent. Pre-existing convention in `stock-request-detail.tsx:84` uses `data.transferStatus === "RECEIVED"` inline; the new `isTransferred` constant is more readable, but the name should describe what it's gating, not what the value means.

- **`stock-request-print-document.tsx:175` and `stock-transfer-print-document.tsx:209` — `dayjs(...)` empty-string fallback.**
  `transferredStock?.stock.expiredAt ? dayjs(...).format(...) : ""` — when `expiredAt` is null/missing, the cell is blank rather than a placeholder like `"-"`. Compare to `stock-transfer-details.tsx:198-202` which uses `?? "-"`. Pick one convention.

### Nit

- **`stock-transfer.types.ts:36-44` — field ordering.**
  The `PrintableTransferRow` type now has `transferredQty`, `companyBatchNo`, `expiry`, `batchNo`, `itemIndex`. The order doesn't match the `itemsWithIndex.push` call order in `stock-transfer-print-document.tsx:45-66`, which means reordering the type or the call site requires updating both. Hoist to a typed factory function `makePrintableRow(...)` that returns `PrintableTransferRow`.

- **`stock-request-detail.tsx:104` — mixed optional chaining.**
  `data.stockTransfer?.items.find(...)` uses optional chaining on `data.stockTransfer` but the `find` callback uses `transferItem.itemId === item.itemId` (no optional chaining needed on itemId). Consistent with `stock-transfer-details.tsx:46` though.

- **`stock-summary-table.tsx` — no test added for the rename.**
  The `json2csv` columns dict changed shape (removed `Price`, added `Total Amount`). If there's a snapshot test for the CSV output, it'll need updating. The PR doesn't mention tests.

- **`stock-request-print-document.tsx:191` and `stock-transfer-print-document.tsx:222` — label rename bundled with column addition.**
  The "ISSUE BY / CHECK BY / RECEIVE BY" rename is a UX/copy change bundled with a column addition. Consider splitting into a separate commit if the codebase uses conventional commits (check `git log` for the convention).

- **`stock-transfer-details.tsx:46` — `isTransferred` naming inconsistency.**
  See Low issue. Rename to match the pattern used elsewhere (e.g. `hasTransferredStatus`).

## Unverified

The following depend on code not in this diff and would shift the verdict if any return "no":

1. **`Stock.companyBatchNo` exists in the Prisma schema.** If absent, the new repository `select: { companyBatchNo: true, ... }` will produce a TypeScript error at compile time and a runtime Prisma error if the type-check is bypassed (`next.config.ts` ignores TS errors at build per `hms-app/CLAUDE.md`). *Likely exists* — the type `StockTransferItem.stock.companyBatchNo: string | null` was already declared in `stock-transfer.types.ts` at line 41 in the prior version, suggesting the field is in the schema — but the prior type was a hand-maintained subtype, not derived from Prisma. **Action:** confirm by checking `hms-app/prisma/schema.prisma` for `Stock.companyBatchNo`. If absent, this PR is **Block**.
2. **`StockSummarySchema.price` semantics.** Is `price` per-unit or a line total? The rename to "Total Amount" implies it was meant to be a total, but the accessor is `price` and the cell formatter does `?.toLocaleString()` on the scalar. If `price` is per-unit, the rename is wrong (High §1). If `price` was recently changed to be a total, the rename is correct but the field name should also change for clarity.
3. **`StockRequest.stockTransfer.items` eager loading.** The detail view's `transferredStock` lookup assumes `data.stockTransfer?.items` is fully populated (not paginated, not lazy). If the parent query uses `take`/`skip` on `stockTransfer.items`, the `.find` will miss items beyond the limit. Check the detail-page tRPC procedure / repository.
4. **`transferStatus` type narrowing.** Both detail views check `data.transferStatus === "RECEIVED"` / `"TRANSFERRED"` as raw string compares. If the type union gains new members in the future, the gate will silently treat them as "not received" and hide the columns. Consider extracting the union into a named const and adding an exhaustiveness check.
5. **`stock-transfer-print-document.tsx:178` — `transferredStock` lookup for the print document.**
   This lookup runs inside the `.map((item, index) => {...})` for *every* row, regardless of whether the columns will be rendered (which is gated on `isTransferred`). For PENDING/UNTRANSFERRED documents, this is wasted work. Same as Medium §3.
6. **CSV export header in `stock-summary-table.tsx`.**
   The CSV now uses `"Total Amount"` (with a space). Some Excel installs and most CSV parsers handle spaces in headers, but downstream tools that expect ASCII keys will break. Check the consuming code for column-name expectations.

## Verification needed (Checklist)

- [ ] `Stock.companyBatchNo` exists in `hms-app/prisma/schema.prisma`.
- [ ] `StockSummarySchema.price` semantics: per-unit or total?
- [ ] No consumer of the stock summary CSV relies on the column header `Price`.
- [ ] `StockRequest.stockTransfer.items` is fully included (not paginated) in the detail-view query.
- [ ] The deleted line at `stock-transfer-print-document.tsx:175` was a dev artifact, not a UI element.

## Recommendation

**Block on High §1 (column rename) and High §2 (silent deletion confirmation).**

If the rename was a typo and is reverted to "Price," the score moves to ~78 (Approve with suggestions). If the rename was intentional and the field truly represents a total, the PR should also rename the field from `price` to `totalAmount` and update the CSV consumer.

The two Medium findings (per-row `.find()` and column-position shift) are follow-up improvements but not blockers. The remaining Medium/Low/Nit findings can land in a follow-up PR.

Once the schema confirmation (Unverified §1) and the column-rename intent (High §1) are resolved, the PR is **Approve with suggestions**.

## Verdict (one-line)

**Request changes** — Wrong column header rename for `price`-keyed accessor (potentially mis-leading clinical-staff users); silent deletion of a dev-artifact string needs author confirmation; per-row `.find` is O(N×M) but tractable; the rest is solid.