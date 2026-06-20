# Code Review — PR #17: Add duration feature to daily medicine

Date: 2026-06-19
PR: https://github.com/MyanCare/HMS-Hni-Zi-Gone/pull/17
Branch: `mpt/medicine-form-add-duration` → `development`
Files changed: 11 (+104 / -8)
Risk: **High** (patient-facing form, multiplies drug qty — clinical impact)
Verdict: **Request changes**

## Summary

Adds a `durationDays` field to daily-medicine records. The form multiplies template item `qty` by `durationDays` before saving, surfaces it in the table/detail views, and refuses to save a daily-medicine record without a duration. The plumbing (schema, repo, service) is mostly sound, but there are at least three logic bugs in the form effects that will produce wrong qty values in real use, and one service-level change that changes recompute behavior for every existing record.

## Findings

### H1. `useEffect` watching `durationDays` overwrites user-edited item qty

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:181-191`

```tsx
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

Every time the user types in the `Duration (Days)` field, this effect loops over `template.items` and writes `templateItem.qty * days` into every item — silently discarding any manual `qty` edits the user has already made on the form. Daily-medicine templates set a baseline, but clinicians routinely adjust individual line items (e.g., half a tablet, different strength). With this effect, a single duration change blows away those edits. Even worse, because `templateItem` (from the saved template) is used rather than the current `form` items, the user's edits are also lost when they switch between template items.

**Fix:** Only seed qty from the template on first apply (i.e. when items were just replaced). Track an "applied" flag, or check whether `items` already exist from the template before overwriting:

```tsx
const appliedRef = useRef(false);

useEffect(() => {
  if (appliedRef.current) return;       // don't re-apply on duration changes
  if (!watchedIsDailyMedicine || record) return;
  const template = dailyTemplateData?.result;
  if (!template || !template.items.length) return;

  replace(/* ...template items with qty * durationDays */);
  appliedRef.current = true;
}, [watchedIsDailyMedicine, dailyTemplateData?.result, record]);
```

If a re-multiply on duration change is genuinely intended, it must multiply the **current** `form.items[i].qty` (which may already be edited), not `templateItem.qty`.

### H2. `useEffect` deps are incomplete — won't fire when template loads async

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:181-191` (same block as H1)

The dep array is `[watchedDurationDays]`. The effect reads `dailyTemplateData?.result`, `watchedIsDailyMedicine`, `record`, and `form`. None of these are in the deps. Concretely:

1. User selects a patient → `dailyTemplateData` arrives async → effect does NOT run (days didn't change).
2. User toggles `isDailyMedicine` on → effect does NOT run (days didn't change).

For case (1) the user gets a stale form with no template applied; for case (2) the existing `useEffect([record, ...])` block already calls `replace(...)` when `isDailyMedicine` flips, so H2 specifically is about the duration-multiplier step. The bigger issue is the dependency linter will flag this — `react-hooks/exhaustive-deps` would surface it.

**Fix:** Either include all referenced values in the dep array, or (preferred) restructure so the duration multiplication is a pure function of `(template.items, durationDays)` that only runs on explicit template-apply, as in the H1 fix.

### H3. Service change always triggers recompute for any pre-PR record

`src/app/(dashboard)/shared/medicine/services/medicine-record.service.ts:80-87`

```ts
if (
  existing.patientId !== payload.patientId ||
  existing.doctorId !== payload.doctorId ||
  existing.durationDays !== payload.durationDays ||
  existing.items.length !== payload.items.length
) {
  throw new AppError(...);
}
```

`existing.durationDays` is `Int?` from Prisma → `null` for any record created before this PR. The form's zod schema infers `durationDays?: number` (optional, not nullable), so the first edit of an old record sends `payload.durationDays === undefined`. `null !== undefined` is `true` in JS, so every first edit of a legacy daily-medicine record throws the recompute error.

Two layered bugs:

1. The `throw new AppError(...)` block (which I can't fully see in this diff) presumably forces the client to recompute totals before saving. That is fine for new records, but here it fires spuriously.
2. The comparison mixes `null` (DB) and `undefined` (form). Normalize before comparing.

**Fix:**

```ts
const existingDays = existing.durationDays ?? null;
const payloadDays = payload.durationDays ?? null;
if (
  existing.patientId !== payload.patientId ||
  existing.doctorId !== payload.doctorId ||
  existingDays !== payloadDays ||
  existing.items.length !== payload.items.length
) { ... }
```

Even better: tighten the schema to either `z.number().int().min(1)` (no `.optional()`) when `isDailyMedicine=true`, and `z.undefined()` otherwise — then the form is always in sync with what the service expects.

### H4. `event.currentTarget.blur()` on wheel capture kills accessibility

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:245`

```tsx
onWheelCapture={(event) => event.currentTarget.blur()}
```

This is a copy-paste of an `e.preventDefault()` recipe for "number inputs that change on scroll", but the form uses `type="number"` and the value is not committed until blur, so scrolling over the field dismisses focus entirely. Keyboard users (and screen-reader users) get a surprising focus loss.

**Fix:** Drop the `onWheelCapture` entirely (it's only needed if the input updates on every scroll tick, which this one doesn't). Or use `event.preventDefault()` instead of `blur()` if the goal is just to suppress scroll-induced value changes.

### M1. `defaultValues` reset only runs at mount; switching `record` prop doesn't re-init

`src/app/(dashboard)/medicine/features/components/medicine-form.tsx:107-128`

`useForm({ defaultValues: getInitialValues(record) })` runs once. When the parent re-renders this component with a different `record`, the form keeps the previous record's values (existing behavior, but the diff adds `durationDays: record.durationDays ?? undefined` to the initializer, exposing the issue). There's also no `form.reset()` call anywhere visible in the diff. If this form is reused for an edit-then-create flow, the user would see the previously-edited record's `durationDays` in the new record.

**Fix:** Either call `form.reset(getInitialValues(record))` in a `useEffect([record?.id])`, or remount the component via `key={record?.id ?? "new"}` at the call site.

### M2. Zod schema uses `preprocess` to coerce, but form sends `undefined` for blank

`src/app/(dashboard)/shared/medicine/schemas/medicine/medicine-record-form.schema.ts:67-79`

```ts
durationDays: z.preprocess(
  (value) => {
    if (value === "" || value === undefined || value === null) return undefined;
    const parsedValue = Number(value);
    return Number.isNaN(parsedValue) ? undefined : parsedValue;
  },
  z.number({ invalid_type_error: "Duration (Days) is required" })
    .int("Please enter a whole number")
    .min(1, "Duration (Days) must be at least 1")
    .optional(),
),
```

`z.number().optional()` combined with `preprocess` that already normalizes empty input to `undefined` means the `.min(1)` validator never runs for the missing case — and the refine in `validateDurationDaysRequirement` is the only thing catching the missing-when-daily case. That's fine, but the `min(1)` validator is unreachable for `undefined` inputs. Also, the `invalid_type_error` is dead code because preprocess always returns either `undefined` or a `number`. Strip the noise:

```ts
durationDays: z
  .preprocess(blankToUndefined, z.coerce.number().int().min(1))
  .optional(),
```

Then enforce "required when daily" exclusively via `superRefine`.

### M3. Detail grid went from 3 cols to 4 cols at `md`, no responsive review

`src/app/(dashboard)/medicine/features/components/medicine-record-detail.tsx:17`

`grid-cols-1 md:grid-cols-4` — fine on `md+`, but at exactly the `md` breakpoint (768px) four columns may squeeze the labels. The container has `minWidth={1000}` on the inner table scroll container, so the overall page is wider than `md` and 4 cols fits, but worth a visual check.

### M4. Column header string has a literal slash and space

`src/app/(dashboard)/medicine/features/components/medicine-record-columns.tsx:54-61`

```ts
{
  id: "Duration (Days)",
  header: "Duration (Days)",
  accessorFn: (row) => row.durationDays ?? "-",
},
```

Same pattern as in the external-charges PR. The header reads `"Duration (Days)"` (fine), but if exported as CSV, the parens and the dash placeholder can confuse downstream parsers. Consider `accessorFn` returning `row.durationDays ?? ""` and rendering `row.durationDays ? row.durationDays : "-"` in the cell so CSV export stays numeric.

### L1. Migration uses non-deterministic default for backfill

`prisma/migrations/20260618153923_add_duration_days_to_medicine_record/migration.sql`

`ADD COLUMN "duration_days" INTEGER` (nullable) — fine for the additive change. No backfill needed since the column is optional. No action required; flagged only because the external-charges PR (#18) does the opposite pattern and it's worth being explicit that this PR's choice is the correct one.

## Recommendations

1. Decide whether duration-days changes should re-multiply item qty. If yes, use the **current** `form.items[i].qty` (preserving user edits), not `templateItem.qty`. If no (recommended), apply the multiplier only on template-apply and guard with a ref.
2. Normalize `null` vs `undefined` for `durationDays` in the service comparison (H3).
3. Drop the `onWheelCapture={blur}` anti-pattern (H4) — it's an accessibility regression.
4. Tighten the zod schema (M2) so the validators actually fire.
5. Add an integration test that covers the full daily-medicine happy path: patient → template applied → duration set → qty multiplied → record saved → record reopened → values still match.

## Test plan checklist

- [ ] New daily-medicine record with `durationDays = 5` and a template of 2 items → saved `qty` = template qty × 5 for each item.
- [ ] Edit an existing daily-medicine record, change `durationDays`, manually edit one item's qty, save → manual qty edit is preserved (or, if product decision is "re-multiply on change", confirm it's documented and tested).
- [ ] Switch `isDailyMedicine` off → `durationDays` cleared and not submitted.
- [ ] Switch `isDailyMedicine` on → `durationDays` defaults to `1`.
- [ ] Submit daily-medicine record with `durationDays = ""` → form blocks submit with "Duration (Days) is required".
- [ ] Edit a **legacy** record (created before this PR) where `duration_days` is `null` → no spurious recompute error.
- [ ] Table and detail pages show `Duration (Days)` column.
- [ ] Keyboard-only user can increment duration without losing focus.