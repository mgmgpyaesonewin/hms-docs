# Code Review: PR #2791 — Fix - wrong label name in special lab test name, prevent tailing-leading spaces in create and update

**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `issue/ppz/25/special-lab-test-86exzqfxd` → `development`
**Files changed:** 2 (+25 / -10)
**Reviewer:** code-reviewer skill (automated, independent re-review)
**Date:** 2026-06-24
**ClickUp ticket:** https://app.clickup.com/t/9018849685/86exzqfxd

## Summary

The PR addresses two distinct, small, real issues in the special-lab-test feature:

1. The `SpecialLabTestForm` text input was labeled `Test Script Name` / `Enter Test Script Name` — a copy-paste from another lab form — and is correctly relabeled to `Special Lab Test Name` / `Enter Special Lab Test Name`. (`special-lab-test-form.tsx:60-61`)
2. The service layer accepted `data.specialLabTestName` verbatim and passed it straight to the repository, so users could create or update a `special_lab_test` row whose name was `"  CBC  "`, `"  "`, or `""`. The PR trims the name in both `createSpecialLabTest` and `updateSpecialLabTest`, then guards against the empty-after-trim case with a 400 `AppError`. (`special-lab-test.service.ts:42-49, 76-80, 107-110`)

The intent is correct and the surface area is small. The implementation is largely on the right track, but it has a real **High**-severity gap: trim/empty-guard is applied **only in the service layer** for create + update, with no equivalent fix in the form-layer Zod schema, the repository, the unique-name conflict detector, or the new logger message. The `AppError("Special Lab Test name cannot be empty", 400)` text duplicates a near-identical existing 400 error on `:52` of `createSpecialLabTest` ("name already exists"), but the trim is checked *before* the uniqueness check, which is the right ordering — that ordering is the strongest part of the diff. The label fix is fine. There is a **Medium** consistency issue: the new check is `if (!trimmedName)` which rejects `""` (good) but the error message uses the singular "name", while the rest of the service uses `Special Lab Test Name` (capitalized) in error messages — minor cosmetic drift. There's also a **Low** concern that the PR does not backfill existing rows in the DB with leading/trailing whitespace, but for a small CRM-style entity, that is a known limitation rather than a defect.

## Verdict

**Request changes**

Score: 68/100
Critical: 0 | High: 1 | Medium: 2 | Low: 2 | Nit: 2

## Strengths

- **`src/app/(dashboard)/lab/special-lab-test/features/components/special-lab-test-form.tsx:60-61`** — The label fix is exact and consistent: both the visible label and the placeholder are updated in one go. No orphaned string in the file. This is the kind of copy-paste bug that slips through code review constantly and the author caught it.
- **`src/app/(dashboard)/shared/lab/services/special-lab-test.service.ts:42-49` and `:76-80`** — The trim happens **before** the uniqueness check (`findSpecialLabTestByName(trimmedName)`), so a user typing `"  CBC  "` and an existing row named `"CBC"` will now correctly collide. Re-ordering the existing-flow check above the trim guard would have produced the opposite (and wrong) behavior. The author got the ordering right.
- **`src/app/(dashboard)/shared/lab/services/special-lab-test.service.ts:46-48` and `:78-80`** — The `if (!trimmedName)` guard rejects empty-after-trim with `400 AppError`, matching the project's existing error pattern (`AppError("Special Lab Test Name already exists.", 409)` on line 56). The guard is in both create and update paths — symmetric.
- **`src/app/(dashboard)/shared/lab/services/special-lab-test.service.ts:55-60` and `:107-110`** — The repository calls receive `{ ...data, specialLabTestName: trimmedName }`, not just the trimmed name — preserving every other field. The diff does not accidentally drop unrelated fields (like `description`, `price`, or whatever else `CreateSpecialLabTestSchema` carries — I cannot see the schema in this PR's diff).
- **Diff size** — `+25/-10` across 2 files is the right size for a label-fix + input-trim ticket. Compared to PR #2780 (lab-template, +545/-244 across 7 files), this is exactly what `Fix` PRs should look like.
- **No scope creep** — No unrelated utilities touched, no unrelated refactors. The two files modified are the two files that need to change.

## Issues

### High

- **`src/app/(dashboard)/lab/special-lab-test/features/components/special-lab-test-form.tsx` — trim is not applied at the form/Zod boundary, only in the service layer**

  The PR trims the name inside `createSpecialLabTest` / `updateSpecialLabTest`, but the form still sends the raw (untrimmed) string from the Mantine `<TextInput>` to the server. The Mantine `TextInput` renders the user's literal input; the `form.register("specialLabTestName")` writes that literal into the form state; the submit handler presumably calls the service or a server action with the raw string. There are three concrete consequences:

  1. **Other consumers of the service bypass the trim.** If any future caller (background job, seed script, tRPC procedure, bulk import) calls `createSpecialLabTest` with untrusted data, it must remember to trim itself — there is no type-system or schema-level guarantee. The empty-after-trim `400` guard is in the service, so empty still throws, but `"  CBC  "` will silently land in the DB with leading/trailing whitespace.

  2. **The Zod schema is the canonical validation boundary.** The codebase pattern (per `hms-app/CLAUDE.md` — "Validate input at system boundaries") is to trim inside the Zod schema with `.trim()`, so every server action / service / tRPC procedure sees a normalized value. The PR bypasses that convention.

  3. **The Mantine `TextInput` shows the raw (untrimmed) value.** If the user types `"  CBC  "` and the form's internal state holds `"  CBC  "`, validation error messages, defaultValue seeding on edit, and `value` resets on `reset()` all use the untrimmed value. There's no UX bug here *yet* (the user sees their own typed whitespace), but combined with (1) the inconsistency is a smell.

  **Suggested fix** (two-line change): add `.trim()` to the `specialLabTestName` field in the Zod schema. The schema lives in `src/app/(dashboard)/shared/lab/validators/special-lab-test.validator.ts` (or similar — I cannot see it from this PR's diff; verify before editing). The schema is the right boundary because it is shared by every entry point that reaches the service. Then the service-layer trim/guard becomes defense-in-depth — keep it, but the primary fix is in the schema.

  Evidence: `special-lab-test.service.ts:42-49, 76-80` — trim is in the service, not in the form's validation. The form file (`special-lab-test-form.tsx`) does not import any validator changes.

### Medium

- **`src/app/(dashboard)/shared/lab/services/special-lab-test.service.ts:46-48` and `:78-80` — Empty-after-trim guard uses a 400 with a new error string, but the rest of the file uses 409 / "Name already exists" — two 400s for "name is bad" is acceptable, but consider extending the Zod schema instead**

  The new `AppError("Special Lab Test name cannot be empty", 400)` is fine and clear. The risk is that a future contributor will reach for *another* manual empty-check when the same field is processed elsewhere (e.g. a bulk import endpoint). The defensive fix is to move the trim+empty-guard into the Zod schema's `.refine()` — that way every entry point gets the same behavior automatically and the service stops carrying validation logic.

  This is a Medium rather than High because the current code is correct; the issue is *durability* across future entry points.

  Evidence: `special-lab-test.service.ts:46-48` (create empty-guard) and `:78-80` (update empty-guard) — both run *before* the uniqueness check, both throw 400. The Zod schema is not shown in the diff but is the natural home for this validation.

- **`src/app/(dashboard)/shared/lab/services/special-lab-test.service.ts:55-60` and `:107-110` — Conflict detector uses trimmed name, but the existing `findSpecialLabTestByName` lookup on `:46` and `:81` does not change the underlying SQL — verify whether the repository's `WHERE` clause already uses `TRIM` or just `=`, otherwise two rows `" CBC"` and `"CBC"` can coexist after this PR**

  The service now trims before calling `findSpecialLabTestByName`, but the repository's lookup predicate is not in this diff. If the repository is doing a plain `WHERE special_lab_test_name = $1` against the new `trimmedName`, that protects against creating `"CBC"` when `"CBC"` exists — but it does **not** protect against an existing row `"  CBC  "` (already in the DB, pre-PR) and a new create of `"CBC"` (trimmed). The two rows will coexist in the DB and `findSpecialLabTestByName("CBC")` will return null, so the new check passes. Then there will be two rows that look identical to the UI.

  **This is a pre-existing data-integrity risk, not introduced by the PR**, but the PR claims to "prevent leading/trailing spaces in create and update" — if the DB already has dirty rows, the PR's claim is only half true.

  **Suggested fixes** (pick one):
  1. Add a one-time backfill migration: `UPDATE special_lab_tests SET special_lab_test_name = TRIM(special_lab_test_name) WHERE special_lab_test_name <> TRIM(special_lab_test_name);` (run as a Prisma migration or raw SQL).
  2. Change the repository's `findSpecialLabTestByName` to use `WHERE special_lab_test_name = TRIM($1)` so the lookup is robust against dirty data.
  3. Document in the PR description that existing dirty rows are out of scope.

  Evidence: `special-lab-test.service.ts:55-60` — `findSpecialLabTestByName(trimmedName)` is called with the trimmed value, but the repository's WHERE clause is not visible in this diff (it's in `special-lab-test.repository.ts`, not modified here).

### Low

- **`src/app/(dashboard)/shared/lab/services/special-lab-test.service.ts:46` and `:78` — Error message uses lowercase "name", but the same file's other error uses capitalized "Special Lab Test Name"**

  `AppError("Special Lab Test name cannot be empty", 400)` on lines 46 and 78 uses lowercase "name", while line 56 uses `AppError("Special Lab Test Name already exists.", 409)` with capitalized "Name". Pick one. Capitalize to match: `AppError("Special Lab Test Name cannot be empty.", 400)`.

  Evidence: `special-lab-test.service.ts:46, 56, 78` — inconsistent capitalization.

- **`src/app/(dashboard)/shared/lab/services/special-lab-test.service.ts:43` — Logger message "Checking if same spcial lab test exists" has a typo (`spcial` → `special`)**

  Pre-existing typo on the `this.logger.info(...)` call. The PR added two new `this.logger.info(...)` calls (`"Creating special lab test"` on line 51, `"Updating Special Lab Test"` on line 105) which use correct spelling. While touching this file, fix the original typo. Two-character change, no risk.

  Evidence: `special-lab-test.service.ts:43` — `this.logger.info("Checking if same spcial lab test exists");` (`spcial`).

### Nit

- **`src/app/(dashboard)/lab/special-lab-test/features/components/special-lab-test-form.tsx:60` — `withAsterisk` is preserved but there's no obvious hint that trimming happens server-side**

  The form shows a required marker (`withAsterisk`) but no client-side trimming. Users who paste `"  CBC  "` and immediately re-edit will see the leading/trailing whitespace in the input — which is correct (don't surprise the user with auto-trim in the input), but if you implement the Zod-schema `.trim()` per the High issue above, consider whether to also strip on `onBlur` for nicer UX. Out of scope for a bug-fix PR — flag for follow-up.

  Evidence: `special-lab-test-form.tsx:60` — `<TextInput withAsterisk … />`, no `onBlur` trim.

- **`src/app/(dashboard)/shared/lab/services/special-lab-test.service.ts:46, 78` — Error class is `AppError` rather than a more specific `ValidationError`**

  The project has `ValidationError` (mentioned in the summary-service CLAUDE.md, but the hms-app likely has an equivalent). If `AppError("...", 400)` is the convention in this service file, then it's fine. Worth a 30-second check: are there other 400 errors in this file that use a more specific class? If yes, use it. If `AppError` is the only class used, keep it.

  Evidence: `special-lab-test.service.ts:56` uses `AppError("...", 409)`. The new guards on `:46, :78` use `AppError("...", 400)`. Consistent with the file's own pattern.

## Scope creep / file placement

There is **no scope creep** in this PR — it touches only the two files that need to change. Good discipline.

The single structural concern is the placement of the trim logic. Putting it in the service layer is acceptable defense-in-depth, but the project's invariant (per `CLAUDE.md` → "Validate input at system boundaries") is that validation lives at the boundary — the Zod schema — and the service trusts its input. The current diff inverts that: the form trusts the user, the service trusts the form, and the repository trusts the service. The trim in the service is correct *now*, but a future bulk-import or seed script that calls the service directly will re-introduce dirty data. Moving the trim into the Zod schema (per the High issue) is the durable fix.

## Type safety & schema issues

- `special-lab-test.service.ts:42-49` — `data.specialLabTestName.trim()` assumes `specialLabTestName` is a `string`. If `CreateSpecialLabTestSchema` makes it optional, `.trim()` on `undefined` throws. Verify the schema is `z.string().min(1)` (or `.trim().min(1)`) before this lands. Cannot verify from this PR's diff — the schema is in a separate file not modified here.
- `special-lab-test.service.ts:46, 78` — `if (!trimmedName)` correctly rejects `""` (after trim), `null`, `undefined`. Good defensive coding.
- `special-lab-test.service.ts:55-60, 107-110` — `{ ...data, specialLabTestName: trimmedName }` is type-safe; `data` is typed as `CreateSpecialLabTestSchema` / `UpdateSpecialLabTestSchema`, and both spreads preserve the original shape. Good.

## Transaction & data integrity

No new transactions are introduced. The existing repository calls (`createSpecialLabTest`, `updateSpecialLabTest`, `findSpecialLabTestByName`) presumably run inside their own transactions in the repository layer (not visible in this diff). The trim is purely client-side string manipulation and does not affect transaction semantics.

The **Medium #2 issue above** is the main data-integrity concern: existing rows with leading/trailing whitespace are not cleaned up by this PR, and the repository's `WHERE` clause is unknown. If the existing data is dirty and the lookup uses plain `=`, the conflict detector will silently miss collisions.

## Performance

No perf concerns. `.trim()` is O(n) on a short string, runs once per create/update. The diff has no new loops, no new queries, no new dependencies.

## Accessibility & UX

- The label fix is a clear UX improvement — `Test Script Name` was misleading for a `specialLabTestName` field. The new label is correct and self-documenting.
- The `placeholder` is also corrected. Good consistency between label and placeholder.
- No keyboard / focus management changes — out of scope for a label fix.
- No ARIA regressions — the form's existing `error={form.formState.errors?.specialLabTestName?.message}` prop is unchanged.

## Error handling

- `AppError("Special Lab Test name cannot be empty", 400)` is clear and user-actionable. The user sees this as a toast (presumably) and knows exactly what to fix.
- `AppError("Special Lab Test Name already exists.", 409)` is pre-existing and unchanged. Good.
- The trim error fires *before* the duplicate-name error, so the user gets the right error first (empty input → empty error, not "already exists").

## Style & consistency

- `specialLabTestName.trim()` (lowercase variable, `.trim()`) is the right primitive — there is no need for Zod `.trim()` at the service layer.
- `if (!trimmedName)` rejects `""`, `null`, `undefined`. JavaScript truthy-check is fine here.
- The error message capitalization drift (Low #1) is the only style nit.
- The new trim/guard is symmetric in `createSpecialLabTest` (lines 42-49, 55-60) and `updateSpecialLabTest` (lines 76-80, 107-110). Good — easy to maintain.

## Questions for the author

1. Is the trim applied in the Zod schema (`CreateSpecialLabTestSchema`, `UpdateSpecialLabTestSchema`) as well, or only in the service? The diff does not show the schema file. If the schema is unchanged, future entry points (bulk import, seed scripts) will bypass the trim. Please confirm.
2. The repository's `findSpecialLabTestByName` uses `WHERE special_lab_test_name = $1` or `WHERE TRIM(special_lab_test_name) = TRIM($1)`? If plain `=`, two rows `"  CBC  "` and `"CBC"` can coexist after this PR. Does the existing data have dirty rows? If yes, is a one-time backfill migration in scope for this PR?
3. The ClickUp ticket title is "wrong label name in special lab test name, prevent tailing-leading spaces in create and update" — does "create and update" include only the service-layer flow, or also bulk imports / API endpoints? If the latter, the schema-level fix (High #1) is required.
4. The `Test Script Name` label was clearly copy-pasted from another form. Are there other forms in the same lab module with similar copy-paste bugs? (e.g. `Microbiology Test Script Name`, `Lab Template Script Name` — out of scope but worth filing a follow-up ticket.)
5. Is `AppError` the right class for a 400, or is there a `ValidationError` / `BadRequestError` in the hms-app error hierarchy? If the latter, prefer it for clarity.

## Cross-references

- **`/Users/pyaesonewin/.claude/CLAUDE.md` §Rules** — "Validate input at system boundaries". The PR trims in the service, not in the schema. The High issue is the canonical application of this rule.
- **`/Users/pyaesonewin/Documents/work/hms-system/CLAUDE.md`** — Confirms hms-app is a Next.js monolith with custom session auth. Not directly relevant to this PR, but confirms the service layer is the right place for *defense-in-depth* validation.
- **`hms-app/CLAUDE.md`** — Out of scope for this review (referenced via the root CLAUDE.md).
- **PR #2780** (lab-template, reviewed 2026-06-24) — showed the cost of bundling unrelated changes (545+/244- across 7 files). This PR correctly avoids that pattern with a 25+/10- diff over 2 files. Worth noting in the verdict.
- **No summary-service or outbox implications** — this PR is purely hms-app. No transaction discipline, HMAC, or tenant-scope concerns.
- **No ADR cross-checks needed** — `hms-docs/architecture/` ADRs are out of scope for a form-label + input-trim fix.

## Verification needed

Things that cannot be verified from the diff alone:

1. **Does the form submit the raw (untrimmed) string, or does it submit the trimmed string via a server-action wrapper?** Trace the form's submit handler to the service. If the form has its own Zod validation that trims, then the service-layer trim is defense-in-depth (good). If not, the service-layer trim is the *only* line of defense.
2. **Is the repository's `findSpecialLabTestByName` using `WHERE name = $1` or `WHERE TRIM(name) = TRIM($1)`?** If plain `=`, the Medium #2 data-integrity concern is real and a backfill is needed.
3. **Is `data.specialLabTestName` typed as `string` or `string | undefined` in `CreateSpecialLabTestSchema`?** If optional, `.trim()` on `undefined` throws — need `.trim() ?? ""` or a schema-level `.min(1)`.
4. **Does the Mantine `TextInput` have a `defaultValue` or `value` prop that's pre-populated with an untrimmed name on edit?** If the form re-renders the input with a dirty defaultValue, the user sees the whitespace and may not realize it's a bug.
5. **Does the `Spcial Lab Test` listing/search API filter by `name LIKE '%query%'` or by exact match?** If LIKE, the trim in the service has no effect on search behavior.
6. **SonarQube Cloud analysis.** The PR comment says "❌ The last analysis has failed." — confirm whether this is a known infra issue or a new finding. The diff is small enough that there should be no new findings.

## Checklist results

- [ ] `console.log` / `console.error` in production — None added in this PR. The `logger.info` calls are fine.
- [x] `any` type annotations — None added in this PR.
- [x] `@ts-ignore` / `@ts-expect-error` / `eslint-disable` — None added.
- [x] TODO / FIXME — None added.
- [x] Hardcoded secrets — None.
- [x] SQL/Prisma injection — N/A (no DB queries in this PR).
- [x] Long files (>500 lines) — Both modified files are well under 500 lines (the service is ~120 lines, the form is ~80 lines).
- [ ] Validation at boundaries — **High gap**: trim is in the service, not in the Zod schema. See High #1.
- [ ] Data integrity for existing rows — **Medium gap**: no backfill migration. See Medium #2.
- [x] Missing `await` inside transactions — N/A.
- [x] Tenant-scope — N/A (hms-app only).
- [x] Permission checks — N/A (no new API routes).
- [ ] Zod schema validation at boundary — **Missing**: see High #1.

## Recommendation

Request changes. The **High** gap (trim not in the Zod schema) is the canonical fix per `CLAUDE.md` §"Validate input at system boundaries" and should be moved to the schema before merge. The **Medium** backfill question is a one-line author clarification — confirm whether existing DB rows have dirty names, and if so, whether a one-time migration is in scope. The **Low** capitalization fix and typo fix are 3-character changes and can land with the same PR.

Once the schema-level trim lands, this PR is an **Approve**. The intent is right, the ordering is right, the scope is right, and the diff size is exemplary.