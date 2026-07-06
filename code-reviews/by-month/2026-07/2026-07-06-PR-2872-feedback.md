# PR #2872 — fix: delete icon hide base on opd invoice

**Repo:** MyanCare/Ycare-HMS
**PR:** https://github.com/MyanCare/Ycare-HMS/pull/2872
**Author:** Xkill119966
**Changed files:** 1 (`src/app/(dashboard)/emr/endo/features/components/endo-opd-emr-table-columns.tsx`, +43/-35)
**ClickUp:** https://app.clickup.com/t/9018849685/86exw9bcm
**Verdict:** Changes requested

## Summary

Small, well-scoped UI fix to the Endo OPD EMR table actions cell: a single `canEditOrDelete` flag is split into `canEdit` and `canDelete` so the delete icon can additionally be hidden when the linked appointment has any `OPDBilling` rows, while the edit icon keeps its previous behavior. The PR also fixes a pre-existing `aria-label="Edit"` typo on the delete button (now `"Delete"`). The change is correct in intent and the rendered structure is reasonable, but a few small things should be tightened before merge: the misleading variable name `hasOpdBillingInvoiceId` does not actually check an invoice id, the two PermissionGuards now run unconditionally while their children are conditional (a minor over-rendering smell), the explanatory comments restate the code, and there is no test for the new branch.

## Strengths

- The shape of the fix is right: a one-line rule addition ("if an OPD invoice exists, hide Delete") plus the minimal JSX restructuring needed to express it.
- The pre-existing `aria-label="Edit"` typo on the delete button is fixed in the same pass — a free a11y win.
- Preserves the existing `PermissionGuard` semantics on both actions.
- Net +8 lines for a behavior change plus a typo fix.

## Issues

### Important

1. **`hasOpdBillingInvoiceId` is a misleading name** — `endo-opd-emr-table-columns.tsx` (new line ~110). The variable is computed from `appointment?.OPDBilling?.length > 0`, i.e. it is an existence/relation check, not an invoice-id check. Rename to something that matches what it actually represents, e.g. `hasOpdInvoice` or `hasAppointmentOpdBilling`. The naming contradicts the PR title ("base on opd invoice") — readers will look for an invoice id and not find one.

2. **PermissionGuard runs for every row even when the icon is hidden** — `endo-opd-emr-table-columns.tsx` (around lines 138-175). Old structure was `{canEditOrDelete && (<><PermissionGuard>…</PermissionGuard><PermissionGuard>…</PermissionGuard></>)}`. New structure is two siblings: `<PermissionGuard action="Edit">{canEdit && …}</PermissionGuard>` and `{canDelete && <PermissionGuard action="Delete">…</PermissionGuard>}`. The Edit-side guard now mounts and runs its permission check on every row regardless of `canEdit`; before, it only ran when `canEditOrDelete` was true. Check `PermissionGuard`'s implementation — if it does an O(1) lookup in a permissions map this is harmless, but if it does a context read, a render-prop, or any other non-trivial work it is now wasted on rows where the icon is hidden. Fix: keep the outer conditional as the *cheap* one and the inner guard as the *real* gate, matching the original layout for the Edit branch:
   ```tsx
   {canEdit && (
     <PermissionGuard action="Edit" subject="OPDEMR">
       <Tooltip label="Edit">…</Tooltip>
     </PermissionGuard>
   )}
   ```
   The Delete branch is already structured this way; do the same for Edit.

3. **No test for the new branch** — neither a Jest/RTL test on the column nor an updated screenshot/story. The previous behavior (both icons always tied to `canEditOrDelete`) was wrong; the new behavior must be locked down. At minimum one assertion that "when `appointment.OPDBilling.length > 0`, the delete icon is not rendered and the edit icon still is."

### Nit

4. **Explanatory comments restate the code** — `endo-opd-emr-table-columns.tsx` (lines 113-117):
   ```tsx
   // Edit is hidden when Lab or Imaging billing exists
   const canEdit = !hasLabBilling && !hasImagingBilling;
   // Delete is hidden when Lab, Imaging, or OPD Billing exists
   const canDelete = !hasLabBilling && !hasImagingBilling && !hasOpdBillingInvoiceId;
   ```
   Both lines just narrate the boolean expression below them. `canEdit` and `canDelete` already say this. Delete the comments.

5. **PR title grammar** — `"fix: delete icon hide base on opd invoice"`. Repo history shows past PRs use titles like `fix(emr/endo): hide delete icon when opd invoice exists`. The current title reads like a sentence-fragment note to self.

6. **Relation traversal uses `length > 0`** — `appointment?.OPDBilling?.length > 0`. Idiomatic for "is there any" is `Boolean(appointment?.OPDBilling?.length)` (handles `undefined` cleanly). The current form returns a boolean either way (`undefined > 0` is `false`), so functionally fine, but `Boolean(...)` reads more clearly at the call site.

7. **PR body is just a ClickUp link** — for a behavior change like this, a one-line "hides Delete when an OPD invoice exists for the appointment; Edit is unchanged" in the PR description would help reviewers and future archaeologists.

## Recommendations

- Rename `hasOpdBillingInvoiceId` → `hasAppointmentOpdBilling` (or similar that matches what it actually checks).
- Restructure the Edit branch to match the Delete branch (outer `canEdit` conditional, inner `PermissionGuard`) so the guard only runs when the icon is about to render.
- Delete the two restating-the-code comments above `canEdit` / `canDelete`.
- Add one test asserting that `OPDBilling.length > 0` hides only Delete, not Edit.
- Tighten the PR title and add a one-line description in the body.

## Reviewer notes

- This is a UI-only defense. If the server-side delete endpoint for OPDEMR doesn't already 409/422 when an OPD invoice exists for the appointment, a user (or any authenticated client) can still trigger deletion by hitting the API directly. Worth confirming with the author that the server guard exists, or filing a follow-up. The PR's value is in stopping the *honest mistake* in the UI — not in enforcing the rule.
- The relation `appointment.OPDBilling` is being relied on to mean "any OPD invoice has been issued for this appointment." If the team later introduces a separate `OPDBilling.invoiceNo` or a "paid/draft" status, this check will need to follow that lifecycle. Worth a comment in code (`// ponytail: hides Delete on ANY OPDBilling row; tighten to "paid" invoices when status lifecycle lands`) if you want to leave a breadcrumb, otherwise the next reviewer will rediscover this nuance.
- Unrelated to this PR but visible in the diff: `canEditOrDelete` was previously a combined guard; this is the second time the same cell has needed to be split (the first was the original `aria-label` typo). If the EMR table grows another conditional per icon, consider moving the per-action predicates into the column helper module so the JSX stays flat.