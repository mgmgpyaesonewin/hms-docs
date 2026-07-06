# PR #2863 — Fix(Reopen): lab result entry cannot enter result issue

**Repo:** MyanCare/Ycare-HMS · **PR:** https://github.com/MyanCare/Ycare-HMS/pull/2863
**Branch:** `issue/lab_86exu34bj` → `development` · **Author:** Pyae41
**Diff:** 4 files · +185 / -55 · **ClickUp:** 9018849685/86exu34bj
**Verdict:** **changes-requested** (1 blocking, 5 important, 4 nits)

> Re-synthesized review. Supersedes the earlier draft at this path.

## Summary

The PR fixes a real bug: when a `LabGroup` mapping is created or updated for a `LabTest` that already has `LabService` rows pointing at it, no `LabServiceItem` rows are created, so the result-entry page has nothing to record against. The fix is a new private helper `syncExistingLabServices` in `lab-group.repository.ts` that backfills `labServiceItem` rows from any pre-existing `labService` for the same `labTestId`.

Three side-fixes ride along:

1. **`page.tsx`** inverts the in-page lab-group lookup from `Map<specialLabTestId, labTestId>` to `Map<labTestId, Set<specialLabTestId>>` and reverses the validation direction ("does this LabTest contain this SpecialTest?").
2. **`lab-service-item-result-entry-status-form.tsx`** wires `zodResolver` into the form config and surfaces `fieldState.error?.message` on the Reading Doctor `<Select>` so the existing `readingDoctorId: z.string().min(1, "Reading doctor is required")` rule actually shows up in the UI.
3. **`lab-result-entry.repository.ts`** adds a defensive `specialLabTestId: { not: null }` filter in `getLabTemplateMicrobiologyItems`.

Direction is right and the data-structure inversion on the page is the correct many-to-many correction. The blocker is the status column copy inside `syncExistingLabServices` (audit-trail corruption); the important issues are reachable on common inputs.

## Strengths

- **Root cause is correct.** The `labGroupMappingMap` of `specialLabTestId → labTestId` collapsed once `LabGroup` became many-to-one; the inverted `Map<labTestId, Set<specialLabTestId>>` is the right shape.
- **Both write paths now wrap in `prisma.$transaction`.** Without this, a partial sync could leave `labGroup` and `labServiceItem` rows inconsistent.
- **Wiring `zodResolver` into the existing form** is exactly what was needed for the Reading Doctor validation message to ever surface.
- **Pushing the `specialLabTestId: { not: null }` filter into the repository** keeps callers from re-doing the null guard at every call site.
- **`tx.labService.update({ data: { updatedById: userId } })`** (still imperfect — see I3) at least acknowledges that `labService.updatedById` should track who touched the parent service.

## Issues

### Blocking

**B1. State-laundering via parent status copy** — `src/app/(dashboard)/shared/lab/repositories/lab-group.repository.ts:308-343` (the `createMany` inside `syncExistingLabServices`).

Newly created `LabServiceItem` rows are seeded with seven status columns copied from their parent `LabService` (`collectStatus`, `acknowledgeStatus`, `testingStatus`, `testDoneStatus`, `resultEntryStatus`, `verificationStatus`, `labReeportStatus`); every `*UpdatedAt` is forcibly set to `now()`; every `*UpdatedById` is set to `userId`. Two concrete bugs:

- An item created on a fresh `LabGroup` mapping is born into whatever stage its parent `LabService` happens to be in (`TOCOLLECT`, `ENTERED`, `VERIFIED`...), bypassing the per-item state machine that audit / verify / report queries rely on. Existing reads will see "frozen" items as if they had advanced.
- The `*UpdatedAt` columns are stamped with `now()` even though the corresponding state has never transitioned on this row. Every "when did this item move to X?" query gets a fabricated answer.

The codebase already has the right pattern for creating these items — `opd-emr.service.ts:2163` creates the same rows with only `{ labServiceId, specialLabTestId, createdById, updatedById }` and lets Prisma's `@default(TOCOLLECT)` apply. The new code should do the same.

**Recommended fix (drop the status copy entirely):**

```ts
if (toAdd.length > 0) {
  await tx.labServiceItem.createMany({
    data: toAdd.map((specialLabTestId) => ({
      labServiceId: labService.id,
      specialLabTestId,
      createdById: userId,
      updatedById: userId,
    })),
  });
}
```

If inheriting parent state is intentional, restrict it to `createLabGroup` only (never on `updateLabGroup`, where cascade delete + recreate loses audit trail) and add a one-line comment naming the invariant + link to an ADR.

### Important

**I1. Unsafe `for (const mapping of item.specialLabTest.labTestMappings)`** — `src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:663-673`.

`getLabTemplateMicrobiologyItems` uses `select` (not `include`), so `item.specialLabTest` can resolve to `null` whenever the FK points at a deleted parent. The `specialLabTestId: { not: null }` filter (added in the same PR) only drops rows where the *local* column is null — orphaned FK rows still come back. The original commented-out code had a `if (item.specialLabTest?.labTestMappings)` guard; the new code dropped it.

**Fix:**

```ts
for (const item of existingMicrobiologyTemplate ?? []) {
  const mappings = item.specialLabTest?.labTestMappings;
  if (!mappings) continue;
  for (const mapping of mappings) { ... }
}
```

**I2. Dropped `useMemo` on the lab-group map** — `src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:663-673`.

The original wrapped the map construction in `useMemo` keyed on `existingMicrobiologyTemplate`. The rewrite dropped the memo, so the `Map<labTestId, Set<specialLabTestId>>` is rebuilt on every parent re-render even when the template data is unchanged. The page re-renders on every checkbox / status change, so this is wasted work on every interaction.

**Fix:** wrap in `useMemo(() => { ... }, [existingMicrobiologyTemplate])` like the surrounding code.

**I3. Unconditional `tx.labService.update` even when nothing changed** — `src/app/(dashboard)/shared/lab/repositories/lab-group.repository.ts:355-358`.

Every iteration of `syncExistingLabServices` ends with `tx.labService.update({ data: { updatedById: userId } })`, regardless of whether `toRemove` or `toAdd` had any elements. For a `LabTest` with many `LabService`s, a single `createLabGroup` save fires an UPDATE per service even when no item changed. This dirties `updatedAt` via Prisma's `@updatedAt` and pollutes "last touched by" reporting.

**Fix:** move the update inside the `if (toRemove.length > 0 || toAdd.length > 0)` branch, or compute touched service IDs up front and issue a single `updateMany`.

**I4. `O(N*M)` diff with `Array.includes`** — `src/app/(dashboard)/shared/lab/repositories/lab-group.repository.ts:260-265`.

Both legs are `O(N*M)`. Small enough not to matter today, but a one-line fix to `Set.has()`:

```ts
const newSet = new Set(newSpecialTestIds);
const existingSet = new Set(existingItemIds);
const toRemove = existingItemIds.filter(id => !newSet.has(id));
const toAdd    = newSpecialTestIds.filter(id => !existingSet.has(id));
```

**I5. `createLabGroup` cascade runs on every create, even when nothing exists yet** — `src/app/(dashboard)/shared/lab/repositories/lab-group.repository.ts:165-188`.

A brand-new `LabTest` has zero `LabService` rows to backfill, but the code still opens a transaction, fires `findMany`, and iterates over an empty result. Cheap to fix, free perf win.

**Fix:** short-circuit with `if (labServices.length === 0) return;` inside `syncExistingLabServices`.

### Nit

- **N1. Dead commented block** — `src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:647-661`. A 14-line commented-out `useMemo` sits next to the new map. Useful during dev; delete before merge — git has the history.
- **N2. Inconsistent Controller render shape** — `src/app/(dashboard)/lab/lab-result-entry/features/components/lab-service-item-result-entry-status-form.tsx:841-867`. The touched `<Controller>` uses explicit `return (…)` braces while siblings use implicit return. Pick one.
- **N3. `$transaction` callback return value silently became `undefined`** — `src/app/(dashboard)/shared/lab/repositories/lab-group.repository.ts:165-189, 199-225`. The new code wraps everything in `prisma.$transaction(async (tx) => { … })` with no explicit return, so callers now get `undefined` instead of `{ count }`. Quick grep to confirm no caller awaits `.count`.
- **N4. Pre-existing `labReeportStatus` typo propagated further** — `src/app/(dashboard)/shared/lab/repositories/lab-group.repository.ts:321`. The Prisma schema still has `labReeportStatus` on `LabServiceItem`. Not introduced by this PR, but the PR is now a second consumer. File a follow-up; do **not** rename in this PR.

## Recommendations

1. **Resolve B1 before merging.** Either drop the status copy or restrict it to `createLabGroup` only with a one-line comment. The current behaviour corrupts audit and verify state for every newly propagated microbiology item.
2. **Address I1 and I2 in the same patch** — both are one-line fixes on the new map construction, and the page renders often enough that the missing `useMemo` will show in any profiler run.
3. **Apply I3's gate** (`if (toAdd.length > 0 || toRemove.length > 0) tx.labService.update(...)`) — cheap, eliminates hot-path waste.
4. **Post-deploy smoke check:** call `createLabGroup` on a test tenant, then inspect `lab_service_items`: every new row should have `collect_status = 'TOCOLLECT'` and `null` for `*_updated_at` / `*_updated_by_id`. If anything else shows up, B1 was not fully removed.
5. **Add a unit test for the new Map reducer** on the page (`Map<labTestId, Set<specialLabTestId>>` from the same input shape as `existingMicrobiologyTemplate`).

## Reviewer notes

- Confirm with the team whether the parent-status copy in `syncExistingLabServices` was intended. If yes, restrict to `createLabGroup` only. If no, delete it entirely per B1.
- The ClickUp ticket is `9018849685/86exu34bj`. Reading it before approval is recommended.
- `next.config.ts` ignores ESLint/TS errors at build time. Run `npm run lint && npm run typecheck` locally before approving.
- The PR title `Fix(Reopen): …` is opaque in `git log` because the actual fix is the repository backfill. A rename to `fix(lab): backfill labServiceItem rows when lab group mapping changes` would be friendlier.

## Ponytail one-liners (over-engineering only)

- `lab-group.repository.ts:303-346` — **delete:** the seven-column status copy plus 14 `*UpdatedAt` / `*UpdatedById` assignments. Let Prisma's `@default(TOCOLLECT)` and `@updatedAt` do their job (see `opd-emr.service.ts:2163`).
- `lab-group.repository.ts:355-358` — **delete:** the unconditional `tx.labService.update` outside the change branch. Move inside `if (toAdd.length || toRemove.length)`.
- `page.tsx:647-661` — **delete:** 14-line commented-out `useMemo` block. Git has the history.
- `lab-result-entry.repository.ts:876-879` — fine as-is, but: **native:** the new `not: null` filter is one Prisma clause; keep it co-located, do not add a defensive `?? null` upstream.
- `form.tsx:841-867` — **shrink:** the `render={({ field, fieldState }) => { return (…) }}` block can drop the braces; siblings use implicit return. Style consistency, not correctness.

**Net:** ~22 lines of status copy + ~14 lines of dead comment + ~3 lines of unconditional update = **-39 lines** possible if B1 + I3 + N1 are all addressed. No new abstractions needed.