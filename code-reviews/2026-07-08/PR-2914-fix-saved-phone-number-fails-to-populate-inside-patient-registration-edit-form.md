# Code Review: PR #2914 — Fix - Saved Phone Number Fails to Populate inside Patient Registration Edit Form
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `issue/ppz/sprint-27/patient-86ey5wvjt` → `development`
**Files changed:** 1 (+26 / -14)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-08
**ClickUp:** https://app.clickup.com/t/9018849685/86ey5wvjt

## Summary
The PR fixes the bug where the saved `phoneNo` and `emergencyPhoneNo` values fail to populate inside the Patient Registration edit form. The root cause is that `PhoneInput` (a custom wrapper around `react-phone-number-input`) is internally controlled, so spreading `form.register(...)` — which only forwards `name`/`onChange`/`ref` and not `value` — leaves the component blank after the form hydrates. The fix swaps the two `<PhoneInput>` fields from `register` to `<Controller>` so `field.value` is passed explicitly. An unrelated tweak changes the `bloodType` Select to render `undefined` when the stored value is the sentinel `"None"`.

## Verdict
**Approve with suggestions**
Score: 84/100
Critical: 0 | High: 0 | Medium: 3 | Low: 1 | Nit: 2

## Issues

### Critical
None

### High
None

### Medium

**M1 — Unrelated change bundled into a bug fix (scope creep).** The `bloodType` Select change (`value === "None" ? undefined : value`) is logically independent of the phone-number fix. It belongs in its own PR with its own description, screenshot, and ClickUp link. Bundling makes the fix harder to revert, bisect, or test in isolation, and obscures which change actually resolved the reported symptom. Recommendation: split it out, or at minimum call it out explicitly in the PR body.

**M2 — `emergencyPhoneNo` lost its `className="mb-4"` wrapper positioning consistency.** In the original, both `PhoneInput`s had `className="mb-4"`. After the refactor, `phoneNo` lost its `mb-4` while `emergencyPhoneNo` kept it. The diff is visually inconsistent — verify whether the rendered spacing still matches the original layout, and apply `mb-4` uniformly (or remove it from both) to match the surrounding form pattern. This is the kind of regression a CSS-only fix can quietly introduce.

**M3 — Controller pattern is heavier than needed if the root cause is just `value` not being forwarded.** `react-hook-form`'s `register()` does not return `value`; it intentionally does not (it's an uncontrolled-path API). The minimal fix is `defaultValues` plus forcing a re-render via a `setValue`-on-mount or passing `value` through a `Controller`. Given that the rest of the file uses `register(...)` for `email` and `address` right next to these fields and those work fine, a smaller-diff alternative is a custom thin wrapper that simply forwards `value={form.watch("phoneNo")}`. Worth confirming the team is OK with mixed patterns (register for TextInputs, Controller for PhoneInput) so it does not drift further. If `Controller` is the chosen long-term pattern for inputs with internal state, that's fine — just be intentional about it.

### Low / Nit

**L1 — `error={form.formState.errors?.phoneNo?.message}` vs `error={form.formState.errors.phoneNo?.message}` inconsistency.** The new `phoneNo` block drops the optional-chaining on `errors`, while `emergencyPhoneNo` (and `bloodType` above) keep it. With `react-hook-form` v7+ `formState` is always defined, so the `?.` is dead. Pick one style for the file; mixing is a smell.

**N1 — Extra blank line.** A trailing blank line was inserted after the closing `</Controller>` of `emergencyPhoneNo`. Cosmetic only.

**N2 — `value === "None"` magic-string check.** Hard-coding the sentinel `"None"` in the render path couples this Select to whatever populates `form.defaultValues.bloodType`. A `BLOOD_TYPE_NONE` constant or a `null`/empty-string default would be clearer and safer against future typos. Also confirm the data source for `bloodTypes` does not actually contain a real option named `"None"` — if it does, the comparison would silently swallow a real user choice.

## Recommendation
1. Split the `bloodType` `"None"` → `undefined` change into a separate PR (or justify it inline in the body) — M1.
2. Verify the rendered vertical spacing matches the original form; align `mb-4` on both PhoneInputs — M2.
3. Normalize the `formState.errors?.…` optional-chaining across the file — L1.
4. Consider extracting `BLOOD_TYPE_NONE` to a constant and double-checking that `"None"` is not a legitimate option in `bloodTypes` — N2.
5. The core fix (Controller for PhoneInput) is correct and addresses the reported bug. Ship it after the scope split.