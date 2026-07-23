# Code Review: PR #2999 — feat(admission): make under care doctor field required
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/28/update-admission-form` → `development`
**Files changed:** 3 (+70 / -2)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-21
**ClickUp:** https://app.clickup.com/t/9018849685/86ey4c7am

## Summary
The PR makes the "Under Care Doctor" field required on the IPD admission form in two ways: (1) adds a Mantine `withAsterisk` visual indicator on the Select at `admission-form.tsx:1108`, and (2) replaces the nullable `doctorId` schema with a new `requiredSelectValue("Under Care Doctor is required")` helper at `admission-form.schema.ts:15-18, 92` that rejects `""` and `null`. As a side effect the dropdown is now sourced from the in-service doctor list (`doctorsInOpts`) rather than the full list. A new unit-test file asserts that a single row with empty `doctorId` fails validation and that newborn under-care doctors remain optional. Both `createAdmissionSchema` and `editAdmissionSchema` reuse `baseAdmissionFormSchema`, so the requirement applies to create and edit flows.

## Verdict
**Approve with suggestions**
Score: 93/100
Critical: 0 | High: 0 | Medium: 1 | Low: 1 | Nit: 1

## Issues

### Critical
None

### High
None

### Medium

1. **"Required" guarantee is incomplete at the schema level.** `admission-form.schema.ts:89-90` declares the array itself as `.optional()`, and `requiredSelectValue` only guards each row's `doctorId`. As a result, `admissionUnderCaredoctors: []` and an omitted array both pass validation — a direct API caller (or a refactor that doesn't seed the row) can submit an admission with zero doctors. The UI papers over this by seeding the default `[{ doctorId: "" }]` (`admission-form.tsx:156, 217`) and hiding the row's trash button when length is 1 (line 1140), but the schema title in this PR ("make under care doctor field required") implies a backend-level guarantee that isn't there. Add `.min(1, "At least one Under Care Doctor is required")` to the array to make the requirement hold for any consumer of the schema.

2. **Potential regression on edit of legacy rows where `doctorId` was nullable.** Before this PR `admissionUnderCaredoctors[].doctorId` was `z.string().nullable()` and stored as `null` for the empty row (see the existing seed at `admission-form.tsx:156, 217`). Any admission saved under the prior schema whose row was inserted with `null` (or with the form's "empty placeholder" string) will now fail validation in edit mode, because `requiredSelectValue` rejects `""` and `null` with no migration / fallback. Confirm with the team that no persisted rows have a null/empty `doctorId`; otherwise, add a one-time data fix in the migration that follows this PR, or have the prefiller coerce blanks to `undefined` so the form degrades gracefully.

### Low / Nit

- **Low — Test coverage does not pin down the `.optional()` array behavior.** `admission-form.schema.test.ts` covers the "row with empty doctorId" and "newborn exempt" cases, but not `admissionUnderCaredoctors: []` or the array being absent. With the schema as written, both currently pass. Add one assertion that documents the current (weak) contract, or — preferred — extend the schema per the Medium finding and have the test assert the array must be non-empty.

- **Nit — Helper inconsistency vs. existing patterns.** `requiredSelectValue` (`admission-form.schema.ts:15-18`) duplicates the `optionalBloodType` preprocess idiom. The implementation is fine, but consider naming it `requiredSelectString` for symmetry with `optionalSelectValue` already defined at line 47, so future readers find the pair together. Not a blocker.

## Recommendation
1. Add `.min(1, ...)` on the `admissionUnderCaredoctors` array so the "required" guarantee holds for any consumer, not just the seeded form default.
2. Verify (or migrate) that no existing admission row has `doctorId` `null` or `""`, otherwise the new schema will reject those rows on edit.
3. Extend the unit test to cover the empty/missing-array case so the schema contract is documented and locked in.
4. Optional: rename `requiredSelectValue` to `requiredSelectString` to sit beside `optionalSelectValue`.

The change is otherwise correct and well-scoped — the `withAsterisk`, the `doctorsInOpts` switch, and the preprocess-then-`min(1)` schema change are all sound. Approve once the Medium finding on array-level enforcement is addressed.
