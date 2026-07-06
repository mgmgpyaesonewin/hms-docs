# Code Review: PR #2784 — feat: add pharmacy request functionality for OPD and ED, including ne…

**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/25/feat/direct-opd-pharmacy-request` → `development`
**Files changed:** 9 (+479 / -101)
**Reviewer:** code-reviewer skill (automated, independent re-review)
**Date:** 2026-06-24
**ClickUp ticket:** https://app.clickup.com/t/9018849685/86ey0kmq1

## Summary

The PR adds a new "direct pharmacy request" entry point for the OPD and ED EMRs. Where the existing pharmacy-request form is reached *from* a prescription (`prescriptionId` is set, items are pre-populated from prescription items, doctor is the prescription's doctor), the new flow lets a doctor or nurse open a standalone pharmacy request page that searches the master items list, picks one or more items, and submits. Two new add-page routes are added (`/opd-management/emr-creation-opd/add/pharmacy-request`, `/ed/emr-creation-ed/add/pharmacy-request`) plus two edit-page redirect shims. A new `Request Pharmacy` button is added to the existing OPD/ED pharmacy-request tabs and now toggles `?page=edit` on the same tab — no longer routing through a new page. The shared `EmrPharmacyRequestForm` gains a `prescription`-less ("direct request") rendering branch: a `Select` over the items API, a `useDebouncedCallback`-driven search, a per-row remove button, a six-column "direct" table layout, and a `returnHref` prop so the Cancel button goes back to a sensible parent. The OPD/ED tab components both grow the same `basePath` + "Request Pharmacy" button block in near-identical form. The shared action (`createEmrPharmacyRequestAction`) is reused unchanged and accepts the new payload because the Zod schema already treats `patientId`, `prescriptionId`, and `doctorId` as optional.

The intent is clear and the diff is well-scoped to the right files. But the implementation ships at least three **High** and several **Medium** issues that should land before merge:

- **Critical: a dead edit-page route that always redirects away.** Both new files under `emr/opd/[id]/edit/pharmacy-request/page.tsx` and `emr/ed/[id]/edit/pharmacy-request/page.tsx` *only* exist to issue a `router.replace(...)` to the main EMR edit page with `?tab=Pharmacy%20Request&page=edit`. They render `<div />` as their body. There is no such ED page added in this PR — the ED edit page path is referenced from the tab component (`/ed/emr-creation-ed/${opdEmrWithServices?.id}/edit/pharmacy-request`) but the page itself is not in the diff, so the new "Request Pharmacy" button on the ED edit page will 404. Confirmed: `gh api .../contents/...edit/pharmacy-request` does not exist for the ED path in the diff.
- **High: data correctness bug in the new client-side uniqueness check.** The direct-request path uses `opdEmrPharmacyRequestItems.some((i) => i.itemId === option.value)` to block duplicates — but every `prependOpdEmrPharmacyRequestItem` call writes `itemId: option.value` (the items table PK, e.g. a cuid) and *also* `item: { itemId: selectedItem.itemId }` (the human-readable item code). The form's existing prescription-driven path uses `item.itemId` for the dedup check (the human code). Mixing the two will let the user add the same item twice depending on which field the consumer reads.
- **High: a `removeOpdEmrPharmacyRequestItem` function reference is captured at render time, but it's only passed as a prop to the row, and the row's `onClick` removes by array index.** The form's `useFieldArray` keys rows by `item.id` (the synthetic id from `useFieldArray`), not by `itemId`. When the user prepends (`prependOpdEmrPharmacyRequestItem`), the *array* index for items already in the list changes — so pressing the trash icon on row 2 will remove whatever is now at index 2, not the item the user thought they were deleting. The existing `key={item.id}` save us from a React `key` warning, but the row's `onClick={() => removePharmacyRequestItem(index)}` is still wrong for any remove-after-prepend sequence.
- **High: the new OPD/ED tab components have an `if (isEditPage) { ... } else { ... }` inside the `Request Pharmacy` button that does the *same* thing in both branches.** The branches differ only in the default value of `tab` (`searchParams.get("tab") ?? "Pharmacy Request"` vs. `"Pharmacy Request"`). The else-branch is reachable only when `isEditPage === false`, which is the add-page case, but the new add-pages redirect away from themselves too — so the only real code path is the if-branch. Two near-identical 7-line blocks are duplicated in both the OPD and the ED tab component (so 4 duplicates total).
- **Medium: the `isEdit` derivation silently drops the `isEditPage` guard.** Before: `const isEdit = isEditPage && !isDetailPage && page === "edit" && canChangeBillableRequests;`. After: `const isEdit = !isDetailPage && page === "edit" && canChangeBillableRequests;`. Now the form renders in edit mode on the *add* page (a fresh `/add` EMR that has no saved state) whenever the user navigates with `?page=edit` in the URL. This is probably never reached in practice because the new add-pages don't expose the `?page=edit` query, but it's a regression in the safety check that protected callers from accidentally rendering the form on a "view" page.

Plus copy-paste of the entire `Request Pharmacy` button block between the OPD and ED tab components, the "search" `Select` writing `item.itemId` to the form state instead of `item.id` in the "already added" check, the `onWheelCapture` and `allowDecimal={false}` / `allowNegative={false}` blocks duplicated four times across the two `isDirectRequest` branches, the new `requestedToStoreId` `Select` being optional in the direct path (the form will save without a destination store on direct requests), and an inner `if (isEditPage)` block whose outer `if/else` is itself pointless.

The PR has no tests. No README / docs update. No CHANGELOG. The OPD/ED page guards use the existing `PermissionGuard` correctly, and the form's data flow is sound in isolation — but the missing ED edit-page route, the duplicated intent, and the index-based row removal are blockers.

## Verdict

**Request changes**

Score: 56/100
Critical: 1 | High: 4 | Medium: 5 | Low: 4 | Nit: 3

## Strengths

- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:217-234`** — `useDebouncedCallback` for the items search is the right tool here; 500 ms is a reasonable balance between "feels live" and "doesn't slam the items API on every keystroke". Same pattern is used elsewhere in the codebase.
- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:228-235`** — The "duplicate item added" guard (`some((i) => i.itemId === option.value)`) and the "select a store first" guard (`:281-285`) are both client-side defensive checks that prevent the user from reaching the server with a payload the server will reject. Good UX, even though the field choice for the check is wrong (see High #2).
- **`src/app/opd-management/emr-creation-opd/add/pharmacy-request/page.tsx` and `src/app/ed/emr-creation-ed/add/pharmacy-request/page.tsx`** — Both new add-pages correctly use `useSuspenseQuery(makeFetchSession())`, pass `session?.storeId` to the form, and wrap the form in `PermissionGuard` with the right subject/action pair (`"OPD Management::Pharmacy Request"` / `"Emergency::Pharmacy Request"`, `action="Add"`). The page is also intentionally client-only (`"use client";`) which is consistent with the rest of the form pages.
- **`src/app/(dashboard)/emr/opd/features/pharmacy-request/opd-emr-pharmacy-request-tab-component.tsx:38-39`** — The `PermissionGuard` for the new "Request Pharmacy" button correctly uses the same subject as the add-page (so users who can render the form on the standalone add-page can also click the button to open the in-tab edit view, but no one else).
- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:438-442`** — The `returnHref` prop is the right abstraction: it lets the form's Cancel button go back to whatever the parent thinks "back" means, without the form having to know about the surrounding route shape. Clean.
- **`src/app/(dashboard)/emr/opd/features/opd-emr-tabs-component.tsx:197-201`** — The `basePath` prop is also the right abstraction. Passing the route string from the tab component down to the pharmacy-request tab component keeps the URL construction in one place and avoids the pharmacy-request tab having to know about the surrounding route conventions.

## Issues

### Critical

- **`src/app/(dashboard)/emr/ed/features/opd-emr-tabs-component.tsx:214-216` and the missing `src/app/(dashboard)/emr/ed/[id]/edit/pharmacy-request/page.tsx` — The "Request Pharmacy" button on the ED edit page will 404**
  The ED tab component is now wired to `basePath={isEditPage ? "/ed/emr-creation-ed/${opdEmrWithServices?.id}/edit/pharmacy-request" : ...}`. That URL has no corresponding page route in the diff. By contrast, the OPD edit-page route is *added* as `src/app/(dashboard)/emr/opd/[id]/edit/pharmacy-request/page.tsx` (a client component that immediately `router.replace`s away). The matching ED edit-page route is missing — the user clicks "Request Pharmacy" in the ED EMR edit view and Next.js returns 404. The PR's diff has 9 files; 4 of them are the four new page files (two add-pages, one OPD edit shim, no ED edit shim). The new `basePath` is only correct in the OPD case.
  **Fix options:**
  1. Add the missing `src/app/(dashboard)/emr/ed/[id]/edit/pharmacy-request/page.tsx` shim that mirrors the OPD one (and `basePath` it to the new ED edit-page route as a real route, not a redirect).
  2. Change the ED tab's `basePath` to point at the same add-page route as the OPD one does for the non-edit case: keep `basePath={isEditPage ? "/ed/emr-creation-ed/${id}/edit/pharmacy-request" : "/ed/emr-creation-ed/add/pharmacy-request"}` but only render the button if the *edit* page exists, or point the button at `/ed/emr-creation-ed/add/pharmacy-request` (no edit shim).
  3. The cleanest fix is to point the "Request Pharmacy" button's `onClick` at the new add-page route directly when `!isEditPage`, and at a real edit-page route (not a redirect) when `isEditPage`. The current design has the button route through `?page=edit` on the same tab instead of opening the standalone form, which is a different UX choice; if that's intentional, the edit-page shim should at least exist for the ED case.
  Whichever option you pick, also document the UX in the PR description (the current title "feat: add pharmacy request functionality for OPD and ED" doesn't make clear that the OPD/ED add-pages *replace* the prescription flow, or that the in-tab button is a *third* entry point).

### High

- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:286-295` and `:302-316` — `item.itemId` vs `itemId` confusion in the new direct-request path**
  The form's pre-existing prescription path uses `prescription.prescriptionItems` whose items have a *string* `itemId` (the human-readable item code like `"MED-001"`). The new direct path adds items via `prependOpdEmrPharmacyRequestItem({ itemId: option.value, item: { ..., itemId: selectedItem.itemId } })` — so the form row has two "item identifiers": `itemId` is the items-table PK (a cuid, e.g. `"clu123abc..."`) and `item.itemId` is the human-readable code (e.g. `"MED-001"`).
  The duplicate check at line 287-295 reads `(item) => item.itemId === option.value`. `option.value` is set on line 268 to `item.id` (the PK). So the check is `row.itemId (PK) === option.value (PK)`. That's *correct in this PR* — but the existing rows from the prescription path have `row.itemId` set to the *human code*, not the PK. If a user later adds a new item to a request that was originally loaded from a prescription, the dedup check will *miss* duplicates between the prescription items and the new direct items (because they're stored under different identifier schemes). The fix: pick one — either always store the PK in `itemId`, or use `item.itemId` consistently in the dedup check.
  **Evidence:** the form's prepend block at `:302-316` sets `itemId: option.value` (the items-table PK) and `item: { itemId: selectedItem.itemId }` (the human code). The dedup check at `:286-295` compares `item.itemId === option.value`, but the option's value is `item.id` (the PK), not the human code. So when the user picks an item whose human code matches an existing prescription row's `itemId`, the check still works (because *neither* field matches the option's value). When the user picks an item whose PK matches an existing prescription row's `itemId` (which is unlikely because the prescription stores human codes there too), the check works. The actual bug surfaces when the same human item is added in two different ways to the same request: the first is stored as `{ itemId: "MED-001", item: { itemId: "MED-001" } }` (prescription), the second is stored as `{ itemId: "clu123...", item: { itemId: "MED-001" } }` (direct). Neither dedup check catches the conflict because the two `itemId` values are different.
  **Fix:** normalize. Either (a) set `itemId: selectedItem.itemId` (the human code) in the prepend call so both paths use the same key, or (b) look up `row.item.itemId === option.label` (the human code shown to the user), or (c) add a separate `itemPk: option.value` field and key the dedup check on the human `item.itemId` only.

- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:541-551` and the `useFieldArray` remove — Removing a row by array index after `prepend` deletes the wrong row**
  The form uses `useFieldArray({ name: "opdEmrPharmacyRequestItems" })` and exposes `remove: removeOpdEmrPharmacyRequestItem` and `prepend: prependOpdEmrPharmacyRequestItem`. The row component receives `removePharmacyRequestItem?: (index: number) => void` and calls it as `removePharmacyRequestItem(index)` on the trash-icon click. `index` here is the **array index** of the row at render time, captured by the `map((item, index) => ...)`.
  When the user prepends, every existing row's index shifts by +1. The new row gets index 0. The old row 0 becomes row 1. The `removePharmacyRequestItem(index)` is the *latest* index, not the index of the row the user clicked on. In practice: the user adds three items (A, B, C via prepending), then clicks the trash on the row showing C. The index passed to `remove` is 0 (because C is at position 0 after prepending) — but the React `key={item.id}` means the row's `useState`/`Controller` is bound to the *row*, not the index, so the trash-icon click on what is visually "C" will call `remove(0)`, which removes A.
  **Fix:** use `removeOpdEmrPharmacyRequestItem(<the row's array id>)` (the `id` field that `useFieldArray` puts on each row), or capture the id at the time the row is created. The `useFieldArray` `remove` function accepts either an index or an id — see https://react-hook-form.com/docs/usefieldarray. Change `onClick={() => removePharmacyRequestItem(index)}` to `onClick={() => removePharmacyRequestItem(item.id)}` (where `item` is the row's `useFieldArray` shape that includes the synthetic `id`).
  **Evidence:** the `useFieldArray` rows are spread via `.map((item, index) => ...)` at `:386-400` of the new file. The `item` is the row object (which has an `id` field per `useFieldArray`'s contract). The row's `onClick={() => removePharmacyRequestItem(index)}` is at line 546. Yes, the `key={item.id}` keeps React from re-rendering the wrong component, but the index is *still wrong* on remove.

- **`src/app/(dashboard)/emr/opd/features/pharmacy-request/opd-emr-pharmacy-request-tab-component.tsx:55-66` and the ED mirror at `:55-66` — The `if (isEditPage) { ... } else { ... }` branches do the same thing**
  In both tab components, the new "Request Pharmacy" button's `onClick` has:
  ```tsx
  if (isEditPage) {
    const tab = searchParams.get("tab") ?? "Pharmacy Request";
    const params = new URLSearchParams();
    params.set("tab", tab);
    params.set("page", "edit");
    router.push(`?${params.toString()}`);
  } else {
    const params = new URLSearchParams();
    params.set("tab", "Pharmacy Request");
    params.set("page", "edit");
    router.push(`?${params.toString()}`);
  }
  ```
  The two branches differ only in the default value of `tab` (`searchParams.get("tab") ?? "Pharmacy Request"` vs. `"Pharmacy Request"`). The only time the `else` branch fires is when `isEditPage === false`, which is the add-page case — but on the add-page, the user is *not* on the EMR edit tab (no `?tab=` query exists). And in the `if` branch, the only "real" `tab` value is "Pharmacy Request" anyway because the click target is *on* the pharmacy-request tab. So both branches effectively set `tab=Pharmacy Request&page=edit`.
  **Fix:** collapse to a single block:
  ```tsx
  onClick={() => {
    const tab = searchParams.get("tab") ?? "Pharmacy Request";
    const params = new URLSearchParams({ tab, page: "edit" });
    router.push(`?${params.toString()}`);
  }}
  ```
  This same simplification applies to both the OPD and the ED tab component (so two duplicates collapse into two single-line blocks instead of two 7-line `if/else` blocks). The block is otherwise copy-pasted between the two tab components — extract a `<RequestPharmacyButton />` or a `useRequestPharmacyNavigation` hook.

- **`src/app/(dashboard)/emr/opd/features/pharmacy-request/opd-emr-pharmacy-request-tab-component.tsx:34` and the ED mirror at `:34` — `isEdit` derivation silently drops the `isEditPage` guard**
  Before: `const isEdit = isEditPage && !isDetailPage && page === "edit" && canChangeBillableRequests;`
  After: `const isEdit = !isDetailPage && page === "edit" && canChangeBillableRequests;`
  The `isEditPage` guard is gone. The form will now render in edit mode on the *add* page (a fresh EMR creation page that has no `opdEmrId`) whenever the URL contains `?page=edit`. There's no `?page=edit` link in the new add-page flow, so this isn't user-reachable in the current code — but it's a regression in the safety check. If a future change adds a `?page=edit` query to the add-page (e.g. for "edit an existing draft"), the form will render in edit mode against a non-existent `prescription.opdEmrId`, and the Cancel button's `returnHref ?? ${baseRoute}/${prescription?.opdEmrId}/edit?tab=Prescription` will produce a literal `${baseRoute}/undefined/edit?tab=Prescription`.
  **Fix:** restore the `isEditPage &&` guard. There is no reason to remove it (the `prescription` and `prescriptionId` props on the form are only valid in the edit case, and the `useEMR()` context has a real `doctorId` only in the edit case).
  **Evidence:** the diff at lines 26-27 in both tab components (OPDEMRPharmacyRequestTabComponent and EDEMRPharmacyRequestTabComponent) shows the old vs. new line.

### Medium

- **`src/app/(dashboard)/emr/opd/[id]/edit/pharmacy-request/page.tsx:1-31` — Redirect shim should not exist; route is a UX bug**
  This file's *only* job is to issue a `router.replace` to the main EMR edit page. The body is `<div />`. This means: a user who pastes or types `/opd-management/emr-creation-opd/<id>/edit/pharmacy-request` into the address bar lands on a blank page, then is silently redirected to the EMR edit page with `?tab=Pharmacy%20Request&page=edit`. That's:
  1. Bad UX — the URL bar shows a non-canonical URL during the brief blank-page render.
  2. Bad for SEO/bookmarkability — the canonical URL for "edit pharmacy request for EMR X" is now the parent EMR's edit page with a query string.
  3. Bad for share-links — the redirect target depends on the EMR's id, not the pharmacy-request's id, so a copy-pasted "edit pharmacy request" link is actually a link to "edit the whole EMR".
  The intent (per the inline `useEffect`) is presumably to "force the user into the in-tab edit view". If so, do that with a Next.js `redirect()` (server-side) instead of a client-side `router.replace`, or with a 301 redirect in `next.config.js`. Or just delete the shim and have the "Request Pharmacy" button's `onClick` issue the navigation directly (the button is in the same file as the navigation code, so this is trivial).
  **Evidence:** the file is 31 lines, of which 23 are boilerplate (imports + `useParams` + `useRouter` + `useEffect` + `<div />`). All the logic is in lines 11-17.
  The same critique applies to the planned ED edit-page shim (see Critical #1).

- **`src/app/(dashboard)/emr/opd/features/pharmacy-request/opd-emr-pharmacy-request-tab-component.tsx:42-77` and the ED mirror — The new "Request Pharmacy" button is a copy-paste of ~36 lines between OPD and ED**
  The new block is essentially identical between the two tab components. The only differences are the `subject` string (`"OPD Management::Pharmacy Request"` vs. `"Emergency::Pharmacy Request"`) and the `moduleType` on the inner `EmrPharmacyRequestForm` (which is in a different code path, but is the only other variant). The `PermissionGuard` + `Button` + `onClick` block can be lifted into a small `RequestPharmacyButton` component in the shared `pharmacy-request/` folder.
  **Fix:** extract a shared `RequestPharmacyButton` component. The two tab components shrink by ~36 lines each, and any future fix to the navigation logic (e.g. the High #3 if/else collapse) lands in one place.

- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:341-378` and the row component at `:484-615` — The two `isDirectRequest ? ... : ...` branches duplicate the entire `NumberInput` block**
  Inside the new `PharmacyRequestItemTableRow`, the `isDirectRequest === false` branch (prescription path) and the `isDirectRequest === true` branch (direct path) both render the same `Controller` + `NumberInput` for `requestedQty` — with the same `onWheelCapture`, the same `allowDecimal={false}`, the same `allowNegative={false}`, the same `className="w-[100px]"`, the same `requestedQtyError` handling. The only difference between the two branches is the *preceding* `Table.Td` cells (item name / generic / unit / dosage / morning / noon / etc. for prescription; index / item name / target-store-stock / unit for direct).
  **Fix:** hoist the `requestedQty` cell out of the `isDirectRequest ? ... : ...` ternary. The component is already a row component — render the item-name/etc. cells conditionally, then render the `requestedQty` cell once, then the optional `ActionIcon` cell. This collapses 130 lines into ~30.

- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:215-225` — The `query` state and the items query are managed by hand when `useDebouncedCallback` already exists**
  The component has three pieces of items-search state: the URL-facing `query` object (with `page`, `limit`, `offset`, `search`, `status`), the local `localSearch` string (driven by the `Select`'s `searchValue`), and the `debouncedSearch` callback that pushes `localSearch` into `query.search`. The flow is:
  1. User types in the `Select`.
  2. `onSearchChange` fires with the new string.
  3. `setLocalSearch(val)` updates the local state.
  4. `debouncedSearch(val)` schedules a `setQuery({ ..., search: val, ... })` for 500 ms later.
  5. `query` change re-runs the items query.
  6. The `Select` re-renders with the new `data`.
  7. When the user picks an item, `onChange` fires.
  8. `setLocalSearch("")`, `setQuery({ search: "" })`, etc. — resets everything.
  This is fine, but the `query` state has a 500 ms lag that affects `value={query.search}` on the `Select` (line 261). When the user types fast, the `Select`'s `value` lags behind the `localSearch` — and the `Select`'s "no exact match" warning may fire because the user-typed string isn't in the data. Mantine recommends `value={null}` when you don't want a controlled-value check; here you want the `data` to drive the suggestions, not the `value`.
  **Fix:** use `Mantine`'s `Autocomplete` (which is designed for "search-then-pick" flows) or set `value={null}` and rely on the `data` for filtering. The current code is a hybrid that mostly works but will produce a "value mismatch" warning in some browsers.

- **`src/app/(dashboard)/emr/opd/features/pharmacy-request/opd-emr-pharmacy-request-tab-component.tsx:42` and the ED mirror — The "Request Pharmacy" button's `onClick` doesn't close the dropdown / clear state**
  The button is a `Button`, not a menu trigger, so this is mostly moot. But the `router.push` is a *soft* navigation; the existing `useEMR()` context's `doctorId` and `appointmentId` are unchanged, which is fine. No issue here other than the lack of a `data-testid` (or `aria-label`) for the e2e tests that will inevitably be added later.
  This is a low-priority cleanup, not a blocker.

### Low

- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:217-225` — `itemStatus.ACTIVE` is type-asserted as `typeof itemStatus.ACTIVE` instead of using the enum value**
  The `query` state declares `status: typeof itemStatus.ACTIVE` (the enum *value*, not the type). At runtime, `status` is one of the enum values. The `setQuery` call at line 224 sets `status: itemStatus.ACTIVE`. This works because `itemStatus.ACTIVE` is a string enum (or a const enum), so the type assertion is benign. But it's a typing smell — declare `status: itemStatus` (the enum type) and let the type checker enforce it.
  **Evidence:** `:218` declares the type; `:225` writes the value; both should be the enum.

- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:485-491` — The new direct-request table renders the row's `key` as `item.id`, but the `useFieldArray` row's `id` is the React-`useFieldArray` synthetic id, not the items table PK**
  The row component receives `item` from the form's `opdEmrPharmacyRequestItems.map((item, index) => ...)` — this `item` is the `useFieldArray` row shape, which has an `id` field (synthetic) plus the spread of whatever `prepend` was called with. So `item.id` is the React synthetic id, not the items table PK. The `key={item.id}` is correct (it's the React key). But the `removePharmacyRequestItem(index)` in the trash icon (line 546) is wrong for the reason explained in High #2.
  **Fix:** see High #2 — pass `item.id` to `remove`, not `index`.

- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:271-277` — The "after onChange" reset duplicates the `useDebouncedCallback` setup**
  After the user picks an item, the form runs:
  ```ts
  setLocalSearch("");
  setQuery({ page: 1, limit: 50, search: "", offset: 0, status: itemStatus.ACTIVE });
  ```
  This is identical to the *initial* state of `query` and to what the debounced callback sets. Extract a `resetItemsQuery = () => setQuery({ page: 1, limit: 50, search: "", offset: 0, status: itemStatus.ACTIVE })` and call it from both places. Three lines becomes one.
  **Evidence:** `:218` (initial state); `:225` (debounced callback); `:271-277` (after pick). All three spell out the same five-field object.

- **`src/app/(dashboard)/emr/opd/features/pharmacy-request/opd-emr-pharmacy-request-tab-component.tsx:48-52` and the ED mirror — The button is hidden when `basePath` is falsy, but `basePath` is always set by the tab's caller**
  The new `PermissionGuard`/`Button` block is guarded by `{basePath && (...)}`. The only caller of `OPDEMRPharmacyRequestTabComponent` (per the diff) is the `OpdEmrTabsComponent` in `opd-emr-tabs-component.tsx:194-198`, and that caller always passes a `basePath` (the `isEditPage ? ... : ...` ternary always resolves to a non-empty string). So the `basePath &&` guard is dead code. Same for the ED tab.
  **Fix:** either drop the guard, or document the contract ("`basePath` may be omitted on read-only pages") and have the caller pass `basePath={undefined}` when appropriate. The current code says "optional, but always set".

### Nit

- **`src/app/(dashboard)/emr/opd/[id]/edit/pharmacy-request/page.tsx:11-17` and the planned ED edit-page — The redirect's query string is hard-coded**
  The shim builds `params.set("tab", "Pharmacy Request")` and `params.set("page", "edit")` by hand. If the EMR edit page ever changes the convention (e.g. uses a different query key, or the tab name changes), this shim will silently break. A small `const PHARMACY_REQUEST_TAB = "Pharmacy Request"` constant in the shared pharmacy-request folder would help.
  **Evidence:** the diff literal at `:13-16` of the new OPD shim file.

- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:155-159` — The `returnHref` prop's default is `undefined`, but the type is `returnHref?: string`**
  The component declares `returnHref?: string` and the usage at `:440-442` is `returnHref ?? \`${baseRoute}/${prescription?.opdEmrId}/edit?tab=Prescription\``. The optional-with-default pattern is fine, but the Cancel button's `onClick` (line 437-442) doesn't `preventDefault` before the `router.push` — for a `<Button type="button">` (no `type="submit"`) this is moot, but the Cancel button is rendered without an explicit `type` attribute, so it defaults to `type="submit"` inside the form. The Cancel button's `onClick` will submit the form (and trigger Zod validation) before the `router.push` fires.
  **Fix:** add `type="button"` to the Cancel `Button`, or `preventDefault()` in the `onClick`. Right now clicking Cancel on an invalid form will show the validation errors *and* try to navigate.

- **`src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-form.tsx:267` — `placeholder="Search Item ID, Item Name , Generic"` has a stray double space**
  Cosmetic. `Item Name , Generic` should be `Item Name, Generic`.
  **Evidence:** `:267` of the new file.

## Scope creep / file placement

The PR is well-scoped to the right files (`emr/features/pharmacy-request/` for the shared form, `emr/{opd,ed}/features/pharmacy-request/` for the tab components, plus four small page files). The `basePath` prop is a clean abstraction, and the `permission` subject strings are pulled from the existing `PermissionGuard` lookup. Nothing is moved to `general-utils.ts` (good — that's a recurring smell in the prior reviews).

**The four new page files are the place where scope creeps:** they exist only to set up a `?page=edit` query parameter on the parent EMR edit page. If the goal is "let users open a direct pharmacy request from a context that doesn't have a prescription", the cleanest design is a single `Request Pharmacy` action that opens a modal over the current tab (or a slide-over panel) — no new routes, no `?page=edit` query, no `useEffect`-based `router.replace` shims. The current design has *three* entry points (in-tab button, OPD add-page, ED add-page) for what is functionally one form, and the two redirect shims that exist purely to make `?page=edit` work.

**Recommendation:** collapse the in-tab button + add-page + edit-shim into a single modal (or a single add-page that the in-tab button opens via a modal). The user experience becomes: "click Request Pharmacy → modal opens with the form → submit → modal closes, list refreshes". No new routes, no `?page=edit` query, no `<div />` shims.

If the team insists on the route-based design (for bookmarkability / deep-linking), then:
- The two add-pages should each receive a `prescriptionId` query parameter (so the modal is not the only way to "edit an existing prescription-based request" — see the existing `/emr/opd/[id]/edit/pharmacy-request/[pharmacyRequestId]` routes for the prescription-flow convention).
- The two edit-shims should be Next.js server-side `redirect()` calls, not client-side `useEffect` + `router.replace`.
- The ED edit-shim should exist (Critical #1).

## Type safety & schema issues

- **`createEmrPharmacyRequestSchema` does not have `.strict()`** — this is pre-existing, not introduced by this PR. But the PR's direct-request path sends `{ patientId, doctorId, requestedFromStoreId, requestedToStoreId, opdEmrPharmacyRequestItems: [...] }` with `prescriptionId` absent. The schema allows this (all fields except `requestedToStoreId` and the items array are optional). The service layer (not in the diff) presumably handles the no-prescription case — but the form's `returnHref` redirect to `${baseRoute}/${prescription?.opdEmrId}/edit?tab=Prescription` will produce a literal `undefined` in the URL when there's no prescription. Worth flagging: the form's `prescription` prop is now optional in the new `returnHref` default (line 441), so the redirect URL will be `/opd-management/emr-creation-opd/undefined/edit?tab=Prescription` if the form is rendered without a prescription and the user clicks Cancel. The form's `onSuccess` redirect (line 192-196) uses `result.data?.opdEmrId`, which is safer.
- **The duplicate-item check at line 287-295 uses `item.itemId` as the comparison key, but the option's value is `item.id`** (the items-table PK). This is the bug described in High #2.
- **The `useFieldArray` row's `remove(index)` is index-based, not id-based.** React Hook Form's `useFieldArray` rows have an `id` field; the `remove` function accepts either an index or a string id. Passing the index here is wrong because the index changes on prepend (High #2). Pass the row's `id` instead.
- **The new add-pages don't take a `prescriptionId` query parameter.** If the form is intended to support editing a *prescription-based* request, the page would need to read the query parameter and pass it down. It doesn't (the add-page is hard-wired to "direct request, no prescription"). That's fine for now, but it means the existing `/emr/opd/[id]/edit/pharmacy-request/[pharmacyRequestId]` routes still handle the prescription-based edit case, and the new "Request Pharmacy" button's `?page=edit` path handles a *different* case (in-tab edit, no pharmacy-request id). This is three UX paths for one feature, which is hard to reason about.
- **`src/app/(dashboard)/emr/opd/features/pharmacy-request/opd-emr-pharmacy-request-tab-component.tsx:38`** — `subject={"OPD Management::Pharmacy Request"}` is a magic string. Pre-existing pattern (the existing `PermissionGuard` calls in the file also use magic strings), so this isn't a regression — but it's a maintenance hazard (a rename in `permission-ui-config.ts` will silently break this guard).

## Transaction & data integrity

No DB writes in this PR's diff. The new direct-request path uses the existing `createEmrPharmacyRequestAction` server action, which presumably handles the no-prescription case (the `prescriptionId` is already optional in the schema). The action's transaction discipline and the `useEMR` context's `doctorId` propagation are out of scope.

**One concern worth flagging:** the new direct-request path does *not* surface a "save and continue" vs. "save and exit" UX. The `onSuccess` handler always navigates to `${baseRoute}/${result.data?.opdEmrId}/edit?tab=Pharmacy%20Request` (line 192-196). For a direct request on the `/add` page, this means the user is kicked back to the EMR edit page after saving — but the direct request might be a *standalone* pharmacy request that doesn't belong to any specific EMR (the `opdEmrId` in the response might be the EMR that was implicitly created, not the one the user was viewing). This is a UX/design question, not a code review question — but the team should confirm the data model supports "pharmacy request without an EMR" before merging this PR.

## Performance

- The new `Select` over the items API uses a 500 ms debounce. Each keystroke fires one API call. With `limit: 50`, the response payload is up to 50 items × ~10 fields each = ~5 KB. The "items" list is potentially thousands of rows, so the user will need to type to filter — the `Select` does *not* fetch all items on mount. Good.
- The `useFieldArray` re-renders the entire table on every prepend/remove. For a typical request of 1-5 items, this is fine. For a request with 50+ items (unlikely but possible), the table would re-render 50 times per prepend. Not a concern in practice.
- The `key={item.id}` is correct (per the `useFieldArray` contract). The `remove(index)` bug (High #2) is a correctness issue, not a performance one.
- The `Select`'s `data` prop is rebuilt on every render via the inline `itemsData?.items?.map(...)`. This is fine for 50 items but allocates a new array on every render. If profiling shows a hot spot, memoize with `useMemo`.

## Accessibility & UX

- The new "Request Pharmacy" `Button` has no `aria-label` or visible label variation — the visible text is "Request Pharmacy" which is clear. No issue.
- The new items `Select` has a `placeholder` that mentions all three search fields ("Search Item ID, Item Name, Generic") but no `aria-describedby` linking to a help text. Screen-reader users will hear the placeholder. Acceptable.
- The new trash `ActionIcon` is wrapped in a `Tooltip label="Delete"` — but `ActionIcon` is an icon-only button. The tooltip is the only label. This is the standard Mantine pattern, but it's not perfect: a screen reader will announce "Delete" only when the tooltip is open (which it isn't, by default). Consider an `aria-label="Delete"` on the `ActionIcon` in addition to the `Tooltip`.
- The Cancel button's `onClick` (line 437-442) does not `preventDefault` (Nit #2). For a `type="submit"` button inside a form, this is a real bug — clicking Cancel will submit the form and trigger Zod validation.
- The redirect shim pages (`emr/opd/[id]/edit/pharmacy-request/page.tsx` and the missing ED equivalent) have a brief blank-page render before the `useEffect` fires. This is visible to the user and shows a flash of empty content. Use Next.js server-side `redirect()` instead.

## Error handling

- `useAction`'s `onError: ({ error }) => { toast.error({ message: error.serverError }) }` is fine — `serverError` is the Zod validation error or the explicit `throw` from the service. No new error handling needed.
- The form's `isValid` check before `execute` (the `useAction` invocation) is implicit — `useAction` will only fire if the schema validates. The form's `onSubmit` does `execute(data)` without a manual `trigger()`. The form's submit button is `disabled={isExecuting || !requestedToStoreId || !opdEmrPharmacyRequestItems.length}` (line 457-460), which prevents the empty-submit case. Good.
- The items `Select` has a `rightSection={isItemsLoading && <Loader size={12} />}` — good UX. No error state for the items query (e.g. "items API is down"). If the query fails, the user just sees an empty `Select`. Worth surfacing with a `notifications.show({ message: "Failed to load items", color: "red" })` on `useQuery` error.
- The form's `useEffect` (line 230-235) sets `patientId`, `appointmentId`, `doctorId`, `requestedFromStoreId` from `useEMR()` and the prop. If any of these is `null` or `undefined` (e.g. the EMR context is not yet hydrated), the form's `defaultValues` (line 134-181) will have the field unset, and the form's `useFieldArray` will still render an empty array. The `if (patientId) setValue(...)` guard is good — it prevents the form from setting `patientId` to `undefined` after mount. But the `useEffect` depends on `setValue` (which is stable from `useForm`) and on the values themselves — so it runs on every change. Acceptable.

## Style & consistency

- The new code follows the existing tab-component style (the `useSearchParams` + `useRouter` + `PermissionGuard` + `Button` pattern). Good.
- The new `Select` over the items API follows the existing `makeFetchItemsQuery` pattern. Good.
- The new `useDebouncedCallback` from `@mantine/hooks` is consistent with the rest of the codebase.
- The new `ActionIcon` + `Tooltip` + `Trash2` pattern is consistent with the rest of the HMS (the `Trash2` icon is from `lucide-react` which is already a dep).
- The four new page files have a copy-paste smell: the OPD and ED add-pages are nearly identical (one has `moduleType="OPD"`, the other has `moduleType="ED"`; one has `"OPD Management::Pharmacy Request"`, the other has `"Emergency::Pharmacy Request"`). Extract a `<NewPharmacyRequestPage moduleType="..." />` component.
- The `if (isEditPage) { ... } else { ... }` block in the "Request Pharmacy" button's `onClick` is the style smell called out in High #3. Collapse.

## Questions for the author

1. The ED edit-page shim is missing (Critical #1). Was this an oversight, or is the ED "Request Pharmacy" button intentionally not wired up to a new route?
2. The "Request Pharmacy" button navigates to `?tab=Pharmacy%20Request&page=edit` on the same tab. Why not open the standalone form (the new add-page) in a new tab, or as a modal? The current UX forces the user to *replace* the existing pharmacy-request table view with the form, with no obvious way to "cancel and go back to the list" (the Cancel button goes back to `prescription?.opdEmrId` edit, not the list).
3. The `prescription` prop is still passed to the form in the `isEdit === true` branch (e.g. `opd-emr-pharmacy-request-tab-component.tsx:39-44`), but the new `returnHref` defaults to `${baseRoute}/${prescription?.opdEmrId}/edit?tab=Prescription` — which is undefined when there's no prescription. What does Cancel do on a direct request?
4. The new direct-request path uses `itemId: option.value` (the items-table PK) for the dedup check, but the existing prescription path uses `item.itemId` (the human code). Is one of these wrong, or is the team OK with the two paths having different identifier schemes?
5. The "Request Pharmacy" button's `onClick` has an `if (isEditPage) { ... } else { ... }` that does the same thing. Why was the `else` branch kept? (Was this meant to be a placeholder for a future "open in new tab" UX?)
6. The four new page files (two add-pages, one OPD edit shim, and the missing ED edit shim) only exist to set up a `?page=edit` query parameter. Was a modal-based design considered? It would eliminate three of the four page files.
7. The `useFieldArray` row's `remove` is called with `index`, which is wrong after a `prepend`. Was this tested? A simple "add three items, then delete the middle one" test would catch this.
8. The items search `Select` uses `value={query.search}` (the debounced value) but `searchValue={localSearch}` (the live value). Was this mismatch intentional, or is it a side effect of mixing controlled and uncontrolled Mantine props?
9. The PR has no tests, no docs, no CHANGELOG. The "feat" prefix in the title suggests this is a user-visible feature — is there a ClickUp ticket for the new UX, and has the team signed off on the new entry points?
10. The `onSuccess` redirect (line 192-196) goes to `${baseRoute}/${result.data?.opdEmrId}/edit?tab=Pharmacy%20Request`. On a direct request, the user is on the `/add` page (no EMR id); after save, the response's `opdEmrId` might be a new EMR created implicitly. Does the data model support "pharmacy request without a parent EMR"?

## Cross-references

- **`/Users/pyaesonewin/.claude/CLAUDE.md` §Rules** — "NEVER create files unless absolutely necessary". The PR adds 4 new page files; 2 of them are necessary (the add-pages), and 1 of them (the OPD edit shim) is questionable. The missing ED edit shim is the critical one.
- **`/Users/pyaesonewin/.claude/CLAUDE.md` §Rules** — "Keep files under 500 lines". `emr-pharmacy-request-form.tsx` is now 619 lines (was 412). The PR grew it by 207 lines, with substantial duplication between the `isDirectRequest` branches. Out of compliance.
- **`/Users/pyaesonewin/.claude/CLAUDE.md` §Rules** — "ALWAYS read a file before editing it". The PR edits `emr-pharmacy-request-form.tsx` (619 lines), `opd-emr-pharmacy-request-tab-component.tsx` (now 88 lines), `ed-emr-pharmacy-request-tab-component.tsx` (now 89 lines), and `opd-emr-tabs-component.tsx` and `ed/opd-emr-tabs-component.tsx`. Hard to tell from the diff whether the author was familiar with the existing form's quirks (e.g. the `useFieldArray` row's `id` vs `index` issue).
- **`hms-app/CLAUDE.md` §Path aliases** — The new code uses `@/app/(dashboard)/...` paths, consistent with the existing aliases. No new aliases introduced.
- **`hms-app/CLAUDE.md` §Caveats** — "Tread carefully with migrations; consult peers before installing new dependencies." No new dependencies; no migrations. Good.
- **`hms-app/CLAUDE.md` §Auth** — "The tRPC context resolves sessions via `AuthService`; procedures use `authorizeProcedure(action, subject)`." The new pages use `useSuspenseQuery(makeFetchSession())` (not tRPC) and `PermissionGuard` (UI-side). The form submits to `createEmrPharmacyRequestAction` which is a server action that uses `authActionClient`. The auth flow is consistent with the existing pharmacy-request form. Good.
- **No summary-service or outbox implications** — this PR is purely UI-side. The OPD EMR's outbox trigger is unchanged (the pharmacy-request action writes to the OPD EMR tables, not the CFI tables).

## Verification needed

Things that cannot be verified from the diff alone:

1. **Does the new "Request Pharmacy" button on the ED edit page 404?** (Critical #1) — should reproduce immediately. Click the button on an ED EMR edit page.
2. **Does the `useFieldArray` row's `remove(index)` delete the wrong row after a prepend?** (High #2) — repro: open a direct pharmacy request, add 3 items via the `Select`, click the trash icon on item #2 (the middle one). If the first item disappears, the bug is real.
3. **Does the duplicate-item check catch a duplicate between a prescription item and a direct item?** (High #2) — add a prescription-based request, then open the form in direct mode, search for an item that's already in the prescription, pick it. If the form lets you add it as a duplicate, the bug is real.
4. **Does the `isEdit` derivation render the form on the add-page when `?page=edit` is in the URL?** (High #4) — should never happen in practice (the add-page doesn't expose the query), but a regression test would catch it.
5. **Does the new `Select`'s debounced query fire on every keystroke or only after the debounce?** (Medium #4) — add a network throttle and type fast. If you see 10 requests for 10 keystrokes, the debounce is broken.
6. **Does the items `Select` show a "value mismatch" warning in the console?** (Medium #4) — open the form, type a search, pick an item. If the browser console shows a "controlled vs uncontrolled" warning, the bug is real.
7. **Does the Cancel button submit the form before navigating?** (Nit #2) — open the form, leave a field invalid, click Cancel. If the form shows validation errors *and* navigates, the bug is real.
8. **Does the items query show an error to the user when the API fails?** (Error handling) — stop the items API, open the form, search. If the user sees an empty `Select` with no error message, the UX is incomplete.
9. **SonarQube Cloud analysis.** The PR's existing comment says "❌ The last analysis has failed." — confirm whether this is a known infra issue or a new finding. The PR adds no new `console.log` / `console.error`, so it should be clean.
10. **No tests, no docs, no CHANGELOG.** Add at minimum: (a) a unit test for the `useFieldArray` row removal (catches High #2), (b) a unit test for the duplicate-item check (catches High #2's secondary issue), (c) a one-line CHANGELOG entry for the new entry points.

## Checklist results

- [ ] `console.log` / `console.error` in production — None added in this PR.
- [x] `any` type annotations — None added in this PR.
- [x] `@ts-ignore` / `@ts-expect-error` / `eslint-disable` — None added.
- [x] TODO / FIXME — None added.
- [x] Hardcoded secrets — None.
- [x] SQL/Prisma injection — N/A (no DB queries in this PR).
- [ ] Long files (>500 lines) — `emr-pharmacy-request-form.tsx` is now 619 lines (was 412). Out of compliance with the 500-line cap.
- [ ] God components — The form was already a large component; the new `isDirectRequest ? ... : ...` branches make it worse. Extract a `<DirectPharmacyRequestTable />` or move the row component to its own file.
- [x] Missing `key` props, index-as-key — N/A (rows use `useFieldArray`'s `item.id`).
- [ ] Unsafe type assertions — `query.status: typeof itemStatus.ACTIVE` should be the enum type, not the value (Low #1).
- [x] Async error swallowing — N/A.
- [x] Missing `await` inside transactions — N/A.
- [x] Tenant-scope — N/A.
- [x] Permission checks — `PermissionGuard` is used correctly in both new add-pages and in the new "Request Pharmacy" button. The subject strings are consistent with the existing pharmacy-request pages.
- [x] Missing Zod validation at boundary — N/A (the form's payload is validated by `createEmrPharmacyRequestSchema` on the server).
- [x] React Query correctness — The `useDebouncedCallback` + `useState` + `useQuery` pattern is correct. The `value={query.search}` mismatch is a UX issue (Medium #4), not a correctness issue.
- [ ] Scope creep — The four new page files (and the missing ED edit-shim) are a UX/design smell, not a code-quality smell. The 207-line growth of `emr-pharmacy-request-form.tsx` is a code-quality smell.
- [ ] Missing tests — Critical: no tests for the new direct-request path. No test for the `useFieldArray` row removal bug (High #2). No test for the duplicate-item check (High #2's secondary issue).

## Recommendation

Block merge. The **Critical** missing ED edit-page route must be added (or the ED `basePath` must be changed to point at the add-page directly). The **High** `useFieldArray` row removal bug is a 2-line fix and should land with this PR. The **High** `itemId` vs `item.itemId` confusion is a 5-line fix. The **High** `if (isEditPage) { ... } else { ... }` collapse is a 1-line fix in each of the two tab components. The **High** `isEdit` derivation regression is a 1-character fix (restore the `isEditPage &&` guard). The **Medium** duplication between the two tab components and between the two `isDirectRequest` branches in the row component should be addressed before this PR gets to "approve" status.

The single biggest recommendation is to **collapse the three entry points** (in-tab button, OPD add-page, ED add-page) into a **single modal-based design**, which would eliminate 3 of the 4 new page files and most of the duplication in the tab components. If the team wants to keep the route-based design, then:
- Add the missing ED edit-page shim.
- Replace the client-side `useEffect`-based `router.replace` with a server-side `redirect()`.
- Extract the four page files into a single shared `<NewPharmacyRequestPage moduleType="..." />` component.
- Add at minimum a unit test for the `useFieldArray` row removal and the duplicate-item check.
- Add a CHANGELOG entry describing the new "direct pharmacy request" entry points.
