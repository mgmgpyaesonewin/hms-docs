# Code Review: PR #3005 — refactor(proxy-bill): preserve price and amount for team fee services
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/28/update-procedure` → `development`
**Files changed:** 1 (+8 / -4)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-17
**ClickUp:** https://app.clickup.com/t/9018849685/86ey74hb5

## Summary
In `proxy-bill-ipd-membership.service.ts`, the team-fee branch previously forced `service.price = 0` and `service.amount = 0` after computing membership discounts. That clobbered any manually-entered prices (e.g. set in the daily bill view) every time the proxy bill was updated. The PR comments out the two assignments so team-fee price/amount pass through unchanged, while keeping the `continue` so they stay excluded from `totalToDeduct`. The log payload now reports the preserved `price`/`amount` instead of a hardcoded zero.

## Verdict
**Approve with suggestions**
Score: 92/100
Critical: 0 | High: 0 | Medium: 2 | Low: 2 | Nit: 0

## Issues

### Critical
None

### High
None

### Medium

- **Dead commented-out code kept in the hot path.** The two assignments (`service.price = 0;` / `service.amount = 0;`) are commented out in place, and the previously-unused `// const lineAmountFull = service.amount ?? unitPrice * qty;` plus `// lineAmount: 0,` log field are also left behind. Git already preserves the history — these lines belong in the diff's deletion, not in the resulting source. Deleting them is what makes this a real refactor rather than a "preserve and comment" change.

- **No regression test for the new pass-through behavior.** The observable contract changed: prior to this PR, after `applyIPDMembershipDiscountAndComputeTotal` any team-fee service on the returned payload had `price === 0 && amount === 0`. After this PR, those fields are the caller-supplied values. Nothing in the diff locks this in. A small unit/integration test asserting `payload.serviceBill.services[i].price` / `.amount` are unchanged for `isTeamFee === true` rows (and `totalToDeduct` still excludes them) would prevent a future drive-by re-introduction of the zeroing.

### Low / Nit

- **Verbose team-fee log in a per-line loop.** `this.logger.info(...)` fires once per team-fee service line and now carries two extra fields. For a proxy bill with many team-fee rows this is noisy. Either downgrade to `debug`, or guard it. Not blocking.

- **Redundant multi-line comment.** The new 3-line comment ("Team fees are excluded from deposit deduction but their price/amount must be preserved…") restates what `continue` + the log message already convey. One sentence — or none — would do; the rationale is already captured in the PR description and the commit body.

## Recommendation
1. Delete the commented-out `// service.price = 0;`, `// service.amount = 0;`, `// const lineAmountFull = ...;`, and `// lineAmount: 0,` lines outright — git history preserves them.
2. Tighten the explanatory comment to a single line, or drop it entirely (the log message plus the `continue` are self-describing).
3. Add at least one regression test covering the team-fee pass-through + exclusion-from-`totalToDeduct` invariant.
4. Consider gating the per-line `info` log to `debug` if team-fee lines are common.

Core fix is correct and the right one — team-fee price/amount preservation is the actual product bug, and the change lives in the single function that was zeroing them out. Just clean up the leftovers and lock the behavior in with a test.
