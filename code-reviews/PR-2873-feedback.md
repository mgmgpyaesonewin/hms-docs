# PR #2873 — Fix: CRID not showing in cathlab request table

**Repo:** MyanCare/Ycare-HMS · **PR:** https://github.com/MyanCare/Ycare-HMS/pull/2873
**Branch:** `issue/ppz/sprint-26/cathlab-request-form-86ey51qeh` → `development` · **Author:** Pyae41
**Diff:** 1 file · +4 / -8 · **ClickUp:** 9018849685/86ey51qeh
**Verdict:** Approve with one clarification

> Reviewed with `engineering-skills:code-reviewer` (quality lens) and `ponytail:ponytail-review` (simplification lens). Synthesized below.

## Summary

A 12-line, single-file JSX fix in the cathlab request-list table:

1. **Request ID column** — removes a `patientType === OPD || EMERGENCY` guard that was rendering `—` for OPD/ED patients and always shows `row.original.requestId ?? "—"`. Also drops the now-unused `patientType` import.
2. **Admission ID column** — adds `?? "—"` fallback for consistency with the Request ID column (and with the rest of the table).

The deletion-only direction on the Request ID cell is the right one. The added `?? "—"` on Admission ID closes a small inconsistency where the column rendered `undefined` (blank) when `admission` was null while every sibling column rendered `—`.

## Strengths

- Pure deletion. Net `-4` lines. Removes a now-unused import rather than leaving it dangling.
- Brings the Admission ID cell into line with the `?? "—"` pattern the table already uses elsewhere.
- No new abstractions, no new state, no new dependencies.

## Issues

### Clarification needed (not blocking, but flag before merge)

**C1. Was the deleted `patientType === OPD || EMERGENCY` guard intentional?** — `src/app/(dashboard)/cathlab/request-list/features/components/cathlab-request-table-columns.tsx:16-22` (pre-diff).

The removed branch suppressed CRID for OPD/ED patients. If CRID generation was deliberately scoped to IPD admissions (because OPD/ED requests don't go through the same request-number pipeline), then showing `requestId` for OPD/ED now will surface either `null` (handled by `?? "—"`) or a misapplied number from a different flow. Worth a one-line confirmation from the author against the ClickUp ticket before merge.

If the guard was a leftover from before CRID was extended to OPD/ED, the deletion is correct and this is moot.

## Quality findings

- None of substance. The `Box miw={120}` and `Box miw={150}` wrappers are preserved; the cell render stays minimal.
- No `console.log`, no commented-out dead code, no leftover imports.

## Simplification findings

- The diff already is the simplification. The deleted `pt`/`hideForOpdOrEd` variables and the `patientType` import were the only over-engineering residue on this column.

**Ponytail net:** `-4` lines, already lean. Ship as-is.

## Recommendations

1. **Confirm C1 against the ticket** (or a quick `git log -p` on this file to see when the `patientType` guard was added and why).
2. **Smoke-test on an OPD patient**: visit the cathlab request list, filter to a known OPD patient, verify `Request ID` shows the expected value (not `null`, not an IPD-scoped number).
3. No code changes required.

## Reviewer notes

- PR title `Fix - CRID not showing in cathlab request table` is clear and matches the diff.
- One-file, +4/-8 diff is exactly the shape of a focused bug fix.
- `next.config.ts` ignores ESLint/TS errors at build time — `npm run lint && npm run typecheck` locally before merge.
- The author's PR body links to the ClickUp ticket and notes UAT was done on Dev_02. Good.