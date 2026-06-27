# Code Review: PR #2781 — Prevent Duplicate Allocation and Grouping of Lab Test in Lab Test Mapping

**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41 (Pyae Phyo Zan)
**Branch:** `lab-group-86exzmg0r` → `development`
**Files changed:** 3 (+53 / −27)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-06-24
**ClickUp:** https://app.clickup.com/t/9018849685/86exzmg0r
**Commits:** `2f5577a4` (initial), `25f02e52` (fix: drop dead `checkExistInLabTemplate` branch + include current test in edit)

## Summary

This PR addresses a real and reproducible bug class: the lab-test-mapping form's "Lab Test" `<Select>` previously returned tests that already had `LabTemplateItem` rows, allowing a single `LabTest` to be mapped into a `LabGroup` more than once. The fix has two parts: (1) a new repository flag `excludeLabTestsUsedInTemplates` that emits `where.NOT = { labTemplateItems: { some: {} } }` so the dropdown only shows unmapped tests, and (2) a form rewrite that splits the query params into create/edit modes, preserves the currently-selected test in edit mode via `includeLabTestId`, and conditionally pushes the selected lab test back into the `<Select>`'s data array when the API omits it. The second commit correctly drops the now-dead `checkExistInLabTemplate` branch and the unused `excludeLabTestsUsedInTemplates` schema field's old sibling.

The UI-side dedup is well thought through and the edit-mode fallback is a clever fix for the case where the currently-mapped test is `INACTIVE`. However, the **dedup is enforced only at the UI level** — there is no DB unique constraint on `LabGroup(labTestId, specialLabTestId)`, no service-layer "before insert" check, and no transaction. Two concurrent users (or a stale dropdown + a stale `labTestId` form value) can still create duplicate `LabGroup` rows, which is the actual ticket ("Prevent Duplicate Allocation **and Grouping**"). The form also passes `status: "ACTIVE"` unconditionally for both create and edit, which can hide the currently-mapped test even before the `includeLabTestId` fallback has fired (the fallback depends on `labTestData` being populated, which in turn depends on `watchLabTestId` being set; in the first render of edit mode neither is true and the dropdown shows nothing). Several smaller issues — type unsafety around `labGroup?.id` being used as both `labTestId` and the option value, a per-render query-object anti-pattern, an empty `<Select>` label fallback, and a dead Zod field — round out the review.

## Verdict

**Request changes**

Score: 58/100
Critical: 1 | High: 3 | Medium: 4 | Low: 3 | Nit: 2

## Strengths

- **`lab-test-mapping-form.tsx:83-101` (commit 25f02e52) — Create vs edit branch correctly passes `includeLabTestId`** — the repository's existing `where.id = query.includeLabTestId` branch (`lab-test.repository.ts:141-143`) is reused for the edit case so the currently-mapped test is not filtered out even when it is `INACTIVE` or has template items. Clean reuse of an existing parameter.
- **`lab-test-mapping-form.tsx:103-122` — The `labTestOpts` push-back fallback for edit mode** is a defensive fix: if the API response omits the current test (status inactive, or filtered), the form still shows the existing selection. Without this the `<Select>` would render empty in edit mode and the user could not see what they were editing.
- **`lab-test.repository.ts` (commit 25f02e52) — Dead `checkExistInLabTemplate` branch deleted** — the second commit correctly removes the now-orphaned `if (query.checkExistInLabTemplate && query.templateId)` branch and the `excludeLabTestsUsedInTemplates` Zod field remains the only filter for this concern. Better hygiene than leaving both.
- **`lab-test.repository.ts:192-198` — Safe Prisma relation filter** — `where.NOT = { labTemplateItems: { some: {} } }` compiles to a clean `NOT EXISTS (SELECT 1 FROM lab_template_items WHERE lab_test_id = lab_tests.id)` subquery. No SQL injection risk, no `$queryRawUnsafe`.
- **Scope discipline** — the PR stays within the lab-test-mapping feature, no migration, no permission change, no schema change in the new Prisma sense. The HMAC/summary-service boundary is not touched.
- **Two-step commit history** — the author pushed the fix in two commits (initial + cleanup), which is easier to review than a single 80-line change.

## Issues

### Critical

- **No DB-level unique constraint on `LabGroup(labTestId, specialLabTestId)` — dedup is UI-only**
  `prisma/schema.prisma:5738-5754` defines `LabGroup`:

  ```prisma
  model LabGroup {
    id          String   @id @default(uuid(7)) @db.Uuid
    ...
    labTestId        String @db.Uuid
    specialLabTestId String @db.Uuid
    labTest        LabTest        @relation(fields: [labTestId], references: [id])
    specialLabTest SpecialLabTest @relation(fields: [specialLabTestId], references: [id])
    ...
    @@map("lab_groups")
  }
  ```

  There is **no `@@unique([labTestId, specialLabTestId])`** and no equivalent on the underlying `lab_groups` table. The PR's fix is therefore UI-only: hide tests in the dropdown that have any template item row. But the actual ticket says "Prevent Duplicate Allocation **and Grouping**" — i.e. a single `(labTest, specialLabTest)` pair should not be insertable twice. Three concrete failure modes:

  1. **Concurrent users.** Two clinicians open the form at the same time, both see the same available special-lab-tests, both submit. Both `LabGroup` rows are inserted. The form is the only thing standing in the way.
  2. **Stale React Query cache.** After the PR, the dropdown is filtered at fetch time, but the form's `defaultValues.labTestId` (line 56) is `labGroup?.id` — this comes from the URL/parent, not the dropdown. If the user navigates back to the form after a stale invalidation, they could pick a `labTestId` that was hidden in the API response but is still in their client-side form state.
  3. **Direct API access.** The action (`lab-test-mapping.action.ts:9-32`) calls `labGroupService.createLabGroup` which calls `findExistingLabGroup` (line 35). That helper is a SELECT-then-INSERT race: the SELECT sees no existing row, the other transaction's INSERT commits first, our INSERT succeeds. There is no surrounding `prisma.$transaction` and no `prisma.labGroup.create({ ..., select: ..., ... })` with a `try/catch` on the unique violation.

  Fix: add a migration that creates `CREATE UNIQUE INDEX lab_groups_lab_test_special_idx ON lab_groups (lab_test_id, special_lab_test_id);`, declare `@@unique([labTestId, specialLabTestId])` in `schema.prisma`, and handle the resulting `P2002` Prisma error in the service layer as a 409 "Lab Test Map already exists". The `findExistingLabGroup` SELECT-then-INSERT pattern then becomes a defense-in-depth nicety rather than the only safety net.

  Evidence: `prisma/schema.prisma:5738-5754` — no `@@unique` on the `(labTestId, specialLabTestId)` pair; `lab-group.service.ts:34-46` — pre-insert check is a non-atomic SELECT; `lab-test-mapping.action.ts:9-32` — action does not wrap service calls in a transaction.

### High

- **`lab-test-mapping-form.tsx:56` — `defaultValues.labTestId: labGroup?.id` confuses `labGroup.id` with the mapped `LabTest.id`**
  `labGroup?.id` is the **LabGroup's** own primary key, not the `LabTest.id` it maps. Looking at the call site, `labGroup` is the entity the user is editing (or creating), and its `labTestMappings` are the join rows. But line 56 reads `labTestId: labGroup?.id`, which would only be correct if the `LabGroup.id` happened to equal the `LabTest.id` — which it does not (the `LabGroup.id` is a fresh UUID, line 5739).

  The actual `labTestId` is `labGroup?.labTestMappings[0]?.labTest.id` (per the relation at `schema.prisma:2935`). And the `labTestOpts` push-back at line 119 uses `value: labGroup.id` — pushing an option whose `value` is the `LabGroup.id` rather than the `LabTest.id`. When the `<Select>` returns this value, `field.onChange` writes the `LabGroup.id` to the form's `labTestId` field, and the action sends a `LabGroup.id` where the service expects a `LabTest.id`.

  This is a **fundamental identity bug** that the existing UI masked: the previous code did not push the option back, so the dropdown came from the API only and the value flowed correctly. With the new push-back, the `<Select>` returns whatever it was given — and the form is now sending the wrong ID.

  Fix: distinguish `labGroup.id` from `labGroup.labTestId`. The `LabGroup` model exposes `labTestId` as a top-level column (`schema.prisma:5745`), so `labGroup?.labTestId` is the correct value. Update `defaultValues.labTestId`, the `includeLabTestId` param, the `labTestOpts` push-back `value`, and the hidden `<input name="id" value={labGroup.id}>` (line 188 — the latter is correct, it should keep `labGroup.id`).

  Evidence: `lab-test-mapping-form.tsx:56` — `labTestId: labGroup?.id`; `:96` — `includeLabTestId: labGroup.id`; `:119` — `value: labGroup.id`; `:233` — `value={field.value || (isEdit ? labGroup?.id : undefined)}`. The `schema.prisma:5745` column is `labTestId String @db.Uuid`, distinct from `id`.

- **`lab-test-mapping-form.tsx:84-101` — Query params object is rebuilt on every render, breaking React Query cache locality**
  `getLabTestQueryParams` is a function called inline at `useQuery(makeGetLabTest(getLabTestQueryParams()))`. The query factory's key derivation almost certainly serializes the params object (`["lab-tests", params]`), and on every render a new object literal is produced — keys are deep-equal compared by TanStack Query, so a hit occurs despite the new reference. But two distinct render paths — (a) `isEdit` flipping during a `labGroup` prop change, and (b) the `labGroup.id` reference changing when the parent re-fetches — produce two different effective keys that *both* match the old cached entry until the first re-render. The result: the dropdown shows the wrong list for one render cycle.

  More importantly, the `useQuery` `enabled` flag is missing — when `watchLabTestId` is empty, the `useQuery` for `makeFetchLabTestingById` is gated by `enabled: !!watchLabTestId` (line 122), but the lab-test dropdown query is *not* gated. On first paint in edit mode, `labGroup?.id` is set, so this is fine, but on first paint in *create* mode, the form still issues the query — and the result is the same as on subsequent renders. The wasted request is minor; the cache-key drift is the real issue.

  Fix: wrap `getLabTestQueryParams` in `useMemo` keyed on `[isEdit, labGroup?.id, labGroup?.labTestId]`:

  ```tsx
  const params = useMemo(
    () => getLabTestQueryParams(),
    [isEdit, labGroup?.id, labGroup?.labTestId],
  );
  const { data: labTest, isLoading: isLabTestLoading } = useQuery(makeGetLabTest(params));
  ```

  Or hoist `getLabTestQueryParams` to a pure function of `(isEdit, labTestId) | null` and call it from the `useMemo`.

  Evidence: `lab-test-mapping-form.tsx:83-101` — function literal called inline; `useQuery` does not stabilize the input.

- **`lab-test-mapping-form.tsx:222-237` — `<Select value>` fallback uses `labGroup?.id` which is the wrong identity (also see High above) and hides a stale form state**
  The line `value={field.value || (isEdit ? labGroup?.id : undefined)}` overrides the field's empty-string value with the `labGroup.id` whenever `field.value` is falsy. Combined with the High #1 bug, this means: in edit mode, the `<Select>` reports `labGroup.id` (wrong — should be `labGroup.labTestId`) as the selected value. Even if High #1 is fixed, the fallback silently substitutes a value the user did not choose — masking the case where `field.value` was cleared intentionally (e.g. user clicked the `clearable` `x` to "change the lab test"). The form then submits the previous selection without the user realizing.

  Fix: drop the fallback. If `field.value` is empty, show the `<Select>` as empty (with the placeholder "Select Lab Test"), and let the user re-select. If the API response is missing the current test, the `labTestOpts` push-back at line 119 handles visibility — that is the right place to inject the option, not in the `<Select>` `value` prop.

  Evidence: `lab-test-mapping-form.tsx:233` — `value={field.value || (isEdit ? labGroup?.id : undefined)}`; `:198` — `clearable` is set; the user can therefore intentionally clear the field.

### Medium

- **`lab-test-mapping-form.tsx:103-122` — Empty-label fallback when API result lacks the service name**
  The push-back path constructs `{ label: labTestData.service.name, value: labGroup.id }`. If `labTestData.service.name` is empty (a corrupted service row, or a recently-archived service), the `<Select>` renders an option with `label: ""` — which Mantine renders as an empty row in the dropdown. The user sees an empty option and cannot tell what they are editing. Fix: fall back to `labTestData.service.name || "(unnamed test)"` or skip the push-back entirely if `service.name` is empty (and surface a warning toast).

- **`lab-test-mapping-form.tsx:83-101` — `status: "ACTIVE"` is applied even when `labGroup.labTest.isActive === false`**
  The current edit flow expects `includeLabTestId` to bypass the status filter, and the `labTestOpts` push-back to handle the case where the API omits the test. Both work, but only because the test's id is known. If the test was archived (`isActive: false`) and `labTestData` is slow to load, the first render of the `<Select>` shows neither the option nor a "loading" indicator — the dropdown is empty until `labTestData` arrives. The `rightSection={isLabTestLoading && <Loader size={12} />}` handles the loading state, but `isLabTestLoading` refers to the *list* query, not the *by-id* query. The user sees a loader for a fraction of a second and then an empty dropdown with no error.

  Fix: track `isLabTestDataLoading` and show "Loading current selection…" in the placeholder until it resolves. Or remove the `status: "ACTIVE"` filter entirely from the edit branch (it does not buy anything in edit mode — the user can see the inactive flag in the option metadata).

- **`lab-test-query.schema.ts:13-18` — `z.nativeEnum({ ACTIVE: "ACTIVE", INACTIVE: "INACTIVE" })` is a stringly-typed hand-rolled enum**
  `z.nativeEnum({ ACTIVE: "ACTIVE", INACTIVE: "INACTIVE" })` produces an enum whose TypeScript keys are inferred as `string`, defeating Zod's static type narrowing. The actual `LabTest` model has an `isActive Boolean` field, not a status enum — so the schema's `status: "ACTIVE" | "INACTIVE"` is a UI-side convention layered on top. Using `z.enum(["ACTIVE", "INACTIVE"])` would give the same runtime semantics with proper inference and a clearer error message on invalid input. Trivial change, worth doing while touching this file.

- **`lab-test.repository.ts:62` — `this.logger` declared but never used in the diff**
  Pre-existing (not introduced by this PR), but the diff does not take the opportunity to use the logger when the new `where.NOT` clause produces an unexpected result. If `query.excludeLabTestsUsedInTemplates` is true but the query returns zero results in a context where the user expects a non-empty list (e.g. a lab test the user knows exists), the lack of logging means support cannot diagnose the issue from logs. Low priority but flag-worthy.

### Low / Nit

- **`lab-test-mapping-form.tsx:103-122` — Dead branch when `labTestData` is undefined**
  The push-back path is `if (!isCurrentIncluded && labTestData)`. If `labTestData` is `undefined` (test was deleted between list load and by-id fetch), the option is silently not pushed — the `<Select>` is empty in edit mode, and the user does not know why. Better: show an explicit error placeholder like "(current selection unavailable — please contact support)" or a Mantine `Notification`.

- **`lab-test-mapping-form.tsx:233` — Comment "Ensure the current value is properly displayed" is misleading**
  The `value={...}` prop does not "ensure display" — it sets the selected value. Display is driven by `data` (the option list). With the right `data` (via the push-back fallback), the display works. The comment makes a future reader think this prop is load-bearing for visibility, when in fact the `data` push-back is. Either remove the comment or rewrite it to explain *why* the fallback exists.

- **PR title has a typo: "Maping" → "Mapping"**
  Trivial. Re-title the PR (no code change).

## Verification needed

1. **Does the dropdown actually hide already-mapped tests?** Manual test: create two `LabGroup`s via the UI, then create a third and confirm the tests from groups 1 and 2 do not appear. Then check the raw `GET /api/lab-test?excludeLabTestsUsedInTemplates=true` response — does it match?
2. **Concurrent insert race.** Open two browser tabs to the form, both pick the same `(labTestId, specialLabTestId)` pair, both submit. Does the second one succeed silently (bug) or fail with a 409 (correct)? Expected: succeeds today (no DB constraint). If reproduced, the Critical issue is real.
3. **Inactive lab test in edit mode.** Find an `INACTIVE` lab test with a `LabGroup`, open the edit form, confirm the dropdown shows the option (via the push-back fallback). Switch to a `null` `labTestData.service.name` row and confirm the empty-label behavior.
4. **Is `labGroup.id` actually distinct from `labGroup.labTestId` in the data?** Inspect the DB or add a `console.log({ id: labGroup.id, labTestId: labGroup.labTestId })` in the form. If they happen to be the same string, the High #1 bug is silently masked by a coincidental equality.
5. **Schema `excludeLabTestsUsedInTemplates` callers.** `grep -rn "excludeLabTestsUsedInTemplates" hms-app/src` should show exactly one caller (this form). If any other module already passes the flag, the PR's behavioral change is broader than intended.
6. **SonarQube** — the prior PR comment for #2780 noted a failed analysis. Verify this PR has a clean run.

## Cross-references

- **`prisma/schema.prisma:5738-5754`** — `LabGroup` model has no `@@unique([labTestId, specialLabTestId])`. The Critical issue proposes adding one.
- **`prisma/schema.prisma:5745`** — `labTestId` is a column on `LabGroup`, distinct from `id`. The High #1 issue points out the form uses `labGroup.id` where `labGroup.labTestId` is correct.
- **`lab-group.service.ts:34-46`** — `createLabGroup`'s pre-insert check is a SELECT-then-INSERT race. The Critical issue proposes adding a DB unique constraint + handling P2002.
- **`lab-test-mapping.action.ts:9-32`** — action does not wrap service calls in a transaction. Even adding a DB unique constraint, the service would need to handle the resulting P2002 properly.
- **`lab-test.repository.ts:141-143`** — existing `includeLabTestId` override, correctly reused by the new `getLabTestQueryParams` edit branch.
- **`lab-test-mapping-form.tsx:56, 96, 119, 188, 233`** — five places that confuse `labGroup.id` and `labGroup.labTestId`. High #1 lists them.
- **`/Users/pyaesonewin/CLAUDE.md` §Rules** — "ALWAYS read a file before editing it" and "Validate input at system boundaries". The form change reads the file (good) but does not validate at the DB boundary (no unique constraint).

## Checklist results

- [ ] **DB-level uniqueness** — missing. Critical issue.
- [x] Hardcoded secrets — None.
- [x] SQL/Prisma injection — `where.NOT = { labTemplateItems: { some: {} } }` is a safe Prisma relation filter.
- [x] `console.log` / `console.error` — None added in the diff.
- [x] `@ts-ignore` / `@ts-expect-error` / `eslint-disable` — None added.
- [x] `any` type annotations — None added.
- [ ] **Identity confusion (`labGroup.id` vs `labGroup.labTestId`)** — High issue.
- [x] Missing `await` inside transaction callbacks — N/A (no transaction touched).
- [x] Tenant-scope — N/A (no tenant boundary in this query).
- [x] Permission checks — N/A (already gated by the page's `PermissionGuard`).
- [ ] Tests — No tests added; the Critical issue is the kind of regression a unique-constraint integration test would catch.
- [ ] Dead code — Second commit correctly removes the dead `checkExistInLabTemplate` branch (good).
- [ ] React Query correctness — Per-render query object (Medium).

## Recommendation

Block merge until the **Critical** issue is addressed: add a DB-level unique constraint on `LabGroup(labTestId, specialLabTestId)`, update `prisma/schema.prisma` with `@@unique([labTestId, specialLabTestId])`, write a migration, and handle the resulting Prisma `P2002` in `LabGroupService.createLabGroup` as a 409 — the UI-level filter then becomes defense-in-depth, not the only line of defense. Also address **High #1** (`labGroup.id` vs `labGroup.labTestId` confusion across five locations — the form is sending the wrong ID today and the only reason it appears to work is that the previous UI never sent it through the dropdown's `onChange`).

The Medium and Low items are worth fixing in this PR or a follow-up — particularly High #2 (per-render query object breaking cache locality) and High #3 (`<Select value>` fallback that masks intentional clears). After the Critical + High items are fixed, this PR is a clean improvement on a real bug class; the current state is a UI sugar-coating that does not actually prevent the duplicate the ticket describes.
