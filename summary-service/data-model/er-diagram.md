# Data Model — ER Diagram

The new tables in the HMS PostgreSQL database. Existing HMS tables are shown for reference (in lighter style) to illustrate the joins.

```mermaid
erDiagram
    opd_billings ||..|| event_outbox : "writes row in same tx"
    event_outbox }o--|| consultation_fees_invoices : "consumed by worker"
    consultation_fees_invoices ||--o{ consultation_fees_invoice_status_changes : "has audit"
    consultation_fees_invoices ||--o{ consultation_fees_invoice_adjustments : "has audit"
    consultation_fees_invoices }o--|| opd_billings : "originates from"
    consultation_fees_invoices }o--|| patients : "for"
    consultation_fees_invoices }o--|| doctors : "billed by"
    consultation_fees_invoices }o--|| stores : "at counter"
    consultation_fees_invoices }o--|| users : "created_by"
    consultation_fees_invoices }o--|| users : "updated_by"
    opd_billings ||--o{ opd_billing_services : "has lines"
    opd_billing_services }o--|| services : "is a"

    event_outbox {
        uuid id PK
        uuid tenant_id "multi-tenant scope"
        text event_type "e.g. opd_invoice.created"
        uuid aggregate_id "the opd_invoice_id"
        jsonb payload "includes eventId UUID"
        text status "PENDING, IN_PROGRESS, DONE, DEAD"
        int attempt_count "incremented on each claim"
        timestamptz next_attempt_at "polled when now() >= this AND status=PENDING"
        text locked_by "worker hostname + pid"
        timestamptz locked_at "set on claim; reaper resets if > 5min old"
        text last_error "for debugging"
        timestamptz created_at
        timestamptz completed_at "when status -> DONE or DEAD"
    }

    consultation_fees_invoices {
        uuid id PK
        uuid tenant_id "multi-tenant scope"
        uuid event_id "from event_outbox.payload, UNIQUE for idempotency"
        uuid opd_invoice_id "FK to opd_billings"
        uuid patient_id FK
        uuid doctor_id FK
        uuid counter_id FK
        text invoice_no "denormalized from opd_billings"
        text patient_name "denormalized"
        text doctor_name "denormalized"
        text counter_name "denormalized"
        numeric amount "Consultation Fees"
        numeric adjustment "default 0, locked once status != UNPAID"
        numeric payout_amount "= amount - adjustment, frozen at PAID"
        text status "UNPAID, PAID, VOID"
        int version "optimistic locking"
        timestamptz billing_date "denormalized from opd_billings.date"
        timestamptz paid_at "set when status PAID"
        timestamptz voided_at "set when status VOID"
        timestamptz created_at
        timestamptz updated_at
        uuid created_by_id FK
        uuid updated_by_id FK
    }

    consultation_fees_invoice_status_changes {
        uuid id PK
        uuid invoice_id FK
        text from_status "nullable for initial row"
        text to_status "UNPAID, PAID, VOID"
        timestamptz changed_at
        uuid changed_by_id FK
        text reason "optional, max 500 chars"
        int invoice_version_at_change
    }

    consultation_fees_invoice_adjustments {
        uuid id PK
        uuid invoice_id FK
        numeric previous_amount ">= 0"
        numeric new_amount ">= 0"
        text reason "required, 1-500 chars"
        timestamptz changed_at
        uuid changed_by_id FK
        int invoice_version_at_change
    }

    opd_billings {
        uuid id PK
        uuid tenant_id
        text invoice_no "source of denormalized invoice_no"
        timestamptz date "source of denormalized billing_date"
        uuid patient_id FK
        uuid doctor_id FK
        uuid store_id "source of counter_id"
        text opd_billing_payment_status "UNPAID/PAID/CANCEL — independent of CFI"
        timestamptz cancelled_at
        timestamptz created_at
    }

    opd_billing_services {
        uuid id PK
        uuid opd_billing_id FK
        uuid service_id FK
        int amount "summed where is_consultation_service=true"
        bool is_cancel "excluded from fee sum if true"
    }

    services {
        uuid id PK
        text name
        bool is_consultation_service "the filter flag (line 1943 of HMS schema)"
    }

    patients {
        uuid id PK
    }

    doctors {
        uuid id PK
    }

    stores {
        uuid id PK
    }

    users {
        uuid id PK
    }
```

## Key design points

1. **`event_outbox` is the trigger.** The HMS writes a row to `event_outbox` in the **same transaction** as the OPD billing insert. The Summary Service worker polls `event_outbox` with `FOR UPDATE SKIP LOCKED` and creates the CFI (ADR 0001). The outbox is a queue, not a stream: rows are claimed, processed, and transitioned to `DONE` or `DEAD`. Every job is a row — easy to search, easy to debug.

2. **Idempotency via `event_id`.** The CFI row has `event_id UUID UNIQUE NOT NULL`. The worker uses `INSERT ... ON CONFLICT (event_id) DO NOTHING`. A duplicate event (from the reaper resetting a stuck claim) is a no-op.

3. **Business invariant via `(tenant_id, opd_invoice_id)`.** Even if the `event_id` changes (it won't, in this design — the outbox preserves it), the business key prevents two CFIs for the same OPD invoice. This is enforced at the DB level (ADR 0004).

4. **Denormalized display fields.** `invoice_no`, `patient_name`, `doctor_name`, `counter_name`, `billing_date` are denormalized onto the CFI row. The summary list page reads them directly without joins. Drift risk is low (assumption in brief Section 8.2 #1).

5. **Status is a TEXT enum with CHECK.** Simple, no separate enum type. Three values: `UNPAID`, `PAID`, `VOID`. Transitions enforced at the app layer (ADR 0005).

6. **Optimistic locking via `version`.** Every UPDATE bumps the version. The API uses `If-Match` (ADR 0006).

7. **Amounts are `NUMERIC(12, 2)`.** Standard precision for currency. The `payout_amount` has a CHECK constraint enforcing the formula `payout = amount - adjustment` (ADR 0014).

8. **Audit tables are append-only.** `consultation_fees_invoice_status_changes` and `consultation_fees_invoice_adjustments` are never UPDATEd. The current state is on the CFI row; the history is in the audit table. The `invoice_version_at_change` column cross-references the version on the CFI at the time of the change.

9. **FK to `opd_billings` is `(opd_invoice_id) REFERENCES opd_billings(id)`.** Non-composite: the HMS is single-tenant in practice, so `opd_billings.id` is globally unique and the simple FK is enough. (Earlier drafts of the brief described a composite `(tenant_id, opd_invoice_id) → (tenant_id, id)` FK, but `opd_billings` has no `tenant_id` column on the on-prem HMS, so the DDL in `schema.sql:130-131` uses the simple form.)

10. **Search uses `pg_trgm` substring match on `lower(invoice_no)`.** One GIN index with the `gin_trgm_ops` operator class. Doctor name is intentionally NOT substring-searchable (doctor lookup goes through the `doctorId` filter); patient name is intentionally NOT searchable (handled by the HMS's existing patient search). See ADR 0010.

11. **Outbox lifecycle.** Rows flow `PENDING → IN_PROGRESS → DONE` (success) or `PENDING → IN_PROGRESS → DEAD` (5 attempts, non-retryable error). The stale-claim reaper resets `IN_PROGRESS` rows whose `locked_at` is > 5 minutes old back to `PENDING`. The daily pruner deletes `DONE` rows older than 7 days.
