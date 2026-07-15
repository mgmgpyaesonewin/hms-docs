# PR #2937 — Enhance admission form validation

- **Author:** April-Naing
- **Branch:** `enhance/april/sprint27/admission-form-validation` → `development`
- **Files changed:** 3 (`+74 / -7`)
- **ClickUp:** https://app.clickup.com/t/9018849685/86ey3btw6
- **URL:** https://github.com/MyanCare/Ycare-HMS/pull/2937

## Summary

The form previously submitted even when the NRC triplet (`stateCode` / `nrcTownship` / `nrcType`) or the `nrcNo` / `passPort` field was empty for the selected identity type. This PR:

1. Splits the Zod schema in `admission-form.schema.ts` into a `baseAdmissionFormSchema` plus a `superRefine` wrapper that enforces identity-specific required fields.
2. Rewires `edit-admission.schema.ts` to merge from the *base* schema so that editing doesn't re-validate the disabled identity fields (with a comment explaining why).
3. Wires `error={errors.patient?.X?.message}` onto each affected input and adds `withAsterisk` (and a manual `*` for the Mantine `Group` containing the NRC triplet).

Net behaviour change is correct and the bug it fixes is real — patients could previously be admitted without an NRC/Passport value.

## Verdict
**Approve with suggestions**
Score: 83/100
Critical: 0 | High: 0 | Medium: 2 | Low: 3 | Nit: 3

---

## Findings

### Correctness / validation

**1. `superRefine` duplicates the `optionalSelectValue` precondition unnecessarily**

`admission-form.schema.ts` already runs every NRC/Passport field through `optionalSelectValue = z.preprocess(...z.string().nullable().optional())`, which means before `superRefine` runs the values are either `string` or `undefined`. The current checks do `!data.patient.stateCode || data.patient.stateCode.trim() === ""`. The `.trim()` is the only thing the precondition doesn't already do, but a SelectInput that submits an empty string is normally pre-validated upstream. If the only thing `superRefine` is checking is "field present and non-empty", you can drop the whole wrapper and use a `discriminatedUnion` on `patientIdentity`:

```ts
const nrcIdentity = z.object({
  patientIdentity: z.literal("NRC"),
  stateCode: z.string().min(1, "State code is required"),
  nrcTownship: z.string().min(1, "Township code is required"),
  nrcType: z.string().min(1, "NRC type is required"),
  nrcNo: z.string().min(1, "NRC No is required"),
  passPort: z.string().nullable().optional(),
});

const passportIdentity = z.object({
  patientIdentity: z.literal("Passport"),
  passPort: z.string().min(1, "Passport is required"),
  stateCode: z.string().nullable().optional(),
  nrcTownship: z.string().nullable().optional(),
  nrcType: z.string().nullable().optional(),
  nrcNo: z.string().nullable().optional(),
});

// z.discriminatedUnion("patientIdentity", [nrcIdentity, passportIdentity, /* fallback for undefined identity */])
```

That also makes the error paths identical to what the form already binds (`patient.stateCode.message`, etc.) without manual `ctx.addIssue`. Worth at least considering — `superRefine` is the right tool when the rule is genuinely cross-field; here it's just per-field conditional `min(1)`.

**2. The "identity not set" branch is silently allowed**

If `patientIdentity` is `undefined` (which the TS type permits — `patientSchema` makes it optional), `superRefine` does nothing. Combined with the fact that `patientId` is also not validated for emptiness here, an admitted-patient form with no identity selected at all will pass schema validation and only fail at submit if the API rejects it. Probably want an explicit:

```ts
if (!identity) {
  ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Identity is required", path: ["patient", "patientIdentity"] });
}
```

Or — better — make `patientIdentity` non-optional on the schema.

**3. `.trim()` on a Mantine Select value is the wrong normalization layer**

If `nrcTownship` legitimately has whitespace you don't want trimmed (NRC codes don't, but as a rule): empty-string-from-Select is what `null`/`undefined` is for. Mantine Select already returns `null` when cleared in v7. If a string slips through with whitespace it's almost certainly a data-entry bug worth surfacing as a different error than "required". Minor.

### Type safety / API contract

**4. `edit-admission.schema.ts` is now derived from a non-public name**

`baseAdmissionFormSchema` is exported (good — has to be), but nothing in the codebase or the docs hints at the contract: "create schema adds a `superRefine`; edit schema uses the base". A future contributor adding a *new* required field to the base schema will silently apply it to both, which is what you want for some fields and not for others. Two options:

- Rename to `admissionFormBaseSchema` and add a JSDoc block on it (the comment currently lives on the `editAdmissionSchema` side, where it's least discoverable).
- Or leave a one-line `// base for create + edit; create adds identity superRefine` on the base export.

**5. `id: z.string({ required_error: "Admission ID is required." })` on the edit schema is unreachable**

`edit-admission.schema.ts` is the *edit* schema. The `id` always comes from the route param / server, never from user input. Adding `required_error` here is defensive theater — Zod will always receive a string. Not harmful, just dead.

### UX / form binding

**6. Manual asterisk for the NRC triplet uses raw Tailwind classes inside a Mantine form**

```tsx
<Text c="error" className="relative -top-1 ml-0.5">*</Text>
```

Mantine has a `required` prop on `Input.Wrapper`/`TextInput`/`Select` that renders the asterisk for you with the same red color and the same vertical alignment as the label. The whole `<div className="flex">…<Text>…<Text c="error">*</Text></div>` block reduces to wrapping the three selects in a single `<Input.Wrapper label="NRC" required>` (or marking each `Select` with `required` + their existing label). Currently you have two different asterisk styles in the same form (Mantine's `withAsterisk` for ID/NRC No/Passport, hand-rolled `<Text c="error">*</Text>` for NRC). One render path, one style.

**7. NRC triplet `error={errors.patient?.X?.message}` may be undefined for legitimate empty Select**

When `errors.patient?.stateCode?.message` is `undefined`, Mantine still allocates the error DOM node but renders nothing — usually fine, but if any of the three selects gets a Mantine warning about controlled-error-with-undefined in your version, prefer `error={errors.patient?.stateCode?.message ?? undefined}` explicitly or leave the `error` prop off entirely (the `formState.errors` will still show on submit). Minor.

### Security / async / performance / resources

Nothing notable. This is a client-side validation change with no I/O.

### Tests

**8. No schema unit tests added**

`hms-app` doesn't have a strong unit-test culture for Zod schemas (per CLAUDE.md there's no mention of a Jest setup for `src/app/(dashboard)/shared/ipd/schemas`), so this may match house style. But the schema is now non-trivial: identity-conditional required fields, two schemas with different rules, and the relationship to the edit schema is the kind of thing a 30-line test would lock in. If adding tests is in scope, one spec covering `(create) empty NRC identity → 4 errors`, `(create) empty Passport identity → 1 error`, `(edit) empty NRC fields → 0 errors` would be enough.

---

## Over-engineering / ponytail pass

`admission-form.schema.ts:L108-152: shrink: 45-line superRefine block. discriminatedUnion on patientIdentity + per-field min(1), ~25 lines and same error paths.`

`admission-form.schema.ts:L46-L106: native: baseAdmissionFormSchema rename + JSDoc on the base export, not on the create wrapper — the contract is base-only.`

`admission-form.tsx:L691-L701: native: hand-rolled <div className="flex"><Text/><Text c="error">*</Text></div>. Mantine Input.Wrapper with required prop, 0 JSX nodes added.`

`edit-admission.schema.ts:L11-L13: yagni: id: z.string({ required_error: ... }). id comes from the route, never empty, no UX.`

`net: ~30 lines possible.`

---

## Verdict

**Approve with suggestions.** The PR fixes a real bug (admission forms submit with empty identity fields) and the create-vs-edit split is well thought out — the `superRefine` wrapper plus `editAdmissionSchema` reusing the base is a clean separation. The findings above are tightening, not blocking:

- The big one is **finding 1** (`discriminatedUnion` over `superRefine`) and **finding 6** (use Mantine's `required`/`withAsterisk` consistently). Both shorten the diff and remove the hand-rolled asterisk markup.
- **Findings 2 and 8** are worth a follow-up if the team has appetite for a small schema test; **findings 3, 4, 5, 7** are nice-to-have.

No security, async, or data-integrity issues. Safe to merge once the `superRefine` vs `discriminatedUnion` choice is settled.

## Recommendation

- **Before merge:** consider replacing the `superRefine` block (Finding 1) with `z.discriminatedUnion("patientIdentity", …)` — same error paths, ~20 fewer lines, no manual `ctx.addIssue` calls.
- **Before merge:** decide whether `patientIdentity` should be required on the schema or rejected explicitly when undefined (Finding 2) — currently an empty-identity form passes validation.
- **Before merge:** drop the hand-rolled `<Text c="error">*</Text>` for the NRC triplet in favour of Mantine's `Input.Wrapper required` / `withAsterisk` (Finding 6) so the form has one asterisk style.
- **Nice-to-have:** add a one-file Zod spec covering `(create) empty NRC → 4 errors`, `(create) empty Passport → 1 error`, `(edit) empty NRC → 0 errors` (Finding 8).
- **Optional:** document the base-schema contract on the base export (Finding 4) and drop the unreachable `id` `required_error` (Finding 5).

Score breakdown: 100 − (2 × 4 Medium) − (3 × 2 Low) − (3 × 1 Nit) = **83 / 100**.
