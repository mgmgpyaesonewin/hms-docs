# Code Review — PR #17: Add duration feature to daily medicine (re-review)

**Date:** 2026-06-20
**PR:** https://github.com/MyanCare/HMS-Hni-Zi-Gone/pull/17
**Branch:** `mpt/medicine-form-add-duration` → `development`
**Files changed:** 11 (+105 / −4)
**Risk:** **High** (patient-facing form, multiplies drug qty — clinical impact)
**Verdict:** **Request changes** — H3 was correctly fixed, but H1, H2, H4, M2 remain unfixed. Re-review needed.

## Summary

Adds a `durationDays` field to daily-medicine records. The form multiplies template item `qty` by `durationDays` before saving, surfaces it in the table/detail views, and refuses to save a daily-medicine record without a duration. The post-review fix commit (`974b0697`) made real progress on H3 (the null/undefined comparison in the service is now correctly normalized on both sides), but the substantive form-side bugs — overwriting user-edited qty on every duration keystroke, incomplete effect deps, the a11y-regressive `onWheelCapture={blur}`, and dead zod validators — were not addressed. Only an explanatory comment and an `eslint-disable-next-line` were added.

## Findings

### H1. `useEffect` watching `durationDays` still overwrites user-edited item qty

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:181-197`

```tsx
// eslint-disable-next-line react-hooks/exhaustive-deps
useEffect(() => {
  if (!watchedIsDailyMedicine || record) return;
  const template = dailyTemplateData?.result;
  if (!template) return;

  template.items.forEach((templateItem, index) => {
    form.setValue(
      `items.${index}.qty`,
      templateItem.qty * (watchedDurationDays || 1),
    );
  });
}, [watchedDurationDays]);
```

The "fix" commit added an explanatory comment but the effect body is unchanged. Every duration keystroke loops over `template.items` and overwrites any manual `qty` edits the user has made on individual line items. Clinicians routinely adjust individual qty values (half-tablet, different strength); a single duration change blows those edits away. The comment claims "the initial template apply is handled by the effect above via `replace()`" — true for the FIRST apply, but this effect then runs again on every keystroke and uses `templateItem.qty` (from the saved template), not the current `form.items[i].qty`, so any post-apply edits are silently lost.

**Fix:** Apply the multiplier only on first template-apply (or multiply the **current** `form.items[i].qty`, not `templateItem.qty`):

```tsx
const appliedRef = useRef(false);

useEffect(() => {
  if (appliedRef.current) return;
  if (!watchedIsDailyMedicine || record) return;
  const template = dailyTemplateData?.result;
  if (!template || !template.items.length) return;
  // single apply on template change; do not re-run on duration keystrokes
  appliedRef.current = true;
}, [watchedIsDailyMedicine, dailyTemplateData?.result, record]);
```

Then either (a) bake `durationDays` into the qty at template-apply time and never touch it again, or (b) if the product decision is "re-multiply on duration change", do so via `form.getValues("items")[i].qty` so user edits are preserved.

### H2. Effect deps remain incomplete — only suppressed by an eslint comment

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:181-197` (same block)

The dep array is `[watchedDurationDays]`. The effect body reads `watchedIsDailyMedicine`, `record`, `dailyTemplateData?.result`, and `form`. None of these are in the deps. The fix commit silenced the linter via `// eslint-disable-next-line` — that is suppression, not a fix.

Concrete broken cases:
- User selects a patient → `dailyTemplateData` arrives async → effect does NOT run (days didn't change).
- User switches patient after entering a duration → closure over stale `template`.

**Fix:** Restructure per H1 so the duration multiplication is a pure function of explicit events, or include all referenced values and reset on patient change.

### H3. *(Resolved)* Service comparison null vs undefined

`src/app/(dashboard)/shared/medicine/services/medicine-record.service.ts:83`

```ts
(existing.durationDays ?? null) !== (payload.durationDays ?? null) ||
```

The fix commit normalized **both** sides, exactly as the previous review requested. `null !== undefined` is now `false`, so the first edit of a legacy daily-medicine record (DB has `null`, form sends `undefined`) will not throw the spurious 400.

**Status:** Fixed in commit `974b0697`. The companion note in `update-medicine-record.schema.ts` ("durationDays is fixed at creation and never user-editable afterwards") explains why the form does not re-validate this field on update — sensible.

### H4. `onWheelCapture={blur}` a11y regression still present

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:257`

```tsx
onWheelCapture={(event) => event.currentTarget.blur()}
```

Same as before. Keyboard and screen-reader users lose focus on scroll over the duration field. The input is `type="number"` and the value is not committed until blur, so scrolling over it dismisses focus entirely. Drop the prop (it is only needed if the input updates on every scroll tick, which this one does not).

### M1. `ensureRecordExists` may not select `durationDays` (NEW, plausible)

`src/app/(dashboard)/shared/medicine/services/medicine-record.service.ts:80-87`

The service now reads `existing.durationDays` (H3 fix). But the diff does not touch the `ensureRecordExists` method or the repository's `select`/`include` for the medicine record lookup. If the new column is not in the include, `existing.durationDays` is `undefined` for every record — `undefined !== 1` is `true`, and the H3 fix is moot.

**Fix:** Verify `durationDays: true` is in the Prisma `select`/`include` of `ensureRecordExists`. Add a regression test that opens a record with `durationDays = null` in DB, edits batches only, saves — must succeed.

### M2. Zod dead validators still present

`src/app/(dashboard)/shared/medicine/schemas/medicine/medicine-record-form.schema.ts:67-80`

```ts
durationDays: z.preprocess(
  (value) => {
    if (value === "" || value === undefined || value === null) return undefined;
    const parsedValue = Number(value);
    return Number.isNaN(parsedValue) ? undefined : parsedValue;
  },
  z
    .number({ invalid_type_error: "Duration (Days) is required" })
    .int("Please enter a whole number")
    .min(1, "Duration (Days) must be at least 1")
    .optional(),
),
```

`z.number().optional()` skips all validators for `undefined` (the only path the preprocess routes blanks to). The `int()` and `min(1)` are unreachable for the form's actual inputs. The `invalid_type_error` is dead code because preprocess never returns anything other than `undefined` or `number`. The "required when daily" case is caught only by `superRefine(validateDurationDaysRequirement)`.

**Fix:**

```ts
durationDays: z
  .preprocess(blankToUndefined, z.coerce.number().int().min(1))
  .optional(),
```

Then enforce "required when daily" exclusively via `superRefine`.

### M3. Two competing multiplication sites

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:168` (inside the `replace()` callback):

```ts
qty: item.qty * (form.getValues("durationDays") || 1),
```

The same multiplication happens in the second effect (H1). Pick one — if qty is fixed at apply time, delete the second effect; otherwise drop the multiplier in `replace()`.

### M4. `defaultValues` reset on `record` prop change

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:107-128`

`useForm({ defaultValues: getInitialValues(record) })` runs once. When the parent re-renders this component with a different `record`, the form keeps the previous record's values. The diff adds `durationDays: record.durationDays ?? undefined` to the initializer, exposing the issue.

**Fix:** Either call `form.reset(getInitialValues(record))` in a `useEffect([record?.id])`, or remount the component via `key={record?.id ?? "new"}` at the call site.

### M5. Detail grid went from 3 cols to 4 cols at `md`

`src/app/(dashboard)/medicine/features/components/medicine-record-detail.tsx:17`

`grid-cols-1 md:grid-cols-4` — fine on `md+`, but at exactly the `md` breakpoint (768px) four columns may squeeze the labels. The container has `minWidth={1000}` on the inner table scroll container, so the overall page is wider than `md` and 4 cols fits, but worth a visual check.

### L1. Column header string `"Duration (Days)"` used as TanStack column id

`src/app/(dashboard)/medicine/features/components/medicine-record-columns.tsx:57-61`

```ts
{ id: "Duration (Days)", header: "Duration (Days)", accessorFn: (row) => row.durationDays ?? "-" }
```

Same pattern as in the external-charges PR. Use the field name as the id (`durationDays`) and the label only in `header`. The `?? "-"` accessor returns a string instead of a number, which will sort lexicographically if the column is made sortable later.

### L2. Migration pattern is correct

`prisma/migrations/20260618153923_add_duration_days_to_medicine_record/migration.sql`

`ADD COLUMN "duration_days" INTEGER` (nullable) — fine for the additive change. No backfill needed since the column is optional. No action required.

## Recommendations

1. **Re-review required.** The "fix: PR review" commit addressed only H3 (correctly) and added comments/eslint-disables elsewhere. H1, H2, H4, M2 still need real fixes.
2. Decide the product question: should changing duration re-multiply item qty? If yes, multiply the **current** `form.items[i].qty` (preserving user edits), not `templateItem.qty`. If no (recommended), apply the multiplier only on template-apply and guard with a ref.
3. Verify `durationDays` is in the Prisma `select`/`include` for `ensureRecordExists` (M1).
4. Tighten the zod schema (M2) so the validators actually fire.
5. Drop the `onWheelCapture={blur}` anti-pattern (H4).
6. Add an integration test that covers the full daily-medicine happy path: patient → template applied → duration set → qty multiplied → record saved → record reopened → values still match.

## Test plan checklist

- [ ] New daily-medicine record with `durationDays = 5`, 2-item template → saved `qty` = template qty × 5 for each item.
- [ ] Edit daily-medicine record, change duration, manually edit one item's qty, save → manual qty edit preserved (currently overwritten — H1).
- [ ] Switch `isDailyMedicine` off → `durationDays` cleared and not submitted.
- [ ] Switch `isDailyMedicine` on → `durationDays` defaults to `1`.
- [ ] Submit daily-medicine record with `durationDays = ""` → form blocks submit with "Duration (Days) is required".
- [ ] Edit a **legacy** record (pre-PR, `duration_days = null`) → no spurious 400 (H3 fixed; verify with regression test).
- [ ] Table and detail pages show `Duration (Days)` column.
- [ ] Keyboard-only user can increment duration without losing focus (currently broken — H4).
- [ ] Switch patient after entering a duration → multiplier does not use previous template's `qty` (H2).

## Compared to previous review (2026-06-19)

| Previous ID | Status | Notes |
|---|---|---|
| **H1** qty overwrite on duration change | **Not fixed** | Effect body unchanged; only a comment and eslint-disable added. Behaviour unchanged. |
| **H2** incomplete deps | **Not fixed** | Suppressed via `// eslint-disable-next-line` instead of corrected. |
| **H3** null vs undefined | **Fixed** | Both sides now `?? null` in the service comparison. Verified at `medicine-record.service.ts:83`. |
| **H4** `onWheelCapture={blur}` a11y regression | **Not fixed** | Same handler. |
| **M1** defaultValues reset on record-prop change | Not addressed | Apply `key={record?.id ?? "new"}` at the call site. |
| **M2** zod dead validators | **Not fixed** | Same preprocess + `.optional()` pattern; `int()`/`min(1)` still unreachable for `undefined` inputs. |
| **M3** grid-cols 3→4 responsive | Not addressed | Visual check at `md` breakpoint. |
| **M4** column header parens for CSV | Not addressed | Cosmetic. |
| **L1** migration pattern | OK | Nullable add, no backfill — correct. |
| **NEW M1** `ensureRecordExists` must select `durationDays` | NEW | Plausible — verify by reading the service's repository include. |
| **NEW M3** two competing multiplication sites | NEW | `replace()` and second effect both multiply. Pick one. |
| **NEW**: schema update path skips `durationDays` re-validation | Documented | Update schema comment explains why — sensible. |