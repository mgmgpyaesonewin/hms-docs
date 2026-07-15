# Code Review: PR #2896 — fix: building and room make optional in ipd service request
**Repository:** MyanCare/Ycare-HMS
**Author:** @Xkill119966
**Branch:** `fix/building-and-room-optional-ipd` → `development`
**Files changed:** 3 (+31 / -23)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-08
**ClickUp:** https://app.clickup.com/t/9018849685/86ey2y9qn

## Summary
Makes `buildingId`, `roomId`, and `roomName` optional in the IPD OT request schema (allowing empty / null submissions) and removes the `withAsterisk` required-indicator from the corresponding form fields. Side effects:
- Refactors `createIPDOTRequestSchema` from `.and(otReferralRequiredSchema)` to `.extend({...referral fields}).superRefine(...)`, and keeps `otReferralRequiredSchema` as a "backward compatibility" alias.
- Removes all four `// @ts-expect-error` annotations on `useFieldArray` calls in both `ot-request-form.tsx` files.
- Replaces `buildingId: z.string().min(1)` and `roomId: z.string().min(1)` with custom `z.preprocess` blocks that log the input/output to `console.log` on every validation.

## Verdict
**Request changes**
Score: 68/100
Critical: 0 | High: 2 | Medium: 3 | Low: 2 | Nit: 0

## Issues

### Critical
None

### High
1. **`console.log` debug instrumentation ships in the production schema** — `src/app/(dashboard)/shared/ot/schemas/create-ipd-ot-request.schema.ts:62-77`. The new `buildingId` and `roomId` schemas wrap their input in `z.preprocess` whose first action is `console.log("[OT Schema] buildingId input:", val, "type:", typeof val)` plus a second log on the output. This fires on every form validation in production. Two patterns already exist in this same file (`optionalNumberSchema`, `optionalBloodTypeSchema`) and in the parallel OPD schema (`create-opd-ot-request.schema.ts:65-70`) that achieve "optional empty-string field" cleanly with no logging and no preprocess — the diff reinvents the pattern with debugging baked in.
   - Fix: replace each preprocess+log block with `z.string().nullable().optional()` (matching OPD). Drop all six `console.log` lines.

2. **Dead "backward compatibility" shim + duplicated referral fields** — `create-ipd-ot-request.schema.ts:199-221`. The PR replaces `createIPDOTRequestBaseSchema.and(otReferralRequiredSchema)` with `createIPDOTRequestBaseSchema.extend({ referralType, referralOutType, referralDoctor, referralClinic }).superRefine(otReferralRefine)`, then re-exports the old name as `otReferralRequiredSchema` for backward compat. Two problems:
   - A repo-wide grep for `otReferralRequiredSchema` and `otReferralBaseSchema` returns zero consumers outside this file — the alias is dead code.
   - The `.extend(...)` block duplicates the four referral field declarations that already exist in `otReferralBaseSchema` (and were copied from the original `otReferralRequiredSchema`). The whole `otReferralBaseSchema` extraction is unnecessary — just `.extend({ ... }).superRefine(otReferralRefine)` directly on `createIPDOTRequestBaseSchema`, or simpler: inline the referral fields into `createIPDOTRequestBaseSchema` since they were already inlined via `.and(...)` in spirit. Net: ~12 lines can be deleted.

### Medium
3. **Inconsistent null/undefined convention vs. established OPD pattern** — `create-ipd-ot-request.schema.ts:69-77`. The IPD `buildingId`/`roomId` preprocess returns `null` for empty values (`val === "" || val === undefined || val === null ? null : val`), while the OPD schema already in this repo (`shared/opd/schemas/opd-ot-request/create-opd-ot-request.schema.ts:65-70`) uses `z.string().nullable().optional()` and returns `undefined` for `""`. Pick one convention. The simplest and most idiomatic is to drop the preprocess entirely (see fix in High #1).

4. **Unjustified removal of `// @ts-expect-error` on `useFieldArray("assistantNurses")`** — `ipd/features/components/service-request/ot/ot-request-form.tsx:549` and the parallel file at `ot/request-list/features/components/ot-request-form.tsx:442`. The other three removals are explained by the schema moving from `.and(...)` (intersection) to `.extend(...)` — the "complex type" comment now genuinely no longer applies. The fourth comment, however, said "it works anyway" (different justification), and the schema change doesn't address the `assistantNurses` field type, which is declared identically to `anesthetists`/`assistantDoctors` in `createIPDOTRequestBaseSchema`. If `@ts-expect-error` was genuinely not needed before, it was never needed and could have been removed earlier; if it was masking a real type error in `assistantNurses`, that error is still latent. Either way, the removal needs a comment explaining why now is safe.

5. **No server-side confirmation that nullable building/room survives the action pipeline** — `ipd/features/actions/ot-request.action.ts` and `ot/features/ipd-ot-request.action.ts` both validate against `createIPDOTRequestSchema`. The PR relaxes the schema, so they will accept `null`/undefined for `buildingId`/`roomId`/`roomName`. The downstream Prisma write must tolerate null in those columns; this isn't visible in the diff and there's no migration or backfill mentioned. The PR title implies this is a known-safe change (presumably those columns are already nullable in the DB), but a one-line confirmation or migration reference in the description would be cheap insurance.

### Low / Nit
6. **`Input.Wrapper` label for "Room" loses the asterisk but still renders** — `ipd/.../ot-request-form.tsx:1334`. This is intentional and correct (label is still shown, just not flagged required), but the `Building` field above it has the asterisk removed at line 1316 with the same result. No action needed — flagging only because Mantine users sometimes expect `withAsterisk={false}` to be explicit; the current form (omitting the prop) is fine.

7. **`passthrough()` removed from the main schema but kept on the legacy alias** — `create-ipd-ot-request.schema.ts:218-220`. The new `createIPDOTRequestSchema` no longer has `.passthrough()`. If callers were relying on extra keys being preserved through the `.and(...)` intersection (unlikely but possible), behavior silently changes. Low risk in practice because the actions use `zod` validation, not key passthrough, but worth a one-line check.

## Recommendation
1. Replace the two `z.preprocess` blocks with `z.string().nullable().optional()` to match the OPD schema and drop all six `console.log` lines (fixes High #1 and Medium #3 together, ~15 lines net).
2. Delete the `otReferralBaseSchema` extraction and the `otReferralRequiredSchema` alias shim; inline the four referral fields directly into `createIPDOTRequestBaseSchema` (fixes High #2, ~12 lines net).
3. Either justify or re-add the `// @ts-expect-error` on `assistantNurses` (fixes Medium #4).
4. Confirm in the PR description that the DB columns for `buildingId`/`roomId`/`roomName` are nullable, or attach the migration that makes them so (fixes Medium #5).

Net of all four: about 30 lines deleted from the schema file alone, no behavior change for any current caller, no debug noise in production.