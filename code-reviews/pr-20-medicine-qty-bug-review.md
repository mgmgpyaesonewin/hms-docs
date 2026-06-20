# Code Review — PR #20: Qty reflecting previous entered item

Date: 2026-06-19
PR: https://github.com/MyanCare/HMS-Hni-Zi-Gone/pull/20
Branch: `mpt/medicine-form-issue` → `development`
Files changed: 1 (+3 / -2)
Risk: **High** (patient-safety: wrong dispensed quantity has clinical impact, but the PR is a 1-file, 5-line fix)
Verdict: **Approve with suggestions**

## Summary

Three lines fix a React reconciliation bug in the medicine form. Rows in `<MedicineItemRow>` were keyed by `key={`${item.itemId}-${index}`}`, which is unstable across `useFieldArray().prepend` calls — when a new item is prepended, the existing rows shift to higher indices, React reconciles by index, and the qty input in a previously-added row keeps its old display value even after the underlying state changed. The fix at `medicine-form.tsx:265` switches to `fields[index]?.id` (the stable id `useFieldArray` provides for each row) and adds `autoComplete="off"` on the qty input at line 649 as a defensive browser-autofill guard. The fix is correct for the reported repro, but two small things to clean up.

## Findings

### H1. `fields[index]?.id ?? `${item.itemId}-${index}`` re-introduces the original broken key

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:265`

```tsx
<MedicineItemRow
  key={fields[index]?.id ?? `${item.itemId}-${index}`}
  ...
/>
```

The fallback to the old key format defeats the entire fix if `fields[index]` is ever undefined. `useFieldArray` always populates `fields` to mirror the current `items` length, so `fields[index]` should always exist. If there's a code path where it doesn't (e.g., during a transient render before `useFieldArray` syncs), the fallback to `${item.itemId}-${index}` reintroduces exactly the broken key the fix is trying to replace, and the bug returns in that edge case.

**Fix:** Drop the fallback:

```tsx
<MedicineItemRow
  key={fields[index].id}
  ...
/>
```

If you want defensive coding, log a warning when the lookup misses:

```tsx
{!fields[index] && console.warn(`MedicineItemRow: missing field at index ${index}`)}
key={fields[index]?.id ?? fields[fields.length - 1]?.id}
```

…or just assert and crash loudly in dev.

### M1. `qty` and `price` watchers in `MedicineItemRow` are still keyed by index — manual regression check needed

The PR fixes the parent-level row key. Inside `MedicineItemRow`, the qty/price `useEffect` at roughly `medicine-form.tsx:555-560` (visible in earlier PR diffs, not in this one) still derives `amount` from `watchedQty * watchedPrice` using `useWatch({ name: \`items.${index}.qty\` })`. If the parent reorders items (not currently a feature, but possible if `prepend` is misused), the per-row effects may briefly fire against the wrong row's state.

For the current feature surface (only `prepend` is used to add rows), this is fine. But the parent key fix means rows no longer swap DOM nodes on reorder, so the per-row effect no longer has the chance to mis-fire. Net positive. Still, worth a quick manual test where a user adds 5 rows, edits qty on row 3, then prepends a new row — confirm row 3 keeps its edited qty.

### M2. `autoComplete="off"` on a numeric input has limited browser effect

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:649`

```tsx
<input ... autoComplete="off" />
```

`autoComplete="off"` is honored inconsistently across browsers — Chrome will still offer to autofill if the user has accepted the prompt previously, and the spec doesn't require browsers to honor it on `type="number"`. If the original bug report included "browser autofilled a stale value", the real fix is `autoComplete="off"` plus `name="quantity-{index}"` (unique name per row), plus `inputMode="numeric"`. The current change is necessary but not sufficient if browser autofill was the trigger.

**Fix:** Combine with a row-specific `name`:

```tsx
<input
  name={`medicine-qty-${fields[index].id}`}
  autoComplete="off"
  ...
/>
```

### L1. The diff is small enough to fold into a sibling PR

This is a 5-line fix to the same file that's already seeing churn in PR #17 (`mpt/medicine-form-add-duration`, open) and PR #15 / PR #16 (recently merged). Merging this PR while #17 is still open will create a merge conflict on the same `key=` line and the same `useFieldArray` destructuring change. Coordinate with the author of #17: either land #20 first, or have #17's author rebase onto this branch.

### L2. No regression test added

This is a reconciliation bug — exactly the class of bug that screams for a regression test. A small RTL test that renders the form, adds two items, edits the qty on item 1, prepends a new item, and asserts that item 1's qty is unchanged would lock the fix in place. Without it, a future change to `key=` or `useFieldArray` ordering can reintroduce the bug silently.

## Recommendations

1. Drop the `?? \`${item.itemId}-${index}\`` fallback (H1) — the fix is incomplete with it.
2. Coordinate with PR #17 to avoid a merge conflict (L1).
3. Add a regression test (L2).
4. Consider `name={`medicine-qty-${fields[index].id}`}` for stronger autofill isolation (M2).

## Test plan checklist

- [ ] Reproduce the original bug: open form → add medicine A with qty 5 → add medicine B with qty 10 → confirm row 1 (medicine A) still shows qty 5, not 10.
- [ ] Add 5 rows, edit qty on row 3, prepend a new row — row 3 retains edited qty.
- [ ] Delete row 2 of 3 — rows 1 and 3 keep their values.
- [ ] Open and close the form several times — qty state is reset each time (no leftover values).
- [ ] Browser autofill: focus the qty input on a fresh form, type a number, refresh, refocus — autofill does not repopulate with a previous value.
- [ ] No merge conflict with PR #17 (or merge that one first).
- [ ] Verify `fields[index]?.id` never returns undefined in the render path (the fallback path is dead code).