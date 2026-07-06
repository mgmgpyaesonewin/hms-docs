# PR #2845 — Restore team fee service

**Repo / State / Author / Branch:** `MyanCare/Ycare-HMS` / **OPEN** / `@Pyae41` / `feat/ppz/sprint-26/team-fee-visibility-86ey2ykbd` → `development`
**Diff stats:** +176 / -61 across 10 files, 1 commit (`37e5ab3`)
**CI:** not captured (run locally: `npm run tsc && npm run lint` per `hms-app/CLAUDE.md`)

**Verdict:** ⚠️
**Critical+High:** 2 Critical, 2 High, 4 Medium, 2 Low

## Summary

Re-enables the team-fee billing feature across CathLab, Endo, HD, and OT modules (EMR + detail pages). Restores previously commented-out sections (`{/* TODO: Uncomment this when team fees are implemented */}` × 4) and adds a new `CathLabCardiologistTeamFee` block. Re-shapes `daily-bill.helper.ts` so team-fee line items participate in proxy-bill totals, swaps `HDCollapse` for the shared `ProxyBillCollapse`, and rewrites the disclosure hook (`useDisclosure` → `useState`) in two contexts.

PR description is just a ClickUp URL — no rationale, no migration note, no reviewer assignment for the money-path change.

## Risks (rollback risk)

- Original removal commit not in this PR's history — find it, read its message, confirm `isTeamFee` schema column still exists on `development`.
- Stale `isTeamFee = true` rows in `ServiceBillItem` will suddenly render: `SELECT COUNT(*) FROM "ServiceBillItem" WHERE "isTeamFee" = true;` before merge.
- Money-path change in `daily-bill.helper.ts` — see Critical #1.

## Findings

### 🔴 Critical

1. **`daily-bill.helper.ts` now INCLUDES team fees in proxy-bill totals** (opposite of prior intent). The ternary `i.isTeamFee ? sum : sum + getBillLineItemDisplayAmount(i)` in `reshapeProxyBills` (≈L489) and `calculateTotalAmount` (≈L873) is replaced with unconditional `sum + getBillLineItemDisplayAmount(i)`. The "exclude team fees" comment is preserved as a commented-out block. The prior inline comment ("not part of deposit / summary totals here") confirms the previous intent. Removing that exclusion changes **deposit balances and IPD total summaries** for every existing proxy bill with team-fee items. Confirm with product whether team fees should now flow into patient-facing totals or only the CFI payout pipeline. If the latter, this is a regression.
2. **No tests accompany the restore.** `reshapeProxyBills` and `calculateTotalAmount` are money helpers; reverting a load-bearing accounting assumption without a regression test is a 3am ticket.

### 🟠 High

3. **`useDisclosure` → `useState` rewrite bundled with the restore** (`endo-service-bill.context.tsx`, `ot-services.tsx`). Drops the `open()` callback, reinvents a 3-line wheel for the sake of removing one Mantine import. Scope-creep refactor inside a "restore" PR. Same pattern duplicated in two files — extract a helper or split into a separate commit.
4. **Duplicated `.some()` checks** for `isTeamFee === true/false` in `endo-emr-services-tab-component.tsx` and `ot-emr-services-tab-component.tsx`. Iterates twice per render. Ponytail: derive once with `useMemo` and destructure `{ hasMain, hasTeamFee }`.

### 🟡 Medium

5. **`HDCollapse` → `ProxyBillCollapse` swap** in `hd-team-fee-service.tsx` — good reuse, but verify `ProxyBillCollapse` handles `isFromEmr` the same way; silent behavior-change risk for cancellation modal / FOC column on EMR pages.
6. **`serviceCardiologistTeamFeeCount`** added to `useBindCathLabForm` destructure — implementation not visible in diff. Confirm memoization in the hook.
7. **Dead inner `length > 0` guards** in `cathlab-ipd-emr-services-tab-component.tsx` — outer `some()` already guarantees non-empty.
8. **`""` literal fallback** in `endo-services.tsx` (`ServiceRow`/`TeamFeeRow`) — JSX should be `null`, not `""`, to render nothing.

### 🔵 Low

9. **`hidden={isDetailPage}`** on `Table.Th` — Mantine v7 passes through to DOM; correct.
10. **PR description lacks** *why* / *what changed in schema* / *who owns the money-path review*.

## Ponytail notes

- **Root-cause vs symptom**: original removal likely commented-out UI AND added the `isTeamFee ? sum : sum` exclusion in the helper in one commit. This PR uncomments UI but flips the helper back. If the original bug was a total-balancing double-count, the original exclusion was a workaround; this restore reintroduces it unless the upstream save path was also fixed in an intermediate commit. Find and read the original removal commit.
- **Re-enable vs rebuild**: 4 files uncomment a JSX block. The rest is plumbing (collapse swap, context refactor, cathlab new section). High scope-creep for "show team fees again".
- **Two ways to do the same thing**: `useDisclosure` still imported elsewhere; new `useState`+`toggle` reinvents it. Pick one.

## Reuse check

- `ProxyBillCollapse` exists and is used in HD; endo/OT still inline collapse logic — swap them too.
- `useDisclosure` (Mantine) still used elsewhere — drop the rewrite.
- `partitionByTeamFee(items)` filter pattern repeated across 4 files — extract one helper.

## Tests

**None added.** Required:

1. Unit test for `reshapeProxyBills` with `isTeamFee = true` items — assert intended (included) behavior.
2. Unit test for `calculateTotalAmount` — same.
3. Regression test for 4 EMR tab components with mixed `isTeamFee` items.
4. Smoke test for the new `CathLabCardiologistTeamFee` count hook.

If Critical #1 is reverted, tests #1 and #2 become regression guards for the existing exclusion.
