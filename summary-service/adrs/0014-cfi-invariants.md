# ADR 0014: CFI invariants — adjustment semantics + payout formula

- **Status:** Accepted
- **Section in brief:** 7.13, 7.14

## Context

Two rules govern the `adjustment` and `payout_amount` columns on `consultation_fees_invoices`:

1. The `adjustment` field is the admin's correction to the consultation fee (always a reduction, never an addition). The CFI becomes immutable once it leaves `UNPAID`.
2. The `payout_amount` is the doctor's net earnings: `payout = amount - adjustment`. No hospital cut, no per-doctor share percentage.

The hospital has confirmed: late corrections after `PAID` are handled outside this service (a separate accounting workflow). Late corrections after `VOID` are handled by issuing a new OPD billing for the corrected consultation.

## Decision

### Adjustment semantics

- **Sign convention:** non-negative only. `CHECK (adjustment >= 0)`.
- **Bounds:** `CHECK (adjustment <= amount)`. A `payout_amount` of 0 is valid; negative payout is not.
- **Reason requirement:** a free-text `reason` (1-500 chars) is required for every adjustment. The API rejects empty reasons.
- **Mutability window:** adjustment is only allowed while the CFI is `UNPAID`. Once `PAID` or `VOID`, the API returns `409 ADJUSTMENT_LOCKED`.
- **Authorization:** the same `consultation_fees:write` permission as status changes.
- **Audit:** every adjustment is recorded in `consultation_fees_invoice_adjustments` (immutable history).

### Payout formula

```ts
function computePayoutAmount(amount: number, adjustment: number): number {
  return amount - adjustment;
}
```

- Pure, deterministic, parameter-free. Trivially testable.
- Called from: the worker on CFI insert; the API on adjustment update.
- **Not** re-evaluated after the CFI transitions to `PAID` or `VOID` — adjustment is locked and `payout_amount` is frozen.

### Rounding

- The amount column is `NUMERIC(12,2)`. Round half-up to 2 decimal places at every recompute.
- A DB-level `CHECK (payout_amount = amount - adjustment)` catches bugs where the app code and the DB drift. (If the formula changes, this constraint is updated in the same migration.)

## Rationale

- The "locked once `PAID`" rule keeps the audit trail clean: what the doctor earned is what was frozen at the `PAID` moment, full stop.
- The "non-negative" rule keeps the math simple: `payout = amount - adjustment` is always non-negative.
- The pure-function formula can move to a percentage model (Model B/C) in v2 without changing the DB schema — just edit the function and the CHECK constraint.
- The data model leaves room for a future `doctor_payout_config` table (per-doctor share percentage) without adding it in v1.

## Consequences

- Schema constraints (enforced at the DB level):
  ```sql
  CHECK (adjustment >= 0)
  CHECK (adjustment <= amount)
  CHECK (payout_amount = amount - adjustment)
  CHECK (payout_amount >= 0)
  ```
- A new `consultation_fees_invoice_adjustments` table for the audit history:
  ```sql
  CREATE TABLE consultation_fees_invoice_adjustments (
    id              UUID PRIMARY KEY,
    invoice_id      UUID NOT NULL REFERENCES consultation_fees_invoices(id),
    previous_amount NUMERIC(12,2) NOT NULL,
    new_amount      NUMERIC(12,2) NOT NULL,
    reason          TEXT NOT NULL CHECK (length(reason) BETWEEN 1 AND 500),
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_by_id   UUID NOT NULL,
    invoice_version_at_change INT NOT NULL
  );
  ```
- API endpoint: `POST /consultation-fees-invoices/{id}/adjustment` with `{ amount, reason, version }` (version from `If-Match`).
- API behavior:
  1. Read the invoice row. If `status != 'UNPAID'`, return `409 { code: "ADJUSTMENT_LOCKED", currentStatus: ... }`.
  2. Validate `version` matches. If not, return `409 VERSION_MISMATCH`.
  3. In a single transaction: insert audit row, update `adjustment`, recompute `payout_amount`, bump `version`, update `updatedAt`/`updatedBy`.
  4. After commit: HINCRBY the Redis aggregate (delta on `payout_total` for the day).
- One helper function: `src/lib/payout.ts` → `export function computePayoutAmount(amount, adjustment)`.

## Related

- [[0005-state-machine|ADR 0005]] (State machine — defines the UNPAID → PAID/VOID transitions that lock adjustment)
- [[0006-concurrent-status-updates|ADR 0006]] (Concurrent status updates — `version` and `If-Match`)
- README → Future work → Doctor payout workflow (v2 forward-look, not a v1 design constraint)
- Section 3.5 in the brief
