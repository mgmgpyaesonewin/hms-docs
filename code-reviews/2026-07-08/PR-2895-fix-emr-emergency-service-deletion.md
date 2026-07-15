# Code Review: PR #2895 — fix: emr emergency service deletion
**Repository:** MyanCare/Ycare-HMS
**Author:** @Xkill119966
**Branch:** `fix/emr-emergency-services-delete` → `development`
**Files changed:** 1 (+12 / -0)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-08
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3c8xf

## Summary
After a successful delete of an Emergency Services billing record, the form was still showing the previous bill's items (pharmacy, services, service packages, procedures) and remark because `onSuccess` only closed the confirmation modal, switched to form view, and invalidated queries — it never reset react-hook-form state. This PR adds a `formMethod.reset(...)` call inside the delete `onSuccess` handler that clears the user-entered bill data (`pharmacyBill`, `serviceBill`, `servicePackageBill`, `procedureBill`, `paymentMethods`, `remark`, `date`) while preserving context-bound fields that come from external state (`storeId`, `patientId`, `appointmentId`, `patientGroup`, `billTypeId`, `displayFOCField`). The use of `formMethod.getValues(...)` for the preserved keys is intentional: those values were populated by the surrounding `useEffect` hooks and must survive the reset.

## Verdict
**Approve**
Score: 98/100
Critical: 0 | High: 0 | Medium: 0 | Low: 0 | Nit: 2

## Issues

### Critical
None

### High
None

### Medium
None

### Low / Nit

1. **Preserved-key list could be derived instead of enumerated.** The seven explicitly preserved keys are exactly the complement of `initialFormValues` keys minus `paymentMethods` and `remark`. A destructuring form (`const { pharmacyBill, serviceBill, servicePackageBill, procedureBill, paymentMethods, remark, ...preserved } = formMethod.getValues(); formMethod.reset({ ...initialFormValues, ...preserved });`) would be ~3 lines instead of 9 and removes the risk that someone adds a new key to `initialFormValues` and forgets to preserve it. Borderline — the explicit list is more grep-friendly and equally correct, so this is a style preference, not a defect.

2. **No test for the post-delete form state.** This is a behavioral fix with a clear observable outcome (form must be empty after delete). A small Jest/RTL test asserting that after `deleteEdBillingAction` resolves, the form values for `pharmacyBill.items`, `serviceBill.services`, etc. are reset would lock the fix in. Not required for a 12-line patch, but worth a follow-up.

## Recommendation
- Approve and merge.
- Optional follow-up: collapse the preserved-key enumeration into a single destructure of `formMethod.getValues()`, and consider a unit test for the delete-success path.