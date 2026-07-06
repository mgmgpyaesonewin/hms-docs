# OPD UX Improvements — Agent Team Brief

## Context
- App: `hms-app` (Next.js 15 App Router, Mantine v7, tRPC, Prisma, Zod)
- Surface: OPD billing forms + billing slip + export
- Working dir for changes: `hms-app/`

## Scope (5 tasks)

### T1 — Split-payment auto-calculation
**Where:** OPD billing payment form (multi-payment-method UI).
**Required behavior:**
- When 2+ payment methods are selected, user enters the amount only on the *first* method.
- The remaining methods auto-distribute the remainder so the sum equals the bill total.
- If the user later edits *any* method's amount, the others re-balance live; the total stays correct.
- Edge cases: rounding remainder (last method absorbs it), single-method bill (no auto-calc).
**Reference image:** `hms-docs/opd/prompts/ux_improvement/assets/task_1.png`

### T2 — Payslip discount summary
**Where:** OPD billing slip (print/export view).
**Required behavior:** Add a summary block above the total showing Subtotal, Total Discount, and Net Amount — matching the mock below:
```
Subtotal (Before Discount) 282,000
Total Discount              -2,400
==============================
NET AMOUNT                  279,600
==============================
```
**Reference image:** `hms-docs/opd/prompts/ux_improvement/assets/task_2.png`

### T3 — Patient/Service name spacing
**Where:** OPD billing line items. Add `whitespace: 'nowrap'` (or appropriate truncation/tooltip) so names don't wrap mid-word. Define a min-width and add a hover tooltip for the full text.

### T4 — Remark overflow in View Detail
**Where:** `OPD billing >> View Detail` modal. When `remark` exceeds N chars, the billing amount is clipped. Fix the layout so the amount column is always visible; either wrap the remark or constrain its width with a max-line clamp + ellipsis.

### T5 — Export file: add Patient ID + Doctor
**Where:** OPD billing Excel (.xlsx) export. Add two columns: `Patient ID` and `Doctor`. For Doctor, prefer `fullName` for spreadsheet readability; use `doctorId` only if downstream joins need it. State the choice in the PR.

## Team & Pipeline

Run in order; each phase must produce the listed deliverable before handing off:

1. **senior-frontend** — implement T1–T5. Deliverable: code diff + screenshots of before/after for T1, T2, T4.
2. **code-reviewer** — review the diff. Deliverable: inline comments + a PASS/FAIL verdict. If FAIL, return to frontend with the comment list. Cap at 3 rounds.
3. **senior-qa** — write/run unit tests covering T1 (rounding, single-method, edit-mid-form), T2 (summary numbers match mock), and any tests code-reviewer flagged. Deliverable: green test run + 1-line summary per task.
4. **senior-architect** — final review: does the change respect the v1 → v2 constraints (no new top-level routes, no schema changes, no breaking tRPC contract)? Deliverable: APPROVED or list of concerns.

If any agent blocks for >1 turn waiting on info from the user, post a question to the lead instead of guessing.

## Out of scope
- No DB migrations.
- No changes to summary-service or outbox.
- No new dependencies without explicit approval.

## Done = all five tasks merged with green tests and architect sign-off.
