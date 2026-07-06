# PR #2839 — fix: imaging reading multi select to single select

**Repo / State / Author / Branch:** `MyanCare/Ycare-HMS` / OPEN / @Xkill119966 / `fix/imaging-reading-doctor-select` → `development`
**Diff stats:** 6 files, +66 / -42 (single commit `6a1383ab`)
**CI:** not reviewed here (local `npm run tsc && npm run lint` are source of truth per hms-app README)
**Verdict:** ✅

## Summary

Replaces `MultiSelect` with `Select` for the "Reading Doctor" field across the six imaging result forms (CT, ECG, Echo, MRI, Ultrasound, X-ray) and narrows the option list to `doctorType === "IN_SERVICE"`. The change is correct and minimal: it preserves the underlying schema (`readingDoctorIds` is still an array, so the API contract is unchanged) while fixing the UX (only one reading doctor per imaging result) and the data quality (excluding non-active doctor types). One root-cause question and a few nits; nothing blocks merge.

## Risks

- **Schema is still array-typed.** `readingDoctorIds` remains `string[]` in Zod/Prisma; the form now writes a 1-element array. Any caller/server-side logic that assumes `> 1` element is fine, but any code that assumes exactly one (e.g. `findFirst` over the array) still works. Low risk, but worth a quick grep on the server side.
- **Sibling `MultiSelect` instances elsewhere in imaging.** The same `readingDoctorIds` field shape may exist in other forms not touched here (e.g. lab/pathology). If those forms also semantically need single-select, they will show the same UX bug. This PR fixes the imaging screens; flag it for the next round.
- **`IN_SERVICE` filter is client-side.** Doctors not in service disappear from the dropdown. If a legacy/audit read shows `readingDoctorIds` containing a non-IN_SERVICE doctor id, opening an old form will now present an empty select with no option that matches. Acceptable (legacy data is rare) but mention to the user if old records exist.
- **No backfill / no migration** — correct, this is a UI-only change.
- **No accessibility regression** — Mantine `Select` is a11y-equivalent to `MultiSelect` for single-value semantics.

## Findings

### 🔴 Critical

- None.

### 🟠 High

- **No change to the field shape, schema, or API contract.** `readingDoctorIds` remains a `string[]` server-side. The PR mixes a *semantic* change (single doctor) with a *cosmetic* one (MultiSelect → Select) by adapting the form via `value={field.value?.[0] ?? null}` and wrapping `onChange` to rebuild a 1-element array. This is the right call (no migration, no breaking API change), but the PR title and commit message don't acknowledge it. **Action:** add a one-line note in the PR body / commit body explaining the deliberate shape preservation, e.g. *"Form schema unchanged — `readingDoctorIds` stays `string[]` for API compatibility. Single-select UX enforced client-side; an empty selection posts `[]`."* This protects the next developer who might be tempted to "clean up" the schema.

### 🟡 Medium

- **Root cause vs. symptom — is the multi-select even the bug?** The ticket says "imaging reading multi select to single select," implying the *capability* is wrong. But the change also silently narrows the doctor list to `IN_SERVICE`. If a radiologist on `OUT_SERVICE` / visiting / locum type was the *correct* reading doctor for a legacy case, this PR makes them unselectable. **Action:** confirm with the ticket author that the active filter belongs in this fix (it probably does — radiology sign-off usually implies internal staff — but it's a domain decision worth a single comment or a follow-up issue).
- **Sibling screens likely have the same bug class.** Six imaging forms were touched and they all share the same `readingDoctorIds` field, the same `MultiSelect`, and the same doctor-option derivation. The diff is essentially the same 6-line edit copy-pasted six times. This screams shared component opportunity — see **Ponytail notes** below. **Action:** file a follow-up issue (do **not** bundle into this PR) to extract a `<ReadingDoctorSelect doctors={...} value={...} onChange={...} />` wrapper that all six forms consume.
- **`IN_SERVICE` filter hardcoded as a string literal in 6 places.** If the enum value ever changes (e.g. `IN_HOUSE`), every imaging form must be updated. A shared helper or a server-side filter on the doctor list query would be the lazy fix — see **Ponytail notes**.

### 🔵 Low / Nit

- **Duplicated `value`/`onChange` adapter logic in 6 files.** The `value={field.value?.[0] ?? null}` + `onChange={(v) => field.onChange(v ? [v] : [])}` pair is identical across all six forms. Hoist into a tiny `useSingleFromArrayField` hook or a wrapper component (see Ponytail).
- **`?? []` fallback already exists on the `doctorsOptions` line.** Fine, but with the new filter it's effectively `[]` more often. Mantine `Select` handles empty `data` cleanly — no UX regression, just noting that the `|| []` is now mostly defensive.
- **No label change.** "Reading Doctor" is singular now. Consider `"Reading Doctor (primary)"` or simply leave as-is — Mantine `Select` doesn't say "(single)" and the UX is self-evident. Leave it.
- **`searchable` not enabled.** Mantine `Select` defaults to a non-searchable dropdown. With dozens of in-service doctors in a hospital, users will likely want type-to-search. The old `MultiSelect` defaults to searchable. **Action:** add `searchable` to the new `Select` (one-line change) — small UX win that matches the old component's behaviour.
- **No tests added.** Pure UI swap; no behavioral test existed before for this field either. Acceptable — the relevant invariant ("at most one value selected, persisted as a 1-element array") is small enough that a unit test on a shared wrapper (see Ponytail) would be the right place to add it.

## Ponytail notes

- **Reuse-first check:** The 6 forms share a near-identical block (doctor list query → options derivation → form field with same label/placeholder). A `<ReadingDoctorSelect>` component or `useReadingDoctors()` hook would collapse 6 ~10-line diffs into 6 1-line usages and one component file. This is the textbook "extract on the second occurrence, not the first" call — but here we have **6** occurrences in one PR. The Ponytail ladder rung 2 ("already in this codebase?") says: **the codebase already has the pattern 6 times, just inconsistently maintained — make it a real component now**. Don't bundle into this PR; file a follow-up.
- **Bug fix = root cause:** The user-visible bug is "the user can pick 2 reading doctors for one imaging result." Root cause is two-fold: (a) `MultiSelect` is the wrong component, (b) the option list wasn't narrowed to in-service doctors. The PR fixes both — good. The deeper root cause is "6 forms re-implementing the same doctor-select widget" — not in scope here, but worth flagging.
- **Stdlib:** Mantine `Select` already accepts `searchable`, `clearable`, `nothingFoundMessage`, `limit`. Use the props the component ships with — don't build a custom combobox. (Adding `searchable` is rung 3/4 territory — zero new code, big UX gain.)
- **No new abstractions:** Don't introduce a `DoctorType` enum wrapper, a `useFilteredDoctors` hook, or a `DoctorSelectProvider`. The right abstraction is the wrapper component, and only when sibling forms are touched.
- **Deletion over addition:** The PR removes `MultiSelect` from imports and the field rendering, which is correct. The filter addition is a tiny net-positive — one extra `.filter()` call.
- **`ponytail:` comment opportunity:** If the team defers the shared component, leave a `// ponytail: 6 copies — extract <ReadingDoctorSelect> when a 7th form is added` on each file so the next person sees the intent.

## Reuse check

- **Mantine `Select`:** already imported everywhere → reused. ✓
- **Doctor data hook (`useGetDoctors` / equivalent via `doctorsData`):** already in use → reused. ✓
- **Filter `doctorType === "IN_SERVICE"`:** a single-line string compare, but appearing 6× — duplicate. Ponytail would hoist this into the doctor-options derivation in one shared helper.
- **Form field adapter (`field.value?.[0] ?? null` / `field.onChange(v ? [v] : [])`):** identical in 6 files — duplicate. Candidate for a `singleFromArrayFieldProps(field)` util or a small `<SelectArraySingle>` wrapper.
- **No new dependencies added.** ✓ (grep the diff — only import removal + filter addition.)

## Tests

- **Existing tests:** none cover this field directly; no regression test suite touched.
- **Manual verification needed (post-merge):**
  1. Open each of the 6 imaging result forms with an existing record → single-select shows the previously-saved doctor pre-selected.
  2. Clear the field → save → reopen → field is empty (verifies `[]` round-trip).
  3. Pick a different doctor → save → reopen → field shows the new doctor.
  4. Confirm doctors list is restricted to `IN_SERVICE` (open dropdown, scroll — no out-of-service / visiting types visible).
  5. Verify server payload still sends `readingDoctorIds: ["..."]` (1-element array), not a bare string. Network tab check.
- **No CI-required test changes.** `npm run tsc && npm run lint` should pass — only JSX/import change + a string literal filter; type surface is unchanged.
