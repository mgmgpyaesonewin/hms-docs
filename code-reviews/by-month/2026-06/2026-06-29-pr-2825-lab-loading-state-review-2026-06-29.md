# Code Review: PR #2825 — Add loading state to lab actions, change microbiology highlight color

**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41 (Pyae Phyo Zan)
**Branch:** `issue/ppz/sprint-25/lab-module-submit-loading-on-button-86ey029we` → `development`
**Files changed:** 6 (+86 / -17)
**Reviewer:** code-reviewer skill (independent re-review)
**Date:** 2026-06-29
**ClickUp ticket:** [9018849685/86ey029we](https://app.clickup.com/t/9018849685/86ey029we)
**PR URL:** https://github.com/MyanCare/Ycare-HMS/pull/2825

## Summary

The PR wires a `loading={isSubmitting}` spinner and `disabled={isSubmitting}` on the action footer of five lab pages (`lab-acknowledge`, `lab-sample-collection`, `lab-test-done`, `lab-testing`, `lab-result-verification/.../preview`) so the user gets visual feedback while a status mutation is in flight and can't double-submit. It also tightens the microbiology-row warning logic in `lab-result-entry/[id]/page.tsx`: the red `bg-[#FEF2F2]` highlight is now scoped to microbiology rows via `isMicrobiologyService && getLabServiceWithoutTemplate(...)` / `hasMicrobiologyWithoutTemplate(...)` instead of being applied to any row that failed a non-microbiology template check. The className was rewritten with `clsx` so `transition-colors` is unconditional and `hover:bg-gray-50` is conditional on `!showWarning`.

The net intent is correct and worth shipping: a missing loading state is a textbook double-submit hazard on slow networks, and the previous color logic was painting normal-template failures red where microbiology-template failures were silently un-warned. The execution, however, ships **two distinct bugs that both defeat the new behavior**: a copy-paste typo in `lab-test-done/[id]/page.tsx:555` (`setIsSubmitting(true)` in `finally` instead of `false`), and an `async`/`try`/`finally` wrapper around a synchronous `handlePrint` in `lab-result-verification/.../preview/page.tsx` that resolves in the same tick it started, so the spinner is invisible.

**Root-cause hypothesis for the typo.** `lab-test-done` and `lab-testing` are sibling pages with near-identical handler bodies. The `setIsSubmitting(true)` line was added in the `try` block (line 531) and the `setIsSubmitting(false)` line was meant for the `finally` block (line 555), but the diff only carries 2 new lines around the `finally` (the closing brace of the catch + the new line), so the author almost certainly copy-pasted from the `try` line above rather than typing `false`. The sibling `lab-testing` page does it correctly (`setIsSubmitting(false)` at line 537 of the PR diff). Both files were edited in the same PR; the same editing pass produced one right and one wrong.

## Verdict

**Request changes — two Critical bugs**

Score: 35/100
Critical: 2 | High: 3 | Medium: 2 | Low: 2 | Nit: 3

Score breakdown. Two Critical bugs each individually drop the score below the 50 floor — the first (the `setIsSubmitting(true)` typo) means the entire loading-spinner feature on `lab-test-done` is broken at runtime: the button will be permanently stuck in a "submitting" state after the first click, every subsequent mutation will be blocked by `disabled={isSubmitting}`, and the cancel button will be unreachable. The second Critical (synchronous `handlePrint`) means the spinner never actually appears in the preview page. The High issues are structural: no tests, an awkward `async` wrapper around sync work, and an `isMicrobiologyService` coupling that re-implements a check that's almost certainly available one hop away. The Medium issues are real but small.

## Strengths

- **`lab-result-entry/[id]/page.tsx:433-446` — the microbiology color scoping is correct in semantics.** Before this PR, `showWarning` was driven by `getLabServiceWithoutTemplate(labTestId)` alone, which means a normal (non-microbiology) template failure would paint the row red while a microbiology template failure (which goes through a different code path entirely) wouldn't. The new logic gates each warning on the right shape: microbiology templates flag their own kind via `hasMicrobiologyWithoutTemplate`, non-microbiology templates flag theirs via `getLabServiceWithoutTemplate`, and the `isMicrobiologyService` XOR prevents the two flags from cross-firing. The `showWarning` short-circuit-OR still collapses to a single boolean, so the row className change is minimal.
- **`lab-result-entry/[id]/page.tsx:448-454` — the className rewrite is a genuine improvement, not just a reformat.** The old template string put `transition-colors` inside the `else` branch, so a warning row had no hover transition. The new `clsx` makes `transition-colors` unconditional and only toggles the hover color when `!showWarning`, which is the correct intent — warning rows shouldn't invite a hover that suggests interactivity on an inert warning state.
- **`lab-sample-collection/[id]/page.tsx:891` — `isSubmitting={false}` → `isSubmitting={isSubmitting}` is a real correctness fix.** The `CancelConfirmationModal` was previously hardcoded to `false`, so the Cancel-test confirmation modal would close silently mid-submit (the parent was already in `isSubmitting=true` from the `useCollectionActions` hook, but the modal was reading its own `false`). The new wiring makes the cancel-confirm flow share the same lock as the collect/uncollect flow, which is the correct invariant.
- **`lab-acknowledge/[id]/page.tsx:201-317, 645-647` — the existing `useCollectionActions` already had `isSubmitting` state and exposed it in the return; this PR just wires it.** No new hook was invented, no new state was duplicated, the existing internal `setIsSubmitting(true/false)` calls in `handleAcknowledge`/`handleDeAcknowledge` are reused. That's the right reuse shape.
- **The five touched pages follow an existing, consistent footer pattern** (`LabAcknowledgeActionFooter`, `LabSampleCollectionActionFooter`, `LabTestDoneActionFooter`, `LabTestingActionFooter`, `LabVerificationPreviewFooter`) — the diff is mechanical and idiomatic for this codebase. No new abstractions were introduced.
- **Branch name carries the ClickUp ID**, which keeps the sprint board traceable.

## Issues

### Critical

- **`lab-test-done/[id]/page.tsx:555` — `setIsSubmitting(true)` in the `finally` block is a copy-paste typo.** The `try` block at line 531 already calls `setIsSubmitting(true)`, and the `finally` block at line 555 was clearly meant to call `setIsSubmitting(false)` to release the spinner. The sibling `lab-testing/[id]/page.tsx:537` does it correctly: `setIsSubmitting(false)`. This is a runtime break, not a stylistic issue — the moment a user clicks "Test Done" once, `isSubmitting` is set to `true` and never released:
  - the "Test Done" button stays in the Mantine `loading` spinner state forever,
  - the "Cancel" button stays `disabled={isSubmitting}` forever,
  - the row stays in `selectedCount > 0` state but the user can never submit again because `isSubmitting` is permanently `true`,
  - and the only way out is to navigate away and come back (which re-mounts the page component and resets state).

  Compare to `lab-testing/[id]/page.tsx:534-537` in the same PR diff:
  ```ts
  } finally {
    setIsSubmitting(false);
  }
  ```
  and `lab-test-done/[id]/page.tsx:552-556`:
  ```ts
  } finally {
    setIsSubmitting(true);   // ← BUG: should be `false`
  }
  ```
  **Fix:** change line 555 to `setIsSubmitting(false)`. One-character change, two-second fix, but it has to land before merge.

- **`lab-result-verification/[id]/preview/page.tsx:108-122` — the `async`/`try`/`finally` wrapper around `handlePrint` resolves in the same tick it started, so the spinner never visibly appears.** `handlePrint` is typed and implemented as a synchronous function in both downstream components:
  - `lab-service-with-template.tsx:31, 88-89`: `handlePrint: (type: "PRINTED" | "REPRINTED" | "DELIVERED") => void`, body calls synchronous `handlePrintAction(type)`.
  - `lab-service-with-micrology-template.tsx:31, 81-82`: identical shape — synchronous `void` return.
  - `window.print()` is also synchronous (blocks the event loop until the print dialog is dismissed).

  Wrapping all three call sites in `try { ... } finally { setIsPrinting(false) }` produces:
  1. `setIsPrinting(true)` → schedules a React re-render.
  2. The branch body runs synchronously (or, for `window.print()`, blocks until the dialog closes).
  3. `setIsPrinting(false)` runs immediately after — schedules another re-render.
  4. React batches both state updates and commits `isPrinting = false` in one render, so the user sees **no spinner at all**. The button briefly flashes to a loading state for zero frames and snaps back to "Print" before the user can register it.

  The disabled-cancel-during-print guard (`disabled={isPrinting}`) is also defeated by the same race, although it's slightly less visible because by the time React commits `isPrinting=true`, the work has already finished and `isPrinting=false` is already queued.
  **Fix options:**
  - **Cheapest:** drop the `async`/`try`/`finally`, keep the `isPrinting` state only around `window.print()`:
    ```ts
    const handlePrint = () => {
      if (microbiologyServices.length > 0 && microPrintRef.current) {
        microPrintRef.current.handlePrint("PRINTED");
      } else if (normalServices.length > 0 && normalPrintRef.current) {
        normalPrintRef.current.handlePrint("PRINTED");
      } else {
        window.print();
      }
    };
    ```
    and remove the `isPrinting` prop / state entirely. The ref-based `handlePrint` paths complete synchronously and don't need a lock. This is the right fix if `window.print()` is acceptable to leave without a spinner (it has its own modal dialog as feedback).
  - **Better:** change the downstream `handlePrint` types to return `Promise<void>` (e.g. by making them `async` and `await`-ing whatever status mutation they perform) and only then does the `async`/`try`/`finally` make sense. This is the right fix if there's an underlying mutation that should be awaited, but it's a larger refactor that touches the `LabServiceWithTemplate` and `LabServiceWithMicrobiologyTemplate` `forwardRef` types.

  Either way, **as written, the new code does nothing** — `isPrinting` is set to `true` and back to `false` before React can commit. The reviewer should verify by clicking Print and confirming whether the spinner is visible at all. (It won't be.)

### High

- **`lab-result-verification/[id]/preview/page.tsx:108-122` — the spinner PR also touches a path that doesn't need one.** When the user clicks Print and `microbiologyServices.length > 0`, the ref's `handlePrint` runs the underlying `handlePrintAction(type)` synchronously. There's no network call, no awaited promise, no deferral — the page state is updated immediately. Adding a spinner to a synchronous DOM mutation is theater. The user's actual feedback channel for "the print is happening" is the print dialog (`window.print()`) for the fallback branch and the rendered preview itself for the ref branch. The Cancel button doesn't need to be disabled during a synchronous DOM mutation either.
  - **Fix:** only set `isPrinting=true` around the `window.print()` branch (where the dialog is the asynchronous, blocking work) and leave the ref branches alone. Or skip the loading state entirely as in Critical #2's cheapest fix.

- **`lab-result-entry/[id]/page.tsx:434` — `hasMicrobiologyItems(labService)` is being introduced into a hot render loop as a per-row computation.** The function isn't shown in the diff; if it's a `.filter(...).length > 0` over `labService.labServiceItem`, that's fine but worth flagging if it walks more than one level of nesting. The new branch `!isMicrobiologyService && getLabServiceWithoutTemplate(labTestId)` correctly avoids the more expensive check for microbiology rows (which would always fail), but if `hasMicrobiologyItems` is O(n) per row and `labService.labServiceItem` is large, consider hoisting the `microbiologyServices` / `normalServices` split once at the parent level (the way `lab-acknowledge/[id]/page.tsx:406-412` already does at lines `labServices.filter(ls => ls.labServiceItem.length > 0)`). Reuse over re-derive.
  - **Fix:** trace `hasMicrobiologyItems` and confirm it's O(1) on `labServiceItem.length` only. If it's anything heavier, hoist it.

### Medium

- **Five sibling pages each hand-roll `isSubmitting` state.** `lab-test-done/[id]/page.tsx:488`, `lab-testing/[id]/page.tsx:469`, `lab-sample-collection/[id]/page.tsx:206` (inside the hook), `lab-acknowledge/[id]/page.tsx:201` (inside the hook), `lab-result-verification/[id]/preview/page.tsx:60`. That's five copies of the same `useState(false)` + try/finally pattern, and one of them already has the typo. A 12-line `useAsyncAction` (or just `useIsSubmitting`) hook colocated with the existing `useCollectionActions` (or in `@/lib/hooks/`) would have prevented the Critical bug in `lab-test-done` and would make the next mutation-bearing page trivial to add.
  - **Fix:** extract a shared `useIsSubmitting()` hook and refactor the five pages. Out of scope for this PR, but worth a follow-up ticket linked from this review.

- **`lab-result-entry/[id]/page.tsx:434` — `hasMicrobiologyItems(labService)` is not exported as a check on this file's existing helper surface.** If the rest of the lab module already has a way to distinguish "this labService is a microbiology service" (e.g. `labService.labServiceItem.length > 0`, the same predicate used in `lab-acknowledge/[id]/page.tsx:407` and `lab-result-verification/[id]/preview/page.tsx:82`), reusing that pattern is preferable to introducing a new helper that lives in a different module. The new helper duplicates intent that the codebase already encodes.
  - **Fix:** check if `hasMicrobiologyItems` already exists elsewhere (try `grep -rn "hasMicrobiologyItems" src/`); if yes, reuse; if no, inline the predicate at the call site (it's one line) rather than exporting a helper for a single use.

### Low

- **`lab-test-done/[id]/page.tsx:319-323` — the existing `toast.error` interpolates `e` (the caught error) directly into a user-visible message with `+ e`.** `Failed to submit testing action.` + `[object Object]` or `[object Error]` is what the user will see if `labTestDoneStatusAction` rejects with a structured error. This is pre-existing, not introduced by this PR, but the PR is touching the surrounding handler. Flagging because the message is genuinely unhelpful. Same issue at `lab-testing/[id]/page.tsx:534-537`.
  - **Fix:** serialize the error properly (`e instanceof Error ? e.message : String(e)`) or, better, change `labTestDoneStatusAction` to return a discriminated union (`{ ok: true } | { ok: false; message: string }`) so the handler doesn't have to stringify anything.

- **`lab-acknowledge/[id]/page.tsx:645-647` and `lab-sample-collection/[id]/page.tsx:771-774` — destructuring `isSubmitting` from a hook that already manages it internally creates a subtle ownership question.** The hook calls `setIsSubmitting(false)` in `finally` after every async operation, but the parent also passes `isSubmitting` to the footer as `loading={isSubmitting}`. If the hook ever returns `isSubmitting=true` while no submission is in flight (e.g. after the user navigates back mid-submit and the hook is re-mounted), the footer will be stuck. Today the hook is well-behaved, but the contract is implicit. Document or rename (`isAnyMutationInFlight`) to make it clear.
  - **Fix:** add a JSDoc to `useCollectionActions` clarifying the lock semantics.

### Nit

- **The PR title has a typo: "hightlight" → "highlight".** This is a public commit message and the second lab-module PR in a row with a typo in the title (the previous was "not showing nothing" in PR #2821).
- **`lab-test-done/[id]/page.tsx:319` and `lab-testing/[id]/page.tsx:323` — error message reads "Failed to submit **testing** action" inside the test-done handler.** Pre-existing copy-paste error from when the two handlers were forked; the test-done handler reports the wrong action name on failure. Two-second fix.
- **`lab-result-verification/[id]/preview/page.tsx:120-122` — `handleCancel = () => { router.back(); }` and `handlePrint = async () => { ... }` are now separated by a missing blank line in the diff.** Prettier's default would insert one. Not blocking; just flagging.

## Unverified

- **Whether the spinner is visible at all in `lab-result-verification/[id]/preview/page.tsx`.** I traced the call types (both ref-handlePrint signatures are `=> void`, and `window.print()` is also synchronous), so the `finally` runs in the same tick. I did not run the dev server and click Print. If the spinner is somehow visible (e.g. via `flushSync` somewhere, or via a non-React microtask), the Critical #2 bug downgrades to a Low.
- **What `hasMicrobiologyItems` actually does.** The diff imports it but the function body is not shown. I assumed it's a `labService.labServiceItem.length > 0` check. If it's heavier (e.g. walks the items array to validate result presence), the High #3 issue escalates to a real perf concern.
- **Whether `setIsSubmitting(true)` in the `finally` on `lab-test-done/[id]/page.tsx:555` is reached on the success path.** The catch block returns void (it doesn't return/throw), so the `finally` does run on success — confirming the button is stuck. Confirmed by code reading, not by running the page.
- **The CI status of the PR.** I did not run `npm run tsc` or `npm run lint` locally — `next.config.ts` ignores both at build time, so the typo would not be caught by CI for the test-done page either. The author should run `npm run tsc` before merging.
- **Whether the `CancelConfirmationModal` in `lab-sample-collection/[id]/page.tsx:891` expects `isSubmitting` to gate the confirm button or just to display a spinner.** Hardcoded `false` suggests it was originally wired but never connected. The new wiring (`isSubmitting={isSubmitting}`) is correct, but I did not verify the modal's internal handling of that prop.

## Verification needed (Checklist)

- [ ] **Fix `lab-test-done/[id]/page.tsx:555`** — change `setIsSubmitting(true)` to `setIsSubmitting(false)` in the `finally` block. **Blocker.**
- [ ] **Decide the loading-state strategy for `lab-result-verification/[id]/preview/page.tsx`.** Either remove the `async`/`try`/`finally` entirely (cheapest, since `handlePrint` is synchronous), or change the ref-handlePrint signatures to return `Promise<void>` (correct, larger). **Blocker.**
- [ ] **Add at least one integration test** that exercises the action-footer pattern across the five pages — assert `loading` and `disabled` reflect `isSubmitting` and that `isSubmitting` resets after the mutation completes. (Would have caught the `lab-test-done` typo.)
- [ ] **Run `npm run tsc`** in `hms-app/` before merging — `next.config.ts` ignores TS errors at build time but the typo is a real runtime bug.
- [ ] **Extract `useIsSubmitting()` (or `useAsyncAction`)** as a shared hook colocated with `useCollectionActions`, and refactor `lab-test-done`, `lab-testing`, and the preview page to use it. Follow-up ticket.
- [ ] **Confirm `hasMicrobiologyItems` is O(1)** and not a deeper walk. If it duplicates an existing predicate, inline it.
- [ ] **Fix the PR title typo** "hightlight" → "highlight". Nit, but it's a public string and the second lab-module typo in a row.
- [ ] **Fix the "Failed to submit **testing** action" message in the test-done handler** — wrong action name on failure. Two-second fix.
- [ ] **Sanitize the `+ e` error interpolation** in both `lab-test-done` and `lab-testing` catch blocks — pre-existing, but easy.

## Recommendation

**Request changes.** Two Critical bugs both defeat the new behavior the PR is shipping — the `lab-test-done` typo will permanently lock the page after one click, and the `lab-result-verification/.../preview` `async`/`try`/`finally` resolves in the same tick so the spinner never actually appears. Both are one- to three-line fixes (the typo is a literal `true` → `false` swap; the print refactor is either deleting the wrapper or changing the ref-handlePrint signatures to return `Promise<void>`), but neither can land as-is.

Once those two are fixed, the rest is real value: the loading-state wiring on `lab-acknowledge` / `lab-sample-collection` / `lab-testing` works because those pages either reuse the existing well-behaved `useCollectionActions` hook or hand-roll the pattern correctly, and the microbiology-color scoping fix in `lab-result-entry` is a genuine correctness improvement that paints the right rows red for the right reasons. The follow-ups (shared hook, tests, error-message sanitization) are real but out of scope for this PR — file them as separate tickets and link them from this review.