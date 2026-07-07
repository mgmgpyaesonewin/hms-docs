# hms-app — SPEC

> **Purpose.** Index into the existing hms-app design tree. This file points
> at the canonical artifacts; it does not duplicate them. For the brief, see
> [`../summary-service-architecture-prompt.md`](../summary-service-architecture-prompt.md)
> (cross-service context only — hms-app itself has no separate design brief).
> For the entry point of the design tree, see [`README.md`](./README.md).

---

## 1. Project overview

**YCare HMS** is a multi-tenant Hospital Management System delivered as a
single Next.js 15 monolith (`ycare-hms` v1.1.12.dev). It owns the
operational source of truth for a hospital: patients, doctors, appointments,
clinical care (OPD / IPD / ED / daycare / cathlab / OT / endoscopy /
hemodialysis / imaging / lab / EMR), pharmacy stock and sales, billing,
and the publish end of the **transactional outbox** that feeds the
summary-service's `Consultation Fees Invoice` workflow.

The deployment shape is **on-prem Linux**, single shared Postgres, served via
ECR + Kubernetes behind an internal network. Multi-tenancy is enforced via
`storeId` (carried on the session) and `tenantId` (carried on cross-service
calls). Local dev runs against a `docker-compose` DB; see
`infra/docker-compose.yml`.

---

## 2. Glossary of clinical terms

A starter-friendly decode of the clinical modules and key domain words used
throughout this SPEC. Read this first if you are new to hospital
information systems — every acronym below appears again in §3–§14.

### Clinical modules

| Acronym | Long form | What it is, in plain English |
| --- | --- | --- |
| **OPD** | Out-Patient Department | Where patients come for a visit, see a doctor, and leave the same day. The OPD visit produces the "OPD bill" that the summary-service consumes. |
| **IPD** | In-Patient Department | Where patients stay overnight. Covers admission, daily bill, room/ward transfer, discharge, final bill, and deposit. |
| **ED** | Emergency Department | The emergency room. Patient is registered and treated without a prior appointment. ED bills are modelled as `ProxyBill` rows today. |
| **Daycare** | Daycare Ward | Short-stay care under a day (e.g. minor procedures) — the patient does not occupy a bed overnight but still has a billable episode. |
| **Cathlab** | Cardiac Catheterization Laboratory | A specialised procedure room for heart-catheter diagnostics and interventions (stent, angiogram). Bills appear as `ProxyBill` rows. |
| **OT** | Operating Theatre | The surgical theatre — major operations are scheduled and run here. Each OT case produces a `ProxyBill`. |
| **Endo** | Endoscopy | Procedures using a camera scope (colonoscopy, gastroscopy, etc.). Same `ProxyBill` + Endo Request + Endo Report triplet. |
| **HD** | Hemodialysis | The dialysis unit — repeated sessions of blood filtering for renal patients. |
| **Imaging** | Diagnostic Imaging | Radiology-style scans and traces: CT, MRI, X-Ray, Ultrasound, ECG, ECHO. All six modalities share one `ImagingList` table. |
| **EMR** | Electronic Medical Record | The patient-centric clinical record — vital signs, doctor and nurse notes, prescriptions, investigations, discharge summary, clinical documents. |

### Other terms used later in this SPEC

- **ProxyBill** — a single billable record shape that ED, daycare, cathlab,
  OT, endo, and HD all share (instead of each module having its own bill
  model). They differ only in the `department` enum value.
- **moduleType** — an enum used inside the EMR service to pick which care
  setting to filter on (e.g. `OPD`, `ED`, `DAYCARE`, `HD_OPD`, `ENDO_ED`).
  One `OPDEmrService` class is constructed 9 different ways via `moduleType`
  to cover the OPD/ED/Daycare/HD/Endo/OT sub-trees.
- **storeId** — the tenant scope. Every Prisma query that touches
  multi-tenant data is filtered by it.
- **event_outbox** — a Postgres table the HMS writes to **inside the
  OPD-bill transaction**. The summary-service polls it; inserting outbox
  rows from anywhere else is a contract violation.

---

## 3. Goals

| # | Goal | How it shows up |
| --- | --- | --- |
| G1 | One operational record for the hospital. | Every clinical / pharmacy / billing / EMR flow writes through the same Prisma client to one shared Postgres. |
| G2 | Accurate money. COGS / IPD bills / pharmacy sales always reconcile. | Pharmacy uses per-item moving-average cost snapshots ([`item-average-cost-design.md`](./item-average-cost-design.md)); selling-price costing follows the cost-method analysis ([`selling-price-cost-method-impact.md`](./selling-price-cost-method-impact.md)). |
| G3 | Clinically faithful EMR. | Every OPD / IPD / ED care setting writes to `EmrClinicalDocument` + per-tab fact tables (vitals, prescriptions, nurse notes, …) via the `OPDEmrService` / `IPDEmrService` pattern. |
| G4 | Reports the admin can trust. | The `reports/*` tree aggregates from the same Prisma data; nothing is double-recorded. |
| G5 | Multi-tenant by construction, not by audit. | `storeId` flows from session through tRPC, RSC, and Prisma; the `safe-action` wrapper stamps the same. |
| G6 | Outbox-only integration. | The summary-service consumes `event_outbox` rows out-of-band — see [`../summary-service/SPEC.md`](../summary-service/SPEC.md) §6A. No second queue, no shared writes. |

---

## 4. Scope

### In scope (v1)

- 14 clinical modules + `common/` + `shared/`: appointment, cathlab,
  daycare, ed, emr, endo, hd, imaging, ipd, lab, membership, opd, ot,
  pharmacy
- The two private git submodules: `appointment`, `opd` (per
  `session notes 2026-06-08` in
  [`./onboarding/solution-architect-plan.md`](./onboarding/solution-architect-plan.md))
- REST + tRPC + server-action surfaces for those modules
- The `event_outbox` insert on the OPD-bill write path
- RBAC, audit log (`activity-logs`), session auth (Argon2 + DB-backed
  session table)
- pg-boss background jobs, S3 file uploads, Winston logging to Postgres
- Multi-tenant by `storeId`

### Out of scope (v1)

- Doctor payout workflow — v2+. v1's `payout_amount` is frozen at the CFI's
  `PAID` transition; the link to a future `doctor_payouts` table is added
  later. Constraint: see
  [`summary-service/README.md` §"Future work"](../summary-service/README.md#future-work-out-of-scope-for-v1).
- Runtime feature flags — module toggles are build-time env vars
  (`NEXT_PUBLIC_*_MODULE_ENABLED`). Runtime flag system is on the SA roadmap.
- Cross-region HA — single on-prem host, on-prem Postgres backup only.
- Replacing tRPC + server-action duplication (currently both surfaces
  coexist; ADR pending).

---

## 5. User roles

The RBAC model uses **Action × Subject**. Concretely, the role set today
(per `manifest.yaml` notes and the existing module layouts):

| Role | Primary module surface | Notes |
| --- | --- | --- |
| **Doctor** | OPD consultation, EMR entries, service requests, prescriptions | Writes nurse notes, doctor notes, treatment prescriptions, investigations. Role-gated by clinical `permissions`. |
| **Nurse** | Vital signs, nurse notes, intake | Often co-gated with the care-setting (OPD/IPD/ED/Daycare). |
| **Front-desk / Reception** | Appointment booking, patient registration | Read on most modules, write on patient + appointment. |
| **Cashier** | OPD / IPD final billing, deposit, payment methods | The OPD-bill write path triggers the outbox event. |
| **Pharmacist** | Pharmacy (sale / return / stock request / GRN / purchase order) | Owns `ItemAverageCost` writes. |
| **Lab technologist** | Lab (sample collection, result entry, verification) | Owns `lab-result-verification` state transitions. |
| **Radiographer** | Imaging per modality (CT / MRI / X-Ray / Ultrasound / ECG / ECHO) | Owns `ImagingIPDService` status transitions (`PENDING → ACKNOWLEDGED → DE_ACKNOWLEDGED`, `PENDING → CANCELLED`). |
| **Specialist (cathlab / OT / endo / HD)** | Procedure-scoped billing + report entry | Owns the proxy-bill + report state machines. |
| **Billing / Finance admin** | Reports (`common-reports/*`), payments, IPD final bill | Read-many, write-on-payments. |
| **Tenant admin / Superadmin** | `common-users`, `common-roles`, `common-set-up`, store mapping | Highest permission surface; gated by `superadmin`-like permissions in `trpc-roles`. |
| **Patient (member portal)** | Membership self-service (`membership` module) | Read-only on own records; write on appointment booking and profile. |

> The `permissions` enum lives in
> `src/app/(dashboard)/common/user-management/roles/features/utils`
> (`Action`, `Subject`, `checkPermission`). RBAC decisions are made
> server-side; the client `<PermissionGuard>` / `WithPermission` wrappers
> are presentation-only.

---

## 6. Functional requirements

### 6.1 Clinical

| Module | What it does |
| --- | --- |
| **appointment** | Book / list / edit appointments (private submodule). Read REST documented in [`api/manifest.yaml`](./api/manifest.yaml). |
| **opd** | OPD visit lifecycle — patient check-in, consultation, OPD bill. Writes the OPD-bill row + the `event_outbox` row in the same transaction (G6). |
| **ipd** | Admissions, daily bills, IPD final bill, discharge, deposit, ward/room/bed management. Largest single module (69 REST routes, `status: pending`). |
| **ed** | Emergency department: appointments-for-ed, ED bills (proxy bills), patient lists. |
| **daycare** | Daycare appointments, daycare proxy bills, daycare-EMR. |
| **cathlab / ot / endo / hd** | Procedure specialties — each has a request + report + proxy-bill triplet. |
| **imaging** | Six modalities sharing `ImagingList` (CT, ECG, ECHO, MRI, Ultrasound, X-Ray). |
| **lab** | Sample collection → result entry → result verification → report delivery. |
| **emr** | Patient EMR — vital signs, doctor notes, nurse notes, prescriptions, investigations, discharge summary, clinical documents. Built on a single `OPDEmrService` instantiated 9 ways via `moduleType`. |
| **membership** | Patient-facing portal — appointment booking, profile, payment. |

### 6.2 Pharmacy

- Sale / return / stock damage / stock transfer
- Stock-in events write `ItemAverageCostHistory` (see
  [`item-average-cost-design.md`](./item-average-cost-design.md))
- GRN / purchase-request / purchase-order / batch / stock-expiry / selling-price-groups

### 6.3 Billing & finance

- OPD bill, IPD daily-bill, IPD-final-bill, deposit
- Payment methods, payment-method report
- Daily-profit report, item-summary, patient-summary, supplier-payment,
  referral reports
- The OPD-bill write **must** commit `event_outbox` in the same tx — this
  is the trigger the summary-service depends on. Removing or splitting the
  outbox insert is a breaking change to the summary-service.

### 6.4 Administration

- `common-users`, `common-roles`, `common-set-up/categories`,
  `common-stores`, `common-store-mapping`
- `common-suppliers`, `common-payment-methods`, `common-bill-types`
- `common-hospital-info`, `common-default-setting`, `common-doctors`,
  `common-departments`, `common-services`
- `common-uploads` — image-proxy, pdf-proxy, signed-urls (S3)

### 6.5 Cross-cutting

- `common-auth` — session resume / heartbeat
- `common-activity-logs` — audit log, written by every state-changing action
- `common-inventory` — 13 endpoints on stock queries
- `common-reports/*` — 47 endpoints split into clinical / financial / misc

The full module inventory (with route counts and files) lives in
[`api/manifest.yaml`](./api/manifest.yaml); do not duplicate it here.

---

## 7. Non-functional requirements

| Concern | Requirement |
| --- | --- |
| **Multi-tenancy** | Every Prisma query that touches multi-tenant data must be `storeId`-scoped (session carries it). API handlers and server actions are the enforcement points. |
| **Auth** | Custom session table + `sid` cookie + Argon2. Sessions resolved through `AuthService` in the tRPC context. See `src/lib/trpc/trpc.ts` for the procedure variants. |
| **RBAC** | `authorizeProcedure(action, subject)` for tRPC; `<PermissionGuard>` / `WithPermission` for RSC; `checkPermission` directly in shared helpers. Server actions wrap through `authActionClient` from `src/lib/safe-action.ts`. |
| **Authorisation rule** | Pass action + subject into `authorizeProcedure`. Cross-module service calls should re-check, not trust the caller's permission. |
| **Audit** | `common-activity-logs` invoked on every state-changing action in every module. Audit fields `createdBy` / `updatedBy` / `createdAt` / `updatedAt` are required on all new Prisma models. |
| **Idempotency** | Mutations touching OPD bill must be safe to retry (the `event_outbox` row is the idempotency anchor for the summary-service). Hostile retries must not duplicate writes. |
| **Performance** | Hot queries index their FKs and filter columns. Daily-profit / pharmacy-sale reports run from denormalised `report-*` tables, not real-time aggregations. |
| **Observability** | `winston` logger writes `error`-level entries to a Postgres `_logs` table; full stream also goes to stdout. Detail in §14. |
| **Background jobs** | pg-boss only. Queue + job-name constants live alongside the handler file. No second queue. |
| **Object storage** | AWS S3 via `@aws-sdk/client-s3` + `s3-request-presigner`. Server-side upload presigning; client uploads directly. |
| **Caveats (from hms-app README)** | (1) Migrations are forward-only — consult peers before adding. (2) Don't add dependencies without peer review. (3) `next.config.ts` ignores ESLint / TS errors at build time — `npm run tsc` and `npm run lint` are the source of truth locally. |
| **Migration policy** | Current tally: 467 Prisma migrations. Policy decision (squash vs. forward-only) is pending — see SA plan §3. |

---

## 8. Data model

**Authoritative schema:** `hms-app/prisma/schema.prisma`. Migrations live
under `hms-app/prisma/migrations/` (467 today). The HMS team owns this
schema. Migrations are forward-only.

**Cross-service tables the summary-service reads** (added to this schema
as part of the summary-service rollout — see
[`../summary-service/data-model/schema.sql`](../summary-service/data-model/schema.sql)):

- `event_outbox` — one row per domain event the summary-service should
  consume. **Inserted in the same Prisma transaction as the OPD bill** —
  this is the contract.
- `consultation_fees_invoices` — owned by the summary-service writer; the
  HMS app reads it via a derived Prisma subset.

**Data conventions for new Prisma models** (per SA plan §3):

- Soft-delete strategy **not** in use today — prefer hard delete + audit
  log. (Verify before adding a model that historically soft-deletes.)
- Required fields: `createdBy`, `updatedBy`, `createdAt`, `updatedAt`.
- `storeId` scoping required for any tenant-aware row.
- Index every foreign key; index every field used in a hot filter.
- Naming: `camelCase` fields, `PascalCase` models, plural route names.

---

## 9. API overview

The app exposes **three** distinct API surfaces, intentionally:

| Surface | Mount | Auth | When |
| --- | --- | --- | --- |
| **REST** | `/api/**` | `apiHandler` / `enhancedApiHandler` (`auth: { required }` + optional RBAC) | Cross-module reads, dashboard hydration, external callers |
| **tRPC** | `/api/trpc/**` | `publicProcedure` / `authProcedure` / `authorizeProcedure` / `storeCheckedProcedure` / `verifyPasswordProcedure` | Cross-module type-safe calls, internal writes, mutations |
| **Server actions** | invoked from RSC | `authActionClient` from `src/lib/safe-action.ts` | Form submissions on a single page |

**Rule of thumb (to be published as ADR-0001 per
[`./onboarding/solution-architect-plan.md`](./onboarding/solution-architect-plan.md) §3):**

- **tRPC** for queries and cross-module calls.
- **Server actions** for form submissions on a single page.

The REST surface is the canonical inventory in
[`api/manifest.yaml`](./api/manifest.yaml); per-module OpenAPI fragments
live under [`api/paths/`](./api/paths/) and [`api/schemas/`](./api/schemas/).

> **Source-of-truth rule.** If a route under `src/app/api/` diverges from
> the manifest, the manifest is right. The same applies to tRPC routers.

---

## 10. UI overview

- **Framework / library:** Mantine v7 + Tailwind. MUI also present in
  package.json (the team is in transition — keep new code on Mantine).
- **Router:** Next.js 15 App Router.
- **Top-level route groups:**
  - `(auth)` — login, session resume, forgot-password.
  - `(dashboard)` — the main app. Hosts the 14 clinical modules +
    `common/` + `shared/`.
  - `api/**` — REST + tRPC routes.
- **Module folders** under `(dashboard)/`: `appointment`, `cathlab`,
  `common`, `daycare`, `ed`, `emr`, `endo`, `hd`, `imaging`, `ipd`,
  `lab`, `membership`, `opd`, `ot`, `pharmacy`, `shared`.
- **Path aliases** (`tsconfig.json`):
  - `@/*` → `src/*`
  - `@common/*`, `@opd/*`, `@pharmacy/*`, `@appointment/*`,
    `@shared/*`, `@ipd/*` → module roots
- **State / data fetching:** React Query (via tRPC) + Mantine state for UI;
  Zustand stores where shared UI state is needed.
- **Forms:** react-hook-form + `@hookform/resolvers` (Zod).
- **Rich text:** `@mantine/tiptap` (clinical notes, prescriptions).
- **Toast:** Mantine notifications + `src/lib/toast.ts` sugar.

---

## 11. Workflows

### 11.1 Auth (every request)

```
Browser
  └─ middleware (auth gate + request-id)
        └─ if (dashboard) RSC
              └─ AuthService.resolve(sid) → session { userId, storeId, tenantId }
                    └─ storeId / tenantId passed through:
                          ├─ tRPC ctx      → storeCheckedProcedure + authorizeProcedure
                          ├─ safe-action   → authActionClient + storeId injection
                          └─ direct Prisma → only inside a request that has the session
```

### 11.2 OPD visit → outbox → CFI (cross-service)

```
1. Receptionist confirms patient (front-desk).
2. Doctor files consultation + EMR entries (OPD / EMR services).
3. Cashier creates OPD bill
   └─ tRPC mutation: OpdBillingService.create
         └─ Prisma tx
               ├─ INSERT opd_billing          ← R1
               ├─ INSERT event_outbox         ← R2 (same tx)
               └─ COMMIT
                       │
                       └─ summary-service worker (FOR UPDATE SKIP LOCKED)
                              ├─ INSERT consultation_fees_invoices
                              └─ HINCRBY aggregate counter
```

Steps R1 and R2 must happen in the same transaction. Removing R2 silently
breaks the summary-service; adding anything between R1 and R2 (e.g., a
pg-boss dispatch) is a write-loss hazard. See
[`../summary-service/SPEC.md` §6A](../summary-service/SPEC.md#a-opd-invoice--cfi-auto-create)
and ADR-0001 (transactional outbox).

### 11.3 State machines (excerpt)

| Entity | States | Source |
| --- | --- | --- |
| OPD bill | unpaid → paid / cancelled | not exposed in REST; mutates only via the doctor-side action |
| IPD final bill | unpaid → paid (multi-deposit) | tRPC payment mutation |
| Pharmacy stock | qty delta | per-stock `Stock.qty` updated by `StockMovement` rows; audit-logged |
| Imaging service | `PENDING → ACKNOWLEDGED → DE_ACKNOWLEDGED`; `PENDING → CANCELLED` | per-modality service; gated by `isValidImageServiceTransition` |
| EndoRequest / HDRequest | `REQUESTED → APPROVED | CANCELLED`; `APPROVED` terminal-ish (CANCELLED + COMPLETED are terminal) | module service; enforced server-side |
| EndoReport | `ENTERED → DELIVERED` | linked proxy bill must be `PAID` |
| CFI (summary-service) | `UNPAID → PAID | VOID` (PAID + VOID terminal) | [`../summary-service/SPEC.md` §4](../summary-service/SPEC.md#data-model) |

### 11.4 Background work

- `pg-boss` queue + job-name constants live next to the handler file.
- Use `pg-boss` for work that must survive a request cycle (heavy reports,
  exports, eventual-consistency retries). Don't put summary-service
  triggers on pg-boss — the outbox is the only mechanism (ADR-0001).

---

## 12. Permissions

The model is **Action × Subject**. Concrete types live in
`src/app/(dashboard)/common/user-management/roles/features/utils/`:

```ts
type Action = 'create' | 'read' | 'update' | 'delete' | 'manage'
type Subject =
  | 'Patient' | 'Appointment' | 'OpdBilling' | 'IpdBill'
  | 'Prescription' | 'Investigation' | 'VitalSign'
  | 'Pharmacy' | 'Inventory' | 'StockMovement'
  | 'Report' | 'User' | 'Role' | 'Store' | /* ... */
checkPermission(user, action, subject): boolean
```

**Enforcement points:**

| Layer | Wrapper | Purpose |
| --- | --- | --- |
| **tRPC procedure** | `authorizeProcedure(action, subject)` | Wraps a procedure; throws `AppError` 403 on denial. |
| **tRPC context** | `storeCheckedProcedure` | Asserts session has a `storeId` (multi-tenant gate). |
| **Server actions** | `authActionClient` from `src/lib/safe-action.ts` | Resolves session, attaches `userId` + `storeId`, asserts `auth: true`. |
| **RSC layout / page** | `<PermissionGuard>` / `WithPermission` | Presentation-only. Always re-check on the server. |
| **Shared helpers** | `checkPermission(user, action, subject)` | Direct call inside services when the action doesn't fit a procedure. |

**Procedure types** (`src/lib/trpc/trpc.ts`):

| Procedure | What it does |
| --- | --- |
| `publicProcedure` | No auth. Used for `healthz`, sentry probe, module-check endpoints (submodule probes). |
| `authProcedure` | Requires session. |
| `authorizeProcedure(action, subject)` | `authProcedure` + RBAC. |
| `storeCheckedProcedure` | `authProcedure` + tenant scope. |
| `verifyPasswordProcedure` | Re-prompts for password (sensitive mutations). |

> **Rule (drafted from SA plan).** RBAC is decided server-side at the
> procedure / action / service boundary. UI `<PermissionGuard>` is
> presentation-only and **never** the sole gate. Cross-module service calls
> must re-check, not trust the caller's permission check.

---

## 13. Architecture

### 13.1 Layering (intended)

```
┌──────────────────────────────────────────────────────────────────┐
│ Browser                                                            │
│   ├─ React + Mantine v7                                           │
│   ├─ React Query (tRPC client)                                    │
│   └─ hooks/use-action (server-action wrapper)                     │
└──────────────────────────────────────────────────────────────────┘
            │                                │
   (RSC, tRPC, server actions;               │ (REST)
    same-session cookie)                     │
            ▼                                ▼
┌──────────────────────────────────────────────────────────────────┐
│ Next.js middleware (auth gate + request-id)                       │
│   └─ /(dashboard) routes → resolve session via AuthService       │
└──────────────────────────────────────────────────────────────────┘
            │
            ▼
┌──────────────────────────────────────────────────────────────────┐
│ tRPC routers                │ server actions (authActionClient)   │
│   authorizeProcedure        │   next-safe-action                  │
│   storeCheckedProcedure     │   Zod input → domain service        │
└──────────────────────────────────────────────────────────────────┘
            │
            ▼
┌──────────────────────────────────────────────────────────────────┐
│ Domain services (OpdBilling, OpdEmr, Pharmacy, …)                 │
│   + activity-logs (audit)                                         │
│   + pg-boss jobs (queue + handler constants col-located)          │
└──────────────────────────────────────────────────────────────────┘
            │
            ▼
┌──────────────────────────────────────────────────────────────────┐
│ Prisma ──── PostgreSQL (single shared DB)                         │
│   └─ Event_outbox insert (same tx as OPD bill)  →  summary-worker │
│                                                                      │
│ AWS S3 ── file uploads (presigned PUT)                             │
│ Winston ── Postgres `winston` table (structured logs)              │
└──────────────────────────────────────────────────────────────────┘
```

### 13.2 Deployed shape

- **On-prem.** Single Linux host, on-prem Postgres, ECR + Kubernetes for
  the app + worker images. Dev / UAT / prod are tag-driven. See the
  GitHub workflow files in `hms-app/.github/workflows/`.
- **Dev.** `docker-compose` DB + `npm run dev`. Two private git submodules
  (`appointment`, `opd`) must be initialised via
  `gh auth setup-git && git submodule update --init` after cloning (see
  [`./onboarding/solution-architect-plan.md` session notes](./onboarding/solution-architect-plan.md)).

### 13.3 Module toggles (build-time)

- `NEXT_PUBLIC_APPOINTMENT_MODULE_ENABLED`, `NEXT_PUBLIC_OPD_MODULE_ENABLED`,
  `NEXT_PUBLIC_IPD_MODULE_ENABLED`, …
- Checked by `submodule-{name}/module-check` routes and the dashboard
  layout. Runtime flags are not yet wired (SA plan §3).

### 13.4 Experimental path

- `server.ts` + `dev:experimental` / `build:experimental` /
  `start:experimental` scripts, with a parallel `tsconfig.server.json`.
- Status: **commit, complete, or remove** (SA plan pending decision).
- Do not route production traffic through the experimental server until
  the decision lands.

### 13.5 Doc ↔ code parity

- The REST inventory is [`api/manifest.yaml`](./api/manifest.yaml); per-module
  detail is in [`api/paths/`](./api/paths/) and [`api/schemas/`](./api/schemas/).
  Manifest wins when code disagrees.
- The tRPC inventory is the same manifest (`api_style: mixed`).
- The summary-service Prisma subset is in
  [`../summary-service/data-model/prisma-additions.prisma`](../summary-service/data-model/prisma-additions.prisma)
  and must be regenerated after changes to `prisma/schema.prisma`.

---

## 14. Logger (Winston)

The app logs through a single Winston `winstonLogger` singleton
(`src/lib/winston.ts`). One instance per Node process; every cross-cutting
boundary imports it and creates a child logger at module scope.

### Configuration (defaults)

| Setting | Default | Source |
| --- | --- | --- |
| `level` | `"info"` | `LOG_LEVEL` env (falls back to `"info"`) |
| Singleton format | `combine(timestamp(), json())` | `src/lib/winston.ts` |
| Console format (non-prod) | `errors({stack:true})`, `timestamp()`, `prettyPrint()` | env-gated |
| Console format (production) | `errors({stack:true})`, `timestamp()`, `json()` | env-gated |

### Transports

| Transport | Levels | Destination | Notes |
| --- | --- | --- | --- |
| `Console` | all | stdout | pretty in dev, JSON in production |
| `PostgresTransport` (custom, `src/lib/winston-postgres-transport.ts`) | `error` only | Postgres `_logs` table | inserts via `prisma.logs.create({ data: { context, level, message, meta, error, timestamp } })` |

Notes:

- Only the **Postgres transport is filtered to `level: "error"`**. Do not
  raise it to capture `warn` / `info` without considering storage growth.
- The Console transport writes all levels to stdout — any non-production
  log streams can be tailed from pod logs.

### Database target

The Postgres destination is the **`Logs` Prisma model** (client accessor
`prisma.logs`), mapped to table **`_logs`**:

| Column | Type | Default | Notes |
| --- | --- | --- | --- |
| `id` | `uuid(7)` | auto | PK |
| `level` | `String` | `"info"` | winston level label |
| `message` | `String` | `""` | winston message |
| `context` | `String` | `""` | child-logger context label (§14.1) |
| `meta` | `Json` | `{}` | arbitrary structured metadata |
| `timestamp` | `DateTime` | `now()` | event time |
| `error` | `Json?` | `null` | error stack or `error.stack` |

The model has **no `tenantId` / `storeId` / `userId` column**. The
`context` field is the only label on the row. Cross-tenant log analysis
requires correlating against request logs (e.g. the `request-id` set in
middleware) — do not assume tenant from the row alone.

### §14.1 — Conventional usage

The single shared pattern:

```ts
import { winstonLogger } from "@/lib/winston";

const logger = winstonLogger.child({ context: "<your-context>" });

logger.info("msg", { extra });
logger.error(err.message, err.stack);
```

Observations from the codebase:

- **Always child-log.** Create one child per file (or boundary) at
  module scope with a `{ context }` tag. Do not call `winstonLogger.info(...)`
  directly from inside a service.
- **Context tags in use today**: `safe-action`, `trpc`, `apiHandler`,
  `handleActionError`, `initPgBossLogger`. Add new contexts in the same
  shape (kebab-case or camelCase, descriptive of the boundary).
- **Levels.** `info` for normal lifecycle; `debug` for hit-on-error
  diagnostics in the tRPC error formatter; `warn` for recoverable issues;
  `error` for anything that goes to Postgres.
- **Repository helper.** Use `repositoryErrorHandle(error, logger)` from
  `src/utils/error-handling.ts` to log a thrown error from a repository
  and re-throw — it handles `Error` vs. unknown shapes.
- **Server-action error split.** `src/lib/safe-action.ts` logs `AppError`
  at `info` for the message + `error` only when `error.code >= 500`.
  Other errors log `error.message, error.stack`. Match this convention.

### §14.2 — Where the singleton is imported

Current call sites for `winstonLogger`:

- `src/lib/trpc/trpc.ts` — child `{ context: "trpc" }`, error formatter.
- `src/lib/safe-action.ts` — child `{ context: "safe-action" }`, `handleServerError`.
- `src/lib/pg-boss/pg-boss.ts` — child `{ context: "initPgBossLogger" }`, queue init.
- `src/utils/api-handler.ts` — child `{ context: "apiHandler" }`, REST catch.
- `src/utils/action-utils.ts` — child `{ context: "handleActionError" }`.
- `src/utils/error-handling.ts` — exported `repositoryErrorHandle(error, logger)`.
- `src/utils/parse-and-validate-{excel,csv}.ts`, `src/utils/csv-importer.ts`.
- Module services / repositories (e.g. `patients-repository.ts`).

### §14.3 — Operational notes

- **Quarterly error-log review** of the `_logs` table is on the SA plan
  Phase 4 health-check list. Look for new error contexts, recurring
  stack frames, and growth rate.
- **Storage.** The `_logs` table has no retention policy today. If table
  size becomes a concern, prune `timestamp < now() - interval '90 days'`
  to match the summary-service's `pruneOldRows` cadence.
- **Test safety.** The Postgres transport inserts via the real Prisma
  client. In tests, construct `PostgresTransport` directly with a stub
  prisma client, or set the transport to `silent: true`.
- **No PII.** Do not log patient PII (name, phone, NRC) in the
  `message` or `meta` fields. Log IDs only.

---

## 15. How to update this SPEC

Add/rename a route → update §6 inventory + `manifest.yaml`/`api/paths`. Add a state machine → §11.3. Add a Prisma model → §8 (and the summary-service subset if read there). Change stack invariants → §7 + `hms-app/README.md` Caveats + workspace `CLAUDE.md` in the same PR. **This SPEC is exempt from the workspace 500-line cap.** It must stay detailed and readable for both AI and Human audiences. If it grows past a comfortable read (e.g., > 1000 lines or more than ~25 sections), prefer extracting a self-contained topic into `spec/{topic}.md` rather than trimming. Keep §1–§14 as the stable index. Onboarding prose lives in [`./README.md`](./README.md) and [`./onboarding/solution-architect-plan.md`](./onboarding/solution-architect-plan.md); this file is the *what*.
