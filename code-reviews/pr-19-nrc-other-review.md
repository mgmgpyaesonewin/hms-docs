# Code Review — PR #19: Add other nrc type in patient registration

Date: 2026-06-19
PR: https://github.com/MyanCare/HMS-Hni-Zi-Gone/pull/19
Branch: `mpt/nrc-other-patient-register` → `development`
Files changed: 13 (+80 / -40)
Risk: **Medium** (database enum rename; touches patient identity display in 5 components; importer schema change)
Verdict: **Approve with suggestions**

## Summary

Renames the `PatientIdentity.Passport` enum value to `PatientIdentity.Other` and routes the free-text `passPort` field to be the "other ID" storage. A new private `applyIdentityExclusivity` helper on `PatientsRepository` zeroes out the inactive branch's fields on create and update so stale values can't leak into display logic. The display components (`patient-detail`, `admission`, `discharge`, `cathlab`, `ipd-pharmacy`) all flip from "show passport if present, else NRC" to "show the `passPort` text only when `patientIdentity === 'Other'`, else the formatted NRC".

## Findings

### H1. Toggling the radio in `EditPatientForm` silently wipes the other ID type's data

`src/app/(dashboard)/common/patients/features/components/patient-form.tsx:340-351` (create form) and `src/app/(dashboard)/ipd/admission/feature/components/admission-form.tsx:415-424` (admission form)

```tsx
onChange={(value) => {
  field.onChange(value);
  if (value === "NRC") {
    form.setValue("passPort", "");
  } else if (value === "Other") {
    form.setValue("stateCode", "");
    form.setValue("nrcTownship", "");
    form.setValue("nrcType", "");
    form.setValue("nrcNo", "");
  }
}}
```

This is fine on the **create** path — there's no existing data to lose. On the **edit** path, a user who selects a different identity type, then realizes the mistake and switches back, has lost the original values (form state only, not yet persisted). Worse, the `EditPatientForm` doesn't even apply this clearing — let me re-check…

Actually looking at the diff: the radio clearing **was not** added to `edit-patient-form.tsx`, only to `patient-form.tsx` (the create flow) and `admission-form.tsx`. So on edit, switching from NRC → Other leaves stale `stateCode`/`nrcTownship`/`nrcType`/`nrcNo` in form state. The new repository-level `applyIdentityExclusivity` will zero them out on submit, but the user sees no UI indication that data was cleared until they hit Save. That's a discoverability bug — they may have intended to keep both for reference.

The bigger problem is the **create** path: clearing form fields on radio change is irreversible for that session. If the user clicks the wrong radio by accident, they have to re-type the NRC. Consider only clearing on submit (which is what `applyIdentityExclusivity` already does) and dropping the in-form clearing.

**Fix:** Remove the in-form `setValue` clearing, rely solely on `applyIdentityExclusivity` at the repository level. Add a small note next to the radio ("Changing ID type will clear the other type's data") so the user isn't surprised at save time.

### H2. `applyIdentityExclusivity` mutates its argument and has no test

`src/app/(dashboard)/common/patients/features/patients-repository.ts:451-473`

```ts
private applyIdentityExclusivity<
  T extends Pick<
    CreatePatientSchema,
    "patientIdentity" | "passPort" | "nrcNo" | "nrcType" | "nrcTownship" | "stateCode"
  >,
>(data: T) {
  if (data.patientIdentity === "Other") {
    data.nrcNo = "";
    data.nrcType = "";
    data.nrcTownship = "";
    data.stateCode = "";
  } else if (data.patientIdentity === "NRC") {
    data.passPort = "";
  }
}
```

In-place mutation of an object passed by reference is fine for a private repository helper, but:

1. The `T extends Pick<...>` constraint is correct (it picks the writable keys from the schema), but TypeScript will still allow callers to pass a frozen object — `data.passPort = ""` will throw at runtime if so. The previous inline code at line 154 (`if (data.nrcNo == "" || data.passPort != "" || null)`) actually had a bug (the `|| null` was dead code), so extracting to a named method is good.
2. The previous `nrcNo == ""` check was wrong (`== ""` matches both `""` and `null`), but it worked by accident because the create flow always sent those fields as strings. The new method is stricter — `data.nrcNo = ""` writes empty string regardless of what was there.

**Fix:** Document the mutation in a JSDoc above the method:

```ts
/**
 * Clears fields that don't belong to the active identity type.
 * Mutates `data` in place — caller must not rely on the original after the call.
 */
```

And add a unit test that covers all three identity values.

### M1. `EditPatientForm` ignores the stored `patientIdentity` and falls back to old heuristic

`src/app/(dashboard)/common/patients/features/components/edit-patient-form.tsx:58-67`

The diff replaces the old heuristic (`patient.nrcNo ? "NRC" : patient.passPort ? "Passport" : undefined`) with `patient.patientIdentity ?? undefined`. Good. But this only works if the database has `patientIdentity` populated for every existing patient. Two questions:

1. What was the default value of `patientIdentity` before this PR? If the column was added with a default of `NRC` (or `Passport`), legacy rows have a value.
2. If the column was nullable without a default, every existing patient now has `patientIdentity = NULL`. The edit form will fall through to `undefined` and the radio will render unselected.

Confirm the schema migration history. If `patientIdentity` was nullable with no default, you need a one-time data migration:

```sql
UPDATE "Patient" SET "patientIdentity" = 'NRC' WHERE "patientIdentity" IS NULL AND "nrcNo" IS NOT NULL;
UPDATE "Patient" SET "patientIdentity" = 'Other' WHERE "patientIdentity" IS NULL AND "passPort" IS NOT NULL;
```

### M2. Importer schema drops `Passport` with no back-compat shim

`src/app/(dashboard)/common/patients/features/patient-importer-service.ts:42`

```ts
patientIdentity: z.enum(["NRC", "Other"]).optional(),
```

Any queued CSV uploads still containing `Passport` will fail validation after this PR lands. Two ways to handle:

1. **Normalize at parse time** — accept both `Passport` and `Other` from the CSV and map to `Other` in the importer service.
2. **Document** the breaking change in the importer docs / release notes.

For a healthcare app where the importer is likely run by ops staff on a schedule, option 1 is safer.

### M3. `EditPatientForm` doesn't run `applyIdentityExclusivity` path correctly for legacy rows

`src/app/(dashboard)/common/patients/features/components/edit-patient-form.tsx:58-67` calls `patient.patientIdentity ?? undefined`. If `patient.patientIdentity` is `null` (legacy row), the form sends `undefined`, and `applyIdentityExclusivity` does nothing (no branch matches). The form then submits with whatever stale `passPort` / `nrcNo` fields are present — but the display logic checks `patient.patientIdentity === "Other"`, so the legacy row's `passPort` value (if present) will never render. Two issues:

1. **User can't recover** — if the legacy row had `passPort = "M12345"` and no NRC, the operator can never see it on the detail page (which only renders `passPort` when `patientIdentity === "Other"`). The edit form may show it but the read paths hide it.
2. **Silent data loss** — the operator edits the legacy patient, doesn't touch the identity radio, submits. `applyIdentityExclusivity` sees `patientIdentity === undefined`, doesn't clear anything. But the display logic continues to hide the data, so the value sits in the DB forever.

**Fix:** Treat `patientIdentity === null || undefined` as `"Other"` for display purposes if `passPort` is non-empty (back-compat shim):

```tsx
const displayIdentity =
  patient.patientIdentity ?? (patient.passPort ? "Other" : "NRC");
```

And add a one-time migration to populate `patientIdentity` for existing rows (see M1).

### M4. `patient-form.tsx` label text changed from `Passport` to `No`

`src/app/(dashboard)/common/patients/features/components/patient-form.tsx:430`

```tsx
<Text size="sm">No</Text>
<TextInput placeholder="Enter No" ... />
```

"Losing" the field name to a generic `No` makes the field ambiguous — is it NRC? Passport? National ID? The label should reflect what the user is supposed to enter, e.g., `Other ID No` or `ID Number`. Same change in `admission-form.tsx:586`.

### M5. Display components now show `"NRC No"` even for `Other` patients

`src/app/(dashboard)/common/patients/features/components/patient-detail.tsx:79`, `cathlab-request-patient-info-card.tsx:39`, `ipd/admission/[id]/page.tsx:43`, `ipd/discharge/features/components/discharge-patient-info-card.tsx:42`, `ipd/features/components/pharmacy-request/ipd-patient-info-card.tsx:35`

The hardcoded label is now `"NRC No"` for every patient, with the value switching between NRC-formatted text and `passPort` text based on `patientIdentity === "Other"`. The label should match the value:

```tsx
const idLabel =
  patient.patientIdentity === "Other" ? "Other ID No" : "NRC No";
```

Or hide the label entirely when `patientIdentity === "Other"` and `passPort` is empty.

### L1. Five component copies of the same JSX expression

All five components above have the exact same `<span key={patient.id}>{...}</span>` block. Extract a `PatientIdentityDisplay` component and reuse it. With this PR touching all five, now is the time.

### L2. `patient-identity` enum rename leaves dangling column references

Search for `Passport` (case-insensitive) across the codebase after this PR to catch any remaining string literals or i18n keys. Common places: en.json / my.json translation files, Sentry labels, analytics events, audit logs.

### L3. No backfill migration for the enum rename

`prisma/migrations/20260619035206_rename_patient_identity_passport_to_other/migration.sql` uses `ALTER TYPE ... RENAME VALUE`. This is supported on Postgres 10+. Verify the prod Postgres version — `RDS` / managed instances sometimes lag.

## Recommendations

1. Add a one-time data migration that populates `patientIdentity` for legacy rows (M1, M3).
2. Decide on the in-form radio clearing behavior (H1). Recommend: remove the clearing, rely on the repository helper, add a small "Changing ID type will clear the other type's data" hint.
3. Add a back-compat alias `Passport → Other` in the CSV importer (M2).
4. Rename the `No` label to something descriptive like `Other ID No` (M4).
5. Fix the `"NRC No"` label in the five display components to match the actual identity type (M5).
6. Extract `PatientIdentityDisplay` to a single component (L1).

## Test plan checklist

- [ ] Create patient with `patientIdentity = NRC` → form, list, detail, admission, discharge, cathlab, IPD pharmacy all show the formatted NRC.
- [ ] Create patient with `patientIdentity = Other` and `passPort = "M12345"` → all views show `M12345` under "Other ID No" (or equivalent).
- [ ] Edit patient, switch NRC → Other → NRC: confirm the original NRC values are still in the DB after save.
- [ ] Edit a **legacy** patient (created before the `patientIdentity` column was meaningful) — confirm the identity radio shows the right default and the displayed value matches.
- [ ] CSV import a file containing `Passport` — currently fails. Either document the break or add the alias.
- [ ] Patient whose `patientIdentity = null` and `passPort = "X"` — display page shows `X` after the back-compat shim lands.
- [ ] Prisma migration runs on prod Postgres without `RENAME VALUE` errors.