# Code Review: PR #2889 — fix: standardize ward list order by createdAt in Request Room
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/27/order-by-ward` → `development`
**Files changed:** 2 (+234 / -215)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07

## Summary
Standardizes the ward ordering in the IPD "Request Room" view to match the IPD Management > Ward UI. The change adds `wardCreatedAt` (carried via the room's `ward.createdAt`) to the `GroupedRooms` interface, selects `ward.createdAt` in the room-list repository query, then sorts `Object.entries(wards)` in `RoomCard` by `createdAt` ascending with a `wardName` tiebreaker. The diff is dominated by re-indentation inside the `Object.entries(wards).map(...)` after wrapping the chain with `.sort(...)`.

## Verdict
**Approve with suggestions**
Score: 92/100
Critical: 0 | High: 0 | Medium: 0 | Low: 2 | Nit: 2

## Issues

### Critical
None

### High
None

### Medium
None

### Low / Nit

1. **Sort is done at render time instead of SQL `orderBy`.** The repository still returns rooms in whatever order Prisma gives them, and the JS-side sort requires the full room tree to be materialized before the wards can be ordered. With a few wards this is fine, but the canonical place to express "wards ordered by `createdAt` asc, tiebreak `name`" is the Prisma query (the `ward` relation on the room select). Pushing it to SQL would (a) keep the render code allocation-light, (b) remove the need for `wardCreatedAt` to live on `GroupedRooms` at all, and (c) eliminate the `MAX_SAFE_INTEGER` fallback for missing `createdAt`. If moving the sort to Prisma isn't tractable because ward data is grouped across rooms, at minimum add a brief comment near the `.sort(...)` explaining why client-side sort is intentional, so the next reader doesn't try to "fix" it back into SQL.
2. **`MAX_SAFE_INTEGER` fallback silently demotes wards with `createdAt = null`.** Wards that genuinely predate the column being added (or rows where the join returned no ward) all collapse to the bottom in an undefined order. Since `localeCompare` then tiebreaks only the ones that share `MAX_SAFE_INTEGER`, the visual order for legacy rows is effectively whatever `Object.entries` yielded — i.e. *not* stable. If the intent is "missing dates go last", make that explicit and stable (e.g. a sentinel slot sorted by name only); if not, sort nulls first like the rest of the IPD Ward UI does.

### Nit

1. **`Object.entries` on every render is now doing an extra `.sort`** plus a per-element `.getTime()`. For wards-per-building in the dozens this is a non-issue, but the existing component already memoizes the `groupedRooms` build — extending the memo to include the sorted array (or memoizing a `sortedWards` derived from `wards`) would remove the redundant per-render pass.
2. **`?.localeCompare` with `?? ""` will throw if `wardName` is `null`** because `localeCompare` is called on the coalesced operand. In practice it's safe here (both sides fall to `""`), but the pattern reads ambiguously and would fail if either were just `undefined`. Prefer explicit `?? ""` on each side or a small `byName` helper to keep the intent obvious.

## Recommendation
Both Low items are worth addressing before merge; neither blocks the change in functionality, but pushing the ward ordering to Prisma (or at minimum documenting why the client sort is intentional) is the right long-term fix and removes the need for the `MAX_SAFE_INTEGER` sentinel. The Nits can be deferred to a follow-up cleanup. Otherwise, the diff is focused and the re-indentation is unavoidable given the wrapping `.sort(...).map(...)` chain.
