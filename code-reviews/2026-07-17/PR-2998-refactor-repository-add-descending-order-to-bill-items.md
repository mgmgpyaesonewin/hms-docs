# Code Review: PR #2998 — refactor(repository): add descending order to bill items
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/28/sort-ot-emr-service-tab` → `development`
**Files changed:** 3 (+69 / -2)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-17
**ClickUp:** https://app.clickup.com/t/9018849685/86ey7qkk3

## Summary
Adds `orderBy: { id: "desc" }` to four Prisma relation sub-queries so service/procedure bill items are returned newest-first: two in `ipd-daily-bill.repository.ts` (one each in `dailyBillValidator` summary view and `dailyBillDetailValidator` detail view) and two in `proxy-bill.repository.ts` (`serviceBillItems` and `procedureBillItem` inside `proxyBillValidator`). A test was also added asserting the new orderBy on both validators, and an existing test for `getProxyBillById` had its mock switched from `findUnique` to `findFirst` to match the repository's actual implementation (a real bug fix).

## Verdict
**Request changes**
Score: 76/100
Critical: 0 | High: 0 | Medium: 2 | Low: 1 | Nit: 1

## Issues

### Critical
None

### High
None

### Medium

**M1. Root-cause fix only at two of many sites — sibling repositories remain broken.** `grep` for `serviceBillItems:`/`procedureBillItem:` across the dashboard shows the same relations queried (without any `orderBy`) in at least five more files: `shared/opd/repositories/opd-billing.repository.ts` (3 calls), `shared/opd/services/opd-billing.service.ts` (via `procedureBillItem`), `shared/ed/repositories/ed-bill.repository.ts` (multiple), `shared/ipd/repositories/ipd-final-bill.repository.ts`, and `shared/ipd/repositories/discharge.repository.ts`. The ticket is "items come back in wrong order on the OT EMR service tab" — if the symptom is order-dependent UI on bill items, then every caller that feeds that UI is at risk, not just `ipd-daily-bill` and `proxy-bill`. Fix the four callsites in this PR and the user's chosen tab still pulls unsorted items from the next sibling, so the ticket stays open. Either grep every `BillItem*` model usage, order by at the model level (Prisma cannot enforce this globally without middleware — see M2), or document explicitly which surfaces are in scope.

**M2. Missing `servicePackageBillItems` ordering in the same file.** `proxy-bill.repository.ts` has three sibling relations wrapped by identical `isDeleted: false` filters: `serviceBillItems`, `servicePackageBillItems`, and `procedureBillItem`. This PR orders two of the three. The omitted one is the most likely target for the same user-visible "wrong order" bug. If the fix is correct for `serviceBillItems`/`procedureBillItem`, there is no reason to leave `servicePackageBillItems` unsorted — order it or scope the PR title/description to make the omission explicit.

### Low / Nit

**L1. Test descriptions say "creation order" but assertion is descending id.** Both new tests in `proxy-bill-repository-main-procedures.node.test.ts` are titled "reads ... in creation order", yet they assert `orderBy: { id: "desc" }`. `id DESC` is reverse-creation-order (newest first). Either flip the title to "newest-first" / "descending order" or invert the assertion. As written, the test name lies about the contract under test — future readers will assume creation-order semantics and change the production code to match, breaking the actual UI requirement.

**N1. Tests couple to Prisma validator object shape.** The two new tests walk `proxyBillValidator.include.serviceBill.include.serviceBillItems.orderBy` and the equivalent in `dailyBillValidator`/`dailyBillDetailValidator`. That works today because Prisma's `validator()` return is a typed plain object, but it will silently break (or pass falsely) if anyone wraps the validator in a function, memoizes it, or moves the include elsewhere. A single `expect(Object.keys(proxyBillValidator.include.serviceBill.include.serviceBillItems)).toContain('orderBy')` is more robust; or test the actual repository call shape the way the existing `upsertProxyMainProcedures` tests do.

## Positive notes
- The `findUnique` → `findFirst` correction in `getProxyBillById` test was a real bug (the production code at `proxy-bill.repository.ts:403` calls `client.proxyBill.findFirst`). The old test would have masked any future findUnique-vs-findFirst regression in this file.
- `orderBy` is placed at the relation level rather than relying on a manual `.sort()` post-fetch — right call, lets Postgres do it.
- Diff is small and targeted. No collateral changes.

## Recommendation
1. Fix M2 first — one block in `proxy-bill.repository.ts:80-96` to add `orderBy: { id: "desc" }` to `servicePackageBillItems`. That is the cheapest, lowest-risk follow-up and closes the most obvious gap.
2. Either expand M1 into a follow-up ticket (and link it from the PR description) or extend this PR to cover the sibling repositories. Pragmatic minimum: the four adjacent relation queries in `ipd-final-bill.repository.ts` and `discharge.repository.ts`, since they are the IPD final-bill flow that shares the same UX as the tab in the ticket.
3. Flip L1 test titles or flip assertions — pick one, don't leave both "creation order" and `desc`.
4. After fix, re-run `npm run lint` and `npm run tsc` per the project's CLAUDE.md guidance; no schema change, so no `prisma generate` required.
