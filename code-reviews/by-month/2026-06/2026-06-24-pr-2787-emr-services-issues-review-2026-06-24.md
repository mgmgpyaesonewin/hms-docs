# Code Review: PR #2787 — fix: emr issues services

**Repository:** MyanCare/Ycare-HMS
**Author:** @Xkill119966
**Branch:** `fix/emr-services-issues` → `development`
**Files changed:** 22 (+211 / -37)
**Reviewer:** code-reviewer skill (automated, independent re-review)
**Date:** 2026-06-24
**ClickUp ticket:** https://app.clickup.com/t/86exzemhu

## Summary

PR #2787 is a wide-reaching "fix" for EMR service-tab editing behavior across five clinical modules (daycare, ED, endo, HD, OT) plus the shared proxy-bill pharmacy-sale and procedures components. The single PR body is just the ClickUp URL — there is no problem statement, no description of the bug being fixed, and no reproduction steps. That is a process smell for a change that touches 22 files.

The actual diff surface is a single, repeatable pattern: introduce an `allowLockedEdit` prop in a chain of components (8 leaf components + 2 shared components + 5 tab-level orchestrators + 1 React context provider), compute it from `paymentStatus` (`PAID` → false, anything else → true for OPD/ED contexts; for non-OPD/ED contexts the rule becomes `PAID → false else UNPAID → true`), and use it to short-circuit several guard `useMemo`s (`hasOpdSlip`, `isPaid`) plus three `disabled={...}` conditions. The endo-context `hasOpdSlip` also picks up an additional `paymentStatus === PAID` predicate that did not exist before. Net behavior: on certain EMR types, a previously-locked service row becomes editable even when there is an existing bill link (and vice-versa).

SonarQube Cloud reports `last analysis has failed` on the PR — so no quality gate output is available. That alone should not block, but combined with the absent PR description, missing tests, and EMR-domain sensitivity (PHI-adjacent editing), the bar has to be higher.

The most important issues are: (1) the rule `allowLockedEdit = paymentStatus !== PAID` collapses three distinct payment semantics into one flag and the `OPD || ED || UNPAID` rule introduces ambiguity that is easy to get wrong on the next edit; (2) `allowLockedEdit` is plumbed as an optional prop with `default false` and is trusted blindly at every call site — a missing prop silently disables locking rather than failing fast; (3) zero tests for behavior changes that are explicitly about "lock vs. allow edit" — a regression here is silent data corruption waiting to happen. There is also a meaningful semantic change in `endo-service-bill.context.tsx`: `hasOpdSlip` now additionally requires `paymentStatus === PAID`, so a bill link alone no longer disables adds — this is not called out in the PR description at all.

## Verdict
**Request changes**

Score: 58/100
Critical: 0 | High: 4 | Medium: 5 | Low: 4 | Nit: 3

## Strengths

- `daycare-pharmacy.tsx:265` — `disabled={isPaid || hasOpdSlip}` reads cleanly and correctly composes the two independent lock reasons (bill link vs. paid). This is the clearest formulation in the PR.
- `ot-emr-services-tab-component.tsx:625` — replacing `disabled={isUpdateMode}` on `MainProcedureSelect` with `disabled={isBillPaid}` is a targeted correctness fix (the previous condition disabled the select on every edit, regardless of payment state).
- `endo-service-bill.context.tsx:325-334` — the new `hasOpdSlip` `useMemo` dep array includes `endoData?.paymentStatus`, which is the right thing to do (previously the memo was stale w.r.t. payment state). Good.
- `proxy-bill-procedures.tsx:191-198` — extracting `shouldLockOpdSlip` and `shouldLockOpdBillingInvoice` as named booleans makes the disabled rule self-documenting, much better than the previous inline expression.
- The change is internally consistent: every new prop has the same name (`allowLockedEdit`), the same default (`false`), and the same semantics at every call site. That is at least easy to grep for and reason about.
- No destructive DB or migration changes. Surface is purely client-side React state.

## Issues

### Critical

*(none — no data-loss path is introduced, but see High #1 and High #2 which collectively argue the lock model is unsafe)*

### High

- **`endo-service-bill.context.tsx:325-334` — `hasOpdSlip` semantic change is undocumented and inconsistent with peers.**
  The new `hasOpdSlip` is `hasBillLink && endoData?.paymentStatus === proxyBillPaymentStatus.PAID`. Every other component's `hasOpdSlip` (daycare, ED, HD-service, OT, proxy-bill-pharmacy) is `hasBillLink && !allowLockedEdit` (i.e. a bill link disables adds only when the prop is not set). The endo context adds a *third* condition: even with `allowLockedEdit=true`, the row is locked unless the bill is PAID. This means the same data shape (`ProxyBilling` with a bill link, UNPAID status, EMR context) renders editable in daycare/ED/HD/OT and non-editable in endo. There is no comment explaining why endo is different. The PR body is empty, so reviewers cannot tell whether this is intentional or a copy-paste bug. **Fix:** either align with the peer components (drop the `paymentStatus === PAID` clause when `allowLockedEdit` is true) or add a one-line comment above this memo explaining the endo-specific business rule, and call it out in the PR description. This is a real behavioral difference, not a stylistic one.

- **`daycare-emr-daycare-services-tab-component.tsx:350`, `ed-emr-emergency-services-tab-component.tsx:341`, and the three sibling tabs — `allowLockedEdit` is a boolean collapsing three orthogonal conditions.**
  In daycare/ED tabs: `allowLockedEdit = paymentStatus !== PAID`. In endo/HD/OT tabs: `allowLockedEdit = !isBillPaid && (emrType === "OPD" || emrType === "ED" || isBillUnpaid)`. The latter is a non-obvious rule that means: "allow locked edit if (a) bill is not paid AND (b) we are OPD/ED OR the bill is unpaid." Since (a) and (b) already imply each other in most realistic states, the `|| isBillUnpaid` is either redundant or covering a specific case the author had in mind (likely "stand-alone HD/OT bill, unpaid, OPD context"). Either way, this should be (i) named with a descriptive intermediate (`canEditLockedItems`, `shouldBypassLinkLock`) or extracted into a helper, and (ii) documented. As written, the next engineer who needs to change "what counts as a locked EMR item" has to touch five files in lockstep to keep the rule coherent. **Fix:** extract `computeAllowLockedEdit({ paymentStatus, emrType })` into one shared helper (e.g. `shared/proxy-bill/lib/allow-locked-edit.ts`) and call it from all five tab components. This also makes it unit-testable.

- **`proxy-bill-procedures.tsx:194-198` — `isAddDisabled` includes a triple-negation condition that is hard to verify and easy to invert by mistake.**
  ```ts
  const isAddDisabled =
    shouldLockOpdSlip ||
    shouldLockOpdBillingInvoice ||
    (!allowLockedEdit && proxyBillData?.paymentStatus === proxyBillPaymentStatus.PAID);
  ```
  The third clause says "block add if not-allowLockedEdit AND status is PAID." But for a paid bill, the expected behavior is "locked." Compare with `daycare-pharmacy.tsx:265` which uses `disabled={isPaid || hasOpdSlip}` — straightforward OR of two booleans. The endo/HD/OT tabs got the cleaner formulation; proxy-bill-procedures got the negated form. There is no good reason for the inconsistency. **Fix:** refactor to `const isPaid = proxyBillData?.paymentStatus === proxyBillPaymentStatus.PAID; const isAddDisabled = shouldLockOpdSlip || shouldLockOpdBillingInvoice || isPaid;` — or, better, compute a single `effectiveLockLevel` and let consumers branch on it.

- **`hd-emr-services-tab-component.tsx:497-499` — `cannotEdit` now uses `!allowLockedEdit` while `cannotDelete` still uses raw `isPaid`. The asymmetry is not justified.**
  ```ts
  const cannotDelete = isPaid || isFinalBillPaid;
  const cannotEdit = emrType === "IPD" && (!allowLockedEdit || isFinalBillPaid);
  ```
  For an IPD EMR with `emrType === "IPD"`, a paid bill, `isFinalBillPaid=false`, `allowLockedEdit=false`: `cannotEdit=true`, `cannotDelete=true` — OK. For an IPD EMR with the same but `allowLockedEdit=true`: `cannotEdit=false`, `cannotDelete=true` — the user can edit but cannot delete. That seems intentional, but the contrast with the OT and endo tabs (`cannotDelete = isPaid`, `cannotEdit = emrType === "IPD" && !allowLockedEdit`) means HD has an extra `isFinalBillPaid` clause on the edit path that the others do not. Three different formulations of "can this be edited?" across three siblings. **Fix:** same helper as High #2; also document the `isFinalBillPaid` final-bill rule once.

### Medium

- **`daycare-services.tsx:236`, `ed-billing-services.tsx:230`, `endo-service-bill.context.tsx:298`, `ot-services.tsx:355` — `useMemo` for `isPaid` short-circuits with `if (allowLockedEdit) return false;` but the surrounding branches still reference `isEdit`.**
  When `allowLockedEdit=true`, `isPaid` is forced to `false` regardless of `isEdit` or `paymentStatus`. This is the intended override, but `isEdit` is still in the dep array, suggesting the author considered both paths. A reader has to mentally trace two branches to convince themselves the short-circuit is exhaustive. **Fix:** add a one-line comment: `// allowLockedEdit forces editable; isPaid is irrelevant in that case` — or replace the useMemo with `const isPaid = !allowLockedEdit && isEdit && paymentStatus === proxyBillPaymentStatus.PAID;` which is simpler and equivalent.

- **`proxy-bill-pharmacy-sale.tsx:218-220` — the new `hasOpdSlip` memo introduces an intermediate `hasBillLink` that is unused elsewhere.**
  ```ts
  const hasBillLink = Boolean(proxyBilling?.appointment?.OPDBilling?.length || proxyBilling?.ipdDailyBill);
  return allowLockedEdit ? false : hasBillLink;
  ```
  The peer components compute the boolean inline (`return Boolean(...)` when not allowing locked edit). The intermediate variable adds no value here and differs stylistically from daycare/ED/HD/OT. **Fix:** drop `hasBillLink`, write `return allowLockedEdit ? false : Boolean(...)`.

- **`proxy-bill-procedures.tsx:257` — `hasOpdSlip={shouldLockOpdSlip}` is passed to a child but `hasOpdSlip` is still in scope as the raw value. There is now a footgun.**
  Inside this file, `hasOpdSlip` is the raw `useMemo` value (line ~190, unchanged) and `shouldLockOpdSlip` is the new derived one. Both are used in the same render — `shouldLockOpdSlip` for the disable/disabled props, `hasOpdSlip` only implicitly (via `shouldLockOpdSlip = hasOpdSlip && !allowLockedEdit`). If a future contributor adds another `hasOpdSlip={...}` line and grabs the raw one, the lock silently fails open when `allowLockedEdit=true`. **Fix:** rename the raw value to `rawHasOpdSlip` or inline the predicate at the call sites.

- **`ot-services.tsx:434` — `hasOpdBillingInvoiceId` is overwritten with `shouldLockOpdBillingInvoice` in the context return value.**
  The hook previously returned `hasOpdBillingInvoiceId` (raw). Now it returns `hasOpdBillingInvoiceId: shouldLockOpdBillingInvoice`. This is a semantic change to the public surface of `useOTServiceBillState`. Any consumer outside this file that destructures `hasOpdBillingInvoiceId` from the context will silently get the *locked* form, which is what they probably want — but only by accident. **Fix:** rename the context field to `hasLockedOpdBillingInvoice` (or similar) to make the change explicit and grep-able; update `OTServiceBillContextType`.

- **`ot-services.tsx:355` — `isPaid` short-circuit comment is missing.**
  See Medium #1 — same issue, same fix proposal. Apply consistently in all four files.

### Low

- **`hd-emr-services-tab-component.tsx:386`, `endo-emr-services-tab-component.tsx:413`, `ot-emr-services-tab-component.tsx:371` — three new constants with the same names (`isBillUnpaid`, `isBillPaid`, `allowLockedEdit`) computed in three places.**
  Each tab computes these locally. Pulling them into a helper (see High #2) eliminates the duplication and the risk of one tab drifting.

- **`daycare-pharmacy.tsx:73`, `daycare-procedures.tsx:9`, `daycare-services.tsx:94` — `allowLockedEdit?: boolean` is optional with default `false`.**
  Optional props default to `false` mean "lock," which is the safe direction. That is good. But the symmetric prop being optional means a forgotten `allowLockedEdit={true}` at a new call site silently locks a previously-editable form. Consider an ESLint rule or a runtime invariant (`invariant(process.env.NODE_ENV !== "production" && !hasBillLink ? allowLockedEdit !== undefined : true, "EMR context must pass allowLockedEdit")`) for new call sites. Out of scope for this PR but worth tracking.

- **`ot-pharmacy-sales.tsx:13`, `ot-procedures.tsx:11`, `ot-services.tsx:87` — three new prop additions on OT components mirror three new prop additions on HD components with the same shape.**
  Same pattern as Low #1 — there is now a cross-module prop vocabulary (`allowLockedEdit`, `isFromEmr`, `hasOpdBillingInvoiceId`, `hasOpdSlip`) that should be documented once in a shared types file (`shared/proxy-bill/types/`).

- **`endo-service-bill.context.tsx:298` — `useMemo` deps for `isPaid` now include `allowLockedEdit`, but the body still references `isEdit`.**
  Same shape as Medium #1. The dep list `allowLockedEdit, endoData, isEdit` is correct but noisy; collapsing the expression (Medium #1 fix) simplifies the dep list to `[allowLockedEdit, isEdit, endoData?.paymentStatus]`.

### Nit

- **`daycare-services.tsx:258-264` and `ed-billing-services.tsx:215-218` — `useMemo` dep array is split across multiple lines in daycare but stays single-line in ed.**
  Cosmetic. Match across siblings.

- **`ot-services.tsx:351` — `const shouldLockOpdBillingInvoice = !allowLockedEdit && hasOpdBillingInvoiceId;` is computed once per render but used multiple times in the same hook return.**
  Micro-perf, ignore. Could be wrapped in `useMemo` for symmetry with `hasOpdSlip`/`isPaid` but not worth it.

- **`hd-service.tsx:71` — destructured `{ data: fetchedHdData }` is not introduced here; the actual fetch is via `useHdFormBase`. The `allowLockedEdit` prop is passed through three layers without being read in the middle layers.**
  This is fine because the leaf component reads it, but it adds a prop to the public type signature of intermediate components that is only there for passthrough. Marking `allowLockedEdit` JSDoc as `@internal pass-through` would help reviewers.

## Test coverage gap

This PR makes 0 changes to any test file. For a PR whose entire purpose is "fix editing behavior in EMR service tabs," that is the single biggest risk. The behaviors that should be covered:

1. `computeAllowLockedEdit({ paymentStatus: "PAID", emrType: "OPD" })` → `false`
2. `computeAllowLockedEdit({ paymentStatus: "UNPAID", emrType: "OPD" })` → `true`
3. `computeAllowLockedEdit({ paymentStatus: "PAID", emrType: "IPD" })` → `false`
4. `computeAllowLockedEdit({ paymentStatus: "UNPAID", emrType: "IPD" })` → `true` (the `|| isBillUnpaid` clause)
5. `hasOpdSlip` in `endo-service-bill.context.tsx` when `paymentStatus=UNPAID` with a bill link and `allowLockedEdit=true` → still `false` (per the new rule); this is the surprising behavior in High #1 and deserves a regression test in particular.
6. `proxy-bill-procedures.tsx` `isAddDisabled` truth table: PAID + bill link + `allowLockedEdit=false` → true; UNPAID + bill link + `allowLockedEdit=true` → false; PAID + `allowLockedEdit=true` → false (locked opens, semantically? verify).

A focused Vitest/RTL test on `endo-service-bill.context.tsx` `useEndoServiceBillState` would catch the most subtle regression (High #1) at minimal cost. Author should add at least one test, ideally one per module, before merging.

## Process concerns

- **PR body is empty** (only the ClickUp URL). For a 22-file change, the description should state (a) what the bug is, (b) what behavior changed, (c) which EMR types are affected, (d) any data-migration implications. Without it, reviewers and future archaeologists have no source of truth beyond reading the diff.
- **SonarQube analysis failed** for this PR. Not a blocker on its own, but combined with the absent description and zero tests, the risk-adjusted merge cost is higher than the line count suggests.
- **Branch name `fix/emr-services-issues`** is generic; consider module-scoped names (`fix/emr-daycare-ed-allow-locked-edit`) so revert-by-branch is meaningful.

## Suggested merge path

1. Author updates the PR body with a 3-5 line problem statement and the rule table for `allowLockedEdit`.
2. Extract `computeAllowLockedEdit` helper (fixes High #2, High #4, Low #1).
3. Reconsider the `endo-service-bill.context.tsx:325-334` rule and either align with peers or document the divergence (fixes High #1).
4. Simplify `proxy-bill-procedures.tsx:194-198` to OR-form (fixes High #3).
5. Add at least one regression test per module.
6. Re-run SonarQube before merge.

After those, this would land cleanly as an Approve with suggestions. As written, request changes.