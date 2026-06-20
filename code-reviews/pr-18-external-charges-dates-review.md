# Code Review — PR #18: Appt/admission date and discharge date to external charges

Date: 2026-06-19
PR: https://github.com/MyanCare/HMS-Hni-Zi-Gone/pull/18
Branch: `mpt/add-admission-appt-date` → `development`
Files changed: 15 (+281 / -186)
Risk: **Medium** (data shape change for a financial module, mandatory NOT NULL migration)
Verdict: **Request changes**

## Summary

Adds two new columns to `external_hospital_charges`: required `appt_admission_date` and optional `discharge_date`. Surfaces them in the form, table, and a new dedicated `/external-charges/[id]` detail page (replacing the previous in-modal view). The wiring is mostly consistent across form → action → service → repository, but several decisions need a closer look: the new `GET` endpoint has no role-based authorization, the date-range filter was silently changed from `createdAt` to `apptAdmissionDate`, and the timezone handling around `DateInput` → `toISOString()` will shift dates for users outside UTC.

## Findings

### H1. New `GET /api/external-hospital-charges/[id]` ships without role-based permission check

`src/app/api/(external-charges)/external-hospital-charges/[id]/route.ts:6-17`

```ts
export const GET = enhancedApiHandler(
  { auth: { required: true } },
  async (_req, _validated, { params }: { params: Promise<{ id: string }> }) => {
    const { id } = await params;
    const charge = await externalHospitalChargeService.getChargeById(id);
    ...
  },
);
```

`auth: { required: true }` only checks that the requester is logged in. The page wrapper at `src/app/(dashboard)/external-charges/[id]/page.tsx:10-13` correctly guards the UI with `PermissionGuard action="View" subject="External Charges"`, but a malicious user who guesses the cuid-style id (or who pulls one from a leaked URL) can hit the JSON endpoint directly and read full patient + financial data. Every other endpoint in this file should be checked the same way; at minimum, this one is now an unauthenticated-data exfiltration hole for the API surface.

**Fix:** Verify the subject/action in the handler, or call out to a shared authorization helper:

```ts
import { authorize } from "@/lib/authorize";

export const GET = enhancedApiHandler(
  { auth: { required: true } },
  async (req, validated, { params }: { params: Promise<{ id: string }> }) => {
    await authorize(req, "View", "External Charges");
    ...
  },
);
```

Match the convention used by the sibling `POST`/`PATCH`/`DELETE` routes in the same module.

### H2. Date-range filter silently moved from `createdAt` to `apptAdmissionDate`

`src/app/(dashboard)/shared/external-charges/repositories/external-hospital-charge.repository.ts:63-67`

```ts
if (query.start && query.end) {
  where.apptAdmissionDate = { gte: query.start, lte: query.end };
}
```

Pre-PR this filtered by `createdAt` (when the row was inserted). Post-PR it filters by `apptAdmissionDate` (when the patient actually visited). Same UI, different semantic — every existing operator who built muscle memory around "rows from last week = `createdAt` last week" will silently miss charges.

Two distinct concerns:

1. **No operator-facing note** in the PR body or migration log. This is a behavioral change to a list filter, not just a column add.
2. **`apptAdmissionDate` is `gte`/`lte` with `Date` objects from `query.start` / `query.end`** — those are presumably day-precision dates (`YYYY-MM-DD` from a date picker). Without explicit `.startOf('day')` / `.endOf('day')` on the boundary values, a query for "2026-06-01 to 2026-06-30" will compare `apptAdmissionDate >= 2026-06-01T00:00:00.000Z` against rows that have `apptAdmissionDate = 2026-06-30T23:30:00+06:30` (Asia/Rangoon), which due to timezone conversion becomes `2026-06-30T17:00:00.000Z` and is included — but the inverse direction has subtle off-by-one risk depending on user TZ.

**Fix:**
1. Mention the filter semantic change in the PR description / release notes.
2. Normalize the range in the repository:

```ts
where.apptAdmissionDate = {
  gte: dayjs(query.start).startOf("day").toDate(),
  lte: dayjs(query.end).endOf("day").toDate(),
};
```

### H3. `SET NOT NULL` migration acquires `ACCESS EXCLUSIVE` lock and rewrites the table

`prisma/migrations/20260618161746_add_appt_admission_discharge_date_to_external_charges/migration.sql:2-9`

```sql
ALTER TABLE "external_hospital_charges" ADD COLUMN "appt_admission_date" TIMESTAMP(3);
...
UPDATE "external_hospital_charges" SET "appt_admission_date" = "created_at" WHERE "appt_admission_date" IS NULL;
ALTER TABLE "external_hospital_charges" ALTER COLUMN "appt_admission_date" SET NOT NULL;
```

On a non-trivial table, `SET NOT NULL` after a backfill requires a full table scan to verify no NULLs exist, holding `ACCESS EXCLUSIVE` for the duration. On a healthcare DB this means the table is read-blocked during deploy. Three options:

1. **Run the backfill in batches** outside the migration, then add `NOT NULL` once zero NULLs remain.
2. **Use `NOT NULL DEFAULT now()`** in the `ADD COLUMN` step and skip the manual UPDATE. Postgres 11+ uses the default for existing rows without a rewrite.
3. **Document** that this is a maintenance-window migration.

The current migration is fine for a development / staging environment but should be flagged before prod rollout.

**Fix (preferred):** collapse to two statements using the default-fills-existing pattern, then add the constraint separately:

```sql
-- Step 1: add with default (no rewrite on PG 11+)
ALTER TABLE "external_hospital_charges"
  ADD COLUMN "appt_admission_date" TIMESTAMP(3) NOT NULL DEFAULT now();

-- Step 2: optional — drop default to keep inserts explicit
ALTER TABLE "external_hospital_charges" ALTER COLUMN "appt_admission_date" DROP DEFAULT;
```

The default-fills-existing behavior on PG 11+ is documented and avoids the explicit UPDATE.

### M1. `Date` round-trip via `toISOString()` produces timezone-dependent dates

`src/app/(dashboard)/external-charges/features/components/external-charges-form.tsx:152`

```ts
fd.append(k, v instanceof Date ? v.toISOString() : String(v));
```

`DateInput` from `@mantine/dates` produces a `Date` object representing midnight in the **user's** local timezone. `toISOString()` converts to UTC. For a Myanmar user (UTC+6:30), `2026-06-30` selected in the form becomes `2026-06-29T17:30:00.000Z`, which Prisma then writes as the previous calendar day in UTC.

The detail view reads back `dayjs(charge.apptAdmissionDate).format("DD MMM YYYY")` which re-renders in the server's timezone (or the user's, depending on hydration). The net effect: a patient admitted on `2026-06-30` in Myanmar shows up as `2026-06-29` in some downstream views, and a charge for `2026-06-30` shows up as `2026-06-30` in others.

**Fix:** Either (a) configure the date input to emit a `Date` at UTC midnight and call `setHours(0,0,0,0)` before `toISOString()`, or (b) use the dayjs `utc` plugin and convert explicitly:

```ts
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
dayjs.extend(utc);
...
fd.append(k, v instanceof Date ? dayjs(v).format("YYYY-MM-DD") : String(v));
```

…and adjust the zod schema / Prisma column to `DATE` instead of `TIMESTAMP(3)` if the date has no time-of-day meaning.

### M2. `apptAdmissionDate` accepts any non-empty string on the server

`src/app/(dashboard)/external-charges/features/external-charges.action.ts:16-19`

```ts
const optionalDateField = zfd
  .text(z.string().optional())
  .transform((v) => (v === "" ? undefined : v));
```

…and the schema uses `zfd.text()` for `apptAdmissionDate` with no transform. The action just forwards the string to the service, which writes it directly to the DB column. So `apptAdmissionDate=garbage` becomes a DB write attempt that Prisma may reject — but the user sees no helpful error message. The browser-side `requiredDate` schema in `base-external-hospital-charge.schema.ts` does validate, but only if the action goes through that path. Two questions:

1. Does the server action pass the raw formData straight to the repository, or does it route through `baseExternalHospitalChargeSchema.parse()`?
2. If the former, all the browser-side validation is advisory only and the server accepts anything.

**Fix:** Always parse with the zod schema on the server side (defense in depth), and use the same schema on both create and update action schemas — currently only `create` (line 79 area) appears to use `baseExternalHospitalChargeSchema`, not visible in this diff whether `update` does the same.

### M3. `optionalDateField` is misleadingly named and identical to `optionalAmountField`

`src/app/(dashboard)/external-charges/features/external-charges.action.ts:9-19`

```ts
const optionalAmountField = zfd.text(z.string().optional()).transform((v) => (v === "" ? undefined : v));
const optionalDateField  = zfd.text(z.string().optional()).transform((v) => (v === "" ? undefined : v));
```

Two constants, same body, different names. Drop one and reuse:

```ts
const blankToUndefined = zfd.text(z.string().optional()).transform((v) => (v === "" ? undefined : v));
const optionalAmountField = blankToUndefined;
const optionalDateField   = blankToUndefined;
```

Or just inline both call sites — the abstraction earns nothing.

### M4. Two formData schemas (create + update) are duplicated

`src/app/(dashboard)/external-charges/features/external-charges.action.ts:21-78` (create) and `:78-...` (update)

The same 14-key `formData()` shape is repeated for create and update. Drift is inevitable. Extract:

```ts
const externalHospitalChargeFormData = zfd.formData({ ... });
export const createExternalHospitalChargeAction = ... externalHospitalChargeFormData ...;
export const updateExternalHospitalChargeAction = externalHospitalChargeFormData.extend({ id: zfd.text() });
```

### M5. `chargeFields` cast suppresses nullability check

`src/app/(dashboard)/external-charges/features/components/external-charges-detail.tsx:14-23`

```ts
{charge[f.name] ? charge[f.name]!.toLocaleString() : ""}
```

The `!` non-null assertion is unsafe — `charge[f.name]` is `number | null`, and the truthiness check (`?`) does narrow to `number` at runtime, but TS doesn't narrow through computed property access on a record. Either use a typed lookup or an explicit guard:

```ts
const value = charge[f.name];
<Text fz="sm">{value != null ? value.toLocaleString() : ""}</Text>
```

### M6. Detail page is async server component, but `params` shape varies across Next versions

`src/app/(dashboard)/external-charges/[id]/page.tsx:5-13`

```ts
export default async function ExternalChargesDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
```

`params: Promise<...>` is correct for Next 15+. If the project still supports Next 14 fallback, this will throw. Verify the Next.js version in `package.json` and the rest of the codebase's pattern. (Pre-existing concern, but worth noting since this is a new page.)

### L1. Column header string with `/` and spaces

`src/app/(dashboard)/external-charges/features/components/external-charges-columns.tsx:13-19`

`"Appt/ Admission Date"` as a TanStack column id and header. Same caveat as PR #17 M4: CSV exports will have spaces and a slash in the column key. Consider `apptAdmissionDate` as the id and `Appt / Admission Date` as the label.

### L2. `format()` callback in `external-charges-table.tsx` uses new key without updating the rendered `TanStack` columns

`src/app/(dashboard)/external-charges/features/components/external-charges-table.tsx:84-95`

The CSV export row now includes `Appt/ Admission Date` and `Discharge Date`, but the on-screen `ExternalChargesColumns` array (now using `apptAdmissionDate` for the first column) doesn't render a `Discharge Date` column. CSV gets a column the UI doesn't show — inconsistent.

### L3. `Link` import + `component={Link}` + `href` requires the click handler removed — confirm a11y

`src/app/(dashboard)/external-charges/features/components/external-charges-columns.tsx:88-93`

Switching from `<ActionIcon onClick>` to `<ActionIcon component={Link} href>` is good for deep-linking and middle-click open, but `<ActionIcon>` renders as a `<button>` by default — when `component={Link}` is passed, it renders as `<a>` without an explicit `aria-label`. The inner `Tooltip label="View"` doesn't act as an accessible name. Add `aria-label="View external charge"` to keep screen readers happy.

### L4. Date column `w-28` is too narrow for `DD MMM YYYY` on mobile

Cosmetic — `w-28` (7rem / 112px) is fine at `md+` but cramped at `sm`.

## Recommendations

1. Authorize the new `GET` endpoint at the same level as the page wrapper (H1).
2. Document the filter semantic change in release notes (H2).
3. Run the backfill + `SET NOT NULL` outside the migration script, or use `DEFAULT now()` to avoid the lock (H3).
4. Pick a single timezone story (M1) — `DATE` column + dayjs `utc` is the simplest. Without this, audit trails will be off by a day for non-UTC users.
5. Extract the duplicated formData shape and the duplicate `optionalXxxField` constants (M3, M4).
6. Tighten server-side validation to mirror the browser schema (M2).

## Test plan checklist

- [ ] Existing rows from before this PR display `apptAdmissionDate = created_at` value in the detail page.
- [ ] Date-range filter "last 7 days" returns the same set of rows the operator used to see under `createdAt` (or, if intentional change, document the divergence).
- [ ] User in `Asia/Rangoon` (UTC+6:30) selects `2026-06-30` in the form → record saves and displays as `30 Jun 2026`, not `29 Jun`.
- [ ] User without `View External Charges` permission is blocked at the API endpoint, not just the page.
- [ ] Selecting a discharge date earlier than the admission date → form blocks submit with the cross-field error.
- [ ] Empty `dischargeDate` → form submits, DB row has `discharge_date = NULL`.
- [ ] CSV export of the table contains `Appt/ Admission Date` and `Discharge Date` columns matching what's on screen.
- [ ] Migration runs on a copy of production data without exceeding the maintenance window.