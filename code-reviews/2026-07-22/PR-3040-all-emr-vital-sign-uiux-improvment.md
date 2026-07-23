# Code Review: PR #3040 — All EMR vital sign uiux improvment
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `mpt/emr-vital-sign-uiux` → `development`
**Files changed:** 6 (+274 / -261)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86eyatbhc

## Summary
UX overhaul for EMR vital signs. Removes the per-vital-sign `DateTimePicker` from the IPD and cathlab vital-sign forms and the `Measured:` button chip from the detail view. Timestamps are now server-derived: `now` for newly entered or changed fields, the original `*DateTime` preserved when the value is unchanged. A new `toPositiveNumber` helper normalizes empty strings and zero to `undefined`. A submit-side guard rejects empty submissions with a toast. Date & Time rows in the detail view are gated on both the value being present and the timestamp being present (instead of always being shown with a `-` placeholder).

## Verdict
**Request changes**
Score: 83/100
Critical: 0 | High: 2 | Medium: 0 | Low: 0 | Nit: 1

## Issues

### Critical
None

### High
1. **Duplicated `onSubmitHandler` (60+ lines, identical body) across two files.** `src/app/(dashboard)/emr/features/vital-sign/emr-vital-sign-form.tsx` and `src/app/(dashboard)/emr/ipd/features/components/vital-sign/ipd-emr-vital-sign-form.tsx` each contain the same `onSubmitHandler` (normalizes numeric fields, validates non-empty, resolves datetimes via `resolveDateTime`, dispatches `onSubmit`). Total ~100 lines of straight duplication. Extract to a single shared hook (`useVitalSignSubmitHandler(emrVitalSign, onSubmit)`) colocated with `util.ts`, or a pure helper that takes the source values and the originals. Without extraction, the next bug fix only lands on one side. Also: the handler is 60+ lines, exceeding the 50-line long-function threshold; the fix is the same — extract.

2. **Breaking change risk: `enableDateTimeFields` prop removed from `IpdEmrVitalSignForm` but remaining call sites are not in the diff.** The diff removes the prop from the form's signature and from `CathLabIpdEmrVitalSignTabComponent`'s call site. If `IpdEmrVitalSignForm` is also rendered from the regular IPD flow (the prop was clearly designed to be toggled by parents), those callers will fail TypeScript compilation and silently lose the date-time UX. Grep for `IpdEmrVitalSignForm` callers and update them, or keep the prop with a default of `false`.

### Medium
None

### Low / Nit
1. **Potentially dead export `bpMeasuredTimeData`** in `emr-vital-sign-form.tsx`. Both `emr-vital-sign-detail.tsx` and `ipd-emr-vital-sign-detail.tsx` removed their imports. Check for remaining consumers; if none, delete the export. ([ponytail:delete])

## Recommendation
- Extract the `onSubmitHandler` into a shared hook/util next to `util.ts`; both forms should call it with their respective `emrVitalSign` source object. This dissolves ~100 lines of duplication and brings the handler under the long-function threshold.
- Grep for all callers of `IpdEmrVitalSignForm` and either update them to drop `enableDateTimeFields` or keep the prop with a default of `false` to avoid a silent compile break.
- Sweep for `bpMeasuredTimeData` consumers; delete the export if dead.
- Otherwise the change is a clean UX simplification: server-derived timestamps remove five synchronous pickers from the form, and the `(value && datetime)` gate is the right predicate for the detail row.
