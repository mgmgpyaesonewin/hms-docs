# Code Review: PR #2744 — Issue/cathlab daily bill 86exxrg5v

**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `issue/cathlab_daily_bill_86exxrg5v` → `development`
**Files changed:** 12 (+1160 / -335)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-06-24
**ClickUp:** https://app.clickup.com/t/9018849685/86exxrg5v
**Prior review context:** `pr-2744.md` (prior blocked attempt, several findings re-verified below), `2026-06-17-cathlab-findings.md` (four findings the PR claims to close).

## Summary

This PR rewires the cathlab "Consumable 1" tabs (services and procedures) inside the IPD daily-bill drawer so a manager can edit prices inline. A new generic `CathLabItemService.updateItems` helper collapses what was a copy-pasted ~200-line transaction between `updateCathLabServiceItems` and `updateCathLabProcedureItems` into ~70-line wrappers that delegate to the helper with per-type `updateFn` and an optional `validateFn`. A new `updateCathLabProcedureItemSchema` fills in the previously-empty schema file, the new `updateCathLabProcedureItemsAction` is wired through `authActionClient`, and the optimistic `setOriginal*` resets move out of the synchronous handler into the `useAction` `onSuccess` callback so a failed save no longer corrupts the local baseline. The procedure row's `id` mapping (`proc.id` was `proc.procedure.id`) is corrected, the mapper threads the full `doctor { id, title, user.fullName }` shape through to the UI, and the company-direct price cap (`max(100)`) is removed (it was a unit-of-measure confusion — the field is a percentage discount, not a money amount).

The headline issue is that the extraction is **partial**. `updateCathLabCompanyDirectItems` is unchanged: it keeps its own ~180-line inline transaction with a custom commission formula, still calls `this.ipdDailyBillRepository.findDailyBillById` directly, and still writes its own audit row. The helper's `case "company-direct"` arm in `fetchExistingItems` (`cathlab-item.service.ts:881-885`) is dead code that pretends to support a path the service never invokes. Worse, the `ItemUpdateConfig.requireDoctorAndZeroPrice` flag is set by both callers but **never read inside the helper** — the actual procedure guard is a thin inline `(item, existing) => !!existing.doctorId` callback that only checks "doctor exists", not "doctor + price=0". The PR title says one thing, the implementation does another. Compounding this: the helper's update path writes any incoming `item.price` straight to the DB without enforcing the create-side rule that "doctor → price=0", so a procedure with a doctor that already had `price=1500` can be edited freely, and the audit message and billed amount will then reflect a user-set price that violates the business rule.

This is a real-money bug surface for a financially-sensitive flow (cathlab pricing on IPD daily bills), and the partial extraction makes it worse because future contributors wiring a new caller (the company-direct migration, or any future item type) will set `requireDoctorAndZeroPrice: true` and assume the helper enforces it. The shape is right and the happy path works — but the partial extraction, the un-enforced "doctor + price=0" rule, the duplicate `findMany` per save, and the duplicate audit row per save mean this PR should not land as-is.

## Verdict

**Request changes**

Score: 55/100
Critical: 3 | High: 5 | Medium: 6 | Low: 4 | Nit: 3

## Strengths

- `src/app/(dashboard)/shared/cathlab/services/cathlab-item.service.ts:1-430` — The generic helper genuinely collapses the 200-line copy-paste. The shape (`updateFn` for typed update payload, `validateFn` for caller-specific guards, `ItemUpdateConfig` for shared bookkeeping, `fetchExistingItems` switch for type-safe SQL) is the right factoring and the public surface (`updateItems<TItem extends BaseCathLabItem>(...)`) is small enough to be testable in isolation.
- `src/app/(dashboard)/shared/cathlab/services/cathlab.service.ts:1280-1479` — `updateCathLabServiceItems` and `updateCathLabProcedureItems` are now thin wrappers that just declare the type-specific `updateFn` and (for procedures) `validateFn`. The deposit side-effect (`handleDepositUpdate`) and audit-row creation moved into the helper. Each service is ~70 lines instead of ~290.
- `src/app/(dashboard)/shared/cathlab/services/cathlab.service.ts:1694-1696` — The inline `validateFn` callback `(item, existing) => !!existing.doctorId` correctly encodes the "doctor is required to edit a procedure" rule from the ticket. (Caveat: see Critical #2 — it doesn't check price=0.)
- `src/app/(dashboard)/cathlab/features/cathlab.action.ts:47-55` — `updateCathLabProcedureItemsAction` is registered through `authActionClient.schema(updateCathLabProcedureItemSchema).action(...)` — this fixes the prior finding "action wired to the wrong schema" by using its own dedicated schema instead of reusing the service schema. The export name and the validation are now consistent.
- `src/app/(dashboard)/shared/cathlab/schemas/update-cathlab-procedure-item.schema.ts:1-18` — This file now exists with a real, narrowly-scoped schema (`dailyBillId` + `items[]` with `id, price, discountPercentage, discountAmount, amount`). The schema is intentionally looser than the service schema (accepts `price.min(0)` without the procedure-specific business rules) and correctly hands those off to the server layer.
- `src/app/(dashboard)/ipd/daily-bill-list/[id]/features/components/daily-bill-cathlab.tsx:111-118, 133-145` — `setOriginalServices(editableServices)`, `setOriginalProcedures(editableProcedures)`, and the related `*HasChanges(false)` resets now live inside the `useAction` `onSuccess` callback. The synchronous in-handler `setOriginalTeamFees` and `setOriginalMachineUsage` calls are removed. A save failure now leaves the local baseline in place, so the user can retry without re-detecting "changes" the server never accepted.
- `src/app/(dashboard)/shared/ipd/helpers/daily-bill.helper.ts:712-725` — The fix `id: proc.id` (was `proc.procedure.id`) is correct and important. The UI now uses `item.id` as React `key` (`daily-bill-cathlab.tsx:549`) and as the row-id parameter passed to the server actions; without this fix the actions would receive `procedure_catalog_id` (e.g. the "Angiography" id) instead of the row id, and the server's `tx.cathLabProcedureItem.update({ where: { id: ... } })` would fail or update the wrong row entirely. This is a real, latent correctness bug the PR closes.
- `src/app/(dashboard)/shared/ipd/repositories/ipd-daily-bill.repository.ts:678` — `id: true` is now selected for `CathLabProcedureItem`. Without this, `proc.id` in the reshaped output would be `undefined` and the React `key` would fall back to `index`. The PR fixes both layers (the validator and the mapper) so they agree.
- `src/app/(dashboard)/shared/cathlab/schemas/update-cathlab-company-direct-item.schema.ts:12` — Removing `max(100)` from the price validator is a real bug fix: the field was being validated as if it were a money amount under 100 kyat, when in fact it's a percentage. The relaxation lets company-direct items receive realistic prices.
- `src/app/(dashboard)/shared/ipd/repositories/discharge.repository.ts:519-530` and `ipd-final-bill.repository.ts:220-231` — Both validators pick up the same `doctor` select. The discharge and final-bill flows now read the same shape as the daily-bill detail — no shape drift between stages of the billing pipeline.
- `src/app/(dashboard)/ipd/ipd-billing/features/utils/map-daily-bills.ts:523-528, 590-595` — The mapper threads the full `doctor: { id, title, user: { fullName } }` shape through both services and procedures (procedures are nullable), matching the new type contract.

## Issues

### Critical

- **`src/app/(dashboard)/shared/cathlab/services/cathlab-item.service.ts:717` — `ItemUpdateConfig.requireDoctorAndZeroPrice` is dead config; the actual "doctor + price=0" rule from the ticket is not enforced**
  Both callers pass this flag (`requireDoctorAndZeroPrice: false` at `cathlab.service.ts:1285` for service items, `requireDoctorAndZeroPrice: true` at `:1596` for procedure items), but the helper never reads it (verified by grepping the helper body — `config.requireDoctorAndZeroPrice` has zero references after `processSingleItem` and `validateFn` blocks). The actual procedure-specific guard is the inline `(item, existing) => !!existing.doctorId` callback at `cathlab.service.ts:1694-1695` — which checks only that the *existing* row has a doctor, **not** that the price is 0.
  The PR title says the rule is "doctor + price=0"; the implementation is "doctor exists". So:
  - A procedure that already has `price = 1500` (a non-zero-price procedure) is still editable today (the doctor gate passes), even though the ticket implies zero-priced procedures are the only editable class.
  - The intended rule "incoming price must equal 0" is not checked anywhere — the helper accepts `item.price` from the schema (`updateCathLabProcedureItemSchema: price: z.number().min(0).optional()`) and writes it straight to the DB.
  - Future contributors wiring a new caller (e.g. the long-promised company-direct migration) will set `requireDoctorAndZeroPrice: true` and assume the helper enforces it; they will be surprised when it doesn't.
  Fix: either (a) actually read `config.requireDoctorAndZeroPrice` inside `updateItems` and reject items where the rule isn't satisfied (returning `changed: false, change: { changeType: "Blocked: missing doctor or non-zero price" }`), or (b) delete the field, drop it from both callers, and put the rule in the `validateFn` body explicitly with a comment. Pick (a) — the helper is the right place to enforce a domain rule that applies to every procedure.

- **`src/app/(dashboard)/shared/cathlab/services/cathlab.service.ts:1197-1205, 1519-1527` and `cathlab-item.service.ts:857-888` — Each service path runs `findMany` twice per save (once in the caller, once inside the helper)**
  `updateCathLabServiceItems` opens with `const existingItems = await tx.cathLabServiceItem.findMany({ where: { id: { in: itemIds } }, include: { cathLab: { select: { id: true } } } });` (`cathlab.service.ts:1197-1205`). It uses `existingItems[0].cathLabId` for the audit message. Then it passes `payload.items` into `cathLabItemService.updateItems(...)`, which immediately calls `fetchExistingItems(...)` (`cathlab-item.service.ts:857-888`) which runs the **same** `tx.cathLabServiceItem.findMany({ where: { id: { in: ids } }, include: { cathLab: { ... } } })` again. Same pattern duplicated for procedures (`cathlab.service.ts:1519-1527` → `cathlab-item.service.ts:857-888`).
  Two identical reads inside the same `$transaction` for the same `id` set, with no intermediate write between them (the helper fetches before the loop, before any `update` calls). Postgres will issue them as two separate statements, double the row-decoder work, and double the lock-pressure on the cathlab row.
  Worse, the caller's `findMany` selects only `cathLab: { select: { id: true } }` (line 1209, line 1524) — it doesn't have `admissionId`, which the helper needs (line 779). So the caller's read is useless for the admissionId lookup, and the helper's read is the only one that carries `admissionId`. The caller only needs `cathLabId` (for the audit), which both queries return.
  Fix: remove the caller's pre-fetch (`cathlab.service.ts:1197-1205` and `:1519-1527`); change `updateItems` to return `cathLabId` in the result, then use it for the audit. Or extract `cathLabId` from the first existing item the helper returns and write the audit before `updateItems` returns. Either way, one query per save.

- **`src/app/(dashboard)/shared/cathlab/services/cathlab.service.ts:690-870` and `cathlab-item.service.ts:719, 881-885` — `updateCathLabCompanyDirectItems` is unchanged; the helper's "company-direct" arm is dead code and the deposit / audit / commission logic still lives inline**
  The diff at `cathlab.service.ts:663-688` removes a commented-out *first* draft of the function and replaces it with the live one — but the live one is the same ~180-line inline transaction the team had before the refactor. The helper explicitly supports `case "company-direct"` in `fetchExistingItems` (`cathlab-item.service.ts:881-885`) but nothing invokes it for that path. The deposit update (`utilService.calculateDepositAmount`) and the audit-row creation (`cathLabRepository.createCathLabAudit`) are *not* factored into the helper, so company-direct pays for its own copy of those calls while service / procedure share the helper's copy.
  Future contributors will:
  1. Either duplicate the deposit logic a third time (when the next item type comes along), or
  2. Migrate company-direct in a third PR.
  Either is fine, but the helper should not pretend to support it (`itemType: "service" | "procedure" | "company-direct"` at `cathlab-item.service.ts:719`) until it actually does. The bigger issue: the company-direct commission calculation at `cathlab.service.ts:758-790` computes `commission = (newBaseAmount * hospitalPercentage) / 100` and then `let newFinalAmount = oldFinalAmount + commission` — that's a **different** formula than the helper's `amount += (amount * hospitalPercentage) / 100` (`daily-bill.helper.ts:35`), so the helper can't absorb this path without more refactoring. That's a legitimate reason to leave it inline — but it should be documented, and the helper's API should not advertise support it doesn't have.
  Fix: in `cathlab-item.service.ts:719`, narrow `itemType` to `"service" | "procedure"` (drop `"company-direct"`). Delete the `case "company-direct"` arm in `fetchExistingItems` (`cathlab-item.service.ts:881-885`). Add a one-line comment at the top of `updateCathLabCompanyDirectItems` in `cathlab.service.ts:690` explaining why it intentionally stays inline (custom commission formula).

### High

- **`src/app/(dashboard)/shared/cathlab/services/cathlab.service.ts:1613-1616` — Procedure update path accepts any `item.price` even though create enforces `doctorId → price=0`**
  At create time (`cathlab.service.ts:1359-1370` and `:1623-1640`), the rule "if a procedure has a doctor, its price is 0" is enforced:
  ```ts
  const effectivePrice = p.doctorId ? 0 : (p.price ?? 0);
  ```
  But the helper's update path (`cathlab.service.ts:1601-1616`) writes the incoming `item.price` straight to the DB:
  ```ts
  if (item.price !== undefined && item.price !== null) {
    updateData.price = item.price;
    finalPrice = item.price;
  }
  ```
  So:
  - A new procedure with a doctor is created at `price = 0` (correct).
  - An existing procedure (which already has `price = 0` because it was created with a doctor) can be edited by the user to `price = 1500` and the helper will save `1500` to the DB — even though the rule says the price must be 0.
  - The audit message and the deposit calculation will then reflect the user-set price, and the daily bill / final bill / discharge will all bill the patient 1500 for a "doctor-led" procedure that the business rule says should be free.
  This is the exact scenario the ticket is trying to prevent ("doctor + price=0"). The create-side enforcement and the update-side enforcement disagree.
  Fix: enforce the rule on update too. In the inline `updateFn` callback for procedures, force `updateData.price = 0` when `existing.doctorId` is non-null, ignoring the incoming `item.price`. This is the same kind of override the create path uses. Then the UI's `canEditPrice = ... && item.price === 0` is consistent with the server's enforcement: the server only honors price=0 for doctor-led procedures.

- **`src/app/(dashboard)/shared/cathlab/services/cathlab.service.ts:1466-1472, 1699-1705` — Audit row is written twice per save: once inside the helper (`cathlab-item.service.ts:840-845`), once at the caller**
  Inside `updateItems`, the helper writes:
  ```ts
  await this.cathLabRepository.createCathLabAudit(cathLabId, `Updated ${config.auditLabel}: ${changeDescriptions}. Total difference: ${totalDifference}`, userId, tx);
  ```
  Then the caller writes:
  ```ts
  if (result.changes.length > 0) {
    await this.cathLabRepository.createCathLabAudit(cathLabId, `Updated service items: ${result.changes.length} items changed. Total difference: ${result.difference}`, userId, tx);
  }
  ```
  Two audit rows per save, with different (and inconsistent) messages — the helper's says "Updated service items: a1b2: Price Updated (1000 -> 1500, diff: 500); c3d4: ...", the caller's says "Updated service items: 2 items changed. Total difference: 600". The cathlab audit log will show two rows for what should be one event. The CathLab list page (`src/app/(dashboard)/cathlab/features/components/cathlab-detail.tsx:82`) reads `data.CathLabAudit` — auditors will see duplicates.
  Fix: delete one. The helper's row is more informative (per-item details), so drop the caller's redundant row at `cathlab.service.ts:1466-1472` and `:1699-1705`. The helper returns enough info (`result.difference`, `result.changes`) that the caller could write a custom audit if it wanted — but it doesn't.

- **`src/app/(dashboard)/ipd/daily-bill-list/[id]/features/components/daily-bill-cathlab.tsx:761-769` — `handleSaveAllChanges` does not `await` the three `execute` calls, so the new "no changes" branch closes the drawer before in-flight toasts fire**
  The new branch:
  ```ts
  if (changedCompanyItems.length === 0 && changedServices.length === 0 && changedProcedures.length === 0 && changedTeamFees.length === 0 && changedMachineUsage.length === 0) {
    close();
    setIsUpdating(false);
  }
  ```
  is reached **after** the three `update*` calls were issued without `await`. Each `useAction` returns an `execute` that returns a Promise, but `useAction` is fire-and-forget by default — the `execute` call enqueues the request and the `onSuccess`/`onError` callbacks fire later. If only *some* of the three changed arrays are non-empty (e.g. only services changed), the other two `execute` calls are still in flight when this `if` is evaluated — the `length === 0` check on the *unchanged* arrays passes immediately, the drawer closes, `isUpdating` flips to false, and the toasts from the in-flight actions still fire later — but the user is now on a different page or has scrolled away, so the success toast appears in the void.
  This is a regression from the prior PR's intent: the prior "if no changes, just close" branch was correct when the saves were synchronous; once the saves are async, it must wait for them.
  Fix: either (a) wrap each `execute` in an `await` and await all three before the "no changes" check, or (b) move the close logic into the `onSuccess` of each `useAction` (so each action closes its own slice when it completes — but then the "no changes" branch becomes unreachable and you can just close synchronously when none of the three are present). Pick (b) — the `useAction` callbacks are already where the success UX lives, this matches the pattern the PR already established at lines 109-118 and 137-145.

- **`src/app/(dashboard)/ipd/daily-bill-list/[id]/features/components/daily-bill-cathlab.tsx:111-115` — `setOriginalServices(editableServices)` is called twice in the same `onSuccess`; one is dead**
  ```ts
  setOriginalServices(editableServices);   // diff line 111 (added)
  setOriginalTeamFees(editableTeamFees);
  setOriginalMachineUsage(editableMachineUsage);
  setOriginalServices(editableServices);   // already there, duplicated
  setTeamFeesHasChanges(false);
  setMachineUsageHasChanges(false);
  ```
  Two consecutive `setOriginalServices` calls with the same argument in the same React commit. The second call is a no-op at runtime (React batches and dedupes), but it is a clear paste-mistake that survived the diff.
  Fix: delete one of the two lines (the second one, since the first appears earlier in the new code path). Alternatively, fold the two `setOriginalServices` into a single `useCallback` if the logic ever needs to grow.

- **`src/app/(dashboard)/ipd/daily-bill-list/[id]/features/components/daily-bill-cathlab.tsx:541-546` — `item?.doctor` runtime-nullable but `DailyBillDetailData.procedures[].doctor` typed as non-nullable**
  The procedures list passed to the daily-bill-cathlab component comes from `DailyBillDetailData.procedures[]` (`daily-bill.types.ts:310-322`), which after the PR types `doctor` as **non-nullable** (the diff at `daily-bill.types.ts:310-322` does not include `| null` on the procedure `doctor` field — only the mapper's `proc.doctor ? {...} : null` returns a nullable). So the type says "every procedure row has a doctor", but the runtime shape produced by `cathlab.service.ts:1359-1370` (`effectivePrice = p.doctorId ? 0 : (p.price ?? 0)`) and `cathlab.service.ts:1623-1640` writes `doctorId ?? null` to the DB — meaning a procedure can exist in the DB with `doctorId = null`.
  Then the UI gate `canEditPrice = canEdit && item?.doctor && (item.price === 0 || editingProcedureIds.has(item.id))` at `daily-bill-cathlab.tsx:541-546` correctly hides the editor when there's no doctor — but only because the optional chain `item?.doctor` is truthy when `item.doctor` is the object or when it's `undefined`. Once the type is fixed to be honest about the nullable, this gate becomes `item.doctor != null`, which is more readable.
  The deeper issue: if the type says "doctor is non-null", what does the UI do when the runtime disagrees? The current `item?.doctor` falls open (the `?.` short-circuits), the gate returns `false`, the row is read-only. That's the safe behavior — but the type system would never have caught this because it lied.
  Fix: make `DailyBillDetailData.procedures[].doctor` explicitly nullable (`{ id, title, user: { fullName } } | null`) to match the mapper. The mapper already returns `null` when there's no doctor — the type just disagrees.

### Medium

- **`src/app/(dashboard)/shared/ipd/helpers/daily-bill.helper.ts:31-39` — `hospitalPercentage` / `hospitalAmount` adds-on-discount ordering silently disagrees with the inline `cathlab.service.ts:758-790` calculation**
  The helper now applies hospital markup **before** discount:
  ```ts
  let amount = price * payableQty;
  if (item.hospitalPercentage != null && item.hospitalPercentage > 0) {
    amount += (amount * item.hospitalPercentage) / 100;
  } else if (item.hospitalAmount != null && item.hospitalAmount > 0) {
    amount += item.hospitalAmount;
  }
  if (item.discountPercentage != null && item.discountPercentage > 0) {
    amount -= (amount * item.discountPercentage) / 100;
  } else if (item.discountAmount != null && item.discountAmount > 0) {
    amount -= item.discountAmount;
  }
  ```
  But the inline company-direct transaction in `cathlab.service.ts:758-790` (called from `updateCathLabCompanyDirectItems`, *not* from `calculateBillLineItemAmount`) computes commission as `commission = (newBaseAmount * hospitalPercentage) / 100` and then `let newFinalAmount = oldFinalAmount + commission`. That's a **different** formula: commission is computed off the *base amount* (price × qty, no foc adjustment), but the helper computes it off `payableQty` (price × max(0, qty - foc)). For an item with `foc > 0`, the helper's number is **lower** than the inline formula's number. The two paths disagree on the final billed amount for the same input.
  This matters because the inline path (company-direct) is what actually writes to `cathLabCompanyDirectItem.amount` today (and is what the daily bill detail then reads). The helper path is a "read-side" recompute that runs against `BillLineItemInput` in `calculateBillLineItemAmount` somewhere — likely in the discharge / final-bill aggregation. If the discharge aggregator uses `calculateBillLineItemAmount` and the daily-bill-detail UI uses `existing.amount` (which was written by the inline path), the displayed total on the discharge screen will not match the persisted total on the daily bill. That's a real money discrepancy.
  Fix: pick one formula. Document the order of operations (markup first, then discount, with foc applied to base). Apply it consistently in both places. Likely the helper is wrong: hospital commission should be on the *post-foc base*, but the `+= amount * pct` order means it's also affected by the discount in the discount branch, which is also weird (a 10% discount on a 10%-markup-up item reduces both the discount base and the markup-corrected amount).

- **`src/app/(dashboard)/shared/cathlab/services/cathlab-item.service.ts:983-990` — `as unknown as TItem` cast on `updatedItem` is a type-safety smell; the field is also unused**
  The helper builds `updatedItem = { ...existing, ...updateData, amount: ..., price: ..., discountPercentage: ..., discountAmount: ... } as unknown as TItem`. The `as unknown as` is a defensive escape because `existing` is typed as `CathLabItemWithRelation` (which has extra fields the runtime shape doesn't), and `updateData` is `Partial<TItem>`. The result is returned in `UpdateResult<TItem>.items: TItem[]`. But neither caller reads `result.items` — service and procedure both just return `result` and the UI's `onSuccess` ignores it (the toast is hard-coded: "Service charges updated successfully" / "Procedure charges updated successfully"). So the cast and the field exist for a consumer that doesn't exist.
  Fix: drop the cast and drop the field. Change the return type to `{ success: true; difference: number; changes: ChangedItem[]; message?: string }` (no `items`). Remove the `as unknown as TItem`. The helper's responsibility is "produce an audit + deposit delta", not "give the caller back the updated rows" — the caller already knows what it sent.

- **`src/app/(dashboard)/shared/cathlab/schemas/update-cathlab-company-direct-item.schema.ts:12` — `hospitalPercentage` and `hospitalAmount` are unbounded; the helper's `+= amount * pct` will explode**
  The schema change at line 12 removes `max(100)` from `price` (correct — it's a money amount, not a percentage). But the schema for `hospitalPercentage` and `hospitalAmount` is still unbounded (`z.number().min(0).optional()`). The helper's branch at `daily-bill.helper.ts:35`:
  ```ts
  if (item.hospitalPercentage != null && item.hospitalPercentage > 0) {
    amount += (amount * item.hospitalPercentage) / 100;
  }
  ```
  accepts any value. A user (or a buggy client) that passes `hospitalPercentage = 10000` will multiply the line item by 100x. The previous schema had no `max()` either, but now that the PR has made the helper the *only* price-update path for company-direct (the inline `updateCathLabCompanyDirectItems` will eventually migrate), an unbounded percentage becomes a higher-leverage bug.
  Fix: cap `hospitalPercentage` at something defensible (1000%? 100%?). Cap `hospitalAmount` at a sane money upper bound (or leave it open and document it). Add `.max()` calls in the Zod schema.

- **`src/app/(dashboard)/ipd/daily-bill-list/[id]/features/components/daily-bill-cathlab.tsx:541-546, 957-964` — Procedure editability gate uses `item.price === 0 || item.price === null` but the schema rejects null at the type level**
  The schema `updateCathLabProcedureItemSchema: z.object({ ..., price: z.number().min(0).optional(), ... })` accepts `undefined` (field omitted) or a `number >= 0`. `null` is **not** accepted — `z.number()` rejects `null` before the `.min(0)` runs. So `item.price === null` in the UI gate is dead: if `item.price` is `null` in the form state, the action's Zod validation would have rejected the payload before reaching the server.
  This is not a runtime bug — the gate does the right thing when `price` is `undefined` or a number — but it telegraphs a misunderstanding of the schema. The intent is "price=0 means unpriced, drag to set", and the gate correctly handles `0` and `undefined`. Drop the `=== null` arm.
  Fix: `canEditPrice = canEdit && item.doctor && (item.price === 0 || editingProcedureIds.has(item.id))`. The `=== null` arm is dead.

- **`src/app/(dashboard)/shared/cathlab/services/cathlab.service.ts:1534-1544` — Procedure early-return shape disagrees with the helper's normal result**
  The procedure path returns `{ success: true, difference: 0, changes: [], items: [], message: "No procedure items to update" }` if `itemIds.length === 0`. The helper's normal return is `{ success: true, difference: totalDifference, changes, items: updatedItems, message: hasActualChanges ? undefined : "No changes" }`. The early-return path duplicates the shape manually, hard-coding `items: []` instead of letting the helper return it. This is harmless (both shapes are passed through and the UI's `onSuccess` ignores `result.items`), but it's a copy-paste trap.
  Fix: drop the early-return; let the helper handle `items.length === 0` (it already returns `success: true, difference: 0, changes: [], items: [], message: "No changes"`). Or alternatively, document that the early-return is a deliberate UX optimization (skipping a transaction).

- **`src/app/(dashboard)/ipd/daily-bill-list/[id]/features/components/daily-bill-cathlab.tsx:181-187, 227-228` — UI rounds `finalAmount` but the helper will recompute it server-side; risk of optimistic / server mismatch**
  The UI rounds `finalAmount` for `amount` and `netAmount` (services only — procedures only set `amount`). The server-side helper then recomputes `amount = Math.max(0, calculatedAmount)` (`cathlab.service.ts:1412` and `:1677`). If the server's recomputation produces a different value (e.g. because `payableQty` differs from what the UI used, or because the discount branch differs), the UI's optimistic value will be overwritten on `onSuccess` via `queryClient.invalidateQueries`. Today they agree, but the rounding in the UI is doing double duty — it's both the optimistic value *and* what's sent in the payload (`amount: item.amount`). The UI is sending the rounded value; the server is re-deriving it; if those diverge by a few kyats due to rounding (the server doesn't always round), the user sees a flash of the rounded value followed by the server's value. Pick one — either (a) round in the server only (drop the UI rounding), or (b) round in both but make sure the rounding logic is identical (use `Math.round` everywhere, including the discount step).

### Low / Nit

- **`src/app/(dashboard)/shared/cathlab/services/cathlab.service.ts:1192` — `this.logger.info("Updating cathlab service items")` is now slightly misleading**
  The previous log message was "Updating cathlab service items (team fees & machine usage)". The PR strips the parenthetical to a single line. But this method is now also called from the daily-bill UI to update `CONSUMABLE_1` services (`daily-bill-cathlab.tsx:681-685`) — which are *not* team fees or machine usage. The trimmed message reads correctly for both call sites, but loses the helpful "this is the team-fees / machine-usage path" context for the *original* call site. Either add a `consumerType` discriminator to the message, or restore the parenthetical and accept the slight awkwardness.

- **`src/app/(dashboard)/shared/cathlab/services/cathlab.service.ts:1507` — `async updateCathLabProcedureItems(payload, userId)` does not return early when `payload.items` is empty (asymmetric with the helper)**
  The procedure path checks `if (itemIds.length === 0)` and returns an early-success message. The service-items path does *not* have an equivalent guard — it falls straight through into `cathLabItemService.updateItems(...)`. The asymmetry is harmless (the helper handles `items.length === 0` internally with a `404 No items found` if the *existing* rows are empty, but doesn't have an early-return for `items.length === 0` either — the diff at `cathlab-item.service.ts:774-776` returns "No items found" for empty existing, not empty items). This is a defensible divergence (procedures need a defensive check because their early-return predates the helper), but it's an asymmetry worth noting.

- **`src/app/(dashboard)/shared/cathlab/services/cathlab.service.ts:751` — Pre-existing `this.logger.info("PAYLOAD", payload.items);` is now exercised on every save but the structured logging wrapper is already in place**
  Pre-existing but now hit on every save (the company-direct path runs the full body every time). This logs the entire `payload.items` array to stdout on every save, which can be tens of items × 5+ fields = hundreds of fields per call. The codebase already uses `winstonLogger` (the helper at `cathlab-item.service.ts:751` declares `this.logger = winstonLogger.child(...)`), so use it: `this.logger.info({ payloadItems: payload.items }, "Company direct items update");` and the structure will round-trip through the log aggregator.

- **`src/app/(dashboard)/shared/cathlab/services/cathlab-item.service.ts:857-888` — `fetchExistingItems` is called inside the helper even though the caller already has the data (caller fetches once at `cathlab.service.ts:1197-1205` and `:1519-1527` for `cathLabId`, then the helper re-fetches with `admissionId` included). Two `findMany` reads per save.**
  Discussed in Critical #2 above. Mentioned here as a nit because the helper's `fetchExistingItems` is a perfectly clean private method — the asymmetry is in the caller, not the helper.

## Verification needed

1. **Does the procedure editability gate actually work end-to-end?** Manual test: open the daily-bill cathlab tab for an admission with `CathLabProcedureItem` rows that (a) have a doctor and price=0, (b) have a doctor and price>0, (c) have no doctor and price=0. The `canEditPrice` gate should be true / true (via editingProcedureIds) / false. Then click into a non-zero-priced procedure and try to save a new price — does the server-side helper enforce 0 for doctor-led procedures? If not, the Critical "procedure update path accepts any item.price" issue is real and the billed amount will reflect the user-set price.
2. **Does the partial-extraction not break company-direct?** The helper has a `case "company-direct"` arm but the function never calls into it. Verify that the company-direct save flow still works (it should, since `updateCathLabCompanyDirectItems` is unchanged). Then remove the dead arm.
3. **Does `handleSaveAllChanges` close the drawer at the right time when only some categories have changes?** Manual test: edit a service price only (no procedure, no company-direct, no team fees, no machine usage changes). The save should fire `updateServiceItem`, the `onSuccess` should toast + invalidate + close. Currently the close happens synchronously *inside* `handleSaveAllChanges` when the other categories have no changes — that's correct for "all empty" but the `await` race in High #4 means mixed cases may close early.
4. **Does the double `findMany` inside the transaction show up in `EXPLAIN ANALYZE`?** Save a cathlab with 20 procedure items and 30 service items. The transaction will issue 4 reads (one per caller + one per helper × 2 item types). For the typical "edit one or two items per save" workflow this is wasteful; for the "bulk import from cathlab EMR" workflow it could matter.
5. **Do two audit rows actually land per save?** Run any save, then `SELECT count(*) FROM cath_lab_audit WHERE ...`. Should be 1, will be 2 until High "duplicate audit row" is fixed.
6. **Does the discharge / final-bill total match the daily-bill total after a price edit?** Save a cathlab procedure with a new price, then generate the discharge bill and the final bill. The aggregate `cathlab amount` on both downstream documents should equal the per-row amount sum on the daily bill. If `calculateBillLineItemAmount` (helper) and the inline `commission = (newBaseAmount * hospitalPercentage) / 100` (`cathlab.service.ts`) disagree on foc / discount ordering, the totals will not match.
7. **Does `npm run tsc` pass?** The type changes (`DailyBillDetailData.procedures[].doctor`, `cathLabItem.service.ts`'s generic helpers) may have introduced downstream TS errors that don't show in the diff but do show on `tsc --noEmit`. Especially the `as unknown as TItem` cast — TS may now reject `cathLabItem.service.ts` if the helper's type constraints and the caller's `updateFn` argument types disagree.
8. **Does the new `setOriginalServices` duplication cause a console warning in React StrictMode?** Two consecutive `setState` calls with the same value in the same commit shouldn't warn, but React's dev-mode double-render may surface this as suspicious. Build with `NODE_ENV=development` and check the browser console.
9. **Does the new `MAX(100)` removal on `price` actually map to the right field?** The schema's `price` field for company-direct was previously capped at 100 kyat, which would block all real prices. Confirm with the team that this is the intended interpretation (price-as-money, not price-as-percentage). If it was actually percentage, the cap was correct and should be restored.
10. **Does the new `updateCathLabProcedureItemsAction` permission check cover "edit procedures"?** The action uses `authActionClient` but the permission module for cathlab may not include "edit procedure" as a separate action. Confirm in `permission-ui-config.ts`.

## Cross-references

- **`/Users/pyaesonewin/Documents/work/hms-system/hms-docs/code-reviews/pr-2744.md`** — Prior blocked review attempt (also automated). Most of the issues overlap with this review (the H1-H4 / M1-M5 grid in the prompt). This review confirms those issues, ties them to specific diff hunks, and adds a few new ones (the `MAX(100)` removal as a bug fix, the `setOriginalServices` duplicate, the `daily-bill.helper.ts` ordering disagreement).
- **`/Users/pyaesonewin/Documents/work/hms-system/hms-docs/code-reviews/2026-06-17-cathlab-findings.md`** — This PR claims to close all four findings (copy-paste, dead schema, wrong-schema action, optimistic state commit). The closing is mostly correct:
  - Finding #1 (copy-paste) — partial close. The service and procedure paths are deduplicated, but company-direct remains inline.
  - Finding #2 (dead schema) — closed. `updateCathLabProcedureItemSchema` is now a real, narrowly-scoped schema.
  - Finding #3 (wrong-schema action) — closed. The new `updateCathLabProcedureItemsAction` uses its own schema.
  - Finding #4 (optimistic state commit) — closed. The `setOriginal*` resets are now in `onSuccess`.
  The partial close of finding #1 introduces new issues (the dead "company-direct" arm, the dead `requireDoctorAndZeroPrice` flag, the asymmetric audit-row writes) — those would not have been visible in the 2026-06-17 review because the helper didn't exist yet.
- **`/Users/pyaesonewin/Documents/work/hms-system/hms-app/CLAUDE.md` §"Auth & Authorization"** — The new `updateCathLabProcedureItemsAction` goes through `authActionClient` (line 47-55 of `cathlab.action.ts`), but doesn't call `authorizeProcedure(action, subject)` explicitly. This matches the existing pattern in the file (the other four actions also skip explicit per-action authorize), so this is consistent — but `CLAUDE.md` says "procedures use `authorizeProcedure(action, subject)`" as a project convention. The implicit assumption is that the action's permission module has a single bundle for "cathlab write", which is not validated here.
- **`/Users/pyaesonewin/Documents/work/hms-system/CLAUDE.md` §"hms-summary-service"** — Out of scope per the prompt. The summary-service is not affected by this PR because: (a) the cathlab service-item / procedure-item / company-direct tables are not in the outbox producer list, and (b) the daily-bill-side updates here do not emit any new outbox events. Flag for v2: if the summary-service's planned doctor-payout workflow ever needs to read cathlab line items, the new `CathLabProcedureItem.doctorId` (nullable) and the new `doctor: { id, title, fullName }` shape will be the natural join key.
- **HMS known gotcha: "server-side price-zero enforcement missing for doctor-led procedures"** — See Critical "Procedure update path accepts any item.price". The create path enforces "doctor → price=0" but the update path accepts any price. The UI gate `canEditPrice = ... && item.price === 0 || editingProcedureIds.has(item.id)` is the *only* thing keeping the rule consistent, and a client-side gate is bypassable.
- **HMS known gotcha: "duplicate audit row"** — New: helper writes one audit row at `cathlab-item.service.ts:840-845`, caller writes another at `cathlab.service.ts:1466-1472` and `:1699-1705`. Two rows per save, both with non-identical messages.

## Checklist results

- [x] Hardcoded secrets — none introduced.
- [x] SQL/Prisma injection — only Prisma typed queries; no `$queryRawUnsafe`.
- [ ] `console.log` / `debugger` — one pre-existing `console.error("Error saving changes:", error)` at `daily-bill-cathlab.tsx:574` (not new, but not fixed).
- [ ] `any` type annotations — one `as unknown as TItem` cast at `cathlab-item.service.ts:990` (Medium issue).
- [x] `@ts-ignore` / `@ts-expect-error` / `eslint-disable` — none introduced.
- [x] TODO / FIXME — none.
- [ ] Long functions (>50 lines) — `processSingleItem` in `cathlab-item.service.ts:891-1003` is 112 lines (single-purpose but stretches the rule); `updateCathLabServiceItems` is 70 lines including the inline `updateFn` callback.
- [x] `useEffect` correctness — three new `useEffect`s for change detection are correctly bracketed by their dependencies (`editableServices/originalServices`, `editableProcedures/originalProcedures`); the cathLab-reset effect properly handles `isOpen`.
- [x] Missing `key` props, index-as-key — fixed: `key={item.id || index}` (was `key={index}`).
- [ ] Permission checks — both new actions use `authActionClient`, but neither calls `authorizeProcedure(action, subject)` explicitly (matches file pattern, but `CLAUDE.md` convention expects it).
- [x] Tenant-scope — N/A, HMS-side only.
- [x] Schema validation — all payload types are Zod-validated (the new `updateCathLabProcedureItemSchema` is strictly correct).
- [ ] Tests — **zero new tests.** The 430-line `cathlab-item.service.ts` helper is the kind of code that begs for unit tests (mock `tx.cathLabServiceItem.findMany`, `tx.cathLabProcedureItem.update`, `utilService.calculateDepositAmount`, `cathLabRepository.createCathLabAudit`; assert that `result.changes`, `result.difference`, and the audit message are correct for representative inputs). The procedure-item schema is also testable in isolation. The repository add for `id: true` / `doctor` select should have a snapshot test on the validator output.
- [ ] Docs — the `daily-bill.helper.ts:31-39` change adds a hospital-markup branch to a public helper but does not document the order-of-operations (markup first, then discount). The inline cathlab.service.ts:758-790 has a different order (commission = base × pct). If both paths are supposed to be "equivalent", document why they differ on foc and discount; if they're not equivalent, fix one to match the other (Medium issue).

## Recommendation

Block merge until the three real blockers are fixed: (1) either actually enforce `requireDoctorAndZeroPrice` inside the helper or delete the flag and put the rule in the inline `validateFn` body (Critical #1); (2) align the procedure update path with the create path so `doctorId` always forces `price = 0` (Critical in "Procedure update path accepts any item.price"); (3) drop the duplicate `findMany` in each caller by having the helper return `cathLabId` (Critical "duplicate findMany"). The two more pervasive hygiene issues — duplicate audit row and partial extraction that leaves dead code — should also be addressed before merge. The rest (UI rounding mismatch, unbounded `hospitalPercentage`, helper `case "company-direct"` arm) are worth addressing in this PR or a follow-up.
