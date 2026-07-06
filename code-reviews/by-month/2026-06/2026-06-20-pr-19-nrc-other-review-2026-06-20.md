# Code Review — PR #19: Add other nrc type in patient registration (re-review)

**Date:** 2026-06-20
**PR:** https://github.com/MyanCare/HMS-Hni-Zi-Gone/pull/19
**Branch:** `mpt/nrc-other-patient-register` → `development`
**Files changed:** 13 (+58 / −38)
**Risk:** **Medium** (database enum rename; multi-component display logic; no data backfill)
**Verdict:** **Approve with required follow-ups** — code is clean, but two data-correctness gaps must be addressed before merge (H1, H2).

## Summary

Renames the `PatientIdentity.Passport` enum value to `PatientIdentity.Other` via Prisma `ALTER TYPE ... RENAME VALUE`. The free-text `passPort` column is now repurposed as the catch-all "Other ID" storage. A new private `applyIdentityExclusivity()` helper on `PatientsRepository` zeroes out the inactive branch's fields on both create and update so stale values can't leak into display logic after a patient switches identity type. The five display components (patient detail, admission, discharge, cathlab, IPD pharmacy) flip from the old `passPort ? passport : NRC` heuristic to `patientIdentity === "Other" ? passPort : formattedNRC`.

A second commit (`a7110260`, "fix: PR review") landed post-initial-review. It tightened the repo helper's type signature but did **not** address any of the data-correctness or display-label findings from the previous review.

## Findings

### H1. No backfill migration — legacy `NULL` `patientIdentity` rows render blank forever

`prisma/migrations/20260619035206_rename_patient_identity_passport_to_other/migration.sql`

```sql
ALTER TYPE "PatientIdentity" RENAME VALUE 'Passport' TO 'Other';
```

`src/app/(dashboard)/common/patients/features/components/edit-patient-form.tsx:61`

```tsx
patientIdentity: patient.patientIdentity ?? undefined,
```

The five display components condition exclusively on `patient.patientIdentity === "Other"`. Any pre-existing patient whose `patientIdentity` was `NULL` before this PR (the default — no migration ever set a default) will now show an **empty** ID cell on every read path: patient-detail, admission, cathlab, discharge, IPD pharmacy. The old code was self-healing (`passPort ? "Passport" : "NRC"`); the new code is not.

**Fix (non-negotiable before merge):**

Add a second migration immediately after the enum rename:

```sql
UPDATE "Patient"
SET "patientIdentity" = CASE
  WHEN "passPort" IS NOT NULL AND "passPort" <> '' THEN 'Other'
  WHEN "nrcNo"     IS NOT NULL AND "nrcNo"     <> '' THEN 'NRC'
  ELSE "patientIdentity"
END
WHERE "patientIdentity" IS NULL;
```

Add the same back-compat shim in the read path as defense-in-depth:

```tsx
const effectiveIdentity =
  patient.patientIdentity ?? (patient.passPort ? "Other" : patient.nrcNo ? "NRC" : null);
```

### H2. `applyIdentityExclusivity` has zero test coverage

`src/app/(dashboard)/common/patients/features/patients-repository.ts:451-473`

```ts
private applyIdentityExclusivity<
  T extends Pick<
    CreatePatientSchema,
    | "patientIdentity"
    | "passPort"
    | "nrcNo"
    | "nrcType"
    | "nrcTownship"
    | "stateCode"
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

This is the only place enforcing "you can't have both an NRC and a passport". The previous inline check had a real bug (`data.passPort != "" || null` — the `|| null` is dead) that the new code fixes. Without a test, the regression risk on the next refactor is high.

**Fix:** Unit tests covering all four identity cases (`"NRC"`, `"Other"`, `undefined`, `""`) plus the round-trip case (switch Other → NRC → submit; switch NRC → Other → submit).

### M1. Five display components show hardcoded `"NRC No"` label even for `Other` patients

Files:
- `src/app/(dashboard)/common/patients/features/components/patient-detail.tsx:79`
- `src/app/(dashboard)/cathlab/request-list/features/components/cathlab-request-patient-info-card.tsx:39`
- `src/app/(dashboard)/ipd/admission/[id]/page.tsx:43`
- `src/app/(dashboard)/ipd/discharge/features/components/discharge-patient-info-card.tsx:42`
- `src/app/(dashboard)/ipd/features/components/pharmacy-request/ipd-patient-info-card.tsx:35`

```tsx
[
  "NRC No",  // hardcoded
  <span key={patient.id}>
    {patient.patientIdentity === "Other"
      ? (patient.passPort ?? "")
      : patient.nrcNo
        ? `${patient.stateCode}/${nrcTownship?.short.en}(${patient.nrcType})${patient.nrcNo}`
        : ""}
  </span>,
]
```

A patient with `patientIdentity = "Other"` and `passPort = "M12345"` will display as `NRC No: M12345` — misleading and clinically dangerous.

**Fix:** Derive label from identity, or extract a shared `<PatientIdentityDisplay patient={patient} />` (L1).

### M2. Forms label changed from `Passport` to ambiguous `No`

`src/app/(dashboard)/common/patients/features/components/patient-form.tsx:430`
`src/app/(dashboard)/ipd/admission/feature/components/admission-form.tsx:586`

```tsx
<Text size="sm">No</Text>
<TextInput placeholder="Enter No" {...form.register("passPort")} />
```

`No` alone is ambiguous — users will not know what to type.

**Fix:** `Other ID No` / `Enter Other ID No`.

### M3. Importer schema drops `Passport` with no back-compat shim

`src/app/(dashboard)/common/patients/features/patient-importer-service.ts:42`

```ts
patientIdentity: z.enum(["NRC", "Other"]).optional(),
```

Any queued CSV containing `Passport` fails Zod validation. Previous review flagged this; fix commit did not address.

**Fix:**

```ts
patientIdentity: z
  .preprocess((v) => (v === "Passport" ? "Other" : v), z.enum(["NRC", "Other"]))
  .optional(),
```

### M4. `EditPatientForm` doesn't run equivalent clearing logic on radio toggle

`src/app/(dashboard)/common/patients/features/components/edit-patient-form.tsx:61` sets `patientIdentity: patient.patientIdentity ?? undefined` but does not clear the inactive branch on radio change. The repo helper zeros fields on submit, but the user gets no UI feedback. Previous review flagged this; not addressed.

**Fix (low priority):** Add a small inline note: "Switching ID type will clear the other type's data on save."

### L1. Five identical `<span>` blocks across display components

Extract once, fix M1 once:

```tsx
export const PatientIdentityDisplay = ({ patient }: { patient: Patient }) => (
  <span key={patient.id}>
    {patient.patientIdentity === "Other"
      ? (patient.passPort ?? "")
      : patient.nrcNo
        ? `${patient.stateCode}/${nrcTownship?.short.en}(${patient.nrcType})${patient.nrcNo}`
        : ""}
  </span>
);
```

### L2. Search for stale `Passport` references in i18n / analytics

Grep `passport` (case-insensitive) excluding `node_modules` and `prisma/migrations` — check `messages/en.json`, `messages/my.json`, `src/lib/analytics/*`, `src/lib/audit/*`. The diff only updates literal label strings.

### L3. Postgres `ALTER TYPE ... RENAME VALUE` requires PG 10+

Verify the prod RDS / managed Postgres is ≥ 10 before deploying.

## Recommendations

1. **Add the backfill migration in H1** — non-negotiable before merge.
2. **Add the back-compat shim in the read path** as defense-in-depth (H1).
3. **Add unit tests for `applyIdentityExclusivity`** (H2).
4. **Fix the five `"NRC No"` labels** (M1) — extract a shared component (L1).
5. **Rename `No` to `Other ID No`** (M2).
6. **Normalize `Passport → Other` in the importer** (M3).

## Test plan checklist

- [ ] Pre-PR patient with `patientIdentity = NULL`, `passPort = "M12345"` → backfill sets `patientIdentity = "Other"`. Detail page shows `Other ID No: M12345`.
- [ ] Pre-PR patient with `patientIdentity = NULL`, `nrcNo = "123456"` → backfill sets `"NRC"`. Detail page shows formatted NRC.
- [ ] Edit patient: switch NRC → Other → save → reopen → switch Other → NRC → enter new NRC → save. Final DB has the new NRC only.
- [ ] CSV import with `patientIdentity = "Passport"` → normalized to `"Other"`, import succeeds.
- [ ] All five display components render the correct label after the M1 fix.
- [ ] Unit tests for `applyIdentityExclusivity` cover all four identity cases plus the round-trip.

## Compared to previous review (2026-06-19)

| Previous ID | Status | Notes |
|---|---|---|
| H1 (radio clear data loss) | Partially fixed | In-form clearing is in create form + admission form. Still applies as M4. |
| H2 (`applyIdentityExclusivity` tests) | Not fixed | No test file added. Still applies. |
| M1 (legacy `NULL` rows) | **Escalated to H1** | No backfill migration. Display paths now silently hide data on every legacy row. |
| M2 (importer drops `Passport`) | Not fixed | Zod schema unchanged. Still applies as M3. |
| M3 (legacy rows display hidden) | Not fixed | Rolled into H1. |
| M4 (label `No`) | Not fixed | Label still `No`. Still applies as M2. |
| M5 (display `"NRC No"` label) | Not fixed | Hardcoded in all five components. Still applies as M1. |
| L1 (extract shared component) | Not fixed | Five copies remain. Still applies. |
| L2 (dangling `Passport` refs) | Not fixed | Still applies. |
| L3 (PG version check) | Not addressed in code | Verify ops-side. Still applies. |