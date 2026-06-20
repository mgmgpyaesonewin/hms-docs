# Code Review — PR #20: Qty reflecting previous entered item (re-review)

**Date:** 2026-06-20
**PR:** https://github.com/MyanCare/HMS-Hni-Zi-Gone/pull/20
**Branch:** `mpt/medicine-form-issue` → `development`
**Files changed:** 1 (+3 / −2)
**Risk:** **Medium** (clinical form — wrong qty can mis-dose a patient)
**Verdict:** **Approve** — High-severity issue from previous review was fixed; remaining items are non-blockers.

## Summary

Fixes the bug where the `qty` input on a newly added medicine item would show the value from the previously entered item. The fix switches the row's React key from the index-based composite `` `${item.itemId}-${index}` `` to `useFieldArray`'s stable `fields[index].id`, which lets React reconcile the row correctly when items are added/removed. A second defensive measure sets `autoComplete="off"` on the qty input to suppress browser autofill interference.

The post-review fix commit (`ab9d84f6`) directly addressed the prior review's H1 finding. The diff is now clean and the fix targets the right root cause.

## Findings

### H1. *(Resolved)* Composite key collision when items have the same `itemId`

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:265`

**Previous code:**
```tsx
<MedicineItemRow
  key={`${item.itemId}-${index}`}
  ...
/>
```

**Current code (in PR):**
```tsx
<MedicineItemRow
  key={fields[index].id}
  ...
/>
```

The composite key fell back to the array index whenever `item.itemId` was `undefined` (e.g., a freshly added row before any field touched it). Two rows could end up with the same key when the user added a new item and edited an existing one in the same render — React then reused the existing DOM node, leaving the stale qty value in place.

`useFieldArray` returns a stable `id` per row (a UUID-like internal handle) that survives the whole row lifecycle. Switching to it is the canonical fix for this class of bug.

**Status:** Fixed in commit `ab9d84f6` ("fix: PR review"). No further action.

### M1. `autoComplete="off"` is a secondary defense — not the root-cause fix

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:649`

```tsx
autoComplete="off"
```

The previous review flagged that browser autofill may have been contributing to the symptom. The `autoComplete="off"` attribute prevents most modern browsers from injecting saved values, which closes the autofill vector. However:

- React's controlled-input `value={field.value ?? ""}` already prevents uncontrolled state from leaking across rows once reconciliation is correct.
- If browser autofill was the *primary* repro in the original report, `name={``item-${fields[index].id}``}` would be a stronger isolation than `autoComplete="off"` alone (browsers key autofill off `name`).

**Recommendation:** Keep `autoComplete="off"` (defense-in-depth is cheap), but the real fix is H1.

### M2. Per-row index-based `useEffect` inside `MedicineItemRow` *(unchanged)*

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx` (around the `MedicineItemRow` definition)

The row component has at least one `useEffect` keyed off the row index or the `item` prop. With the new `fields[index].id` key, React now mounts a fresh component per row on add — so the effect fires correctly. But the same effect will *not* fire on edit if `item.itemId` changes for the same row (e.g., user picks a different medicine from the dropdown). Worth a regression test.

### M3. Weak autofill isolation across rows *(unchanged)*

Each row's qty input uses `name="qty"` by default (RHF does not assign per-row names unless explicitly configured). Two rows with the same `name` is a classic autofill trigger. The `key` fix prevents React from reusing the wrong DOM node, but Chrome may still surface a saved value on focus.

**Fix (low priority):** Either set a per-row `name` (`name={``items.${fields[index].id}.qty``}`) or add `data-form-type="other"` to the input. Already partially mitigated by `autoComplete="off"`.

### L1. No regression test *(unchanged)*

The fix is one line; the absence of a test means the next refactor could regress silently. Add a single RTL test: render the form, add a row, type qty=5, add another row, assert the new row's qty is empty.

### L2. Possible interaction with PR #17 *(unchanged)*

PR #17 introduces `useFieldArray` effects on `items` (duration multiplier). The two PRs both modify `medicine-form.tsx`. Verify no merge conflict in the row component and that both fixes cooperate. Coordinate the merge order — #20 first, then #17.

## Recommendations

1. **Land this PR.** The H1 fix is correct and minimal.
2. Add a regression test (L1) — preferably in the same PR so it ships with the fix.
3. Coordinate merge order with PR #17 (L2) — review both diffs together before merging either.

## Test plan checklist

- [ ] Open medicine form for a new patient.
- [ ] Add item 1, set qty = 5. Add item 2 → assert item 2's qty is empty.
- [ ] Add item 1, set qty = 5. Edit item 1's medicine dropdown → qty stays 5.
- [ ] Add 3 items, set qty values 3/7/2, remove item 2 → remaining qty values still 3 and 2.
- [ ] Browser autofill: focus the qty input on a freshly added row → no suggestion popup.
- [ ] Open an existing record for edit → qty values match the saved record.

## Compared to previous review (2026-06-19)

| Previous ID | Status | Notes |
|---|---|---|
| H1 (composite key fallback) | **Fixed** | Commit `ab9d84f6` replaced `` `${item.itemId}-${index}` `` with `fields[index].id`. Verified in current diff. |
| M1 (autofill as contributing factor) | Partially mitigated | `autoComplete="off"` added. Per-row `name` still missing — non-blocking. |
| M2 (per-row `useEffect` keyed on index) | Unchanged | Now less likely to fire spuriously due to correct key, but still depends on `item.itemId` not changing within a row. |
| L1 (no regression test) | Unchanged | Still missing. |
| L2 (conflict with PR #17) | Unchanged | Still a merge-order consideration. |