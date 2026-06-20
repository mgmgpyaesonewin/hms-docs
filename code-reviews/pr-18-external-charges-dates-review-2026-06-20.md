# Code Review — PR #18: Appt/admission date and discharge date to external charges (re-review)

**Date:** 2026-06-20
**PR:** https://github.com/MyanCare/HMS-Hni-Zi-Gone/pull/18
**Branch:** `mpt/add-admission-appt-date` → `development`
**Files changed:** 16 (+309 / −188)
**Risk:** **Medium** (mandatory NOT NULL migration on a financial module; behavioural change to date-range filter; cross-cutting UI rewiring)
**Verdict:** **Request changes** — post-review fix commit made real progress on access-control and migration lock concerns, but the user-visible date-handling bugs (TZ shift, off-by-one filter) are still open.

## Summary

Adds two new columns to `external_hospital_charges`: required `appt_admission_date` and optional `discharge_date`. Surfaces them in the form, table, and a new dedicated `/external-charges/[id]` detail page that replaces the previous in-modal view. Cross-layer wiring (Prisma → repository → service → schema → action → form) is mostly consistent and the type is plumbed through everywhere.

The post-review fix commit (`13abaae3`, "fix: PR review") addressed:
- Added `View`/`Delete` permission checks on the new API routes.
- Switched the migration to a `NOT VALID` check constraint → `VALIDATE` → `SET NOT NULL` → `DROP CONSTRAINT` pattern so `SET NOT NULL` doesn't take an `ACCESS EXCLUSIVE` rewrite lock.
- Added `requiredDate` / `optionalDate` zod preprocessors to the second-stage schema.

It did **not** address: the date-range filter still lacks `dayjs.startOf/endOf` normalization (off-by-one across timezones); `Date.toISOString()` is still used to round-trip the form date (TZ shift for non-UTC users); the `optionalDateField` constant is still a duplicate of `optionalAmountField`; and the create/update `formData` schemas remain duplicated.

## Findings

### H1. Date-range filter uses `apptAdmissionDate` without `startOf/endOf` normalization

`src/app/(dashboard)/shared/external-charges/repositories/external-hospital-charge.repository.ts:65-67`

```ts
if (query.start && query.end) {
  where.apptAdmissionDate = { gte: query.start, lte: query.end };
}
```

Two problems compound here:

1. **Silent semantic change.** Pre-PR the filter was `createdAt` (when the row was inserted). Post-PR it filters by `apptAdmissionDate` (the actual visit date, which for backfilled rows equals `created_at` but for new rows can be arbitrarily earlier). Operators with muscle memory around "last week" will miss charges.
2. **Off-by-one across timezones.** `query.start` / `query.end` are day-precision dates from a `DateInput`. Without `dayjs(query.start).startOf("day")` / `endOf("day")`, the `lte` boundary compares `apptAdmissionDate <= 2026-06-30T00:00:00.000Z` against rows whose Asia/Rangoon midnight on 30 Jun is `2026-06-30T17:00:00.000Z` — those rows **fail** the `lte` and get dropped.

The previous review flagged this and it wasn't addressed.

**Fix:**

```ts
import dayjs from "dayjs";
...
if (query.start && query.end) {
  where.apptAdmissionDate = {
    gte: dayjs(query.start).startOf("day").toDate(),
    lte: dayjs(query.end).endOf("day").toDate(),
  };
}
```

And document the semantic change in the release notes / PR body so operators aren't blindsided.

### H2. `Date.toISOString()` round-trip silently shifts dates for non-UTC users

`src/app/(dashboard)/external-charges/features/components/external-charges-form.tsx:152`

```ts
fd.append(k, v instanceof Date ? v.toISOString() : String(v));
```

`@mantine/dates` `DateInput` returns a `Date` at **user-local** midnight. `toISOString()` converts to UTC, which for Myanmar (UTC+6:30) shifts `2026-06-30` → `2026-06-29T17:30:00.000Z`. Prisma stores that as `2026-06-29 17:30:00.000` and the detail page's `dayjs(charge.apptAdmissionDate).format("DD MMM YYYY")` renders `29 Jun 2026` instead of `30 Jun 2026`.

The previous review flagged this as M1 and the fix commit did not address it.

**Fix (pick one):**

```ts
// Option A: emit YYYY-MM-DD only (lose time-of-day)
fd.append(k, v instanceof Date ? dayjs(v).format("YYYY-MM-DD") : String(v));
```

…and switch the Prisma column to `DATE` instead of `TIMESTAMP(3)` (the time portion is meaningless for an admission date anyway). Then both `requiredDate` / `optionalDate` zod schemas should drop `z.coerce.date()` in favor of `z.coerce.string().regex(/^\d{4}-\d{2}-\d{2}$/)` parsed with dayjs.

### H3. `apptAdmissionDate` validation only at second-stage schema — action layer accepts blank strings

`src/app/(dashboard)/external-charges/features/external-charges.action.ts:32-86`

The new `zfd` schema adds `apptAdmissionDate: zfd.text()` (no transform) to both create and update. But `zfd.text()` for a date field passes the raw string straight to the second-stage `createExternalHospitalChargeSchema` / `updateExternalHospitalChargeSchema` parse. That second-stage parse uses `requiredDate` (defined in `base-external-hospital-charge.schema.ts`) which does `z.coerce.date()` — but only **after** `blankToUndefined`. The `blankToUndefined` preprocess converts empty strings to `undefined`, so an empty `apptAdmissionDate` from the form **silently passes** the action's first parse, **fails** the second parse, and the user sees a generic `"Appt/ Admission Date is required"` error.

This is partly defensive (M2 from the previous review), but the chain still allows the form to submit an empty value before the second-stage schema rejects it, which means **race conditions or partial state** are possible if the second-stage schema is ever bypassed. The right fix is to validate the date in the `zfd` layer too:

```ts
const requiredDateField = zfd
  .text()
  .transform((v, ctx) => {
    if (!v) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Appt/ Admission Date is required" });
      return z.NEVER;
    }
    const d = new Date(v);
    if (isNaN(d.getTime())) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Appt/ Admission Date is required" });
      return z.NEVER;
    }
    return d;
  });
```

### M1. `optionalDateField` is byte-identical to `optionalAmountField`

`src/app/(dashboard)/external-charges/features/external-charges.action.ts:12-19`

```ts
const optionalAmountField = zfd.text(z.string().optional()).transform((v) => (v === "" ? undefined : v));
const optionalDateField  = zfd.text(z.string().optional()).transform((v) => (v === "" ? undefined : v));
```

Two names, same body. Drop one (and inline the other at both call sites — the abstraction earns nothing):

```ts
const blankToUndefined = zfd.text(z.string().optional()).transform((v) => (v === "" ? undefined : v));
// then use blankToUndefined for both amount and date optional fields
```

The previous review flagged this as M3 and it was not fixed.

### M2. Create and update `zfd` schemas are duplicated

`src/app/(dashboard)/external-charges/features/external-charges.action.ts:16-30` (create) and `:71-86` (update)

The same 12-key `formData` shape is repeated. Adding a 13th field in the future means editing both copies. The previous review flagged this as M4 and it was not fixed.

**Fix:**

```ts
const baseChargeFormData = zfd.formData({
  patientId: zfd.text(),
  invoiceNo: zfd.text(z.string().optional()),
  hospitalName: zfd.text(),
  apptAdmissionDate: requiredDateField,
  dischargeDate: blankToUndefined,
  externalPharmacyAmount: blankToUndefined,
  // ... rest of fields
  remark: zfd.text(z.string().optional()),
});

const updateChargeFormData = baseChargeFormData.extend({ id: zfd.text() });
```

### M3. Detail page `charge[f.name]!.toLocaleString()` uses non-null assertion on a record lookup

`src/app/(dashboard)/external-charges/features/components/external-charges-detail.tsx:84-87`

```ts
{charge[f.name] ? charge[f.name]!.toLocaleString() : ""}
```

TypeScript can't narrow `charge[f.name]` from `number | null` to `number` through a computed property access on a record. The `!` non-null assertion is a TS escape hatch. Safer:

```ts
const value = charge[f.name];
<Text fz="sm">{value != null ? value.toLocaleString() : ""}</Text>
```

### M4. CSV export row has `Discharge Date` but table UI doesn't render that column

`src/app/(dashboard)/external-charges/features/components/external-charges-table.tsx:84-95` (format) vs `external-charges-columns.tsx:11-21` (columns)

```ts
// table.tsx CSV format
"Appt/ Admission Date": dayjs(row.apptAdmissionDate).format("DD MMM YYYY"),
"Discharge Date": row.dischargeDate ? dayjs(row.dischargeDate).format("DD MMM YYYY") : "",
```

The on-screen TanStack columns render an "Appt/ Admission Date" column using `apptAdmissionDate` but **no** Discharge Date column. CSV will contain a column the UI doesn't show — inconsistent for users comparing screen to export.

**Fix:** Add a `dischargeDate` column to `ExternalChargesColumns`, or remove `Discharge Date` from the format map. The previous review flagged this as L2 and it was not fixed.

### L1. Column header string `"Appt/ Admission Date"` used as both TanStack column id and visible label

`src/app/(dashboard)/external-charges/features/components/external-charges-columns.tsx:13-21`

```ts
{
  id: "Appt/ Admission Date",
  header: () => <div className="w-28">Appt/ Admission Date</div>,
  ...
}
```

Same issue as PR #17 M4: spaces and a slash in a column key will surface in CSV exports and any analytics pipeline that keys on column id. Use the field name as the id and the label only in `header`:

```ts
{ id: "apptAdmissionDate", header: () => <div className="w-28">Appt / Admission Date</div>, ... }
```

### L2. `blankToUndefined` helper duplicated between formData and base-external-hospital-charge schema

`src/app/(dashboard)/shared/external-charges/schemas/external-hospital-charge/base-external-hospital-charge.schema.ts:15-22`

```ts
const blankToUndefined = (val: unknown) =>
  val === "" || val === null || val === undefined ? undefined : val;

const requiredDate = z.preprocess(blankToUndefined, z.coerce.date({...}));
const optionalDate = z.preprocess(blankToUndefined, z.coerce.date().optional());
```

A near-identical `blankToUndefined` is also implicitly inlined in the formData layer (`transform((v) => (v === "" ? undefined : v))`). Consolidate to one shared helper.

### L3. `deleteCharge` action doesn't invalidate the `/external-charges/[id]` cache

`src/app/(dashboard)/external-charges/features/external-charges.action.ts:114-132`

After a delete, `revalidatePath("/external-charges")` invalidates the list but a stale entry on `/external-charges/<id>` will still render for a user with the URL open. Add `revalidatePath("/external-charges/[id]", "page")` or similar dynamic revalidation.

## Recommendations

1. Normalize the date-range filter with `dayjs.startOf("day")` / `endOf("day")` and document the semantic shift from `createdAt` to `apptAdmissionDate` in release notes (H1).
2. Switch the Prisma column to `DATE` and emit `YYYY-MM-DD` from the form, so the `toISOString()` timezone shift goes away entirely (H2).
3. Add `apptAdmissionDate` validation to the `zfd` action schemas so blank dates can't reach the service layer (H3).
4. De-duplicate `optionalAmountField` / `optionalDateField` (M1) and the create/update `zfd` schemas (M2).
5. Replace the `!` non-null assertion in the detail page (M3).
6. Either render the `Discharge Date` column or remove it from the CSV (M4).

## Test plan checklist

- [ ] Operator filters by "last 7 days" — result set matches the rows they used to see under the `createdAt` filter, OR the divergence is documented in release notes.
- [ ] User in `Asia/Rangoon` selects `2026-06-30` in the form → DB row stores `appt_admission_date = 2026-06-30` and detail page renders `30 Jun 2026`.
- [ ] User without `View External Charges` permission is blocked at the API endpoint (already fixed in commit `13abaae3` — verify with integration test).
- [ ] User without `Delete External Charges` permission cannot delete via API (verify with the new `permissions` block on `DELETE` route).
- [ ] Submitting the form with `apptAdmissionDate` blank returns the field-level error from the action layer, not a generic 500.
- [ ] Selecting a discharge date earlier than the admission date → form blocks submit with the cross-field error.
- [ ] Empty `dischargeDate` → form submits, DB row has `discharge_date = NULL`.
- [ ] CSV export columns match what's visible on screen (no `Discharge Date` column unless it's rendered in the table).
- [ ] Migration runs against a copy of production data and `apptAdmissionDate` is `NOT NULL` with no NULL rows after backfill.
- [ ] `getChargeById` for an id the requester has no permission to view returns 403, not 404 or 200-with-data.

## Compared to previous review (2026-06-19)

| Finding | Severity then | Status now | Notes |
|---|---|---|---|
| H1. New `GET` endpoint missing role-based permission | High | **Fixed** | Diff shows `permissions: [{ action: "View", subject: "External Charges" }]` on the new `GET` handler; `DELETE` and the list `GET` also gained explicit permissions. |
| H2. Date-range filter silently moved to `apptAdmissionDate` | High | **Partially fixed** | The semantic change was made, but the fix commit did **not** add `dayjs.startOf/endOf` normalization. Still a High. |
| H3. `SET NOT NULL` acquires `ACCESS EXCLUSIVE` lock | High | **Fixed** | Migration now uses `ADD CONSTRAINT ... CHECK ... NOT VALID` → `VALIDATE CONSTRAINT` → `SET NOT NULL` → `DROP CONSTRAINT`. This is the canonical Postgres pattern to avoid the rewrite lock. |
| M1. `Date` round-trip via `toISOString()` TZ shift | Medium | **Not fixed** | Form still calls `v.toISOString()`. Same issue. Promoted to High in this review because it's the most user-visible defect for Myanmar users. |
| M2. Server action accepts any non-empty string | Medium | **Partially fixed** | `baseExternalHospitalChargeSchema` now has `requiredDate` / `optionalDate` zod preprocessors. But the `zfd` action schemas still use `zfd.text()` with no validation, so the second-stage schema is the only guard. Still H3 in this review. |
| M3. `optionalDateField` is duplicate of `optionalAmountField` | Medium | **Not fixed** | The constants are still byte-identical. |
| M4. Create/update `zfd` schemas duplicated | Medium | **Not fixed** | Still 12-key duplicated formData. |
| M5. `charge[f.name]!.toLocaleString()` non-null assertion | Medium | **Not fixed** | Same code. Now M3. |
| M6. `params: Promise<...>` Next 15+ only | Medium | **N/A** | Pre-existing codebase pattern; not a PR blocker. |
| L1. Column header string with `/` and spaces | Low | **Not fixed** | Still `"Appt/ Admission Date"` as id. |
| L2. CSV has `Discharge Date`, UI doesn't | Low | **Not fixed** | Same code. Now M4 (elevated because the inconsistency is user-visible). |
| L3. `ActionIcon` as `Link` missing `aria-label` | Low | **Not fixed** | Cosmetic a11y. |
| L4. Column `w-28` too narrow on mobile | Low | **Not fixed** | Cosmetic. |