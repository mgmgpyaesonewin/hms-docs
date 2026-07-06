# PR #2884 — fix: add referral clinic validation for service request forms

**Repo:** MyanCare/Ycare-HMS
**PR:** https://github.com/MyanCare/Ycare-HMS/pull/2884
**Author:** Xkill119966
**Branch:** → `development`
**Changed files:** 8 (+304 / -96)
**State:** OPEN
**Verdict:** Changes requested (1 Critical, 2 Important, 3 Medium, 4 Nit)

## Summary

Adds Clinic-side validation to the four service-request Zod schemas (HD / OT / Endo / Cathlab) and lifts the HD form's parallel `referralOutType` state into react-hook-form. The intent — stop accepting a clinic form whose `referralClinicId` does not match the referral doctor's primary clinic, or whose doctor doesn't match the referral type — is right, and the test coverage (`referral-clinic-validation.node.test.ts` + the schema-level safeParse negative cases) is reasonable.

But the diff ships (1) leftover debug `console.log` to production, (2) the same `referralValidationRefine` block copy-pasted four times with diverging fixes for what is really the same upstream serialization bug, (3) six `@ts-expect-error` directives on `useFieldArray` calls, one with a typo (`@-expect-error`) that doesn't actually suppress, and (4) the OT schema silently softens `referralDoctor` from `min(1)` required to `nullable().optional()`, a behavior change no reviewer's going to catch from the diff. The substantive validation logic is fine; the diff shape needs cleanup before merge.

## Strengths

- New `referral-clinic-validation.node.test.ts` exercises the four schemas (HD/OT/Endo/Cathlab) with valid and invalid referral-clinic combos — covers the new rule directly.
- The `referralValidationRefine` logic itself is correctly written: looks up `referralClinicId.referralDoctorId[0]` (or equivalent), checks the clinic is one of the doctor's clinics, surfaces a path-keyed issue so react-hook-form highlights the right field.
- Lifting `referralOutType` into the HD form's RHF state cleans up the parallel `useState` form/side-state dance.
- Schema-level negative tests (`safeParse({...})` with bad combos → `success: false`) catch drift in the refine path independent of any render harness.
- Domain-aware — same logic in all four modules, no per-module bypass.

## Issues

### Critical

1. **`console.log` debug noise (with emoji) left inside `otReferralRefine`** — `src/app/(dashboard)/shared/ot/schemas/create-ipd-ot-request.schema.ts:115-150`. The log includes referral-doctor and clinic IDs and ships in the OT bundle — i.e. it runs in the browser. Two problems: (a) browser-console noise in production, and (b) the IDs are pseudo-PII that end up in any browser-console sharing plugin (e.g. Datadog RUM, Sentry session replay). Delete or gate behind `process.env.NODE_ENV !== "production"`. This is a ship-blocker.

### Important

2. **`referralValidationRefine` is copy-pasted across all four schema files** — `cathlab/schemas/*`, `endo/schemas/*`, `hd/schemas/*`, `ot/schemas/*`. A small helper module (e.g. `shared/referral/schema/validation.ts`) that exports one `referralValidationRefine` factory taking the two field names as arguments would deduplicate ~80 lines and close the obvious divergence points (`===` vs `==`, `some(...)` vs `length > 0`, the null-string check). The current copy-paste means a fix to one schema's clinic rule will silently miss the other three.

3. **`@ts-expect-error` used as a structural escape hatch on six `useFieldArray` calls** — and at least one has a typo: `@-expect-error` on `ipd/.../ot-request-form.tsx:558`. Typos like that don't suppress anything; they get treated as a regular comment and TypeScript surfaces the underlying error to the production build (although `next.config.ts` ignores errors at build time, so it slips through to runtime). Audit every `@ts-expect-error` and `@-expect-error` in the diff: either fix the underlying type mismatch (preferred — `useFieldArray` should be typeable here) or replace with a real `// @ts-ignore` if the suppression is unavoidable.

### Medium

4. **Endo edit-page Suspense wrapper change is scope-creep into an unrelated PR** — `endo/features/components/edit-page.tsx`. Wrapping the edit page in `<Suspense>` for a service-request-referral validation PR is unrelated. Either split into its own PR or revert; bundling unrelated changes makes the diff harder to review and harder to revert.

5. **Endo page error states use plain `<div>` + raw `error.message` interpolation** — same `edit-page.tsx`. Mantine `<Alert>` (or any of the existing error UI patterns in this repo) renders a typed, themed error; raw `error.message` interpolation surfaces whatever the upstream error library produces, including stack traces if a `Error` is passed through. Use the existing `formatError` / `<ErrorAlert>` pattern.

6. **OT schema silently changes `referralDoctor` from `min(1)` required to `nullable().optional()`** — `create-ipd-ot-request.schema.ts`. Required → optional is a behavior change. Audit every OT caller (`otRequestCreateAction`, the OT action adapters in the proxy-bill/OT-emr flows, any action that maps the form state to an API call) to confirm an empty `referralDoctor` is acceptable. If it isn't, add `min(1)` back. Either way, document the intent — calling out a behavior change in the PR body costs nothing and protects the next reader.

### Nit

7. **HD schema formatting regression** — the new HD schema file lost a blank line that was present in the pre-PR source (`hd/schemas/*` after the patch). Trivial; flag and fix.

8. **50 lines of dead commented-out Zod discriminated union in OT schema** — `create-ipd-ot-request.schema.ts` near the new refine. The dead code is actually the right architecture for the cross-field check (a discriminated union over `referralOutType` would express the whole rule at schema level without the `superRefine`) — if the team has appetite, swap the refine for the union and delete the dead block. Otherwise just delete the dead block.

9. **PR body is just a ClickUp link.** For a 304-line change spanning 4 modules and a behavior change in the OT schema, one paragraph describing the new rule and the test plan would help.

10. **OT schema uses string literal `"REFERRALIN"` instead of the enum import** — sibling files use `ReferralType.REFERRALIN`. Cosmetic; grep-replace to the enum.

11. **`referralDoctorId` is no longer asserted empty when `referralOutType === "CLINIC"`** — `referralValidationRefine` in all four schemas. The prior copy-paste accidentally covered the case where a clinic-form had a referral-doctor selected; the new version (which only checks the clinic-vs-doctor match) silently accepts a clinic-form with both a doctor AND a clinic. Decide whether that's a regression (most likely yes) and add the empty-doctor-on-clinic check back, or call out the loosening in the PR body.

## Security / Privacy

- The Critical `console.log` leaks referral IDs to browser console in production. Fix in #1.
- Other than that, no secrets, PII handling, or permission boundary changes. Auth still routes through the same BFF endpoints.

## Recommendations

1. **Remove or gate the `console.log`** in OT schema — Critical.
2. **Extract `referralValidationRefine` factory** into `shared/referral/schema/validation.ts` — Important #2, closes the next clinic-rule fix in one place.
3. **Audit every `@ts-expect-error` and `@-expect-error`** in the diff — fix the underlying type or replace with a real escape hatch. Important #3.
4. **Revert the Endo Suspense + raw-error-message change** into its own PR — Medium #4, #5.
5. **Decide the OT `referralDoctor` semantics** (required vs optional, empty-on-clinic check) — Medium #6, #11.
6. **Delete the 50 lines of dead discriminated-union comments** in OT schema — Nit #8.
7. **Use the enum import** in OT schema — Nit #10.

## Reviewer notes

- The HEAD commit and the diff agree — and the substantive validation work is correct. The blockers are (a) the production debug `console.log` and (b) the `@ts-expect-error` typo. The structural complaints (refactor, scope-creep, behavior-change documentation) are ship-able in a follow-up but should at least be tracked.
- This is a pure-schema/UI change — no DB, no auth, no summary-service impact. Lowest-risk category *after* the `console.log` is removed.
- Verification with `console.log` removed: a manual test that submits an HD-form with a referral-doctor whose primary clinic is NOT the selected `referralClinicId` should land a field-level error message on `referralClinicId`; a matching pair should pass. Repeat for the other three modules. The unit test `referral-clinic-validation.node.test.ts` already covers the negative cases; this just confirms the UI wiring flows through RHF.

**Ponytail net estimate:** refactor the four schema refinements into one factory, delete the dead union comments, drop the unused `useFieldArray` suppressions — net -90 to -120 lines possible.
