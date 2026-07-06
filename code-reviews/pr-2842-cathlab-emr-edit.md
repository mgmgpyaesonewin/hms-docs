# PR #2842 — Fix - Cathlab service cannot edit in cathlab emr

**Repo / State / Author / Branch:** `MyanCare/Ycare-HMS` / **OPEN** / `@Pyae41` / `issue/ppz/sprint-26/cathlab-module-86ey2rjb6` → `development`
**Diff stats:** IPD-EMR cathlab services tab + `use-cathlab-bind-form.tsx` + Zod schema (commits pending verification)

**Verdict:** ⚠️ Approve with required fixes
**Critical+High:** 0 Critical, 1 High, 3 Medium, 3 Low

## Summary

Re-enables editing of services inside the IPD-EMR cathlab tab. Touches the guard that disables the edit button (`Boolean(cathLabId) && !isDirty`), reshapes the form bind hook to refresh the price on selection, and tightens the items Zod schema. Direction is correct but the IPD fix **doesn't patch the standalone `/cathlab/[id]/edit` route** carrying the same guard.

## Risks

- **Sibling route, same bug.** Standalone `/cathlab/[id]/edit` (`src/app/(dashboard)/cathlab/features/components/cathlab-form.tsx:708/710/715`) carries the same `Boolean(cathLabId) && !isDirty` block and is **not** patched by this PR. After merge, IPD-EMR edit will work but the standalone edit page will still be broken — confusing UX state for users who land there directly.
- **Price regression.** `use-cathlab-bind-form.tsx:140` now binds `price: item.amount`. Previously `price: Number(item.stock?.pricePerUnit ?? 0)`. Sibling EMR hooks (`use-cathlab-emr-form` etc.) still bind the per-unit form. If the cathlab line items are sold per unit, the new code overcharges by the qty when a user changes items.
- **Schema reuse missed.** `cathLabPharmacySaleItemSchema` re-declares two `.refine` clauses already on `pharmacySaleItemSchema`. Should be a `.extend({ id: z.string().optional() })`.

## Findings

### 🔴 Critical
None.

### 🟠 High

1. **Sibling route has the exact same guard, untouched.** `src/app/(dashboard)/cathlab/features/components/cathlab-form.tsx:708/710/715` carries `Boolean(cathLabId) && !isDirty`. PR only patches the IPD-EMR services tab. The standalone cathlab edit page will continue to be broken. **Action:** also patch the standalone route in this PR, *or* file a tight follow-up and link it in the PR body. Otherwise users hit two flows with different edit-state UX.

### 🟡 Medium

1. **`price: item.amount` regression in `use-cathlab-bind-form.tsx:140`.** Was `price: Number(item.stock?.pricePerUnit ?? 0)`. Sibling EMR hooks still use the per-unit form. **Action:** restore per-unit-from-stock binding **or** confirm the cathlab flow is gross-amount-based end-to-end (i.e. `amount` already contains qty * unit) before merging. A wrong-shape money binding is a 3am ticket.
2. **`cathLabPharmacySaleItemSchema` re-declares the same two `.refine` clauses already on `pharmacySaleItemSchema`.** Should reuse via `.extend({ id: z.string().optional() })`. Ponytail rung 2 — already in this codebase.
3. **`formState.isValid` requires `mode: "onChange"` on `useForm` to be reactive on load.** Without it, the button-disable logic gates on stale form state until the first blur. Confirm the form's `useForm` opts into `mode: "onChange"` before trusting the new button condition.

### 🔵 Low / Nit

1. **Mantine `TextInput` `error` prop** — if the same form has multiple inputs at the same error tier, scoping by name keeps the message correct.
2. **No tests added.** Pure UX gating change; sibling-route regression is the test you'd write against.
3. **Possibly relevant:** check whether the same `Boolean(cathLabId) && !isDirty` guard exists on OP/ED/HD cathlab-equivalent routes — root-cause flag once, don't bundle.

## Ponytail notes

- **Rung 1 — does this need to exist at all?** Yes, the bug (services un-editable in cathlab EMR) is real. Direction is correct.
- **Rung 2 — already in this codebase?** Yes — the *idiom* (count-based disable, cathlab price hook, Zod item schema) appears in `use-cathlab-emr-form` and `pharmacySaleItemSchema`. PR should reuse; instead it duplicates the schema and the price binding logic diverges.
- **Rung 6 — can it be one line?** The guard rewrite (`!Boolean(cathLabId) || isDirty`?) — yes, small. The schema rewrite — no.
- **Root-cause vs symptom.** The user-visible bug is "can't edit service in cathlab EMR." Root cause is "edit-disable guard is over-broad." The PR fixes the IPD side but the same guard is on the standalone cathlab route and (likely) OP/ED/HD equivalents. Patch once at the guard, not per-route.

## Reuse check

- `use-cathlab-emr-form` hook — sibling pattern for cathlab item binding. **PR diverges** (`price: amount` vs per-unit).
- `pharmacySaleItemSchema` — base Zod schema with the same two refines. **PR duplicates** as `cathLabPharmacySaleItemSchema`.
- **No new shared helper added.** Correct (this is a per-route guard; a wrapper only pays off when the third route needs the same fix).

## Tests

- **None added.** Required minimum (Ponytail "one runnable check"):
  1. RTL render of cathlab IPD services tab with a saved `cathLabId` → click edit service → item form opens + populates (proves fix).
  2. RTL render standalone `/cathlab/[id]/edit` route → click edit → still broken (regression pre-PR; PR doesn't fix it).
  3. Unit test for `use-cathlab-bind-form` `price: item.amount` vs `Number(item.stock?.pricePerUnit ?? 0)` — pick one shape.

## Bottom line

After **H1** (also patch standalone route, or tight follow-up), **M1** (restore per-unit price binding — money path), and **M2** (reuse `pharmacySaleItemSchema` via `.extend`), ship. Tests optional.
