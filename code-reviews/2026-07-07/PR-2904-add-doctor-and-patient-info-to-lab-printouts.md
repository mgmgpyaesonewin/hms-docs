# Code Review: PR #2904 — Add Doctor and Patient Info to Lab Printouts
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-27/lab-print-ui-86ey4c3qp` → `development`
**Files changed:** 7 (+242 / -126)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07
**ClickUp:** https://app.clickup.com/t/9018849685/86ey4c3qp

## Summary
Restructures the header section of three lab-report printout views (EMR, IPD, and the canonical lab-report print document) into a clean two-column grid with new fields: Patient ID, Refer Doctor, Date of Report, Doctor Name, and Center Info (moved out of the left column). Adds a `reportStatus` prop to `LabReportPrintDocument` so a REPRINTED render shows the previous print timestamp instead of "now". Wires up a new `referralDoctorName` on `LabReport` by querying the most recent IPD service request's referral doctor in the lab-report repository. Also extends three `formatToDefault*` date helpers in `src/utils/date.utils.ts` to accept an optional format-string override, and removes two stray `console.log` debug statements in the repository.

## Verdict
**Approve with suggestions**
Score: 84/100
Critical: 0 | High: 0 | Medium: 3 | Low: 3 | Nit: 5

## Issues

### Critical
None

### High
None

### Medium

1. **Fallback strings removed → empty cells on missing data.** The pre-PR code used `?? "-"` / `|| "-"` on `patientId`, `name`, `gender`, `age`, `doctor`, `labRefNo`, `invoiceNo`, and `department.name` so the printout always rendered a hyphen for missing values. The new code in all three files renders the value verbatim with optional chaining (`labReport?.opdBilling?.patient?.name`, etc.). When a field is `null`/`undefined`, React will print nothing, leaving blank gaps in a printed artifact handed to a patient. Re-introduce the hyphen fallback, e.g. `{labReport?.opdBilling?.patient?.name ?? "-"}`.

2. **`reportDate` silently falls back to "now" on REPRINTED.** `lab-report-print-docutment.tsx`:
   ```
   const reportDate =
     reportStatus === "REPRINTED"
       ? (printedService?.labReportStatusUpdatedAt ?? new Date())
       : new Date();
   ```
   If a lab report has never been PRINTED/DELIVERED before (e.g., REPRINTED is triggered without a prior successful print), the printout will show *today*'s date under the "Date of Report" field — which is semantically wrong for a reprint header. Either block REPRINTED when `printedService` is absent, or surface the missing-state (e.g., leave the field blank) rather than substituting "now". Also note `find()` has no `orderBy`, so the "last printed/delivered" service depends on DB row order — explicitly order by `labReportStatusUpdatedAt: "desc"` (consistent with how `referralDoctorName` does it).

3. **`referralDoctorName` only resolves for IPD.** The new repository branch is gated on `result?.ipdDailyBill?.admission?.id`; for the OPD path, `referralDoctorName` is always `null`, and the printout still renders "Refer Doctor" with an empty value for every OPD patient (compounding issue #1). Either query OPD referrals too, or hide the row when the value is absent. As-is, this PR only fixes half the bug.

### Low / Nit

1. **Three near-identical print headers.** `emr/.../view-lab-report-content.tsx`, `ipd/.../view-lab-report-content.tsx`, and `lab-report/features/components/lab-report-print-docutment.tsx` now contain the same ~70 lines of two-column layout (diffs are byte-identical between the EMR and IPD copies). Extract one shared component (e.g., `LabReportHeader`) and import it in all three places — that's the change the ClickUp ticket was likely asking for and would make future header updates a one-file diff.

2. **`formatToDefaultDate` overload defeats its name.** `src/utils/date.utils.ts` now adds `formatSyle?: string` to `formatToDefaultDate`, `formatToDefaultDateTime`, and `formatToDefaultTime`. The only caller of the override is the new `lab-report-print-docutment.tsx` doing `formatToDefaultDate(reportDate, "DD/MMM/YYYY")`. That is exactly `dayjs(reportDate).tz(DEFAULT_TIMEZONE).format("DD/MMM/YYYY")` — i.e., the helper now wraps a wrapper for no benefit. Either inline `dayjs(...).tz(...).format(...)` at the one call site and revert the helpers, or rename the helpers (e.g., `formatDate`) to signal they accept a custom format.

3. **Misspelling in helper parameter: `formatSyle`.** Should be `formatStyle` or `format`. (See #2 — fixing #2 makes this moot.)

4. **`as unknown as Doctor` cast in repository.** `lab-report.repository.ts`:
   ```
   const referralDoctorName = getDoctorName(
     serviceRequest?.referralDoctor as unknown as Doctor | null,
     ["title", "fullName"],
   );
   ```
   The double cast hides a real type mismatch between the Prisma `referralDoctor` shape and the local `Doctor` type. Either widen the `getDoctorName` signature to accept the Prisma `referralDoctor` shape, or define a structural adapter — at minimum drop the `unknown` step so the cast is auditable.

5. **N+1-shaped repo query.** Every call to `getLabReportById` for an IPD report now triggers a second `findFirst` on `serviceRequest` (no `admissionId` index check shown, but `serviceRequest.admissionId` should be indexed). With the lab-report list page already loading many reports, this is a measurable regression — consider a single batched query or extending the existing `include` on the lab pivot. Verify the existing Prisma `serviceRequest` indexes before shipping.

### Nit

1. The duplicated header between `emr/.../lab/view-lab-report-content.tsx` and `ipd/.../lab/view-lab-report-content.tsx` is byte-identical (same SHA before and after the PR). Worth a one-line comment in each file pointing at the shared component when it lands.
2. `currentPrintType` state in `lab-service-with-template.tsx` is reset in the `setTimeout` cleanup but not on the early-error paths (permission denial, print failure). If `handlePrintAction` throws before `setCurrentPrintType(null)` is called, the document could be left mounted with a stale status. Minor because the user will retry anyway.
3. The new `REPORT_STATUS.PRINTED || DELIVERED` filter inside `LabReportPrintDocument` only checks those two states — `REPRINTED` is not a stored `labReportStatus` value in the type, so the filter is correct, but the asymmetry with the `reportStatus === "REPRINTED"` branch above it is non-obvious; one short comment would help the next reader.
4. Removing the `console.log` debug statements is correct and worth keeping — but no test was added for the new repository field, so coverage is now zero for the new code path.
5. The `reportStatus` prop on `LabReportPrintDocument` is typed as a string literal union rather than reusing the existing `ReportStatus` type from `lab-report.type.ts` — minor consistency issue (`"PRINTED" | "REPRINTED" | "DELIVERED"` is a superset of `ReportStatus`, so the union is correct, but importing the existing type would prevent drift if `REPORT_STATUS` ever gains a new value).

## Recommendation
Address the three Medium items before merge — they are user-visible in a clinical document. Specifically:

1. Restore `?? "-"` fallbacks (or hide rows entirely) so printed reports never have blank gaps.
2. Tighten the REPRINTED `reportDate` logic — block or blank when `printedService` is missing, and add an explicit `orderBy` on the `.find()`.
3. Either extend referral-doctor lookup to OPD or conditionally render the row so the new field isn't permanently empty for the majority of lab reports.

After that, follow-up cleanup (separate PR): extract the shared print-header component and either revert the `formatToDefault*` overload or rename the helpers. Both are pre-existing patterns that this PR exposes rather than introduces, but they're now amplified.