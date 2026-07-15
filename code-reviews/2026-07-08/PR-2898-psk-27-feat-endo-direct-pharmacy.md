# Code Review: PR #2898 — Psk/27/feat/endo direct pharmacy
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/27/feat/endo-direct-pharmacy` → `development`
**Files changed:** 13 (+625 / -284)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-08

## Summary
Adds a "direct" (non-prescription) pharmacy-request flow to the Endoscopy and Hemodialysis EMR specialty tabs (OPD, ED, IPD). Each of the six pharmacy-request tab components now reads `requestType` from the URL, renders a permission-gated `Request Pharmacy` button that navigates into the edit form with `requestType=direct`, and forwards both `requestType` and a `returnHref` to the underlying `EmrPharmacyRequestForm` / `IpdEmrPharmacyRequestForm`. Threads a previously-missing `isDetailPage` prop from the three HD tab components through. Includes a parametrized node test asserting each of the six tab components exposes the routing primitives. Unrelated: IPD room-card wards are now sorted by `ward.createdAt` (then ward name as a tiebreaker), exposing `createdAt` via the Prisma `select` in `room-list-reposity.ts`. Also tweaks `.gitignore`.

## Verdict
**Request changes**
Score: 64/100
Critical: 0 | High: 2 | Medium: 4 | Low: 1 | Nit: 4

## Issues

### Critical
None

### High

1. **`isEditPage` prop is now silently ignored — readers can no longer tell how the form is reachable.** All six tab components removed the `isEditPage` prop from the destructured list *but did not remove it from the prop type or the call sites.* Every caller still passes `isEditPage={isEditPage}`, so it compiles, but the prop is now read only by the parent and ignored by the child. Worse, the new edit-mode condition `isEdit = !isDetailPage && page === "edit"` means the form is now reachable on *every* route page-render where `?page=edit` is in the URL — no longer gated by who is allowed to edit the EMR. This silently breaks the previous access model: previously `isEditPage && page==="edit"` was *true* only when the EMR was in edit mode; now any URL like `?page=edit` opens the form even on read-only/print pages. Recommend either keep `isEditPage` as a real gate (`isEdit = isEditPage && !isDetailPage && page === "edit"`) or remove it entirely from the type and every call site to make the contract honest.

2. **`canChangeBillableRequests` default flipped from `undefined` to `true` — privilege escalation by default.** In `endo-opd-…` and `hd-opd-…`, the destructured default changed from `canRequestPharmacy` being `undefined → false-y` to `canChangeBillableRequests = true`. Combined with `showRequestPharmacyButton = !isDetailPage && canChangeBillableRequests`, a caller that forgets to pass the permission flag (which they correctly did before this PR) now renders the button and exposes the route by default. Same story for `canRequestPharmacy = true` in the ED variants. This is a permission bypass that would never trigger a regression in tests because the new test only checks string-shape, not the boolean semantics. Recommend reverting the default to `false` (or `undefined`) and threading the explicit permission from the page-level tab component, as the previous code did.

### Medium

3. **`getScopedPermissionSubject` for Endo but a raw string literal for HD — inconsistency masked by the test.** Endo uses `getScopedPermissionSubject("Endoscopy", "Pharmacy Request")` while HD hard-codes `"Hemodialysis::Pharmacy Request"`. If `getScopedPermissionSubject` exists, use it for both — the constants then live in one place and the test could enforce that contract. The new test only asserts the string `Hemodialysis::Pharmacy Request` exists, so the divergence is invisible to CI.

4. **PermissionGuard is duplicated six times with the same `subject`/`action` and the same button text — extract it.** The whole "Request Pharmacy" button block (PermissionGuard wrapping the `Button.onClick`) is copy-pasted across all six files. One generic `PharmacyRequestButton` component (or a `useRequestPharmacy()` hook that returns the click handler) would delete ~80 lines of near-identical JSX and make the permission subject/action a single point of truth. Ponytail flag: `shrink`.

5. **Per-ward `Object.entries(...).sort(...)` runs on every render in `room-card.tsx`.** The `sort` callback reads `wardCreatedAt.getTime()` and `.localeCompare` for every ward on every render. For a building with dozens of wards this is a small O(n log n) on each keystroke that re-renders the parent. Hoist the sort to run once over the memoized `groupedRooms` (use `useMemo`) or, simpler, accept that the parent already groups/derives this and sort at the reducer boundary above the render. As written, every tab switch / hover re-sorts.

6. **`wardCreatedAt` falls back to `Number.MAX_SAFE_INTEGER`** — wards that have never had a `createdAt` (legacy rows, NULL column, future schemas) sink to the bottom silently. Fine *if* `createdAt` is `NOT NULL`; if it ever becomes nullable or new wards are seeded before `createdAt` is set, the ordering becomes order-of-insertion-dependent and confusing. Either sort NULLs last deterministically with a comment ("legacy wards sink") or sort by `createdAt, name` with the explicit fallback declared in a named comparator.

### Low / Nit

- **Nit:** The `.gitignore` change adds `.kilo`, `.devin`, `.continue`, `.claude` — but the file no longer ends with a newline (the diff shows `\ No newline at end of file`). Trivial, but it makes git diffs in the file noisy forever. Add the terminating newline.
- **Nit:** `returnHref="?tab=Pharmacy Request"` is hard-coded inside all six tab components instead of being computed from the current `tab` param. The button's onClick *does* read `searchParams.get("tab")` but the form's `returnHref` does not — if the EMR is integrated into a page where the tab name is localized or differs, the cancel/back button will return to the wrong tab. Use the same `searchParams.get("tab")` logic in both places.
- **Nit:** The test file `specialty-direct-pharmacy-request-tabs.node.test.ts` reads every component from disk and asserts only on substring presence of identifiers (`useRouter`, `requestType`, `params.set("requestType", "direct")`, `showRequestPharmacyButton`). A regex like `/requestType\s*=\s*[\s\S]*direct/` matches anywhere — it will pass even if the `requestType` variable and the `direct` literal end up in unrelated branches. Tighten the regexes or assert on a single, complete block.
- **Nit:** `hd-*-emr-tab-component.tsx` now passes both `isEditPage={isEditPage}` and `isDetailPage={isDetailPage}`. If you delete the unused `isEditPage` prop (issue 1) the three call sites get shorter too.

## Recommendation
1. Decide whether `isEditPage` is still a real gate. If yes, restore it in the `isEdit` expression and keep the prop. If no, delete the prop type and remove it from every caller (three HD tab components, plus wherever Endo is mounted).
2. Revert the `canRequestPharmacy = true` / `canChangeBillableRequests = true` defaults to `undefined` so missing permissions fail closed rather than open. Thread the real permission from the parent.
3. Factor the `PermissionGuard + Button + onClick router push` block out of the six tab components into a single shared `PharmacyRequestButton` (or `useRequestPharmacy()` hook). The duplication is the largest single source of maintenance burden in the diff.
4. Hoist the ward sort out of the JSX render (`useMemo` or compute once in the existing `groupedRooms` reducer) and document the `createdAt NULL` fallback so future readers don't trip on the `MAX_SAFE_INTEGER` sentinel.
5. Tighten the new test so a regression on the actual boolean semantics (not just identifier presence) gets caught.
