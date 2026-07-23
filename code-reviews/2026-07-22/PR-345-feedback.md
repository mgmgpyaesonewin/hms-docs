# Code Review: PR #345 — refactor(opd-billing): rename store terminology to counter and update UI labels
**Repository:** MyanCare/YCare-HMS-Service-Module
**Author:** @DaDDy-chilll
**Branch:** `psk/29/echance-opb-bill-ui` → `development`
**Files changed:** 2 (+91 / -118)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86eyar7hp

## Summary
Two-file UI-only refactor of the OPD billing list. (1) Renames the user-facing "Store" label to "Counter" in the list table and filter modal, drops the "Patient Phone No" column, swaps the title "Service Bill List" to "OPD Bill List", updates the search placeholder, and relabels "Payment Terms" to "Payment Term" (singular). (2) Restructures the table column definitions in `opd-billing-table-columns.tsx`: consolidates "Invoice No" + "Bill Type" and "Patient Name" + "Patient Group" + "Patient Type" into single multi-line cells, moves the "Counter" column, and re-orders "Created By" / "Updated By" to the right of the status column. Also flips the Edit-button disabled check from inline (`disabled={!isEditable}` + `pointer-events:none`) to render-guard (`isEditable ? <Edit/> : null`).

The PR mixes a pure rename with substantial structural UI restructuring under one commit. Most of the "rename" claims in the title/body are accurate; the column restructuring is bundled in silently.

## Verdict
**Approve with suggestions**
Score: 84/100
Critical: 0 | High: 1 | Medium: 2 | Low: 2 | Nit: 3

## Issues

### Critical
None

### High

1. **PR title/body undersells the scope — column restructuring is buried inside a "rename" PR.** `opd-billing-table-columns.tsx` removes the `Patient Phone No`, `Patient Group`, `Patient Type`, and `Bill Type` columns entirely, merges them into composite cells under "Patient" and "Invoice No / Bill Type", moves the Counter column, and reorders "Created By" / "Updated By" to the right of `status`. This is a visible behaviour change to users (different columns, different sort affordances, different column order) — reviewers and QA will not infer it from the title "rename store terminology to counter". Split into two PRs, or at minimum amend the body to enumerate every column change. (Ponytail: the rename fits the diff's stated intent; the cell-consolidation does not — and once cells are merged, downstream consumers expecting separate columns lose data they may have been copy-pasting.)

### Medium

1. **Behaviour change to the Edit button is undocumented and potentially a regression.** The diff replaces `<Edit/> disabled={!isEditable} pointer-events:none` with a render-guard `isEditable ? <Edit/> : null`. Same visible result, but the old form preserved the button in the DOM for keyboard tab order and accessibility tree; the new form removes it entirely. For users relying on screen-reader orientation (knowing "this row has no Edit action" vs. "this row has a disabled Edit action"), the affordance signal changes. If the goal is to also disable keyboard focus, the new form is better; if the goal is purely visual, the old form is more accessible. Either way, this is a deliberate change that should be called out in the PR body, and the rationale (a11y vs. visual) should be explicit.

2. **Cell merge drops `Bill Type` as an independent sortable column.** Users who filter by bill type (e.g., pharmacy-bundled OPD bills vs. consultation-only) can no longer sort or filter by it independently — the value is buried in a small grey sub-line under the invoice number. If `opdBillings` ever fed an Excel export or downstream CSV, those columns would now need to be re-derived from the cell. Worth confirming no API/CSV consumer expects the four removed columns (`Patient Phone No`, `Patient Group`, `Patient Type`, `Bill Type`) as separate fields.

### Low / Nit

- **Low: Inconsistent label casing with the rest of the project.** "OPD Bill List" vs. the surrounding "OPDBillingListPage" / "opdBillingPaymentStatus" identifiers and the page-level title that was previously "Service Bill List" (full English). Verify the rest of the billing nav still says "OPD Billing" / "OPD Bills" so the list page is not the odd one out.

- **Low: `Payment Terms` → `Payment Term` (singular) is unrelated to the stated rename.** If the rest of the codebase uses plural ("Payment Terms" elsewhere in the OPD billing flow), this label flip is gratuitous and will look like a typo. Either include it in the PR title or revert to match the rest of the UI.

- **Nit: Hard-coded style values `#6b7280` and `0.8em` for the sub-line.** The existing `UserNameDateCell` and other components presumably already encode these styles via a className/tokens. Two inline `style={{...}}` props in the column definitions will be hard to keep visually consistent if the design system ever changes; consider reusing the existing secondary-text utility if one exists, or extracting a `<SecondaryLine>` helper if there are now 3+ call sites (currently 2, so inline is fine — but flag for the next refactor).

- **Nit: `upperFirst(row.original.patientGroup) || "-"` silently swallows the case where `patientGroup` is an empty string.** `upperFirst("")` returns `""` which is falsy, so the `|| "-"` works, but it would be cleaner as `upperFirst(row.original.patientGroup ?? "-")` or to match the surrounding `?? "-"` pattern used elsewhere in the file.

- **Nit: Composite column id `Invoice No / Bill Type` with a slash.** TanStack table column ids typically become keys in `columnVisibility` / `sorting` state; a `/` in the id is unusual and may need escaping in URL state. Consider keeping `id: "Invoice No"` and rendering the sub-header separately.

## Recommendation
1. Update the PR title and body to enumerate every column change and the Edit-button render-guard swap — currently hidden behind a "rename" headline. Reviewers, QA, and product should sign off on the column consolidation as a deliberate UX decision, not as an incidental cleanup.
2. Decide whether `isEditable ? <Edit/> : null` is a deliberate a11y change or should be reverted to the disabled-with-pointer-events pattern. Add a one-line comment in code explaining the choice either way.
3. Confirm no CSV/Excel export or downstream API consumer expects `Patient Phone No`, `Patient Group`, `Patient Type`, or `Bill Type` as separate fields — they are now collapsed into composite cells.
4. Reconsider whether `Payment Terms` → `Payment Term` belongs in this PR. If it's part of a broader label-normalization sweep, mention it; otherwise revert.
5. After the above, ship — the rename work itself is clean and the cell-consolidation is a real UX improvement (less horizontal scrolling on the OPD billing page) once it's intentional.
