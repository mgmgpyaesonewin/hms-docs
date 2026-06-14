# Summary Service — Architecture Design Brief (v2)

> **Purpose of this document:** This is a design brief / prompt intended for a senior architect (human or AI) to produce a complete architecture design for a new **Summary Service** that augments the YCare HMS Next.js monolith.
>
> **v1 of this brief (deprecated) described a CSV export reporting service on AWS EKS. The scope has changed: the hospital is deploying on-prem, the new service is a *summary* service (not an export service), and the headline feature is a `Consultation Fees Invoice` lifecycle with admin status management.**
>
> **Read this whole brief before designing.** Sections 5–8 define hard constraints and open questions that the design must resolve or explicitly call out as assumptions.

---

## 0. Revision History

| Version | Date | Notes |
|---|---|---|
| v1 | 2026-06-11 | Reporting service, AWS EKS, S3, CSV exports — **deprecated, kept in git history only** |
| v2 | 2026-06-11 | **Summary service, on-prem deployment, Redis-cached aggregates, Consultation Fees Invoice lifecycle with admin status updates** |

---

## 1. Background & Context

YCare HMS is a multi-tenant hospital management system. The current codebase is a Next.js 15 (App Router) monolith with:

- TypeScript, Mantine UI, Tailwind, tRPC, React Query, Zod
- Prisma ORM against **PostgreSQL**
- Custom session-based auth (Argon2, cookie `sid`)
- Background jobs via **pg-boss** in-process
- AWS S3 for file storage (`ycare-hms.s3.ap-south-1.amazonaws.com`)
- Multi-tenant — every domain table carries a `tenantId`

**Deployment target change.** The hospital is moving to an **on-prem local server installed in the building** for this service (and potentially the broader HMS over time). The on-prem server has:

- Linux (Ubuntu LTS, version TBD by hospital IT)
- Local **PostgreSQL** (the same DB instance the HMS uses — they share the database)
- **Redis** (new, to be installed as part of this work)
- No internet connectivity assumed (local network only)
- systemd for service supervision
- Single tenant of the hospital in this on-prem install — but the HMS schema is multi-tenant by design, so `tenantId` discipline is preserved

**The problem.** Three pain points today:

1. **OPD total-cost summary is expensive to compute on every page load.** The admin dashboard hits the HMS directly and runs aggregate queries (`SUM`, `GROUP BY date`, `GROUP BY counter`) over the `opd_invoices` table and its joins. As invoice volume grows, this is slow.
2. **Consultation fees are not modelled as their own first-class invoice.** They live as line items inside OPD invoices. The admin needs to track which consultation fees are **paid** vs **unpaid** vs **void** — but there is no place to record that status separately from the parent OPD invoice. When a patient pays their consultation fee, there is no clean event to record.
3. **The dashboard summary needs filtering** by date, by counter/store, by doctor, and by restricted search on the OPD/IPD invoice number. None of these are fast or well-indexed in the current schema.

**The goal of this engagement.** Build a new **Express.js Summary Service** that:

- Auto-creates a `Consultation Fees Invoice` record (`UNPAID`) whenever an OPD invoice is generated.
- Lets the admin **view a summary** of consultation fees with date / counter / doctor / status / search (invoice no) filters.
- Lets the admin **update the status** of a consultation fees invoice (`UNPAID` → `PAID` or `UNPAID` → `VOID`).
- Caches aggregate counters in **Redis** for fast dashboard rendering.
- Is architected to be extended in v2+ to cover additional summary types (e.g. OPD total cost by counter, by doctor, by department).

---

## 2. Goals & Non-Goals

### Goals
1. **Auto-create consultation fees invoices** from OPD invoice creation, with strong consistency (no lost or duplicated creations).
2. **Admin summary view** of consultation fees — filterable by date range, counter/store, doctor, status, and restricted search on the invoice no; results paginated.
3. **Status updates** — admin can mark consultation fees invoices as `PAID` or `VOID`, with full audit history of who changed what when.
4. **Fast dashboard load** — aggregate counters (totals, counts by status) served from Redis; no `GROUP BY` on every page load.
5. **On-prem deployable** — runs as a systemd service on the hospital server, no cloud dependencies.
6. **Multi-tenant safe** — every query and Redis key scoped by `tenantId`, even though the on-prem install is single-tenant in practice.
7. **Operational simplicity** — minimal new infra, standard runbook, restorable from backup.

### Non-Goals
- **No new OPD billing logic.** The Summary Service does not own OPD invoice creation, payment collection, or receipt generation. It consumes existing OPD invoice data.
- **No patient-facing UI.** Admin-only.
- **No new multi-tenant onboarding flows.** `tenantId` discipline is preserved but new tenant setup is out of scope.
- **No real-time push to admin UIs.** Dashboards refresh on user action (or short polling); no WebSocket / SSE in v1.
- **No reporting or CSV export.** That is a separate v1 brief (deprecated). The Summary Service does not generate downloadable artifacts in v1.
- **No new reporting / BI warehouse.** Operational summaries only.
- **No migration of existing pg-boss jobs.** HMS pg-boss usage stays as-is.

---

## 3. Functional Requirements

### 3.1 Trigger: OPD invoice created → Consultation Fees Invoice created

**Source event:** A new `opd_invoices` row is created in the HMS. (IPD invoices are out of scope for v1 — see "IPD support" note at the end of this section.)

**Required behaviour:** A corresponding `consultation_fees_invoices` row is created with:

- `tenantId` copied from the OPD invoice
- `opdInvoiceId` linking back to the source
- `patientId`, `doctorId`, `counterId` (and denormalized display fields for fast summary rendering; `invoice_no` is the search target)
- `invoice_no` — **the parent's patient-direct invoice number, denormalized** (OPD or IPD). The CFI itself has no separate invoice number — it is a derived tracking record identified by the parent's invoice number + tenant. See "Invoice No terminology" below.
- `amount` = the **consultation-fee component** of the OPD invoice (see below)
- `status` = `UNPAID`
- `createdAt`, `createdBy` from the originating user

**Invoice No terminology.** The `consultation_fees_invoices.invoice_no` field is the **patient-direct invoice number** of the parent — the OPD or IPD invoice number printed on the bill the patient sees and pays. The CFI itself has no separate invoice number — it is a derived tracking record identified by the parent's invoice number + tenant. The admin's "Invoice No" search field searches against this denormalized value, so typing the patient-facing OPD or IPD invoice number finds the CFI(s) generated from that invoice. In v1, only OPD invoices create CFIs, so IPD invoice numbers do not appear in the search results yet — the field is forward-compatible.

**IPD support (v2+).** The CFI's `opd_invoice_id` FK is OPD-specific. If/when IPD invoices start creating CFIs in v2, the FK will need to be generalized (rename to `parent_invoice_id` plus a `parent_invoice_type` enum) and the denormalized `invoice_no` will hold the parent IPD invoice number. The current design does not block this:
- The `invoice_no` column is already a free-form string and the search semantics already cover "OPD or IPD invoice number".
- The `pg_trgm` GIN index on `lower(invoice_no)` already matches IPD numbers — no index rebuild needed.
- The worker's "denormalize from parent" step just changes the parent table it reads from.

The cost of v2+ IPD support is one schema change (the FK rename + new type column) and a worker change (read from `ipd_billings` instead of `opd_billings`).

**Consultation fee source (confirmed by reading `prisma/schema.prisma`):**

There is no single `opd_billings.consultation_fee` column. The OPD billing is structured as:

- `OPDBilling` (line 1442) — the OPD invoice header. Has `totalAmount` (the whole bill), `opdBillingPaymentStatus` (`UNPAID` / `PAID` / `CANCEL`), `doctorId`, `storeId`, `patientId`, `invoiceNo`, etc.
- `OPDBillingService` (line 1585) — line items on the OPD billing. Has `serviceId`, `price`, `amount`, `qty`, `isCancel`, etc.
- `Service` (line 1931) — the catalog. Has `isConsultationService: Boolean` (line 1943).

The consultation fee on an OPD billing is therefore:

```sql
SELECT COALESCE(SUM(obs.amount), 0)
FROM opd_billing_services obs
JOIN services s ON s.id = obs.service_id
WHERE obs.opd_billing_id = :id
  AND obs.is_cancel = false
  AND s.is_consultation_service = true;
```

The worker must compute this when the CFI is created, and **denormalize the resulting `amount` onto the `consultation_fees_invoices` row** at insert time. Subsequent changes to `OPDBillingService.isCancel` or `Service.isConsultationService` do NOT retroactively update the CFI in v1 — the CFI is a snapshot of the consultation fee at the moment the OPD billing was generated. (Drift risk: if a consultation line is later cancelled in HMS, the CFI shows the original amount. Acceptable for v1; out of scope to fix.)

**Important relationship to existing `OPDBilling.opdBillingPaymentStatus`:**

The OPD billing already tracks its own payment status (`UNPAID` / `PAID` / `CANCEL`). The new CFI is a **separate, focused tracking concept** for admin reporting — not a replacement for the OPD billing's payment status. The two are independent:

- An OPD billing can be `PAID` while a CFI is still `UNPAID` (the patient paid for other items but not the consultation).
- A CFI can be `PAID` while the OPD billing is `UNPAID` (consultation paid separately, OPD balance outstanding).
- `VOID` on the CFI is admin-side cancellation only; it does not flow back to the OPD billing.

This is the intentional design: the CFI gives the admin a clear "are our consultation fees being collected?" view, decoupled from the OPD billing's broader payment flow.

**Delivery guarantee:** At-least-once. The system must not silently drop an OPD invoice (i.e. fail to create a consultation fees invoice) and must not double-create from a single OPD invoice (idempotency required).

**Failure isolation:** If the Summary Service is down or the trigger fails, the OPD invoice creation in HMS **must still succeed**. Summary creation is a side-effect, not a precondition. The catch-up mechanism must be safe to run after an extended outage.

### 3.2 Consultation Fees Invoice status lifecycle

States and allowed transitions:

```
            ┌─────────┐
   create   │ UNPAID  │
  ─────────▶│         │──── Mark as Paid ───▶ ┌─────┐
            │         │                       │PAID │
            │         │                       └─────┘
            │         │
            │         │──── Mark as Void ───▶ ┌──────┐
            └─────────┘                       │ VOID │
                                              └──────┘
```

- **Allowed transitions:** `UNPAID → PAID`, `UNPAID → VOID`. **No transition from `PAID` or `VOID`.** Once an invoice is paid or voided, it is terminal. A correction is a separate adjustment flow (out of scope for v1).
- **Required fields on transition:** `updatedBy` (admin user id), `changedAt` (timestamp), `reason` (optional free text, required for `VOID`).
- **Audit row:** every transition writes a row to `consultation_fees_invoice_status_changes` (immutable).

### 3.3 Admin summary view

The admin opens a "Consultation Fee Report" page in the HMS admin UI. The page shows:

**A. Aggregate counters (top of page, fast):**
- Total count of consultation fees invoices in the current filter
- Total Consultation Fees (sum of `amount`)
- Total Adjustment (sum of `adjustment`)
- Total Payout Amount (sum of `payout_amount`)
- By status: `UNPAID` count + Consultation Fees + Payout Amount, `PAID` count + Consultation Fees + Payout Amount, `VOID` count + Consultation Fees + Payout Amount
- Source: Redis for the cached dimensions (date × counter), Postgres for the live filter; served in <100ms

**B. Filterable invoice list (main body):**

Columns (in display order, left to right):

| # | Column | Source field | Notes |
|---|---|---|---|
| 1 | **Billing Date** | `consultation_fees_invoices.billing_date` | The date on the parent OPD invoice (denormalized at CFI creation). |
| 2 | **Payment Date** | `consultation_fees_invoices.paid_at` | `NULL` until the CFI transitions to `PAID`. |
| 3 | **Doctor Name** | `consultation_fees_invoices.doctor_name` (denormalized) | Display name; "Dr. " prefix in UI. |
| 4 | **Invoice No** | `consultation_fees_invoices.invoice_no` (denormalized from the parent OPD/IPD invoice) | The **patient-direct invoice number** of the parent (OPD or IPD). The CFI itself has no separate invoice number. Click → opens the parent invoice in the HMS. |
| 5 | **Consultation Fees** | `consultation_fees_invoices.amount` | Gross, in the hospital's local currency. |
| 6 | **Adjustment** | `consultation_fees_invoices.adjustment` | Admin-editable; `0` by default. See Section 3.5. |
| 7 | **Payout Amount** | `consultation_fees_invoices.payout_amount` | Net: `amount - adjustment` (or per the chosen payout formula — see Section 7.14). |
| 8 | **Status** | `consultation_fees_invoices.status` | `UNPAID` / `PAID` / `VOID`, rendered as a Mantine `Badge`. |

Filters:
- Date range on `billing_date` (default: current month)
- Counter/store
- Doctor
- Status (multi-select: `UNPAID` / `PAID` / `VOID`)
- Date range on `paid_at` (for the "paid this week" report)
- Search (case-insensitive substring match on **OPD/IPD invoice number** only — doctor name and patient name are not searchable)

Sort options: `billing_date` desc (default), `paid_at` desc, `payout_amount` desc, `amount` desc.

Pagination: cursor-based, default 25 per page. Source: Postgres with proper indexes for the filter and sort columns. Default ordering: most recent first.

**C. Per-invoice actions (drawer / right panel):**
- Click row → drawer with full invoice detail
- Sections: source OPD invoice link, Consultation Fees / Adjustment / Payout Amount breakdown, status, status history, adjustment history
- Action buttons (visible only if `status = UNPAID`): "Mark as Paid", "Mark as Void", "Add Adjustment"
- Action button (visible always for admins): "Edit Adjustment" (with reason required)
- Action buttons (out of scope for v1): "Send to Payroll", "Export Payout Report"

### 3.4 Status update flow

Admin clicks "Mark as Paid" / "Mark as Void" in the UI:

1. UI calls HMS BFF (`POST /api/consultation-fees-invoices/{id}/status`).
2. HMS BFF validates the admin's permission, then calls the Summary Service (`POST /consultation-fees-invoices/{id}/status` with `{ status, reason? }`).
3. Summary Service:
   - Loads the invoice row, checks current status is `UNPAID`, checks the transition is allowed.
   - In one DB transaction: updates the row's `status`, `updatedAt`, `updatedBy`, and `paid_at` / `voided_at` (set `paid_at = now()` if `status = PAID`); inserts the audit row.
   - On commit: updates Redis aggregate counters (decrement old status, increment new status). `Payment Date` is the value of `paid_at` that was just written.
   - Returns the updated invoice.
4. BFF returns to UI; UI refreshes the summary.

If Redis update fails: log a warning; the next read of that bucket (via cache-aside) misses, recomputes from Postgres, and overwrites. The user sees correct data on the next page load. No reconciliation job.

### 3.5 Adjustment update flow

An adjustment modifies the `adjustment` field on a CFI, which in turn changes the `payout_amount` (per the formula in Section 7.14). Allowed in any status, not just `UNPAID`. Each change is audited.

1. Admin opens the invoice drawer and clicks "Add Adjustment" or "Edit Adjustment".
2. UI prompts for: `amount` (non-negative number; see 7.13 for sign semantics), `reason` (required free text).
3. UI calls HMS BFF (`POST /api/consultation-fees-invoices/{id}/adjustment`).
4. BFF forwards to Summary Service: `POST /consultation-fees-invoices/{id}/adjustment` with `{ amount, reason }`.
5. Summary Service:
   - Loads the invoice row, checks the optimistic-lock version matches what the UI sent.
   - In one DB transaction:
     - Updates `adjustment = <new amount>`.
     - Recomputes `payout_amount` per the formula.
     - Bumps `version`.
     - Updates `updatedAt`, `updatedBy`.
     - Inserts an audit row into `consultation_fees_invoice_adjustments` (new table — see Section 7.13).
   - On commit: updates Redis aggregates **if** the dashboard counters include adjustment/payout totals (otherwise skip — they're not status-scoped, so they may be recomputed at read time instead).
   - Returns the updated invoice.
6. UI refreshes.

**Important: the `payout_amount` field is a stored column, not a virtual column.** The recompute happens on:
- CFI creation (insert)
- Any adjustment change (update)

The DB-level `CHECK (payout_amount = amount - adjustment)` constraint (Section 7.14) is the safety net: if manual SQL ever drifts from the formula, the constraint fails and surfaces the bug. There is no separate job to "re-recompute" payout_amount — manual SQL fixes are caught by the constraint, not by a sweep.

This avoids re-running the formula on every read and keeps the displayed value consistent with the stored value.

### 3.6 Search

- Search is **not free text**. The search box matches against exactly one column: `consultation_fees_invoices.invoice_no`. Doctor name and patient name are **not searchable** (doctor lookup goes through the `doctorId` filter; patient lookup is the HMS's existing patient search — see rationale in ADR 0010).
- The `invoice_no` column on the CFI is the **patient-direct invoice number** of the parent — the OPD **or** IPD invoice number printed on the bill the patient sees and pays. The CFI itself has no separate invoice of its own; the search finds the CFI by the parent's invoice number. The search is therefore defined as: "OPD or IPD invoice number".
  - **v1 caveat:** only OPD invoices create CFIs. Searching an IPD invoice number returns zero results in v1 because no CFI exists with that parent. The search semantics are forward-compatible: when IPD support is added in v2+, the same `invoice_no` column carries the IPD invoice number and the same `pg_trgm` GIN index matches it.
- Semantics: case-insensitive substring match. Typing `"0042"` matches any invoice number containing `"0042"`, e.g. `"INV-2026-0042-JOHNSMITH"`.
- Backed by a `pg_trgm` GIN index on `lower(invoice_no)`. Standard Postgres extension, no new infrastructure.
- Result is ordered by `billing_date DESC`, not by relevance. A single-field substring match has no meaningful relevance ranking; admins expect to find the row they searched for, not a ranked list.

### 3.7 Notification

- In v1: **no notifications** on status change beyond the in-page UI refresh.
- Future (out of scope for v1): an in-app notification row in the existing HMS `notifications` table on `PAID` / `VOID`, viewable in the admin's notification center.

---

## 4. Non-Functional Requirements

| Category | Requirement |
|---|---|
| **Availability** | Service downtime may delay consultation-fees-invoice creation and admin status updates, but **must not** block OPD invoice creation in the HMS. |
| **Durability** | Every state transition survives service / DB / Redis crash. Postgres is the source of truth. Redis is a cache that can be rebuilt. |
| **Latency** | Summary list page p95 < 800ms; aggregate counters p95 < 100ms (Redis hit). Status update p95 < 500ms. |
| **Throughput** | Initial target: 1k OPD invoices / day, 50 concurrent admin users. Must scale 10x without redesign. |
| **Multi-tenancy** | Every query, every Redis key, every log line scoped by `tenantId`. Defense-in-depth. |
| **Security** | Service binds to localhost only. Service-to-service auth: shared HMAC secret (file-based) for v1. No public exposure. |
| **Observability** | Structured JSON logs to a local file (`/var/log/ycare-summary/*.log`) with rotation. Prometheus-format metrics on `/metrics` (optional). Audit log table for every state transition. |
| **Compliance** | Audit history of status changes retained indefinitely (or per hospital policy). |
| **Backup** | Postgres is backed up via the existing hospital backup policy. Redis state is recoverable from Postgres lazily, on the first read of each affected bucket (cache-aside). |
| **Cost** | Zero recurring cloud cost. On-prem hardware cost is fixed and out of scope. |

---

## 5. Constraints & Assumptions

### Hard constraints
- **On-prem deployment** — the service runs on a Linux server inside the hospital building. No AWS, no EKS, no ALB, no SQS, no SNS, no Secrets Manager.
- **Express.js + TypeScript** for the service runtime (matches HMS conventions).
- **PostgreSQL** is the existing HMS DB. The Summary Service reads from and writes to **the same DB**. (New tables; no new DB instance.)
- **Redis** is new — to be installed on the hospital server alongside Postgres. Standard `redis-server` 7.x, local socket or `127.0.0.1:6379`, no auth (localhost-only) or password set in `/etc/redis/redis.conf`.
- **systemd** supervises the service. Two units: `ycare-summary-api.service` and `ycare-summary-worker.service` (one binary, two modes), restarted on failure.
- **Trigger source:** HMS writes an `event_outbox` row in the **same transaction** as the OPD invoice insert. The Summary Service's worker polls the outbox.
- **Call surface:** Only the HMS Next.js BFF calls the Summary Service. The service binds to `127.0.0.1` only.
- **Tenant model:** Shared schema, `tenantId` column on every new table (matches HMS).
- **Multi-tenant data isolation:** Even though the on-prem install is single-tenant in practice, every query in the Summary Service filters by `tenantId`. (Future-proofs against multi-hospital installations.)

### Assumptions to validate (each must be answered or marked as an explicit assumption in the design)
- **The Summary Service is the sole writer of `consultation_fees_invoices` and `consultation_fees_invoice_status_changes`.** The HMS reads but does not write.
- **The "consultation fee amount" on the OPD invoice is computed** as the sum of `OPDBillingService` line items where `isCancel = false` and the joined `Service.isConsultationService = true`. (Confirmed against `prisma/schema.prisma` lines 1585, 1931, 1943.) The amount is denormalized onto `consultation_fees_invoices.amount` at CFI creation time; later mutations to those source fields do not retroactively update the CFI in v1.
- **Denormalized display fields** (patient name, doctor name, counter name, invoice number) on `consultation_fees_invoices` are acceptable. They avoid a join on every summary row read. (Alternative: keep normalized and join — slower, but no denormalization drift to manage.)
- **No need for soft-delete in v1.** `VOID` is the soft-delete equivalent.
- **The hospital backup policy already covers the HMS Postgres**; the new tables are covered automatically.
- **Time zone:** The hospital's local time. Stored in Postgres as `TIMESTAMPTZ`; rendered in hospital local time in the UI.
- **The HMS already has an admin role / permission for "manage consultation fees"** — or the designer must add one. (Reuse existing RBAC if present.)

---

## 6. Proposed Architecture (high level — to be refined)

The design must produce a concrete version of the following sketch, with every box and arrow justified.

```
                       ON-PREM HOSPITAL SERVER
                       ─────────────────────────
                                                      
   ┌────────────────────┐                             
   │  Next.js (HMS)     │                             
   │  - Admin UI        │                             
   │  - OPD invoice UI  │                             
   │  - BFF (tRPC)      │                             
   └──┬──────────────┬──┘                             
      │ writes       │ reads / status updates        
      │ (txn)        │                               
      ▼              │                               
   ┌─────────────────▼────────────────────────────────┐
   │            PostgreSQL  (shared DB)               │
   │  ┌──────────────────┐  ┌───────────────────────┐  │
   │  │ opd_invoices     │  │ event_outbox          │  │
   │  │ (existing)       │  │ (new — outbox)        │  │
   │  └──────────────────┘  └───────────────────────┘  │
   │  ┌──────────────────────────────────────────────┐ │
   │  │ consultation_fees_invoices (new)             │ │
   │  │ consultation_fees_invoice_status_changes (n) │ │
   │  │ consultation_fees_invoice_adjustments  (n)   │ │
   │  └──────────────────────────────────────────────┘ │
   └────▲────────────────────▲────────────────────────┘
        │ poll (FOR UPDATE   │ read / write            
        │  SKIP LOCKED)      │                        
   ┌────┴────────────────────┴────────────────────────┐
   │        Summary Service (Express + TypeScript)    │
   │   ┌──────────────────┐   ┌────────────────────┐  │
   │   │ inbox-worker     │   │ api (HTTP)         │  │
   │   │ (systemd)        │   │ (systemd)          │  │
   │   │                  │   │                    │  │
   │   │ polls outbox,    │   │ GET  /summary/...  │  │
   │   │ creates CFI row, │   │ POST /.../status   │  │
   │   │ updates Redis    │   │ reads Redis + DB   │  │
   │   └────────┬─────────┘   └─────────┬──────────┘  │
   └────────────┼───────────────────────┼─────────────┘
                │ HINCRBY                │ HGET
                ▼                        ▲
        ┌───────────────────────────┐    │
        │  Redis (127.0.0.1:6379)   │────┘
        │  aggregate counters only  │
        │  (not on the publish path)│
        └───────────────────────────┘
```

**Deployment on a single host:**

| Process | systemd unit | Port | Purpose |
|---|---|---|---|
| Next.js (HMS) | (existing) | 3000 | User-facing app + BFF |
| Summary Service — API | `ycare-summary-api.service` | 4000 (127.0.0.1 only) | Read + status-update HTTP API |
| Summary Service — Worker | `ycare-summary-worker.service` | n/a | Polls outbox, processes events |
| PostgreSQL | (existing) | 5432 | Shared DB |
| Redis | `redis-server.service` | 6379 (127.0.0.1 only) | Aggregate cache |

The HMS BFF makes HTTP calls to `http://127.0.0.1:4000`. Network-level isolation ensures no other process on the host or on the LAN can reach the Summary Service.

---

## 7. Key Design Decisions Required

Each subsection below is a decision the designer must make and document. Use the Decision Workflows from the senior-architect skill (Monolith vs Microservices, Database Selection, Architecture Pattern Selection) where applicable.

### 7.1 Trigger mechanism: Postgres transactional outbox

The HMS must reliably emit an "OPD invoice created" event to the Summary Service. The user has chosen the **Postgres transactional outbox** pattern because it is easier to search and debug jobs (every job is a row, queryable with SQL).

The design must:

- Add a new `event_outbox` table to the HMS Postgres (one row per event).
- Have the HMS insert an `event_outbox` row in the **same transaction** as the OPD billing insert. The two rows commit atomically — there is no window where one exists without the other.
- Have the Summary Service worker poll the outbox with `SELECT ... FOR UPDATE SKIP LOCKED LIMIT N`, claim a batch, process each event in its own transaction, and mark the outbox row as `DONE` (or `DEAD` after 5 attempts).
- Run a **stale-claim reaper** every 5 minutes: any `IN_PROGRESS` row whose `locked_at` is older than 5 minutes is reset to `PENDING` and re-claimed on the next poll. This handles worker crashes mid-event.
- Prune `DONE` rows after 7 days via a daily job.

**Eventual consistency window:** 1 second (the poll interval, configurable). The outbox is not strictly transactional-from-CPU-cache, but it is durable: the event either committed with the OPD billing or it didn't.

**Why not Redis Streams?** Considered previously; rejected because the `XADD` is a separate step from the DB commit, requiring a reconciliation job to catch the crash window. Outbox eliminates the crash window. The user also preferred being able to `SELECT * FROM event_outbox WHERE status='DEAD'` from psql.

**Why not pg-boss?** Considered; rejected because pg-boss would require the Summary Service to run a second job-runtime pointed at the same DB and adds a heavier footprint for what is a single-event-type use case.

**Justify** against the durability and failure-isolation requirements in Section 4. The outbox is at-least-once delivery; idempotency at the consumer (via the CFI's `event_id` UNIQUE and `(tenant_id, opd_invoice_id)` UNIQUE) collapses re-processing into a no-op.

**Future evolution to pub/sub.** The outbox is the foundation, not the ceiling. Pub/sub (Redis Streams, Kafka, etc.) is added **only when a second consumer with different latency or replay needs lands** — typical candidates: the doctor payout workflow (v2+), a real-time admin notification feed, an audit-log forwarder. The upgrade path is staged: `outbox` → `outbox + LISTEN/NOTIFY` → `outbox + Debezium CDC → streaming platform`. Adding pub/sub on top of the outbox is cheap; removing a pub/sub layer that turned out to be premature is expensive. See ADR 0001 § "Future evolution: when to add pub/sub" for the full reasoning.

### 7.2 Service decomposition

One Express process with two roles (API + inbox worker) running as two systemd units, or two separate services (Node packages)?

- **Recommended:** one codebase, two systemd units — one process per role, started with `--mode=api` or `--mode=worker`. Code sharing, single dependency tree, ops can restart independently.

### 7.3 Idempotency

- The outbox event carries a unique `event_id` (UUID generated by HMS at write time).
- `consultation_fees_invoices` has a unique constraint on `event_id` (or on `(tenantId, opdInvoiceId)` — designer to pick, see 7.3a).
- On insert collision, the worker treats the event as already processed and advances. This handles at-least-once delivery from the outbox safely.

### 7.3a Uniqueness for consultation fees invoices

- One OPD invoice → exactly one consultation fees invoice. The unique key is `(tenantId, opdInvoiceId)`. The designer must confirm no edge case in HMS allows one OPD invoice to be re-created or voided-and-recreated such that a second CFI would be needed.

### 7.4 State machine

- Already defined in Section 3.2. The designer must produce the exact SQL constraint (`CHECK (status IN (...))` plus a trigger or app-level guard for transition validity) and the audit table DDL.

### 7.5 Concurrent status updates

- Two admins open the same invoice and both click "Mark as Paid" simultaneously.
- **Recommended:** optimistic locking via a `version` column on `consultation_fees_invoices`. The status-update API takes `If-Match: <version>`; service returns `409 Conflict` if version mismatches.
- Alternative: `SELECT ... FOR UPDATE` on the invoice row inside the transaction.

### 7.6 Multi-tenancy enforcement

- **Model: shared schema, `tenantId` column** (matches HMS).
- Defense-in-depth:
  1. **API edge:** every request carries the calling admin's `tenantId` (resolved from HMS session in BFF). Service rejects requests with missing/mismatched `tenantId`.
  2. **Query layer:** a Prisma client extension or middleware injects `where: { tenantId: ... }` into every query. A test asserts no query can omit the filter.
  3. **Redis keys:** all keys prefixed `summary:consultation_fees:{tenantId}:...`. Cross-tenant key access is impossible by key naming.
  4. **Logs:** `tenantId` is a required field on every log line.

### 7.7 Service-to-service auth

- **Recommended for v1:** HMAC-SHA256 over `(method, path, body, timestamp)` with a shared secret in `/etc/ycare-summary/shared-secret` (mode 0400, owned by the service user). Service rejects requests with timestamps > 5 minutes old (replay protection).
- The BFF adds headers: `X-Service-Id: hms-bff`, `X-Signature: <hmac>`, `X-Timestamp: <unix-secs>`, `X-Tenant-Id: <tenantId>`.
- The service validates all four headers on every request and 401s otherwise.
- Secret rotation: file-based; new secret deployed via ops procedure (place new file, restart service with new env var pointing at it, keep old secret valid for a grace period for in-flight requests).

### 7.8 Redis cache model

- **What is cached:** aggregate counters only. The summary list page reads from Postgres; the dashboard counters read from Redis.
- **Key shape:** `summary:consultation_fees:{tenantId}:{YYYY-MM-DD}:{counterId|"all"}` → HSET with fields `total`, `paid_total`, `paid_count`, `unpaid_total`, `unpaid_count`, `void_total`, `void_count`.
- **Update:** `HINCRBY` on every event (CFI creation, status change). Idempotent under at-least-once delivery if the worker uses a Redis Lua script to compare-and-update based on event_id.
- **Read fallback:** if Redis is down, the API computes the counter from Postgres (`SELECT status, COUNT(*), SUM(amount) FROM consultation_fees_invoices WHERE tenantId = ? AND created_at::date = ? GROUP BY status`). Slower but correct.
- **TTL:** every key has an expiry — `EXPIRE 86400` (24h) for the active day's buckets, `EXPIRE 604800` (7d) for past-day buckets. The TTL forces periodic refresh from Postgres via cache-aside; cold days are eventually re-read and refreshed; the active day is bounded against drift.
- **No reconciliation job.** Drift heals itself on the read path. A daily cron rebuilding Redis would race with active writes (e.g. a 02:00 cron can clobber a 01:59:30 status change). Cache-aside is simpler and race-free: the next read either sees a value that was correctly written by the most recent writer, or computes fresh from Postgres.

### 7.9 Search strategy

- **Search is restricted to Invoice No.** Doctor name and patient name are **not** searchable. Substring match (case-insensitive) on `invoice_no` only.
- **Recommended:** `pg_trgm` GIN index on `lower(invoice_no)`. Substring match, no new infrastructure, no generated column, no relevance ranking. Standard Postgres extension.
- **Why not FTS?** Originally specified `tsvector` + GIN. Rejected because tokenization, stemming, and ranking are not useful for a single-field substring match. FTS brings surprising matches (e.g., "dr" matching "Andre" via stemming) that aren't useful here.
- **Why no relevance ranking?** A substring match on a single field has no meaningful relevance. Admins expect to find the row they searched for; ordering by `billing_date DESC` (the same as the unfiltered list) is the right default.

### 7.10 Observability

- **Logs:** pino with structured JSON output to stdout and `/var/log/ycare-summary/app.log` (logrotate). Required fields: `timestamp`, `level`, `tenantId`, `requestId`, `eventId` (when relevant), `msg`.
- **Metrics (optional in v1):** Prometheus-format on `/metrics` (port 4001, 127.0.0.1 only). Counters: `c_events_processed_total`, `c_status_changes_total{from,to}`, `c_redis_cache_hits_total`, `c_redis_cache_misses_total`. Histograms: `h_request_duration_seconds{route}`, `h_event_processing_seconds`.
- **Audit log:** the `consultation_fees_invoice_status_changes` table is the audit log. A separate `summary_service_audit` table is unnecessary.
- **Monitoring (no automated alerting in v1):** systemd's `Restart=on-failure` brings the unit back on a crash; the operator monitors health via `journalctl -u ycare-summary-*` and the structured log files under `/var/log/ycare-summary/`. Push-based alerts (webhook / email / pager) are a v2 concern — the system already produces the right signal in structured logs, so the v2 work is just plumbing delivery.

### 7.11 Failure modes

The designer must enumerate each of the following and specify the system's response:

- Worker crashes mid-event-processing (event row already marked processed in DB but Redis not yet updated)
- Outbox poll query times out / DB temporarily unavailable
- Redis is down during event processing
- Redis is down during a read
- Status update requested on an invoice that's not `UNPAID`
- Status update requested on an invoice from a different tenant
- Two workers running simultaneously (split-brain) — must not double-process
- Summary Service is offline for an extended period; large outbox backlog

### 7.12 Backup and recovery

- The new tables live in the HMS Postgres, so they're covered by the existing backup policy. No new backup procedure.
- Redis state is rebuildable from Postgres lazily, on the first read of each affected bucket. No reconciliation job, no startup hook.
- Document: in a disaster, "rebuild Redis" = `DELETE` all `summary:consultation_fees:*` keys. Normal admin traffic repopulates them via cache-aside.

### 7.13 Adjustment semantics (RESOLVED — confirmed by hospital)

The `adjustment` field on `consultation_fees_invoices` is the admin's correction to the consultation fee. Confirmed rules for v1:

- **Sign convention:** Non-negative only. `CHECK (adjustment >= 0)`. An adjustment is always a *reduction* of the payout; never an addition.
- **Bounds:** `CHECK (adjustment <= amount)`. A `payout_amount` of 0 is valid (full write-off — the doctor gets nothing for this consultation). Negative payout is not allowed.
- **Reason requirement:** A free-text `reason` is required for every adjustment, max 500 chars. Persisted in the audit table. UI enforces this; the API rejects requests with empty `reason`.
- **Authorization:** Same role as status change (`consultation_fees:write`). No separate, more privileged role in v1.
- **Mutability window:** **Adjustment is only allowed while the CFI is `UNPAID`.** Once the CFI transitions to `PAID` or `VOID`, the `adjustment` field is immutable.
  - The API rejects adjustment updates on non-`UNPAID` CFIs with `409 Conflict` and a clear error code (`ADJUSTMENT_LOCKED`).
  - For late corrections after `PAID`: not supported in v1. The hospital records the correction through a separate accounting / finance workflow outside this service.
  - For corrections after `VOID`: the hospital generates a new OPD billing for the corrected consultation, which the worker picks up as a new CFI. (This works because the original CFI's `opd_invoice_id` is distinct from the new OPD billing's id.)
- **Audit table:** A new `consultation_fees_invoice_adjustments` table mirrors the structure of `consultation_fees_invoice_status_changes` (immutable history, one row per change). The latest row's `amount` is the current adjustment value; the full history is preserved.
- **Redis impact:** Adjustments don't change `status`, but they do change `payout_amount` totals. The Redis hash for the affected day must be updated to reflect the new `payout_amount` aggregate. (HINCRBY the `payout_total` field by the delta, not the full recompute.)

### 7.14 Payout formula (RESOLVED — Model A)

`payout_amount = amount - adjustment`.

Simple subtraction. The hospital does not retain a cut in v1; the doctor gets the full net consultation fee.

Implications:
- The formula is parameter-free; no `doctor_share_pct` lookup, no `DoctorPayoutConfig` table, no global config.
- Re-evaluation triggers: on CFI insert (after the `amount` is computed) and on any adjustment update while `status = UNPAID`. Nowhere else.
- Rounding: round half-up to 2 decimal places at every recompute. Storing pre-rounded values is fine — `NUMERIC(12,2)` already enforces the precision.
- The data model leaves room for Model B/C in a future version. The formula lives in a single helper function (`computePayoutAmount(amount, adjustment): number`) so swapping it out later is a one-file change. The DB constraints do not need to change for the model swap.

### 7.15 Doctor payout workflow (out of scope for v1, but the data model must support it)

The CFI's `payout_amount` answers "how much does the doctor earn for this consultation?" It does **not** answer "has the doctor been paid?" The actual money movement (cash, bank transfer, payroll batch) is a separate workflow that lives in the hospital's finance / payroll system.

In v1, the CFI tracks what is owed; it does not track what has been disbursed. The data model must leave room for a future `doctor_payouts` table (or `payout_batches`) without forcing a v2 schema migration that would touch the CFI. Specifically:

- `consultation_fees_invoices.payout_amount` is a stored column, not a view — so it can be referenced from future payout tables without circular dependencies.
- No foreign key from CFI to a `payout` table in v1; that link is added when the payout workflow is built.
- The CFI's `status` (`UNPAID` / `PAID` / `VOID`) refers to the **patient's payment to the hospital** for the consultation fee, **not** the doctor's receipt of payout. Future payout states (e.g., `PAYABLE`, `DISBURSED`) are out of scope and must not be conflated with the existing CFI status.
- The CFI's `payout_amount` is **frozen at the moment of `PAID` transition** (since adjustment is locked once `PAID`, and the formula is parameter-free). Whatever it is at that moment is the doctor's earnings for this consultation, full stop.

Document this clearly in the data model and in the API responses, so a future implementer doesn't accidentally overload the CFI's `status` field with payout state.

---

## 8. Resolved & Open Questions

### 8.1 Resolved

| # | Question | Answer | Design impact |
|---|---|---|---|
| 1 | Is this a reporting service or a summary service? | **Summary service** | No file exports in v1. The service computes and caches aggregates; admins read summary lists. |
| 2 | Deployment target | **On-prem hospital server** | No AWS. systemd. localhost binding. File-based secrets. |
| 3 | What entity is the core of v1? | **Consultation Fees Invoice (CFI)** with status `UNPAID` / `PAID` / `VOID` | New `consultation_fees_invoices` table + `consultation_fees_invoice_status_changes` audit table. |
| 4 | Trigger source | **OPD invoice creation** | HMS writes an `event_outbox` row in the same transaction. Worker polls outbox. |
| 5 | What is cached in Redis? | **Aggregate counters** (totals, counts by status, by date, by counter) | Dashboard counters load in <100ms. Filterable list still hits Postgres. |
| 6 | Filterable summary dimensions | **Date range, counter/store, doctor, status, restricted search on invoice no** | Indexes on `created_at`, `counter_id`, `doctor_id`, `status`, plus a `pg_trgm` GIN index on `lower(invoice_no)`. Doctor name and patient name are **not** searchable. |
| 7 | Admin actions on summary | **View summary, update status of individual invoices** | Status update is `UNPAID → PAID` or `UNPAID → VOID`. Terminal states — no further transitions. |
| 8 | Notification channel | **None in v1** (in-page refresh only) | The deprecated "in-app notification table" approach is dropped. v2+ may add it. |
| 9 | Multi-tenant model | **Shared schema, `tenantId` column** | Defense-in-depth at edge, query layer, Redis, logs. |
| 10 | Consultation fee amount source | **Sum of `OPDBillingService` rows where `isCancel=false` AND joined `Service.isConsultationService=true`** (confirmed against `prisma/schema.prisma`) | Worker computes the fee via SQL join at CFI creation time; denormalizes the amount onto the CFI row. CFI is a snapshot — later mutations to source fields do not retroactively update the CFI. |
| 11 | OPD void behaviour | **Out of scope for v1** | Only the `opd_invoice.created` event is emitted. No `voided` event. OPD-void → CFI-void linkage deferred. |
| 12 | Backfill historical OPD invoices | **No — start from v1 deployment forward** | Clean cutover. No backfill script needed. Historical OPD invoices remain queryable via existing HMS UI; they simply have no CFI. |
| 13 | Payout formula | **Model A: `payout = amount - adjustment`** | No `doctor_share_pct` lookup, no payout config table. Formula lives in a single helper function, swappable to Model B/C later. |
| 14 | Adjustment semantics | **Non-negative, `adjustment <= amount`, `reason` required, only editable while `UNPAID`** (locked once `PAID` or `VOID`) | DB-level `CHECK` constraints. API returns `409 ADJUSTMENT_LOCKED` for late edits. Late corrections after `PAID` are out of scope in v1. |

### 8.2 Assumed (designer defaults — flag in the design, user can override)

The user has chosen to mark the remaining open questions as designer defaults. Each is given a sensible default below. If the hospital's actual situation differs, override before implementation.

1. **Denormalized display fields on CFI** — **Assumed: yes, denormalize.** Patient name, doctor name, counter name, invoice number live on `consultation_fees_invoices`. Drift risk is low (patients rarely change names; if they do, the CFI shows the historical name at the moment of capture, which is correct for an audit log). Read speed wins.
2. **RBAC permission for consultation fees** — **Assumed: a new permission `consultation_fees:write` following the HMS's existing RBAC pattern.** If a similar permission already exists, reuse it. Same permission covers both status changes and adjustments (per 7.13).
3. **Reconciliation cadence** — **None.** Read-path cache-aside is the recovery. No daily cron, no startup hook. (Earlier designs included a daily cron + Redis-restart hook; both were dropped as over-engineering — see ADR 0009 and the design notes for the failure modes each addresses.)
4. **Log retention** — **Assumed: 90 days for application logs (rotated via `logrotate`), indefinite for DB audit tables (`consultation_fees_invoice_status_changes`, `consultation_fees_invoice_adjustments`) — covered by the existing Postgres backup.** If the hospital has a stricter policy (e.g., 1 year for app logs), bump the `logrotate` config accordingly.
5. **On-prem server specs** — **Assumed: 4 vCPU, 16 GB RAM, 100 GB SSD, gigabit ethernet, Ubuntu 22.04 LTS.** This is the minimum to comfortably run Postgres + Redis + Next.js + Summary Service on the same host. **Designer must confirm with hospital IT** before finalizing the capacity plan.
6. **Backup policy** — **Assumed: the existing Postgres backup covers the new tables** (they're in the same DB). Designer to confirm with hospital IT. If not, add the new tables explicitly to the backup config.
7. **v2+ summary types** — **Assumed: OPD total cost, OPD revenue by doctor, OPD revenue by department.** The data model keeps `amount` / `adjustment` / `payout_amount` fields **per-CFI** (not per-summary-type), so v2 just adds new read queries / new Redis keys / new UI tabs — it does NOT need new tables. The data model is summary-type-agnostic from day 1.

---

## 9. Deliverables Expected

The design output should include:

1. **Architecture Decision Record (ADR)** — one ADR per decision in Section 7, with Context, Options, Decision, Consequences.
2. **C4 diagrams** (or equivalent):
   - System context (Summary Service in the HMS landscape)
   - Container diagram (Express API, Express worker, Postgres, Redis, Next.js)
   - Component diagram (inside the Summary Service: HTTP routes, inbox worker, Redis client, Prisma client, audit logger)
   - Deployment diagram (single on-prem host, systemd units, ports, file paths)
3. **Sequence diagrams** for the four critical flows:
   - OPD invoice creation → CFI creation (outbox → worker → DB → Redis)
   - Admin loads summary page (Redis hit for counters, Postgres for list)
   - Admin updates status (DB transaction, Redis update, audit row)
   - Worker crash + reaper recovery
4. **Data model** — DDL for `consultation_fees_invoices` (with the new `adjustment`, `payout_amount`, `paid_at`, `voided_at`, denormalized `invoice_no` / `patient_name` / `doctor_name` / `counter_name` columns), `consultation_fees_invoice_status_changes` (audit), `consultation_fees_invoice_adjustments` (audit — new for Section 3.5), `event_outbox` (Section 7.1). Indexes, constraints, foreign keys, Mermaid ER diagram.
5. **API specification** — OpenAPI 3.1 for the Summary Service's HTTP surface. Auth header spec. Error model.
6. **HMAC auth spec** — exact signing algorithm, header names, timestamp skew window, replay-protection rule, secret rotation procedure.
7. **Prisma schema additions** — the new models, with relations to existing HMS models (use `@@schema` or `@@map` to avoid name collisions with HMS conventions).
8. **systemd unit files** — `ycare-summary-api.service` and `ycare-summary-worker.service`. `ExecStart` with the right `--mode` flag, restart policy, environment file.
9. **Observability spec** — log fields, metric names/labels, logrotate config.
10. **Security review** — threat model for the on-prem deployment (STRIDE), auth model, secret handling, file permissions, network isolation, what an attacker with shell access on the host could do.
11. **Migration / cutover plan** — how the new service goes live (backfill decision from Q7, feature flag in HMS, canary test plan, rollback procedure).
12. **Runbook** — operational procedures for: restarting the service, rotating the HMAC secret, rebuilding Redis from scratch, recovering from a worker crash with an unprocessed outbox, scaling (if/when the host can't keep up).
13. **Capacity plan** — given host specs (Q8), expected daily OPD invoice volume, and expected admin concurrency: is the host sized correctly for Postgres + Redis + Summary Service + HMS simultaneously? If not, what to add.

---

## 10. Reference Patterns & Skills

Use the senior-architect skill's reference documentation to inform the design:

- `references/architecture_patterns.md` — microservices, event-driven, outbox, CQRS, saga, cache-aside.
- `references/system_design_workflows.md` — capacity planning, API design, migration workflow.
- `references/tech_decision_guide.md` — queue, DB, and cache selection.

**Patterns that should likely appear in the design:**
- **Transactional outbox** (Section 7.1) — atomic event emission from the HMS.
- **Cache-aside** (Section 7.8) — Redis aggregates rebuilt lazily on miss.
- **Optimistic concurrency control** (Section 7.5) — version column for status updates.
- **Multi-tenant "tenant per row" with defense-in-depth** (Section 7.6).
- **Bulkhead / process isolation** — the API and worker run as separate systemd units; a worker crash does not take down the API.

---

## 11. Out of Scope

- Implementation code (this is a design only).
- Migrating existing pg-boss jobs in the HMS.
- Any new OPD billing logic, payment collection, or receipt generation.
- Patient-facing UI.
- WebSocket / SSE push to admin UIs.
- Report / CSV / PDF export of consultation fees (the deprecated v1 scope).
- BI / data warehouse / OLAP.
- Multi-hospital / cloud-hybrid deployment.
- Disaster-recovery RTO / RPO targets beyond the existing hospital backup policy.

---

## 12. How to Use This Brief

1. Read Sections 1–6 to understand the problem and the target shape.
2. Resolve or assume the open questions in Section 8.2 — flag every assumption explicitly in the design.
3. For each subsection in Section 7, produce an ADR.
4. Produce every deliverable in Section 9.
5. Sanity-check the design against Section 4 (NFRs) and Section 11 (out of scope).
6. Present a summary: key decisions, top 3 risks, recommended phasing (e.g. Phase 1: CFI creation only, Phase 2: admin UI + status updates, Phase 3: Redis cache, Phase 4: observability and metrics).

The design is **not done** until a senior engineer who was not involved in writing it can read the ADRs + diagrams and explain the system to a new team member.
