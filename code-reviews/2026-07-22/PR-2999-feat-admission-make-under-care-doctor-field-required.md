# Code Review: PR #2999 — feat(admission): make under care doctor field required
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/28/update-admission-form` → `development`
**Files changed:** 3 (+70 / −2)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86ey4c7am

## Summary
The PR makes the "Under Care Doctor" field required on the IPD admission form. It (1) introduces a reusable `requiredSelectValue` Zod helper that turns `""` / `null` into `undefined` and enforces `min(1)`, applies it to `admissionUnderCaredoctors[].doctorId`, and adds a `withAsterisk` UI marker. It also swaps the field's option list from `doctorsOpts` (all doctors) to `doctorsInOpts` (IN_SERVICE only). A new Jest test asserts the required-when-empty behavior and that the new-born schema is unaffected.

## Verdict
**Request changes**
Score: 73/100
Critical: 0 | High: 1 | Medium: 2 | Low: 1 | Nit: 2

## Issues

### Critical
None

### High

**H1 — Behavioral change smuggled into a "required field" PR.** The hunk in `admission-form.tsx` swaps `data={doctorsOpts}` to `data={doctorsInOpts}` alongside the `withAsterisk` addition. `doctorsOpts` returns every active doctor; `doctorsInOpts` filters to `doctorType === "IN_SERVICE"`. That is a separate product decision (and indeed it is split into commit `5234741dd refactor(admission): update doctor options data source in admission form` on the branch — but `gh pr diff` against `development` still folds both into this PR's review surface, and the PR title and body describe only the required-field change). Two issues ride together with no migration note: (a) existing admissions taken against OUT_SERVICE doctors in this field will now silently become invalid (the dropdown no longer shows them); (b) the reviewer has to discover the swap from a one-line `data={...}` change. Split or call it out: this is the kind of change a follow-up audit of "what was approved" misses if it lives inside a "field validation" PR. The risk is real because the form is the source of truth for `admissionUnderCaredoctors`.

### Medium

**M1 — `requiredSelectValue` helper has one call site.** The helper factory `(message: string) => z.preprocess(...)` is introduced for a single use case — `admissionUnderCaredoctors[].doctorId`. It mirrors the existing `optionalBloodType` and `optionalSelectValue` patterns in the same file (those are reused), so the pattern itself is justified, but the parameterization is premature: no second caller exists. Inline it now; extract when a second required-select field actually shows up.

```
M1 ponytail: shrink: requiredSelectValue helper used once.
Replace with the inline preprocess.
```

**M2 — Test does not cover the multi-row, empty-all-rows path the UI produces.** The form initialises `admissionUnderCaredoctors: [{ doctorId: "" }]` (or appends additional rows from the "+" button) and the schema's `.optional()` on the array still lets a missing/empty array through. The test only asserts `[{ doctorId: "" }]` fails. Add at least one assertion that a fully-populated form with multiple empty rows produces one issue per row, and confirm `[]` / `undefined` still parse (since `.optional()` is preserved). Without this, a future refactor that, say, switches the schema to `.min(1, "...")` on the array could regress silently.

### Low / Nit

**L1 — Test fixture is not representative of a real admission payload.** `validAdmissionPayload` omits most fields the superRefine and the rest of `baseAdmissionFormSchema` accept (no `maritalStatus`, no `ethnicGroup`, no Nrc for the patient, no `newBornBabies`, etc.). It happens to pass only because those fields are `.optional()`. Acceptable for a unit test, but if anyone copy-pastes it as a starting point for future schema tests, the coverage gaps will hide. A short comment in the fixture noting "minimal valid payload for this assertion; see the integration tests for full coverage" would help.

**N1 — `doctorsInOpts.map(...)` re-filters the same array that `doctorsOpts` and `doctorsOutOpts` also map over.** The PR doesn't introduce the duplication (it predates it), but every `Select` consumer now reads `doctorsData?.result.doctors` three times per render and runs three independent `.map`/`.filter` chains. Not this PR's debt; mention only so the diff isn't read as a "clean refactor" of the option pipeline. Ponytail says: leave it, the form is fine.

**N2 — `safeParse` + `expect.objectContaining` for the error shape is fine, but a positive control that the schema accepts `[{ doctorId: "abc" }]` is missing.** Without it, a regression that flips `.optional()` back to `.required()` on every field could pass both tests. Cost: two lines.

## Recommendation

1. Land the M-side of this PR only (schema helper, `withAsterisk`, tests). Revert the `doctorsOpts` → `doctorsInOpts` swap in `admission-form.tsx` (keep it as commit `5234741dd` on the same branch, but address it separately — add a clear body line that it is a separate intent, ideally a second PR). That restores a clean review surface: "required field" PR + "doctor option source" PR.
2. If you keep the helper, drop the parameterization and inline it; reintroduce the factory only when a second required-select field appears.
3. Strengthen the test: add the multi-row empty case and a positive case for an accepted `doctorId`.
4. Verify downstream that no existing admission in production references an OUT_SERVICE doctor as `admissionUnderCaredoctors[].doctorId` — the data migration story is silent in the PR description, and the schema isn't tightened (array stays `.optional()`), so old data won't break, but the UI will silently drop the option to keep using those doctors.

Once H1 is addressed (split or document the option-source swap) and the multi-row test path is added, this is straightforward to approve.
