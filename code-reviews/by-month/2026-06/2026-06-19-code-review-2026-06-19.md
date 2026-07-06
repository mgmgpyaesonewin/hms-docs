# Code Review — validateAgeRange & debounced validation

Date: 2026-06-19
Scope: age-range / result validators, debounced validation refs

## H1. `itemErrors.conflict` is never assigned — dead UI branch

`validateAgeRange` initializes `newFieldErrors.conflict = undefined` as `string | undefined` but no branch ever assigns it. The render then renders:

```tsx
{itemErrors.conflict && (
  <span className="text-xs text-amber-600 mt-1">{itemErrors.conflict}</span>
)}
```

This span is unreachable. Either remove the JSX and the field, or wire up the conflict message (the old `validateResult` used `itemErrors.message` for the same purpose — pick one shape).

**Fix:** Either remove the `{itemErrors.conflict && ...}` block, or populate `newFieldErrors.conflict` in the `num1Val >= num2Val` branch (e.g. `newFieldErrors.conflict = "First age must be less than second age"`). The old `validateResult` had a single `message` string — keep that shape for both validators instead of inventing a new `conflict` field.

## H2. `setTimeout` handles for debounced validation are not cleared on unmount

`debounceAgeRef.current[debounceKey]` and `debounceResultRef.current[debounceKey]` schedule callbacks that call `setAgeRangeErrors` / `setResultErrors` / `validateTemplateLogic`. There is no cleanup `useEffect(() => () => Object.values(debounceAgeRef.current).forEach(clearTimeout))`. If the user navigates away within 1s of editing a value, the callback fires against an unmounted component and triggers React's "state update on unmounted component" warning (and a memory leak in production). This is a resource-management regression introduced by this PR (the previous version had the same shape, but the PR doubles the surface area by adding `debounceAgeRef`).

**Fix:** Add to the component:

```tsx
useEffect(() => {
  return () => {
    Object.values(debounceAgeRef.current).forEach((id) => id && clearTimeout(id));
    Object.values(debounceResultRef.current).forEach((id) => id && clearTimeout(id));
  };
}, []);
```

## H3. `Number("")` is 0, not NaN — comparator bug in `validateAgeRange` line 608-611

```ts
const num1Val = Number(num1);
const num2Val = Number(num2);

if (!isNaN(num1Val) && !isNaN(num2Val) && num1Val >= num2Val) { ... }
```

This branch is only reachable after `if (!num1 || !num2)` short-circuits, so `num1` / `num2` are non-empty strings — fine here. However, this defensive `isNaN` check is misleading; `Number("")` is 0, so the comment "guarding against NaN" is misleading. The pre-existing `validateResult` does `Number(num1) >= Number(num2)` without the `isNaN` guard, also relying on prior empty-string rejection. Either commit to that simplification in both, or document why the new validator differs.