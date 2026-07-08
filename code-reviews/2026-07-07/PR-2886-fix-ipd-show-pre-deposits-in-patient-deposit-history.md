# Code Review: PR #2886 — fix(ipd): show pre-deposits in patient deposit history
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `fix/ipd-show-pre-deposits-in-patient-deposit-history` → `main`
**Files changed:** 4 (+291 / -5)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07

## Summary
Bug fix that makes pre-deposits (deposits created before an admission exists) appear in the patient's deposit transaction history. The PR records an `IN` `Pre Deposit` transaction on create, replaces it on update (deletes then re-creates, like the regular-deposit update path), and backfills the missing `IN` row when an admission is later linked to an existing pre-deposit. Also bumps the OPD submodule to pick up a refund-item typing fix needed for `npm run tsc`. Tests added for all three code paths.

## Verdict
**Approve with suggestions**
Score: 88/100
Critical: 0 | High: 0 | Medium: 1 | Low: 2 | Nit: 1

## Issues

### Critical
None

### High
None

### Medium

**M1 — `cancelPreDeposit` no longer balances the IN row this PR creates.** `deposit.service.ts` now writes an `IN` `Pre Deposit` transaction on pre-deposit creation (line 503 area). The existing `cancelPreDeposit` path (around `existingDeposit.admissionId === null` → `cancelPreDeposit`) marks the deposit `isCancelled` but writes no compensating `OUT` history row — unlike `cancelRegularDeposit`, which writes an `OUT` `Deposit Cancellation` row. After this PR, cancelling a pre-deposit will leave an `IN` row in history whose deposit is `isCancelled: true`. Patients / admins viewing the history will see "Pre Deposit +500000" but the underlying deposit is cancelled; the legend says money was received that was never actually settled. Fix: write an `OUT` `Pre Deposit Cancellation` history row in `cancelPreDeposit` (or annotate the IN row as cancelled). Low urgency because pre-deposit cancellation is rare in practice, but the asymmetry is a real correctness gap introduced by adding the IN row.

### Low / Nit

**L1 — `createPreDepositTransactionHistory` duplicates the existing `createDepositTransactionHistory` call shape.** `deposit.service.ts` adds a new private helper that constructs one transaction-history row with `reason: "Pre Deposit"`. The very next code path (`createRegularDeposit`) writes the same shape inline with `reason: "Deposit"`. The two could share a single `createDepositHistory(reason, params)` builder — saves ~15 lines and a future-proofing win if a fourth reason is added. Not blocking; ship as-is if the author prefers the explicit duplication for readability.

**L2 — `preDeposits.map(async ...)` in `AdmissionService.createAdmission` runs all `findFirst` checks in parallel before any `update` happens.** Cosmetic / micro-perf only. The previous synchronous map fired updates in parallel; the new async map fires all the `findFirst` lookups first (one extra round-trip), then all the `update`+`create` writes. Functionally identical, no race. No action needed; flagging because the redundant round-trip is the kind of thing that surprises the next reader.

**N1 — Test file lives at repo root (`__tests__/deposit-predeposit-history.node.test.ts`) instead of next to the service.** Per `hms-app/CLAUDE.md` conventions the team's `__tests__` directories typically live under `src/.../__tests__/`. Verify the root `__tests__/` folder is the configured `roots` entry in `jest` config; if so, fine, just flagging for the next person looking for the file.

## Recommendation
- **M1 (Medium):** Add a compensating `OUT` row (or a `cancelled` flag on the `IN` row) inside `cancelPreDeposit`. Otherwise the deposit history will lie to the user when a pre-deposit is cancelled.
- **L1 (optional):** Collapse `createPreDepositTransactionHistory` and the inline IN-row in `createRegularDeposit` into one shared private helper.
- Confirm `npm run tsc` is green post-merge so the OPD submodule bump (which carries the refund-item typing fix) stays compatible.
- Otherwise ship — the test coverage (create / update / backfill) is exactly right for this kind of migration fix, the backfill guard (`if (!existingPreDepositTransaction)`) prevents double-insert on subsequent admissions, and the new `metaData.deductType: "DEPOSIT"` aligns pre-deposits with regular deposits so the existing grouping logic in `getGroupedHistoryByAdmissionId` (Case B) handles them with no further changes.
