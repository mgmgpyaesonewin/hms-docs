-- =============================================================================
-- Summary Service — Data Model (DDL)
-- =============================================================================
-- New tables for the Consultation Fees Invoice (CFI) lifecycle.
-- Target database: the existing HMS PostgreSQL (on-prem).
-- Prerequisite: the existing HMS schema is in place.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. event_outbox
-- -----------------------------------------------------------------------------
-- Transactional outbox. The HMS writes a row to this table in the SAME
-- transaction as the opd_billings insert. The Summary Service worker polls
-- this table with `FOR UPDATE SKIP LOCKED` and processes the events to
-- completion. See ADR 0001.
--
-- The outbox is at-least-once: a row can be claimed, the worker can crash,
-- and the reaper resets it for retry. The (tenant_id, opd_invoice_id) UNIQUE
-- constraint on consultation_fees_invoices (see below) makes re-processing
-- safe — duplicate CFI inserts are rejected at the DB level.
-- -----------------------------------------------------------------------------

CREATE TABLE event_outbox (
    id                  UUID            PRIMARY KEY DEFAULT uuidv7(),

    -- Tenant scope
    tenant_id           UUID            NOT NULL,

    -- Event identity
    event_type          TEXT            NOT NULL,                -- e.g. 'opd_invoice.created'
    aggregate_id        UUID            NOT NULL,                -- e.g. the opd_invoice_id
    payload             JSONB           NOT NULL,                -- full event body (includes eventId UUID)

    -- Lifecycle
    status              TEXT            NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'IN_PROGRESS', 'DONE', 'DEAD')),
    attempt_count       INTEGER         NOT NULL DEFAULT 0,
    next_attempt_at     TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- Claim metadata
    locked_by           TEXT,                                    -- worker hostname + pid
    locked_at           TIMESTAMPTZ,

    -- Debugging
    last_error          TEXT,

    -- Timestamps
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ                              -- when status -> DONE or DEAD
);

-- Hot-path partial index: the worker's poll query is `WHERE status='PENDING'`
CREATE INDEX idx_outbox_pending ON event_outbox (next_attempt_at) WHERE status = 'PENDING';

-- Operator-friendly indexes for "find events for tenant X", "find stuck jobs", etc.
CREATE INDEX idx_outbox_tenant_created ON event_outbox (tenant_id, created_at DESC);
CREATE INDEX idx_outbox_status         ON event_outbox (status);
CREATE INDEX idx_outbox_aggregate      ON event_outbox (aggregate_id);


-- -----------------------------------------------------------------------------
-- 1. consultation_fees_invoices
-- -----------------------------------------------------------------------------
-- One row per OPD invoice's consultation-fee invoice.
-- Created by the Summary Service worker when it processes an
-- 'opd_invoice.created' event from the event_outbox (see ADR 0001).
-- Updated by the API on status / adjustment changes.
-- -----------------------------------------------------------------------------

CREATE TABLE consultation_fees_invoices (
    id                              UUID            PRIMARY KEY DEFAULT uuidv7(),

    -- Tenant scope (multi-tenant by design; on-prem is single-tenant in practice)
    tenant_id                       UUID            NOT NULL,

    -- Idempotency
    event_id                        UUID            NOT NULL,   -- from event_outbox.payload.eventId

    -- Link to the source OPD billing
    opd_invoice_id                  UUID            NOT NULL,

    -- Foreign keys (for joins; denormalized display fields also stored below for fast list reads)
    patient_id                      UUID            NOT NULL,
    doctor_id                       UUID            NOT NULL,
    counter_id                      UUID            NOT NULL,

    -- Denormalized display fields (snapshot at CFI creation; see brief Section 3.1)
    -- invoice_no is the parent (OPD/IPD) patient-direct invoice number.
    -- The CFI itself has no separate invoice number; it is a derived tracking
    -- record identified by the parent's invoice number + tenant. v1: always OPD.
    -- v2+: IPD support requires generalising the parent FK (opd_invoice_id ->
    -- parent_invoice_id + parent_invoice_type); invoice_no is already generic.
    invoice_no                      TEXT            NOT NULL,
    patient_name                    TEXT            NOT NULL,
    doctor_name                     TEXT            NOT NULL,
    counter_name                    TEXT            NOT NULL,

    -- Amounts (in the hospital's local currency; smallest unit is the integer part of NUMERIC(12,2))
    amount                          NUMERIC(12, 2)  NOT NULL CHECK (amount >= 0),
    adjustment                      NUMERIC(12, 2)  NOT NULL DEFAULT 0 CHECK (adjustment >= 0),
    payout_amount                   NUMERIC(12, 2)  NOT NULL
        CHECK (payout_amount = amount - adjustment)
        CHECK (payout_amount >= 0)
        CHECK (adjustment <= amount),

    -- Status lifecycle (UNPAID → PAID, UNPAID → VOID; see ADR 0005)
    status                          TEXT            NOT NULL DEFAULT 'UNPAID'
        CHECK (status IN ('UNPAID', 'PAID', 'VOID')),

    -- Optimistic locking
    version                         INTEGER         NOT NULL DEFAULT 1,

    -- Dates
    billing_date                    TIMESTAMPTZ     NOT NULL,    -- denormalized from opd_billing.date
    paid_at                         TIMESTAMPTZ,                 -- set when status → PAID
    voided_at                       TIMESTAMPTZ,                 -- set when status → VOID

    -- Audit
    created_at                      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at                      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    created_by_id                   UUID            NOT NULL,
    updated_by_id                   UUID            NOT NULL,

    -- Constraints
    CONSTRAINT uq_cfi_event_id                  UNIQUE (event_id),
    CONSTRAINT uq_cfi_tenant_opd_invoice        UNIQUE (tenant_id, opd_invoice_id),

    -- Foreign keys (point to existing HMS tables)
    CONSTRAINT fk_cfi_opd_invoice  FOREIGN KEY (opd_invoice_id)
        REFERENCES opd_billings (id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_cfi_patient      FOREIGN KEY (patient_id)  REFERENCES patients (id)  ON DELETE RESTRICT,
    CONSTRAINT fk_cfi_doctor       FOREIGN KEY (doctor_id)   REFERENCES doctors (id)   ON DELETE RESTRICT,
    CONSTRAINT fk_cfi_counter      FOREIGN KEY (counter_id)  REFERENCES stores (id)    ON DELETE RESTRICT,
    CONSTRAINT fk_cfi_created_by   FOREIGN KEY (created_by_id) REFERENCES users (id)   ON DELETE RESTRICT,
    CONSTRAINT fk_cfi_updated_by   FOREIGN KEY (updated_by_id) REFERENCES users (id)   ON DELETE RESTRICT
);

-- Indexes for the summary list page (filter + sort)
CREATE INDEX idx_cfi_tenant_billing_date  ON consultation_fees_invoices (tenant_id, billing_date DESC);
CREATE INDEX idx_cfi_tenant_counter_date  ON consultation_fees_invoices (tenant_id, counter_id, billing_date DESC);
CREATE INDEX idx_cfi_tenant_doctor_date   ON consultation_fees_invoices (tenant_id, doctor_id, billing_date DESC);
CREATE INDEX idx_cfi_tenant_status        ON consultation_fees_invoices (tenant_id, status);
CREATE INDEX idx_cfi_tenant_paid_at       ON consultation_fees_invoices (tenant_id, paid_at DESC) WHERE paid_at IS NOT NULL;

-- Search index (pg_trgm substring match on invoice_no; see ADR 0010)
-- Doctor name and patient name are intentionally NOT searchable.
-- Doctor lookup is via the doctorId filter (see idx_cfi_tenant_doctor_date);
-- patient lookup is the HMS's existing patient search.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX idx_cfi_invoice_no_trgm
    ON consultation_fees_invoices USING GIN (lower(invoice_no) gin_trgm_ops);


-- -----------------------------------------------------------------------------
-- 2. consultation_fees_invoice_status_changes
-- -----------------------------------------------------------------------------
-- Immutable audit of every status transition. One row per change.
-- Source of truth for "who changed what when" on the CFI's status field.
-- -----------------------------------------------------------------------------

CREATE TABLE consultation_fees_invoice_status_changes (
    id                              UUID            PRIMARY KEY DEFAULT uuidv7(),
    invoice_id                      UUID            NOT NULL,
    from_status                     TEXT,                          -- NULL for the initial row
    to_status                       TEXT            NOT NULL CHECK (to_status IN ('UNPAID', 'PAID', 'VOID')),
    changed_at                      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    changed_by_id                   UUID            NOT NULL,
    reason                          TEXT,                          -- optional, max 500 chars enforced at app layer
    invoice_version_at_change       INTEGER         NOT NULL,    -- the version of the CFI after the change

    CONSTRAINT fk_sc_invoice     FOREIGN KEY (invoice_id)    REFERENCES consultation_fees_invoices (id) ON DELETE CASCADE,
    CONSTRAINT fk_sc_changed_by  FOREIGN KEY (changed_by_id) REFERENCES users (id) ON DELETE RESTRICT
);

CREATE INDEX idx_sc_invoice_changed_at ON consultation_fees_invoice_status_changes (invoice_id, changed_at DESC);


-- -----------------------------------------------------------------------------
-- 3. consultation_fees_invoice_adjustments
-- -----------------------------------------------------------------------------
-- Immutable audit of every adjustment change. One row per change.
-- The latest row's `new_amount` is the current adjustment value (also stored on
-- consultation_fees_invoices.adjustment for fast reads).
-- -----------------------------------------------------------------------------

CREATE TABLE consultation_fees_invoice_adjustments (
    id                              UUID            PRIMARY KEY DEFAULT uuidv7(),
    invoice_id                      UUID            NOT NULL,
    previous_amount                 NUMERIC(12, 2)  NOT NULL CHECK (previous_amount >= 0),
    new_amount                      NUMERIC(12, 2)  NOT NULL CHECK (new_amount >= 0),
    reason                          TEXT            NOT NULL CHECK (length(reason) BETWEEN 1 AND 500),
    changed_at                      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    changed_by_id                   UUID            NOT NULL,
    invoice_version_at_change       INTEGER         NOT NULL,    -- the version of the CFI after the change

    CONSTRAINT fk_adj_invoice     FOREIGN KEY (invoice_id)    REFERENCES consultation_fees_invoices (id) ON DELETE CASCADE,
    CONSTRAINT fk_adj_changed_by  FOREIGN KEY (changed_by_id) REFERENCES users (id) ON DELETE RESTRICT
);

CREATE INDEX idx_adj_invoice_changed_at ON consultation_fees_invoice_adjustments (invoice_id, changed_at DESC);


-- -----------------------------------------------------------------------------
-- Notes on HMS tables (existing, no changes)
-- -----------------------------------------------------------------------------
-- The Summary Service READS from these HMS tables to compute the consultation
-- fee at CFI creation time. The HMS does not change its schema (except for the
-- new event_outbox table — see section 0).
--
--   opd_billings
--     - Used for: tenant_id, id (as opd_invoice_id), date (as billing_date),
--                 doctor_id, store_id (as counter_id), patient_id, invoice_no,
--                 created_at, cancelled_at.
--     - The Summary Service's worker queries this to compute the consultation fee.
--
--   opd_billing_services (joined to services to filter on is_consultation_service)
--     - Used for: computing the consultation fee at CFI creation.
--     - The fee is the SUM(amount) where is_cancel=false AND services.is_consultation_service=true.
--
--   services
--     - Used for: the is_consultation_service boolean (line 1943 of the HMS schema).
--
--   patients, doctors, stores, users
--     - Used for: foreign key targets and (in the worker's denormalization) display names.
--
-- HMS code change required:
--   - At the OPD billing insertion site, INSIDE the existing transaction,
--     also insert a row into event_outbox. See ADR 0001 for the exact change.
--   - The HMS adds the `EventOutbox` model to its Prisma schema; the model
--     definition is in `prisma-additions.prisma`.
--   - No new HMS columns on existing tables. Only one new HMS table (event_outbox).
-- -----------------------------------------------------------------------------
