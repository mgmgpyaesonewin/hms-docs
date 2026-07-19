# OPD Billing Activity Log Architecture

**Status:** Design (ground floor) — pending implementation
**Scope:** `@hms-app/` — `opd_billing_activity_logs.payload` column + per-call-site inline writes
**Authoring session:** `/grill-with-docs` round 1

## Goal

Add a `payload JSONB` column to `opd_billing_activity_logs` and migrate the 7
existing `createServiceOPDBillingLog` call sites to write structured per-action
payloads. Future modules (OpdPackageBill, FOCItem, ExpiryUpdatedStock,
PurchasedPriceUpdatedStock) follow the same pattern by copying the call-site
shape — no shared service, no registry.

The OPD billing modal is the **showcase** for the product team to understand what
audit data should be captured going forward.

**Out of scope for this ticket** (parked for a separate design session):

- Per-field before/after diffing for `EDIT_SERVICE_BILL` events.
- Per-action pretty renderers in the modal (v1 dumps raw JSON).

## Decisions locked

| # | Decision | Reason |
|---|----------|--------|
| Write point | Server-side, same `trx` as business write | Same pattern as `opd-package-bill.repository.ts:269`; transactional guarantee |
| Payload strategy | Snapshot-only | Explicit before/after parked; per-action payloads already carry enough fidelity |
| Actions | 6 — `CREATE`, `EDIT_SERVICE_BILL`, `CHANGE_PAYMENT_STATUS`, `CANCEL`, `ADD_PHARMACY_ITEM`, `REMOVE_PHARMACY_ITEM` | Derived from data: today 3 actions exist (Create / Changed Payment Status / Edit Service Bill); adding CANCEL + pharmacy-item add/remove |
| Payload shape | Per-action (asymmetric); thin `{refInvoiceNo}` header on every payload | Different actions = different fields; header makes rows self-describing on export |
| Description column | Keep; template-string at writer | 527 legacy rows depend on it; modal already renders it |
| Action column | Stay `TEXT`; TS interface as the contract | Cheaper migration; no direct-SQL writers in this codebase |
| 527 existing rows | Leave as-is; `payload` is null on them; UI renders `description` only | No data is recoverable from description; backfill would be inventing data |
| "from" value for status / cancel / edit | Caller reads the existing row inside the same `trx` as the business write | Trx isolation = consistent snapshot; no race with concurrent edits |
| `changedFields` for EDIT | Inline shallow diff with `JSON.stringify` equality | v1 priority: get the common case working; per-row array diffs deferred |

## Call-site refactor (7 sites)

All seven existing calls to `createServiceOPDBillingLog` migrate to writing the
audit row inline inside the same `trx` as the business write.

```ts
// CHANGE_PAYMENT_STATUS example
await prisma.$transaction(async (tx) => {
  const existing = await tx.opdBilling.findUniqueOrThrow({
    where: { id: opdBillingId },
    select: { id: true, invoiceNo: true, opdBillingPaymentStatus: true },
  });

  await tx.opdBilling.update({
    where: { id: opdBillingId },
    data: { opdBillingPaymentStatus: payload.paymentStatus },
  });

  await tx.opdBillingActivityLog.create({
    data: {
      action: "CHANGE_PAYMENT_STATUS",
      description: `Changed Payment Status from ${existing.opdBillingPaymentStatus} to ${payload.paymentStatus}`,
      user: { connect: { id: userId } },
      opdBilling: { connect: { id: existing.id } },
      payload: {
        refInvoiceNo: existing.invoiceNo,
        from: existing.opdBillingPaymentStatus,
        to: payload.paymentStatus,
      },
    },
  });
});
```

This pattern is **mandatory for every EDIT / CHANGE_PAYMENT_STATUS / CANCEL call
site**: read existing state → business write → build payload (using the read
result for `from`) → audit write. All four steps in one `trx`.

CREATE is simpler — no `from` value, the post-write row IS the snapshot.
ADD/REMOVE_PHARMACY_ITEM build the payload from the items list being attached
or detached, which the caller already has in scope.

```ts
// EDIT_SERVICE_BILL example — project + shallow diff
await prisma.$transaction(async (tx) => {
  const before = await tx.opdBilling.findUniqueOrThrow({ where: { id }, include: SERVICES_INCLUDE });
  await tx.opdBilling.update({ where: { id }, data: editData });
  const after  = await tx.opdBilling.findUniqueOrThrow({ where: { id }, include: SERVICES_INCLUDE });

  // Project to the form-shaped fields. Otherwise `id`, `updatedAt`, and
  // joined relation metadata register as "changes" in the diff.
  const project = (r: typeof after) => ({
    patientName: r.patient.name,
    date: r.date,
    billType: r.billType,
    patientType: r.patientType,
    pharmaInvoice: r.pharmaInvoice,
    appointmentId: r.appointmentId,
    additionalServices: r.additionalServices,
  });
  const b = project(before), a = project(after);
  const changedFields = Object.keys(a).filter(
    k => JSON.stringify(b[k]) !== JSON.stringify(a[k])
  );

  await tx.opdBillingActivityLog.create({
    data: {
      action: "EDIT_SERVICE_BILL",
      description: `Edited Service Bill (${changedFields.join(", ") || "no field changes"})`,
      user: { connect: { id: userId } },
      opdBilling: { connect: { id: after.id } },
      payload: { refInvoiceNo: after.invoiceNo, ...a, changedFields },
    },
  });
});
```

**The `trx` isolation guarantee is load-bearing.** Reads inside the same `trx`
as the business write see a consistent snapshot — no risk of recording
`from: "UNPAID"` when someone else flipped it to `PAID` between the read and the
write.

### Where each field comes from

| Field | Source | When |
|---|---|---|
| `refInvoiceNo` (header) | the `opdBillings.invoiceNo` of the entity being audited | read inside the same `trx` as the business write |
| `patientName`, `date`, `billType`, `patientType`, `pharmaInvoice`, `appointmentId`, `additionalServices` (CREATE / EDIT) | the **post-write** state of the OPD billing row + its services | read inside the same `trx`, after the business write succeeds |
| `changedFields` (EDIT only) | shallow diff over the form-shaped fields (project both rows first — full Prisma rows catch `id` / `updatedAt` / joined relation metadata) | inside the same `trx` |
| `from` (CHANGE_PAYMENT_STATUS) | the **pre-write** `opdBillings.opdBillingPaymentStatus` | read inside the same `trx`, before the update |
| `to` (CHANGE_PAYMENT_STATUS) | the incoming `payload.paymentStatus` | from the request body |
| `previousPaymentStatus` (CANCEL) | the **pre-write** `opdBillings.opdBillingPaymentStatus` | read inside the same `trx`, before the cancel |
| `reason` (CANCEL) | from the request body | from the request body |
| `pharmacyInvoiceNo`, `items`, `totalAddedAmount` (ADD/REMOVE_PHARMACY_ITEM) | from the request body + the items being attached/detached | from the request body |

## Per-action payload shapes

TS interfaces only — no runtime validation. The action boundary (server action /
tRPC procedure) already validates request bodies with Zod; the audited row was
just read from the DB. Re-validation at audit time would catch nothing.

```ts
// Header present on every payload for self-describing exports.
type Header = { refInvoiceNo: string };

type CreatePayload = Header & {
  patientName: string;
  date: string;                                   // ISO, the bill date
  billType: string;
  patientType: string;
  pharmaInvoice: string | null;
  appointmentId: string | null;
  additionalServices: ServiceLine[];
};

type EditServiceBillPayload = CreatePayload & {
  changedFields?: string[];                       // top-level keys that differ
};

type ChangePaymentStatusPayload = Header & {
  from: "UNPAID" | "PAID" | "CANCEL";
  to:   "UNPAID" | "PAID" | "CANCEL";
};

type CancelPayload = Header & {
  previousPaymentStatus: "UNPAID" | "PAID";
  reason?: string;
};

type AddPharmacyItemPayload = Header & {
  pharmacyInvoiceNo: string;
  items: PharmacyItem[];
  totalAddedAmount: number;
};

type RemovePharmacyItemPayload = AddPharmacyItemPayload;

type ServiceLine = {
  serviceName: string;
  priceType: string;                              // free-text for v1
  doctorName: string;
  qty: number;
  price: number;
  discount: { kind: "AMOUNT"; value: number } | { kind: "PERCENT"; value: number };
  foc: boolean;
  amount: number;
};

type PharmacyItem = {
  itemName: string;
  qty: number;
  price: number;
  amount: number;
};
```

Caveat: `priceType` is free-text for v1. Tighten to enum later if the product
team signs off on a canonical list. `discount` uses a discriminated union
because both AMOUNT and PERCENT occur in the data; an audit log that lies about
its data is worse than none.

## View details UI

`service-billing-activity-log-modal.tsx` renders each row as
`{timestamp, userName, description}`. A "View details" disclosure on each row
dumps the `payload`:

```tsx
<details>
  <summary>View details</summary>
  <pre>{JSON.stringify(row.payload, null, 2)}</pre>
</details>
```

Acceptable for v1 because the product team is the audience and wants to see the
raw data shape. Per-action pretty renderers are parked — they cost ~6
renderers and a registry; add when the second consumer needs them.

## Migration

Single statement, additive, no data backfill:

```sql
-- prisma/migrations/<ts>_opd_billing_activity_log_payload/migration.sql
ALTER TABLE "opd_billing_activity_logs" ADD COLUMN "payload" JSONB;
```

Existing 527 rows retain their `description` and gain `payload = null`. The
existing modal renders `description` for those rows; the new "View details"
expansion is empty.

The corresponding `schema.prisma` change:

```prisma
model OPDBillingActivityLog {
  // ... existing fields ...
  payload Json? @map("payload") @db.JsonB
}
```

## Call-site table

| File | Line | Old action string | New action |
|------|------|-------------------|------------|
| `app/(dashboard)/shared/opd/workflows/create-opd-billing-workflow/audit-log.step.ts` | 13 | `"Create"` | `CREATE` |
| `app/(dashboard)/shared/opd/services/opd-billing.service.ts` | 622 | (TBD — inspect at impl time) | (TBD) |
| `app/(dashboard)/shared/opd/services/opd-billing.service.ts` | 703 | `"Changed Payment Status"` | `CHANGE_PAYMENT_STATUS` |
| `app/(dashboard)/shared/opd/services/opd-billing.service.ts` | 809 | `"Changed Payment Status"` | `CHANGE_PAYMENT_STATUS` |
| `app/(dashboard)/shared/opd/services/opd-billing.service.ts` | 910 | `"Edit Service Bill"` | `EDIT_SERVICE_BILL` |
| `app/(dashboard)/shared/opd/services/opd-billing.service.ts` | 976 | `"Edit Service Bill"` | `EDIT_SERVICE_BILL` |
| `app/(dashboard)/shared/opd/services/opd-billing-payment-status.service.ts` | 63 | `"Changed Payment Status"` | `CHANGE_PAYMENT_STATUS` |

After all 7 sites migrate, `createServiceOPDBillingLog` (repository method) is dead code — delete.

## Modal

`service-billing-activity-log-modal.tsx` is OPD-specific today. The
OPD-specific header (Patient Name, Bill Type, Doctor, Payment Status, Store,
etc.) renders inline; the route is the existing
`GET /api/opd-billing-log/[id]`.

When a second module adopts audit logging, promote the modal to a shared
component and the route to `/api/audit-log/[entity]/[id]` then. Not before.

## Outbox interaction

The OPD billing writes already fire an `event_outbox` event for the
`hms-summary-service` worker (consultation-fees invoice flow, ADR 0001). The
audit log write is a **separate** `prisma.opdBillingActivityLog.create` in the
same `trx`, NOT an outbox event. Do not mix the two paths — audit logs are
local; outbox is for cross-service events.

## Follow-ups (out of scope)

- Per-field before/after diff for `EDIT_SERVICE_BILL` — parked.
- Promote modal + route to shared component — when a second module needs it.
- Migrate `OpdPackageBill`, `FOCItem`, `ExpiryUpdatedStock`,
  `PurchasedPriceUpdatedStock` onto the same per-call-site pattern. Copy the
  writer shape; add a `payload` column if the domain's audit table lacks one.
- The `payout_amount` / status-history tables for the summary-service CFI work —
  different domain, separate design.

## Reference

- Existing activity-log tables in this codebase: `opd_billing_activity_logs`,
  `opd_package_bill_activity_logs`, `foc_item_activity_logs`,
  `expiry_updated_stock_activity_logs`, `purchased_price_updated_stock_activity_logs`,
  `activity_logs` (generic `Logs` model).
- Reference implementation for transactional audit writes:
  `opd-package-bill.repository.ts:258-285` (`createPackageBillLog`).
- Reference for caller pattern:
  `opd-package-bill.repository.ts:269` is called inside the business write's `trx`
  by `create-package-bill-workflow/audit-log-step.ts:14`.
- Outbox design (separate concern, do not duplicate):
  `hms-docs/summary-service/adrs/0001-transactional-outbox.md`.