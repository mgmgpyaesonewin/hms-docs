# Code Review: PR #3012 — Change lab template name and type - Microbiology to lab group
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-28/lab-template-name-change-86ey3bfey` → `development`
**Files changed:** 4 (+13 / -7)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-17
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3bfey

## Summary
Renames a seeded lab template from `Microbiology Template` / `MICROBIOLOGY` to `Lab Group Template` / `LAB_GROUP`. Updates both `prisma/seed.ts` and `src/scripts/create-template.ts` so the template is created with the new name/type in fresh environments. Updates `lab-template-columns.tsx` so the routing branch that previously keyed off `MICROBIOLOGY` now keys off `LAB_GROUP`. Also changes `capitalize()` in `src/utils/general-utils.ts` from a first-char-only cap to a snake_case → Title Case transformer.

The PR body notes a SQL query is required in each environment to update rows already in the database — no Prisma migration is included.

## Verdict
**Approve with suggestions**
Score: 92/100
Critical: 0 | High: 0 | Medium: 1 | Low: 2 | Nit: 1

## Issues

### Critical
None

### High
None

### Medium

**M1. `capitalize()` behavior change is a silent, broad-ripple rename of a shared util**

`src/utils/general-utils.ts` is exported and almost certainly used across the app — `capitalize("hello world")` previously returned `"Hello world"` and now returns `"Hello world"` (same), but `capitalize("FIRST_NAME")` previously returned `"FIRST_NAME"` (only first char capped, rest lowercased) and now returns `"First Name"`. The old function was not a true `capitalize` at all (it lowercased everything past index 0), but it still had a defined behavior. The new version changes semantics for callers that passed strings containing `_` or multi-word phrases.

Concrete failure mode: any caller that relies on `capitalize("N/A")` (the one explicit early-return) still works, but a caller like `capitalize(someEnumValue)` that previously got `"Paid"` will now get a different shape if the enum is snake_case.

Two paths forward, pick one:
- (a) Keep this change and audit every `capitalize(...)` caller — `grep -rn "capitalize(" src/` from the repo root — and confirm none of them relied on the old "first-char-uppercase, rest-lowercase" behavior with multi-word/underscored inputs. The PR has no such audit.
- (b) Add a second function (e.g. `humanize(str)` or `titleize(str)`) for the LAB_GROUP display case and leave `capitalize()` alone. The new behavior is "snake_case → Title Case", which is a different function with a different name.

The function's name `capitalize` does not describe "split on `_`, join with space, title-case each segment". Either rename or split.

**Recommendation:** option (b) — introduce a small `formatTemplateType(type)` helper used only in the one place that needs the LAB_GROUP display, or inline it at the call site.

### Low / Nit

**L1. `seed.ts` and `create-template.ts` now contain identical seed blocks**

`prisma/seed.ts` (lines ~228–241) and `src/scripts/create-template.ts` (lines ~21–34) each define the same `templates` array literal with the same hardcoded template entries. This PR edits both files identically, which is the predictable cost of duplication: a future edit will land in one and miss the other. Worth flagging as debt, though not a blocker for this PR.

**L2. SQL update for existing rows is described in prose but not committed**

The PR body says a SQL query is needed to update existing rows in each environment, but no migration file, no script, and no concrete query is included in the diff. That's intentional per the PR description (it's a manual step), but worth surfacing: the team should agree on which file owns the SQL (a one-off `prisma/migrations/<ts>_rename_lab_template_type/migration.sql`? a docs page? a runbook entry in `hms-docs/`?) so it doesn't drift between dev/staging/prod.

**N1. `filter((word) => word.length > 0)` on the split result is dead**

In `capitalize`, `"foo__bar".split("_")` produces `["foo", "", "bar"]` — the empty string filter handles consecutive underscores. Reasonable defensiveness, but a one-line comment (`// collapses runs of "_"`) would make intent obvious to the next reader. Not load-bearing.

## Recommendation
1. Decide the `capitalize` semantics question (Medium M1) before merge — either rename the new behavior to `humanize`/`titleize` and revert `capitalize`, or grep every caller and confirm the old behavior was unused.
2. Land the manual SQL update against dev/staging/prod per the PR body; capture the query in a runbook or migration file so the next environment doesn't have to re-derive it.
3. (Optional cleanup, not required for this PR) Extract the duplicated seed block between `prisma/seed.ts` and `src/scripts/create-template.ts` into a shared constant.

The functional rename of the seeded template (name + type) and the routing branch in `lab-template-columns.tsx` look correct; the only meaningful concern is the silent util change in `general-utils.ts`.
