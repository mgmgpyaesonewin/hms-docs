# Code Review: PR #2901 — Change UI Imaging Printouts
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-27/imaging-print-ui-86ey4c4dj` → `development`
**Files changed:** 17 (+242 / -89)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07
**ClickUp:** https://app.clickup.com/t/9018849685/86ey4c3qp

## Summary
PR updates the printed imaging result/receipt UI for CT, ECG, Echo, MRI, Ultrasound, and X-Ray across IPD and EMR contexts. The patient info block on each result printout is restructured into a two-column layout with explicit grid rows for `Patient ID`, `Age and Gender`, `Reading Doctor`, and `Refer Doctor`. The `Patient` type now requires `patientId`, and a new `referralDoctorName`/`referDoctorName` prop carries the referring doctor's name through the modal → details → content chain.

## Verdict
**Request changes**
Score: 68/100
Critical: 2 | High: 2 | Medium: 2 | Low: 2 | Nit: 1

## Issues

### Critical

**C1. `result-receipt.tsx` — duplicate "Reading Doctor" label; the refer doctor row is mislabeled.**
At the new `PatientInfo` block in `src/components/result-receipt.tsx` (the section rendering `referralDoctorName`), there are two consecutive rows both labeled `Reading Doctor`. The second row binds `referralDoctorName` and is therefore shown to users as the reading doctor instead of the refer doctor. This is a printout going out to clinicians — wrong attribution of the reading physician is a clinical/correctness bug, not cosmetic. Likely an accidental copy-paste when adding the refer row.
```tsx
<span className="w-28 text-gray-600">Reading Doctor</span>
<strong>{readingDoctors?.join(", ") || "-"}</strong>
...
<span className="w-28 text-gray-600">Reading Doctor</span>   // BUG: should be "Refer Doctor"
<strong className="flex-1">{referralDoctorName || "-"}</strong>
```

**C2. `view-imaging-report-modal.tsx` (IPD) — service doctor information silently dropped; dead commented-out code remains.**
At `src/app/(dashboard)/ipd/features/components/service-request/imaging/view-imaging-report-modal.tsx`, the `serviceDoctorName` calculation is commented out:
```tsx
// const serviceDoctorName = getDoctorName(
//   (service?.ipdDailyService?.doctor ??
//     service?.opdBillingService?.doctor) as unknown as Doctor | null,
//   ["title", "fullName"],
// );
const referralDoctor = getDoctorName(
  detailsResponse?.result?.referralDoctor as unknown as Doctor | null,
  ["title", "fullName"],
);
```
The receiving `ViewImagingReportContent` had its `serviceDoctorName` prop **renamed** to `referDoctorName` and is now being passed the referral doctor value. Net effect: the service/requesting doctor is no longer rendered on the IPD imaging printout. Either (a) the IPD receipt is intentionally removing the service doctor and this needs product confirmation, or (b) it's an accidental information loss from the rename. In either case: dead commented code must be removed before merge (it has no reason to ship).

### High

**H1. Prop-name inconsistency: `referDoctorName` vs `referralDoctorName`.**
The shared `ViewImagingReportContent` component uses `referDoctorName` (no "ral"), while every caller (`ResultColumn` in ct/ecg/echo/mri/ultrasound/x-ray, and `view-imaging-report-modal.tsx`) uses `referralDoctorName`. `ResultReceipt` / `PatientInfo` also use `referralDoctorName`. This works because TypeScript enforces the rename at the call site, but it is a sharp footgun — anyone adding a new caller or refactoring will get a type error and have to guess which spelling is canonical. Pick one (recommend `referralDoctorName` to match the existing `referralDoctor` field on the result model and every caller) and rename in the content file.

**H2. New positional parameter inserted in the middle of `onViewResult` signature.**
In every `*-service-columns.tsx`, the `onViewResult` callback had a new positional parameter added between `readingDoctors` and `serviceDoctorName`:
```tsx
onViewResult(resultHtml, printOption, readingDoctors, referralDoctorName, serviceDoctorName);
```
That same callback type is duplicated across all six imaging types (CT/ECG/Echo/MRI/Ultrasound/X-Ray) plus their respective `*-details.tsx`. The shared `ViewImagingReportContentProps` already accepts an options object; the same approach for `onViewResult` (or at minimum, appending the new param at the end instead of inserting it in the middle) would prevent every new caller from silently passing the referral doctor where the service doctor used to go. Today, if anyone inverts the order by accident, the printout will swap doctor identities without a type error (both are `string`).

### Medium

**M1. `view-emr-imaging-report-modal.tsx` was widened (`patientId` added) but the EMR receipt never receives a referral doctor.**
The EMR modal updates `patientForReceipt` to include `patientId`, but `ViewImagingReportContent` now has a `referDoctorName` prop that is never set by the EMR modal. Result: EMR imaging printouts will render `-` for "Refer Doctor" silently. Either the EMR flow needs to pass the referral doctor too, or the `referDoctorName` prop should remain optional and the empty state should be made explicit (it already shows `-`, which is acceptable — flagging so it's not silently regressing on data the EMR result model likely already carries).

**M2. `view-imaging-report-content.tsx` duplicates the exact same JSX in two locations.**
The body of `ViewImagingReportContent` (the two-column patient info block) is byte-for-byte identical between:
- `src/app/(dashboard)/emr/features/service-request/imaging/view-imaging-report-content.tsx`
- `src/app/(dashboard)/ipd/features/components/service-request/imaging/view-imaging-report-content.tsx`

This duplication existed before the PR (the diff shows the same edits applied to both copies in lockstep), so it's not introduced here, but the PR is the natural moment to deduplicate. Two copies of the same printout block are guaranteed to drift — and one already did (see C1).

### Low / Nit

**L1.** `src/components/result-receipt.tsx` — `PatientInfo` still has `serviceDoctorName` in its type, and `ResultReceipt` still destructures it, but neither the content component nor the modal pass it through anymore. Dead prop after this rename. Remove `serviceDoctorName` from the `Props`/`PatientInfo` props type in `result-receipt.tsx` to match the rest of the rename.

**L2.** In the new grid columns, the left column uses `grid-cols-[90px_1fr]` while the right uses `grid-cols-[95px_1fr]`. A 5px difference with no semantic reason — pick one. The `result-receipt.tsx` version uses `w-28` (≈112px) and `w-24` (≈96px) for the same purpose. Three different layouts for the same row label across three files. Pick one and reuse.

**N1.** `view-emr-imaging-report-modal.tsx` was touched only for the `patientId` Pick widening (1 line) — this is a positive change (it would otherwise fail to type-check the EMR receipt's new `patient.patientId ?? "-"` reference), but it underscores that EMR and IPD modals are siblings and should share more.

## Recommendation
1. **Fix the "Reading Doctor" duplicate label in `result-receipt.tsx`** — rename the second row to `Refer Doctor`. (C1)
2. **Decide whether the service doctor stays on the IPD receipt.** If yes, restore the `serviceDoctorName` prop and pass the actual service doctor, not the referral doctor. If no, remove the commented-out block and confirm with product that the requestor no longer needs to be on the printout. (C2)
3. **Rename `referDoctorName` → `referralDoctorName` in both `view-imaging-report-content.tsx` copies** so all callers and fields agree. (H1)
4. **Append the new `referralDoctorName` parameter at the end of `onViewResult`** in all six `*-service-columns.tsx` callers to keep positional safety; or convert the callback to take an options object. (H2)
5. After the above, sweep for the dead `serviceDoctorName` prop on `ResultReceipt`/`PatientInfo` (L1) and unify the label-column widths (L2).
6. Verify EMR imaging printouts are not silently missing the refer doctor (M1) and that `ViewImagingReportContent` is shared between EMR and IPD (M2 — the existing duplication is what made C1 reach one caller but not the other).

This is a UI-only change with no data-layer risk. The bugs are all in label wiring and prop plumbing; once C1 and C2 are fixed and the names are consistent, the diff is straightforward to merge.