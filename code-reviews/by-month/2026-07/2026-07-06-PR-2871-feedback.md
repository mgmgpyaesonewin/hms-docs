# PR #2871 — Enhance admission patient query

**Verdict:** Approve with one Important note (no blockers). Smallest possible diff for its stated intent; one schema-verification item and a missing test for a billing-gating query.

**Headline:** Approve with changes — verify `ProxyBill.isConsignment` exists, add a regression test, get product sign-off for the cash-flow implication.

## Summary

A one-file, ten-line change in `patients-repository.ts` that broadens the admission patient query so **EMERGENCY** patients (in addition to OPD) are returned, and excludes consignment bills from both `PatientBill` and `ProxyBill` filters. The diff matches its title — a surgical, ticket-scoped tweak to an existing eligibility filter, not a refactor. The query appears to gate credit admission (filters by outstanding pharmacy bills), so the broadening has product/cash-flow implications worth flagging.

## Strengths

- Minimal diff — only the two `where` blocks that needed changing were touched. No drive-by edits.
- Symmetric change: `patientType: { in: ["OPD", "EMERGENCY"] }` and `isConsignment: false` applied consistently to both `PatientBill` and `ProxyBill`. Easy to reason about.
- Uses Prisma's native `{ in: [...] }` operator instead of OR-ing two equality clauses — the right primitive.
- ClickUp ticket (`86ey2yd5p`) linked in PR body for traceability.

## Issues

### Important

- **`isConsignment` on `ProxyBill` — verify the field exists** (`src/app/(dashboard)/common/patients/features/patients-repository.ts:225`)
  The new `isConsignment: false` filter is added to both `PatientBill` and `ProxyBill`. `PatientBill` is filtered by `departmentType: "PHARMACY"`, where consignment stock is a real concept; `ProxyBill` has no department filter and may not carry an `isConsignment` column. If `ProxyBill` lacks the field, this won't typecheck and the query will fail at runtime. Fix: confirm both models have `isConsignment: Boolean` in `prisma/schema.prisma` before merge; if `ProxyBill` does not, drop the filter from that block only and note it in the PR description.

- **No regression test for a billing-gating query**
  This query gates credit admission — patients with outstanding pharmacy bills are normally excluded. The PR relaxes that gate (EMERGENCY now admitted; consignment bills ignored). A small test covering two cases would be cheap: (1) OPD patient with PENDING consignment pharmacy bill is returned; (2) EMERGENCY patient with PENDING non-consignment bill is returned. Repo `CLAUDE.md` says "ALWAYS run tests after code changes" — no test file modified.

### Nit

- **Cast style is pre-existing** (`patients-repository.ts:214, 222, 229`)
  `as PaymentStatus[]` / `as PatientType[]` / `as BillPaymentStatusEnum` inline casts on Prisma `where` clauses are a codebase smell — Prisma's generated types should already infer these. Inherited, not introduced; not in scope, but worth a follow-up issue.

## Recommendations

1. Before merge: confirm `ProxyBill.isConsignment` exists in `prisma/schema.prisma`. If not, drop that one filter.
2. Add one Jest test for the admission-patient query (~15 lines).
3. Product sign-off with requester/finance — this is a cash-flow-relevant change.
4. Resist scope creep — the diff is appropriately small.

## Reviewer notes

- Read the ClickUp ticket (`86ey2yd5p`) to confirm both product changes (EMERGENCY admission + consignment exclusion) are explicitly intended.
- Branch `enhance/april/sprint-25/opd-credit-admission` targets `development` — sprint-25 scope, not hotfix, so it can wait for the schema verification.
- Quick grep for callers of the enclosing repository method is worth it — if anything else consumes it, the broadening could surface emergency patients in unrelated lists.