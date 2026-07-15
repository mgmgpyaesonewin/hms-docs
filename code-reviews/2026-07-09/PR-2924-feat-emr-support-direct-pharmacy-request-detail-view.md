# Code Review: PR #2924 — feat(emr): support direct pharmacy request detail view
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/27/bugs/emr-pharmacy-and-room-` → `development`
**Files changed:** 4 (+670 / -237)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-09
**ClickUp:** https://app.clickup.com/t/9018849685/86ey7j3kr

## Summary
Splits the pharmacy-request detail view into a "direct" flow (no prescription) and the existing prescription-backed flow, in both the EMR and IPD modules. Direct requests get a smaller item table (no dosage/route/duration columns, no `prescriptionItems` join), a stripped-down header (no `Prescription ID`, no `Requested From`), and a `PrintButton`. The two new tables are extracted into `DirectPharmacyRequestItemsTable` and `PrescriptionPharmacyRequestItemsTable` so the existing single-table monolith is no longer interleaved with conditional logic.

A separate, unrelated change in `room-card.tsx` broadens the `wardCreatedAt` type from `Date | null` to `Date | string | null` and routes the sort key through `getRoomSortTimestamp`, which accepts both shapes. A new test (`__tests__/room-card-ward-created-at.test.tsx`) covers the string-serialized case.

Two production-code bugs surfaced during review: the "Rejected Date" branch in both modules formats `data.createdAt` instead of the actual rejection timestamp, and the `DirectPharmacyRequestItemsTable` only renders Received Qty after a transfer exists, even when a direct request can land in `RECEIVED`/`RECEIVED_PARTIALLY` with `targetStoreStockQty` available.

## Verdict
**Request changes**
Score: 60/100
Critical: 0 | High: 2 | Medium: 3 | Low: 4 | Nit: 2

## Issues

### Critical
None

### High

1. **Wrong date source in "Rejected Date" rows** — `src/app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-detail.tsx:107` and `src/app/(dashboard)/ipd/features/components/pharmacy-request/pharmacy-request-detail.tsx:82` both format `data.createdAt` instead of `data.opdEmrpharmacyTransfer?.rejectedAt` / `data.pharmacyTransfer?.rejectedAt`:
   ```ts
   data.opdEmrpharmacyTransfer?.rejectedAt
     ? dayjs(data.createdAt).format("DD MMM YYYY")
     : "",
   ```
   The whole point of the row is to show when the rejection happened. Users viewing a rejected direct request will see the request creation date under "Rejected Date". This is a copy-paste bug from the cancelled-time row above it. Fix the field name; the conditional is already correct.

2. **Direct request Received Qty column is unconditionally rendered** — `emr-pharmacy-request-detail.tsx:445` and `pharmacy-request-detail.tsx:889` show `Received Qty` for every direct request regardless of status, while the prescription table only renders it when `isReceived`. A `PENDING` or `REJECTED` direct request shows an empty Received Qty column for every row. Mirror the prescription table's `{isReceived && <Table.Th>Received Qty</Table.Th>}` pattern, or stop hiding the value when zero (current behavior makes the column visually inconsistent — header says "Received Qty" but cells are blank for not-yet-received rows in both tables).

### Medium

1. **Two near-identical detail components diverge in column count** — The IPD `PrescriptionPharmacyRequestItemsTable` has 12 columns (no `Target Store Stock`) while the EMR version has 13 (with `Target Store Stock`). That's a pre-existing divergence but the PR doubles it by duplicating both tables side-by-side. Either share a column-config constant or accept that IPD intentionally omits the column (in which case a one-line comment would help the next reader). Two parallel files of ~80 lines each will drift.

2. **`isDirectRequest` heuristic is "no prescription"** — Both files use `const isDirectRequest = !data.prescription;` to decide which table and which fields to show. If a direct request ever comes back with a stub `prescription: null` in its type but a populated `prescriptionItems`, or vice versa, the rendering silently picks the wrong table. If the domain has an actual `requestType` enum (DIRECT vs PRESCRIPTION), key off that. Otherwise add a `// direct requests have no prescription` comment so the heuristic isn't mistaken for the field being redundant.

3. **`DetailSection` in EMR component drops `gridCols` for direct requests** — `emr-pharmacy-request-detail.tsx:117` always passes `gridCols={4}`, but the direct content has fewer fields (no `Prescription ID`, no `Requested From`). With 4 columns, 6 fields render as 4 + 2, which may leave a gap. Verify the rendered output; if it looks fine, no action — but the prop should be tuned to the smaller content set (`gridCols={3}` would balance 6 fields as 3 + 3).

### Low / Nit

1. **`PharmacyRequest` type for the direct table may include unused `prescription`/`prescriptionItems` fields** — Passing the whole `PharmacyRequest` into `DirectPharmacyRequestItemsTable` carries the optional prescription payload into a component that never reads it. Tighten the prop to the subset the table actually uses (`Pick<PharmacyRequest, "pharmacyRequestItems" | "pharmacyTransfer">`) to make the boundary explicit. Same applies to the EMR pair.

2. **`PrintButton` is rendered with no props** — `emr-pharmacy-request-detail.tsx:298` renders `<PrintButton />` but the IPD equivalent (which also shows direct requests) does not. Either the print action is universally desired and the IPD page should get one too, or the print template is EMR-only and should be clarified. Worth confirming with the requester — the PR title mentions only "add print action for direct pharmacy request details", but only one of the two affected modules gets the button.

3. **`getRoomSortTimestamp` accepts `string | Date`** — `room-card.tsx:87` is a sound fix for serialized JSON, but the broader fix (keep timestamps as `Date` end-to-end) would let the helper collapse to `value?.getTime() ?? MAX_SAFE_INTEGER`. Acceptable as written; flagged because if every consumer of `RoomList` needs to re-parse strings, the leak has likely already spread past `room-card.tsx`. Worth grepping.

4. **New test file is large for what it asserts** — `__tests__/room-card-ward-created-at.test.tsx` mocks 10+ modules to render the full `RoomCard` just to assert that a string `createdAt` doesn't crash sorting. A focused test that imports `getRoomSortTimestamp` directly (or extracts the sort comparator) would be 10 lines and not require the entire Mantine/RoomCard render tree. Defensible if you want a true integration check, but a unit test on the helper would catch the same bug with much less surface area.

5. **Nit — `cancelledContent` formatting inconsistency** — `data.cancelledAt ? dayjs(data.cancelledAt).format("DD MMM YYYY") : ""` uses `DD` (zero-padded day) while `receivedContent`/`rejectedContent` use `D` (no padding). The two "date & time" rows already use `D MMM YYYY, h:mm A`. Pick one convention.

6. **Nit — duplicated "Pharmacy Request Detail" `<Title>`** — `emr-pharmacy-request-detail.tsx:295-303` renders the same `<Title>` in both branches of the `isDirectRequest` ternary; only the wrapper differs. Pull the title out and conditionally wrap with `<Flex>` + `<PrintButton>` instead of duplicating the heading.

## Recommendation
1. Fix the two `data.createdAt` typos in the Rejected Date rows — that is the highest-impact issue, users are seeing wrong data.
2. Either guard `Received Qty` with `isReceived` in the direct tables or render the column unconditionally with the existing "blank when 0" cell behaviour.
3. Extract a shared `getRequestContent(data)` helper if the direct/prescription branching is going to keep growing; the two files now have ~140 lines of near-duplicate `baseContent`/`directBaseContent` arrays.
4. Land the `getRoomSortTimestamp` change but consider whether the upstream serializer (server action returning JSON-stringified dates) is the actual root cause — fixing it once there removes the need for the runtime parse everywhere.