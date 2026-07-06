# Code Review: PR #2792 — ED emr services cancel

**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `mpt/ed-emr-cancel-service` → `development`
**Files changed:** 1 (+0 / -193)
**Reviewer:** code-reviewer skill (automated, independent re-review)
**Date:** 2026-06-24
**ClickUp ticket:** https://app.clickup.com/t/86exw9gg4

## Summary

This PR is a **pure deletion** (0 added, 193 removed) targeting `src/app/(dashboard)/emr/ed/features/emergency-services/ed-emr-emergency-services.actions.ts`. It removes the entire post-invoice "cancel-only" lockdown layer that was added in PR #2773 ("ED emr cancel service error", merged 2026-06-22) by the same author, on the same branch, against the same ClickUp ticket (`86exw9gg4`). The removed code is a 110-line helper `assertCancelOnlyEdBillUpdate` (plus its 2 utility helpers `valuesMatch` / `amountsMatch`, the error factory `cannotModifyAfterInvoiceError`, the `ExistingEdBill` type alias), a 16-line lockout block at the top of `updateEdBillFromEmrAction`, two imports (`UpdateEdBillSchema`, `prisma`, `AppError`), and two commented-out block placeholders in `createStandaloneEdBillAction` / `createEdBillFromEmrAction`. The two commented-out placeholders are also being deleted in this PR, which is incidental but fine.

The PR is also the second deletion-driven PR on the same branch: PR #2712 ("EMR list and service action control when billing", merged 2026-06-11) introduced the UI-level controls and PR #2773 introduced the server-side "after invoice: only cancel is allowed" enforcement. PR #2792 reverses the server-side enforcement and reduces the feature to its UI-only controls. The PR description is just a copy of the ClickUp ticket URL — there is no prose explanation of *why* the enforcement layer is being removed, no mention of regression tests, no migration/feature-flag plan, and no cross-link to the relevant follow-up work.

The three core concerns a reviewer has to answer for a 193-line pure-deletion PR are: (1) does removing the code leave a dead import or dead route? — **partially** (the `UpdateEdBillSchema` import is correctly removed; `prisma` and `AppError` are correctly removed; but the two commented-out lockout blocks at the top of the create actions are also being deleted, which is the right call but means *both* the server enforcement and the placeholder for future re-introduction are gone in one go); (2) is there a documented decision backing the removal? — **no** (the PR body is the ClickUp URL only; no ADR, no comment, no commit-body rationale); (3) are there callers elsewhere that depend on the removed exports? — **none visible from the diff** (the three exported actions remain and the removed helpers are not exported), but the `edBillService.updateEdBill` call still happens and now it can be called with arbitrary mutations even when an `OPDBilling` row exists, which is the actual behavior change. The ClickUp ticket is the only "documentation" and it predates the original implementation, so the ticket alone does not justify removal of the lockdown it implicitly required.

## Verdict

**Request changes**

Score: 38/100
Critical: 2 | High: 4 | Medium: 3 | Low: 3 | Nit: 2

## Strengths

- **`ed-emr-emergency-services.actions.ts:5-11` (post-diff) — Clean import removal.** After the deletion, the import block at the top of the file no longer references `UpdateEdBillSchema`, `prisma`, or `AppError`. All three were only used inside the removed `assertCancelOnlyEdBillUpdate` / lockout blocks, so removing the import is the right call. No dead-import lint error will fire.
- **`ed-emr-emergency-services.actions.ts:5-11` (post-diff) — All three public actions remain exported.** `createStandaloneEdBillAction`, `createEdBillFromEmrAction`, and `updateEdBillFromEmrAction` are still exported. The schema wiring (`authActionClient.schema(...).action(...)`) is unchanged. Callers will not see a missing-symbol at the route-import level. Good hygiene for a pure-deletion PR.
- **`ed-emr-emergency-services.actions.ts:12-43, :52-70` (post-diff) — Removal of the dead commented-out placeholders.** The two `// const existingBillCount = await prisma.oPDBilling.count({…}); … if (existingBillCount > 0) throw new AppError(…)` blocks at the top of `createStandaloneEdBillAction` (former lines 48-61) and `createEdBillFromEmrAction` (former lines 109-121) were commented-out stubs that referenced `prisma` and `AppError` even though those imports were already going away. The PR correctly deletes them rather than leaving them as misleading "TODO: re-enable" markers. This is one less footgun.
- **`ed-emr-emergency-services.actions.ts:55-58` (post-diff) — `updateEdBillFromEmrAction` is now ~5 lines of business logic.** After the deletion, `updateEdBillFromEmrAction` reduces to a direct delegation to `edBillService.updateEdBill`. The simplification is real, but see the High #1 issue — the simplification is achieved by removing a defense-in-depth check, not by refactoring the lockout into the service layer.
- **No `console.log` / `console.error` added or removed.** The deleted code had no logging of its own; no logging regression.

## Issues

### Critical

- **Removal of the "after invoice: only cancel is allowed" enforcement has no documented rationale and likely re-opens a billing-integrity bug**
  The removed `assertCancelOnlyEdBillUpdate` (former `ed-emr-emergency-services.actions.ts:78-176`) is what enforced the invariant that **once an `OPDBilling` row exists (status ≠ `CANCEL`) for an appointment, the ED bill can only be cancelled — no add, no remove, no qty/price/amount change, no un-cancel of an already-cancelled item**. The accompanying `cannotModifyAfterInvoiceError()` returns a 400 "Cannot modify emergency services after an invoice is generated" message. After this PR, `edBillService.updateEdBill(payload, ctx.session.user.id, { isFromEmr: true, opdEmrId })` is called unconditionally on the EMR update path, with no check that the appointment is in a "pre-invoice" state. The two earlier deleted `// …` blocks at the top of `createStandaloneEdBillAction` / `createEdBillFromEmrAction` were an unrelated, **commented-out** version of the same check (and not active), so the live server-side guard was `assertCancelOnlyEdBillUpdate` only.
  Two concerns from a billing-integrity standpoint:
  1. The PR title is "ED emr services cancel" — it sounds like a *new feature* (allow cancelling services from the EMR) or a *fix* to the existing flow, not a *revert* of the just-merged #2773 enforcement. The ClickUp ticket `86exw9gg4` is shared with #2773, which means this PR is being filed against the same ticket that produced the lockdown 2 days ago. The reviewer is asked to trust that the product owner re-decided in 2 days.
  2. The PR body is *only* the ClickUp URL. There is no commit message body, no PR description prose, no linked issue/PR explaining the re-decision. The author needs to justify this removal in writing — either in the PR body, the commit message, or a new ADR — because the removal is a behavior change for any active ED patient whose appointment has an existing OPD billing row.

  **Suggested fix:** Either (a) revert the deletion and re-open the design discussion in #2773's PR thread, or (b) keep the deletion but add a PR description and commit-body rationale citing the business reason, and add a Jest test that proves `edBillService.updateEdBill` is now called with arbitrary mutations (this is the new expected behavior). At minimum, add a comment to the `updateEdBillFromEmrAction` body explaining that the "after invoice" check has been moved to / is now the responsibility of `edBillService.updateEdBill` — otherwise the next reader will not know whether the absent check is intentional or a regression.

  Evidence: `ed-emr-emergency-services.actions.ts:55-72` (post-diff, the full body of `updateEdBillFromEmrAction` is `return await edBillService.updateEdBill(payload, …)`). Former `:78-176` (`assertCancelOnlyEdBillUpdate` with `cannotModifyAfterInvoiceError`). ClickUp `86exw9gg4` is the same ticket as PR #2773 (merged 2026-06-22). PR #2712 (merged 2026-06-11) introduced the UI-level locks; PR #2773 introduced the server-side enforcement; PR #2792 reverts the server-side enforcement.

- **No test was added for the new (post-removal) behavior, and the tests that covered the lockdown (if any) are likely now broken in unverified ways**
  PR #2773 added 175 lines / removed 22 — that is a non-trivial feature addition that almost certainly came with Jest tests. The current PR removes 193 lines with no test changes (only 1 file in the changedFiles list). Either (a) #2773 did not include tests for the lockout (already a High concern for #2773 that the author has not addressed), or (b) the tests existed and are now failing because the lockdown no longer fires the `cannotModifyAfterInvoiceError` message, or (c) the tests existed and have been silently removed by the deletion in some way the diff does not show. The `gh pr view --files` for #2792 shows exactly 1 file changed, so case (c) is unlikely — meaning the tests for #2773 are now either failing in CI (unreported in the PR) or never existed. The author needs to confirm which.
  **Suggested fix:** run the full test suite locally (`cd hms-app && npm test`) and paste the relevant output (or a green CI link) into the PR. If tests for #2773's lockdown existed and are now failing, either restore the lockdown or update the tests to reflect the new "any mutation is allowed" behavior with a clear test name like `updateEdBillFromEmrAction allows arbitrary mutations after invoice generation`.

### High

- **The "after invoice: only cancel" invariant is now enforced only at the UI layer — a defense-in-depth regression**
  PR #2712 (merged 2026-06-11, "EMR list and servce action control when billing") added the UI-level locks in `ed-emr-emergency-services-tab-component.tsx` and the related `daycare-emr-daycare-services-tab-component.tsx`. PR #2773 added the server-side mirror as defense-in-depth (the canonical pattern in this repo: the UI hides the controls, the server still rejects mutations). PR #2792 deletes the server-side mirror. The new state is: **UI locks the controls; the server accepts whatever the UI sends**. A direct POST to the server action (bypassing the React form), a stale tab with a half-edited payload, a copy-pasted fetch from devtools, or a future code path that calls `updateEdBillFromEmrAction` without going through the tab UI — all of these can now mutate an ED bill after an invoice has been generated. This is the "second wall" pattern: the UI is the first wall, the server check is the second. Removing the second wall in a billing path is a textbook defense-in-depth regression.
  **Suggested fix:** If the product reason for #2792 is "the UI locks are sufficient," document that explicitly in the PR description and add a comment in the action that says so. If the product reason is "the user must be able to edit ED services even after invoicing," the right fix is to *move* the lockdown into `edBillService.updateEdBill` (so the check is not in the route file) and to extend the lockout to OPD and Daycare as well — not to remove it. A bare deletion of the only server-side check on a billing path should not land without the equivalent check being added back somewhere.
  Evidence: `ed-emr-emergency-services.actions.ts:55-72` (post-diff `updateEdBillFromEmrAction` has no check). PR #2712 commit-message in the file list: `ed-emr-emergency-services-tab-component.tsx:18 +/-15` and the sibling `daycare-emr-daycare-services-tab-component.tsx:18 +/-15` — confirms the UI-level locks exist in both ED and Daycare modules, both still do their UI work, but only ED had a server-side mirror.

- **The 110-line removed helper contained non-trivial business logic — value-equality, amount-equality, and item-id matching rules specific to ED billing**
  `assertCancelOnlyEdBillUpdate` encodes rules that are specific to how the ED billing form round-trips data:
  - Services round-trip a stable `id`, so the helper matches by id and re-checks 9 fields per item.
  - Procedures never round-trip a stable id (the repository fully replaces them on every save — see the deleted comment on former `:138-139`), so the helper matches by field values.
  - Pharmacy items match by id + 5 fields, with an extra rule that `existing.cancelRecord?.isCancel && !item.isCancel` is forbidden (no un-cancelling).
  - Service packages have no cancel workflow in this tab; the set must stay untouched.
  These are four distinct domain rules, not boilerplate. Removing the helper removes the only place in the codebase where the "un-cancelling a cancelled item is forbidden" rule lives. If the next round of ED-billing work needs that rule back, the author (or the next maintainer) will have to re-derive it from scratch.
  **Suggested fix:** If the product truly wants to allow un-cancellation, say so in the PR description. If not, the right fix is to keep the helper and just remove the "no un-cancel" check (which is the one rule the product might have wanted to relax). A blanket deletion of 110 lines of business logic is the wrong lever.
  Evidence: former `ed-emr-emergency-services.actions.ts:78-176` (full helper). The four domain rules above are encoded at former `:103-128` (services), `:131-155` (procedures), `:157-176` (pharmacy), `:178-189` (service packages).

- **`valuesMatch` and `amountsMatch` are not exported but they are the only implementation of "Prisma-nullable equality" in the file — if the next round needs the same rules, they will be re-implemented inline**
  `valuesMatch(a, b) => (a ?? null) === (b ?? null)` and `amountsMatch(a, b) => Number(a ?? 0) === Number(b ?? 0)` are tiny but they encode two real conventions: "Prisma returns `null` for missing optional fields, the form sends `undefined`, treat both as equal" and "compare numerics by coercion so `'1.0' === 1` holds." These are the kinds of helpers that get re-invented three times across a codebase. The PR removes them along with the helper. If `edBillService.updateEdBill` or any new caller needs the same comparison semantics, the next person will write a different version.
  **Suggested fix:** Promote `valuesMatch` and `amountsMatch` to `@/utils/equality.ts` (or similar) and keep them, even if the lockout helper is being removed. The helpers are independent of the lockout logic.
  Evidence: former `ed-emr-emergency-services.actions.ts:33-37`.

- **The two deleted commented-out lockout blocks are themselves a regression — they were the only documentation that the post-invoice check *was* once considered for the create paths**
  At former `ed-emr-emergency-services.actions.ts:48-61` (in `createStandaloneEdBillAction`) and `:109-121` (in `createEdBillFromEmrAction`), the deleted code had `// const existingBillCount = await prisma.oPDBilling.count({…}); … if (existingBillCount > 0) throw new AppError(…)`. These were commented-out, but they were the only place in the file that flagged "we considered blocking ED service creation once an invoice is generated and decided not to." Removing the comments means the next maintainer who tries to add the check has no breadcrumb. (Note: I am also calling this out as a Strength because deleting dead comments is generally correct — the two concerns cut both ways, but the High here is the loss of design context.)
  **Suggested fix:** If the design decision is "create paths do not need the check" (which is the more conservative read — the form *creates* a bill, it does not *modify* one), replace the deleted comments with a one-line `// Note: create paths do not block when an invoice exists; only the update path did. See PR #2712 / #2773.` so the next reader does not re-litigate it.
  Evidence: former `ed-emr-emergency-services.actions.ts:48-61`, `:109-121`.

### Medium

- **The `ExistingEdBill` type alias is deleted with the helper, and the equivalent shape is not re-exported anywhere else**
  `ExistingEdBill` is `NonNullable<Awaited<ReturnType<typeof edBillService.getEdBillById>>>`. This is the return type of `edBillService.getEdBillById`. The helper uses it to type-annotate the `existingBill` parameter. After the deletion, the only call site of `edBillService.getEdBillById` (within this file) is gone — but the function itself still exists in `edBillService` and is presumably called from elsewhere. If the next round of work calls `getEdBillById` from a new action and wants the same `NonNullable<…>` pattern, the type alias is no longer in this file. Minor, but a `type` re-export would have preserved the convention.
  **Suggested fix:** If `edBillService.getEdBillById` is called from any other action file, add `type ExistingEdBill = NonNullable<Awaited<ReturnType<typeof edBillService.getEdBillById>>>` near the top of the service file so the convention has one home. Or accept the small loss and move on.
  Evidence: former `ed-emr-emergency-services.actions.ts:28-30`.

- **No CHANGELOG, no version bump, no notification to the team that owns the ED module — a 193-line revert is a release-note-worthy event**
  The HMS team's CLAUDE.md (per the project root) is silent on CHANGELOG conventions, but the size of the change (193 lines removed, 1 file, on a billing-adjacent path) means downstream consumers of the ED EMR module (the ED module's own UI tests, the integration test in `hms-docs/`, any ops team running nightly exports) need to know. The PR has no `## CHANGELOG` section, no `BREAKING CHANGE:` footer, no `cc @ed-module-owners`. If this is a deliberate removal, the right signal is a `## Breaking change` section in the PR body.
  **Suggested fix:** Add a one-paragraph PR body explaining the change in business terms. Even if the body is just three lines ("Reverts the server-side lockout added in #2773 per product re-decision. The UI locks from #2712 remain in place. No data migration required."), that is enough to let the merge button be clicked without a reviewer ping.
  Evidence: PR body from `gh pr view 2792 --json body` is `https://app.clickup.com/t/86exw9gg4` — 36 characters, no prose.

- **The `cannotModifyAfterInvoiceError` message text is now lost — if the same rule ever needs to come back, the message string is gone too**
  "Cannot modify emergency services after an invoice is generated." — this was the user-facing 400 message. The PR removes the only place this string is defined. If a future test or a future re-introduction needs the same message, the author will have to either grep the git history (which still has the string in #2773's commit) or re-invent it. Minor, but worth preserving.
  **Suggested fix:** None required — git history is the right place for removed strings. Calling this out only so the author is aware that the user-facing message has been retired, not relocated.
  Evidence: former `ed-emr-emergency-services.actions.ts:46-49`.

### Low

- **The two utility helpers `valuesMatch` and `amountsMatch` are mentioned in the High #3 issue above; their loss is a Low concern in terms of LOC, not in terms of business meaning**
  See High #3 — the helpers are 2 lines each but encode real conventions. Promote them to a shared utility or accept the loss.
  Evidence: former `ed-emr-emergency-services.actions.ts:33-37`.

- **The `// if (existingBillCount > 0)` block in `createEdBillFromEmrAction` was the *only* design comment in the file explaining the post-invoice decision — its deletion is a Low-concern doc loss**
  See High #4 — the deleted comments were the only breadcrumb. A one-line replacement comment would suffice.
  Evidence: former `ed-emr-emergency-services.actions.ts:109-121`.

- **SonarQube Cloud analysis failed for this PR**
  The single PR comment is from `sonarqubecloud` with status "❌ The last analysis has failed." This is a bot comment, not a code-quality finding, but it means the PR is merging without a Sonar scan. If the codebase has a CI gate on SonarQube status, the merge button will not be available until this is re-run. The reviewer cannot tell from the diff whether the failure is infra (Sonar server down) or a new finding (the deletion triggered a coverage drop in the test file). The author should re-run Sonar and link the green status here.
  **Suggested fix:** Re-run `mvn sonar:sonar` (or whatever the HMS Sonar command is) and paste the URL. If the failure is infra, file a ticket.
  Evidence: `gh pr view 2792 --comments` shows the only comment is the SonarQube bot.

### Nit

- **The PR title "ED emr services cancel" is the same title as PR #2773's sibling, but the action is opposite — consider a title that reflects the reversal**
  PR #2773 = "ED emr cancel service error" (added the lockout). PR #2792 = "ED emr services cancel" (removes the lockout). A future grep for "ED emr" will surface both. Consider "Revert: ED emr cancel service lockout (#2773)" or "Remove: ED emr post-invoice service lockdown" to make the direction explicit.
  Evidence: PR title from `gh pr view 2792 --json title`.

- **The post-diff file is now ~95 lines (down from ~290), well under the 500-line cap — a small win, but worth noting for the next round**
  The action file is now a thin wrapper over `edBillService`. If the next round of work is "re-enable the lockout," the file will grow back. If the next round is "move the lockout into the service," the file will stay thin and `edBillService` will grow. Either direction is fine, but the trajectory should be deliberate.
  Evidence: `ed-emr-emergency-services.actions.ts` post-diff line count is ~95 (the diff is -193 lines, the file was ~290 lines pre-diff).

## Scope creep / file placement

This PR is the *opposite* of scope creep — it is a focused deletion of 193 lines in 1 file. But it is a **silent re-decision** of a design choice that was made 2 days ago (PR #2773) on the same branch. The lack of a PR body means the reviewer has to reconstruct the design history from the linked ClickUp ticket and the related PRs (#2712, #2773). That reconstruction is doable (it is what this review is), but it is not what the author should be asking of every reviewer who looks at this PR. The fix is one paragraph of prose in the PR body.

## Type safety & schema issues

- No new types, no new Zod schemas, no new Prisma queries. The deletion is type-safe by construction: removing a code path that consumed `UpdateEdBillSchema` and `prisma` is fine because the imports are also removed.
- The `ExistingEdBill` type alias is deleted; no caller outside this file referenced it (it was `type` not `export type` — confirmed by the diff, which only removed the definition, not any `import` line). Good.
- No `any` introduced, no `@ts-ignore` introduced, no `as` assertions touched. Type-safety pass.

## Transaction & data integrity

This is the **single most important section** of this review. The PR removes the only server-side check that prevented ED-bill mutations after an `OPDBilling` row had been generated. The full data-integrity implications:

1. **What is no longer blocked:** A user with the ED EMR open in a tab, after an invoice is generated, can now:
   - Add a new service line to the ED bill (previously blocked by the services count check at former `:101-103`).
   - Remove an existing service line (same).
   - Edit qty / price / discount / amount on any existing service (same).
   - Un-cancel a previously cancelled service (previously blocked at former `:126-128`).
   - Same for procedures (count check at `:143-145`, value-equality check at `:147-160`).
   - Same for pharmacy items (count check at `:163-165`, value-equality check at `:168-181`, no-un-cancel check at `:182-184`).
   - Mutate the service-package list (previously blocked at `:189-197`).
   - Change `billTypeId`, `patientId`, `appointmentId`, `storeId`, `displayFOCField`, or `date` (previously blocked at `:96-100`).
2. **What is still blocked:** The UI locks from PR #2712 still hide the controls. Daycare EMR is unchanged. OPD EMR is unchanged.
3. **What is not affected:** The `OPDBilling` row itself is not touched by `edBillService.updateEdBill` (the call is on the ED bill, not the OPD billing). The `OPDBillingPaymentStatus` and the OPD totals are decoupled from this PR.
4. **What might be affected:** The `consultation_fees_invoices` row (CFI) — if one was generated from the OPD billing, and the underlying ED services change, the CFI payout amount (`payout_amount`, frozen at PAID transition per `hms-summary-service` ADR 0005) is *not* recomputed (the CFI is a snapshot). So an ED service change after CFI generation would mean the OPD billing, the CFI, and the ED bill are all out of sync. This is a downstream-consistency concern, not a correctness-of-this-PR concern, but the reviewer should be aware.

The right resolution is **not** "the UI locks are enough" — the UI locks are the first wall, the server check is the second, and removing the second on a billing path is a defense-in-depth regression. The right resolution is to either keep the server check, or move it into `edBillService.updateEdBill` so it lives with the other invariants of ED-bill mutation.

## Performance

No perf impact. Removing 193 lines from a server-action handler reduces the per-request work for `updateEdBillFromEmrAction` by exactly the cost of the `oPDBilling.count`, the optional `edBillService.getEdBillById` (which is a Prisma query with includes — the most expensive part of the deleted code), and the `assertCancelOnlyEdBillUpdate` helper (which iterates over services, procedures, pharmacy items, and service packages with a `for` loop and `Array.find` calls — also non-trivial). On a hot path with many ED patients this is a small but real perf win. Cite this as a strength if the team values the perf gain over the defense-in-depth loss.

## Accessibility & UX

No UX changes — the form is unchanged. The user-visible error message "Cannot modify emergency services after an invoice is generated." (the 400 from `assertCancelOnlyEdBillUpdate`) is no longer reachable, so no toast / inline error regression. Note: if a user previously saw that 400 in a stale state, they will now silently succeed — which is the intended behavior of the PR per the deletion, but the user-facing string is gone, so the user has no way to know "I am doing something the UI did not intend."

## Error handling

- The PR removes the only `throw new AppError(…, 400)` call in this file (the `cannotModifyAfterInvoiceError` factory). The action now has zero `throw` statements — every error path goes through the implicit `safe-action` / `authActionClient` error handler.
- The `edBillService.updateEdBill` call (post-diff line 55) presumably has its own error handling. The reviewer cannot tell from this PR whether that error handling covers the "post-invoice mutation" case. **Verification needed**: read `edBillService.updateEdBill` and confirm it either (a) re-implements the same lockout, or (b) explicitly documents that the lockout has been moved to the UI.

## Style & consistency

- The deletion is consistent with the file's existing style (the helper used the same `valuesMatch` / `amountsMatch` patterns that the rest of the ED module uses).
- The PR does not introduce any new lint violations (no `console.log`, no `any`, no `@ts-ignore`).
- The branch name `mpt/ed-emr-cancel-service` is the same as PR #2773's branch name — both PRs were cut from the same long-lived branch. This is fine for a revert-style PR but means a `git log mpt/ed-emr-cancel-service` will show a "remove the lockout added 2 days ago" commit message, which is unusual. The commit message body of the squash commit should explain this.

## Questions for the author

1. Why is the server-side lockout from PR #2773 (merged 2 days ago, same author, same branch, same ClickUp ticket) being removed? Is the product owner explicitly requesting the reversal, or is this a "the UI locks are enough" call by the author?
2. Is `edBillService.updateEdBill` being modified separately to take over the post-invoice check, or is the check being removed entirely? If the former, that PR should be linked. If the latter, the PR body should say so.
3. Were Jest tests added in PR #2773 for `assertCancelOnlyEdBillUpdate`? If yes, are they now failing in CI? If no, why not?
4. What is the expected behavior of `edBillService.updateEdBill` when called from this action after an `OPDBilling` row exists? Should it accept any mutation, or is there a downstream check I am missing?
5. The two deleted commented-out blocks at former `:48-61` and `:109-121` were in `createStandaloneEdBillAction` and `createEdBillFromEmrAction` — were they ever active in any branch, or were they always commented-out stubs? If they were ever active, the same defense-in-depth concern applies to the create path too.
6. The SonarQube Cloud analysis failed for this PR — is that an infra issue, or did the deletion trigger a coverage drop in some test file?
7. Why is the branch name the same as PR #2773? Is this a follow-up commit on the same branch that was force-pushed, or a new branch cut from `development`?

## Cross-references

- **`/Users/pyaesonewin/.claude/CLAUDE.md` §Rules** — "Do what has been asked; nothing more, nothing less" and "ALWAYS read a file before editing it." The PR is a pure deletion, so the second rule is satisfied. The first rule is the lens through which the reviewer asks "is the author doing what was asked, or is the author reverting a recent decision without justification?"
- **`/Users/pyaesonewin/CLAUDE.md` (project root)** — "The canonical source of truth is `hms-docs/`" — there is no ADR in `hms-docs/` covering the post-invoice ED lockout, and there is no ADR covering the reversal. If the reversal is the new policy, it should be documented in `hms-docs/summary-service/adrs/` (or a new ADR directory under `hms-docs/ed-emr/` if one exists). The fact that the project has a strong docs-first culture and this PR has zero doc updates is a flag.
- **PR #2712** (merged 2026-06-11, "EMR list and servce action control when billing") — the UI-side lockout. The PR body for #2712 lists `86exw7mmj`, `86exw9g2u`, `86exw9gg4` as the ClickUp tickets — `86exw9gg4` is the same ticket as #2773 and #2792. The ticket is a long-running multi-PR effort.
- **PR #2773** (merged 2026-06-22, "ED emr cancel service error") — the immediate predecessor, added the `assertCancelOnlyEdBillUpdate` helper that this PR deletes. 175+ / 22- across 4 files, including a schema type change in `shared/ed/types/emergency-billing.types.ts`. The diff in #2773 is not in this reviewer's hand, but the file list confirms the lockout was a multi-file change.
- **`hms-summary-service` ADRs** — ADR 0005 ("CFI status state machine") and ADR 0006 ("optimistic lock on status change") — both freeze the CFI at PAID transition. If an ED service is mutated after CFI generation, the CFI is stale. Not a regression in this PR, but a downstream-consistency concern.
- **No monorepo-level orchestrator** (per project root `CLAUDE.md`) — the ED module and the summary-service are developed independently. The reversal in this PR does not require a summary-service change, but the CFI consistency concern above is worth raising with the summary-service team.

## Verification needed

Things that cannot be verified from the diff alone:

1. **Does `edBillService.updateEdBill` have its own post-invoice check?** Read `src/app/(dashboard)/shared/ed/services/ed-bill-init.service.ts` and confirm. If yes, the deletion is acceptable; if no, the deletion re-opens the bug #2773 was meant to close.
2. **Are there Jest tests for the lockout in the test suite?** Run `cd hms-app && npx jest --testPathPattern=ed-emr-emergency-services` and check. If tests exist and are now failing, the PR is broken in CI.
3. **Does the UI lockout in `ed-emr-emergency-services-tab-component.tsx` (from #2712) actually hide all the controls the server check used to enforce?** If the UI is incomplete (e.g. a control was added after #2712 without a corresponding UI lock), the deletion means that control is now exploitable.
4. **What does the ClickUp ticket `86exw9gg4` actually say?** WebFetch is denied in this reviewer's environment, but the author should paste the ticket's current status / latest comment into the PR description. If the ticket has a comment from the product owner saying "remove the server check," the PR is justified. If the ticket has no such comment, the PR is not justified.
5. **Is the OPD billing (`OPDBilling`) row modified by `edBillService.updateEdBill`, or is the ED bill a separate table that does not feed back into OPD billing?** If they are coupled, the deletion is a serious data-integrity regression. If they are decoupled, the deletion is mostly a UX/perf change. Confirm the schema.
6. **SonarQube Cloud analysis** — re-run the scan and link the green URL.
7. **Daycare and OPD consistency** — does the same "after invoice: only cancel" rule apply to the Daycare EMR (`daycare-emr-daycare-services-tab-component.tsx`) and the OPD EMR? If yes and the same rule has a server-side check elsewhere, the pattern is established and this PR is an outlier. If no, the rule was always ED-specific and this PR is a product-driven removal.

## Checklist results

- [ ] `console.log` / `console.error` in production — N/A (no change).
- [x] `any` type annotations — None.
- [x] `@ts-ignore` / `@ts-expect-error` / `eslint-disable` — None.
- [x] TODO / FIXME — None added.
- [x] Hardcoded secrets — None.
- [x] SQL/Prisma injection — N/A (the only `prisma` call in the file is being removed).
- [ ] Long files (>500 lines) — `ed-emr-emergency-services.actions.ts` is now ~95 lines (well under 500); the deletion reduces the file's footprint, which is a small win.
- [x] God components — N/A.
- [x] Missing `key` props, index-as-key — N/A.
- [x] Unsafe type assertions — None.
- [ ] Async error swallowing — The `updateEdBillFromEmrAction` no longer `await`s `edBillService.updateEdBill` inside a `try` — the deletion removed the only `try`-able error site in this file. The action now propagates errors via the implicit `authActionClient` / `safe-action` error handler. Acceptable, but verify `edBillService.updateEdBill` has its own `try/catch` for the post-invoice mutation case.
- [x] Missing `await` inside transactions — N/A (no transactions in this file).
- [x] Tenant-scope — N/A (the deleted `prisma` call was a `count` against `OPDBilling`; tenant scope is enforced at the Prisma client level for the rest of the ED module).
- [ ] Permission checks — N/A (UI-only PR from a server-action standpoint — but the server action itself is now less restrictive, see Critical #1).
- [x] Missing Zod validation at boundary — N/A (the schemas `createEdBillSchema`, `updateEdBillSchema`, `updateEdBillFromEmrSchema` are unchanged).
- [ ] React Query correctness — N/A (no client-side cache changes).
- [ ] **Defense-in-depth regression** — **CRITICAL**: the only server-side check that enforced the post-invoice lockout has been removed with no replacement and no documented rationale.

## Recommendation

Block merge. The deletion is technically clean (imports removed, types removed, file compiles, no dead code left behind), but the **business change is unannounced and the data-integrity implications are not addressed**. The author needs to either:

1. **Restore the lockout** (revert the deletion) and reopen the design discussion in PR #2773's thread or in a new ADR.
2. **Move the lockout** to `edBillService.updateEdBill` so the invariant lives in the service layer, with a PR description that explains the move and a new test that covers the "post-invoice mutation is rejected" case.
3. **Confirm with the product owner in writing** that the post-invoice lockout is no longer required, paste the confirmation in the PR body, and add a Jest test that proves `edBillService.updateEdBill` is now called with arbitrary mutations (i.e. the test name should be `updateEdBillFromEmrAction allows arbitrary mutations after invoice generation` and it should pass on this PR's code).

The single most important follow-up is **a PR body that explains the business reason for the reversal**. A 193-line deletion in a billing-adjacent file, on the same branch as the 175-line addition that introduced the same code 2 days ago, against the same ClickUp ticket, with no prose, is a recipe for an emergency revert in 3 months when someone notices the inconsistency.

The High #1 (defense-in-depth regression) is the strongest reason to block. The Critical #1 (no documented rationale) is the weakest reason to block on its own, but combined with #2 (no test) it becomes a strong block. The Medium issues are all recoverable once the design is settled.
