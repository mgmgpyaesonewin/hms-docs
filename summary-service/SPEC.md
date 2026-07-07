# Summary Service — SPEC

> **Purpose.** Index into the existing Summary Service design tree. This is an
> entry point, not a replacement. For the full reading order and rationale,
> see [`README.md`](./README.md). For the originating brief, see
> [`../summary-service-architecture-prompt.md`](../summary-service-architecture-prompt.md).

---

## 1. Scope

**v1.** Auto-create a `Consultation Fees Invoice` (CFI) on every OPD billing,
serve the admin summary + status/adjustment API, and cache aggregate counters
in Redis. Deploy as two systemd units (`ycare-summary-api`,
`ycare-summary-worker`) from one Express + TypeScript binary, on-prem alongside
the HMS Next.js monolith.

**Non-goals (v1).** Doctor payout workflow, alternative trigger mechanisms,
cloud-managed infra, multi-region. The v1 data model is constrained so the
v2 payout workflow can land without breaking changes — see
[`README.md` §"Future work"](./README.md#future-work-out-of-scope-for-v1).

---

## 2. Module map

```
src/
├── index.ts                          entrypoint -- parses --mode=api|worker
├── config/                           Zod-validated env (cached)
├── lib/
│   ├── logger.ts                     pino
│   ├── redis.ts                      ioredis singleton
│   ├── redis-counters.ts             HINCRBY aggregates (cache-aside)
│   ├── hmac.ts                       HMAC-SHA256 primitives
│   ├── errors.ts                     AppError / NotFound / Conflict / Validation
│   └── validators/cfi.ts             Zod schemas for query/body
├── db/
│   ├── prisma.ts                     base PrismaClient
│   ├── outbox.ts                     claim / markDone / handleFailure / reapStaleClaims / pruneOldRows
│   └── tenant-scope.ts               Prisma extension forcing tenantId on every CFI query
├── services/
│   ├── cfi-payout.ts                 pure: payout = amount - adjustment
│   └── cfi-service.ts                createFromOpdInvoice, changeStatus (optimistic lock), addAdjustment
├── http/
│   ├── server.ts                     Express bootstrap (rawBody, HMAC, tenant, routes)
│   └── routes/
│       ├── health.routes.ts          GET /healthz (public)
│       └── cfi.routes.ts             5 business endpoints
├── workers/
│   ├── index.ts                      worker entry (poller + reaper + pruner)
│   ├── outbox-poller.ts              SELECT FOR UPDATE SKIP LOCKED
│   ├── stale-claim-reaper.ts         resets IN_PROGRESS rows older than 5 min
│   ├── outbox-pruner.ts              deletes old DONE/DEAD rows
│   └── handlers/opd-invoice-created.ts
└── types/express.d.ts                Request augmentation (tenantId, rawBody, prisma, serviceId)
```

---

## 3. CFI HTTP API

All routes under `/consultation-fees-invoices`; all require HMAC.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/consultation-fees-invoices` | List with filters (date, counter, doctor, status, restricted `invoiceNo` search); cursor pagination; `sort` enum |
| GET | `/consultation-fees-invoices/aggregates` | Unfiltered → Redis (`X-Cache-Status: hit`); filtered → Postgres |
| GET | `/consultation-fees-invoices/:id` | Detail + `statusHistory` + `adjustmentHistory` |
| PATCH | `/consultation-fees-invoices/:id/status` | `If-Match: <version>` required; `body.status ∈ {PAID, VOID}` |
| POST | `/consultation-fees-invoices/:id/adjustment` | `If-Match` required; 409 `ADJUSTMENT_LOCKED` when status ≠ `UNPAID`; 409 `ADJUSTMENT_EXCEEDS_AMOUNT` |

Declared order in `cfi.routes.ts` matters: `GET /aggregates` is registered
before `GET /:id` so the literal "aggregates" is not parsed as a UUID.

**Full spec:** [`api/openapi.yaml`](./api/openapi.yaml) ·
**captured end-to-end run:** [`api/api-smoke-test.md`](./api/api-smoke-test.md)

---

## 4. Data model

**Authoritative DDL** (includes CHECK constraints and `pg_trgm` GIN index that
Prisma cannot express): [`data-model/schema.sql`](./data-model/schema.sql).

**ER diagram:** [`data-model/er-diagram.md`](./data-model/er-diagram.md).

**Prisma additions** (used by `hms-summary-service/prisma/schema.prisma`,
which is a hand-maintained subset — see comment at the top of that file):
[`data-model/prisma-additions.prisma`](./data-model/prisma-additions.prisma).

The summary-service **does not** run migrations against the shared DB. The HMS
team runs the DDL.

### Invariants (do not change without updating the ADRs)

| # | Invariant | ADR |
| --- | --- | --- |
| 1 | Trigger is a **Postgres transactional outbox** — the HMS inserts a row into `event_outbox` in the same tx as the OPD billing; the worker polls with `FOR UPDATE SKIP LOCKED`. **No** BullMQ / Redis Streams / pg-boss / second consumer. | 0001 |
| 2 | CFI idempotency is rooted in `event_outbox.id` UNIQUE and `consultation_fees_invoices.event_id` UNIQUE. | 0003, 0004 |
| 3 | Status state machine is **`UNPAID → PAID | VOID`** only. `PAID` and `VOID` are terminal. Status changes use optimistic lock `version` (`If-Match`). Adjustment locked when status ≠ `UNPAID`. | 0005, 0006, 0014 |
| 4 | `payout_amount` is a stored `NUMERIC(12,2)` **frozen at the moment of `PAID` transition**. No `PAYABLE` / `DISBURSED` in the CFI status enum. | `README.md` §"Future work" |
| 5 | Multi-tenancy is defense-in-depth: HMAC-verified `X-Tenant-Id` at edge → `tenant-scope` Prisma extension forces `tenantId` on every CFI query → Redis keys tenant-prefixed → logs carry `tenantId`. Cross-tenant access returns **404** (do not leak existence). | 0007 |
| 6 | Auth is HMAC-SHA256: required headers `X-Service-Id` (must = `hms-bff`), `X-Signature`, `X-Timestamp` (±5 min skew), `X-Tenant-Id` (UUID). 10k-entry LRU replay cache. | 0008, [`api/openapi.yaml`](./api/openapi.yaml) §security |
| 7 | Redis is **aggregate counters only**, cache-aside, no reconciliation job. Unfiltered reads try Redis first; any filter bypasses cache; missing/stale/expired keys recompute from Postgres on next read. | 0009 |
| 8 | Two systemd units, one binary: `node dist/index.js --mode=api` and `... --mode=worker`. Canonical units in `ops/`; copies live in `hms-summary-service/ops/systemd/`. | 0002 |
| 9 | Service binds to **`127.0.0.1` only**. CORS closed (`origin: false`). Only the HMS BFF calls it. | `README.md` §"Stack" + `server.ts` |

---

## 5. ADRs (decision log)

| # | File | Decision |
| --- | --- | --- |
| 0001 | [`adrs/0001-trigger-mechanism.md`](./adrs/0001-trigger-mechanism.md) | Postgres transactional outbox |
| 0002 | [`adrs/0002-service-decomposition.md`](./adrs/0002-service-decomposition.md) | Two systemd units, one binary |
| 0003 | [`adrs/0003-idempotency.md`](./adrs/0003-idempotency.md) | Idempotency model |
| 0004 | [`adrs/0004-uniqueness-for-cfis.md`](./adrs/0004-uniqueness-for-cfis.md) | UNIQUE constraints on `event_id` / `outbox.id` |
| 0005 | [`adrs/0005-state-machine.md`](./adrs/0005-state-machine.md) | CFI status state machine |
| 0006 | [`adrs/0006-concurrent-status-updates.md`](./adrs/0006-concurrent-status-updates.md) | Optimistic-lock concurrency |
| 0007 | [`adrs/0007-multi-tenancy-enforcement.md`](./adrs/0007-multi-tenancy-enforcement.md) | Multi-tenancy enforcement |
| 0009 | [`adrs/0009-redis-cache-model.md`](./adrs/0009-redis-cache-model.md) | Redis cache-aside aggregates |
| 0010 | [`adrs/0010-search-strategy.md`](./adrs/0010-search-strategy.md) | Search (`invoiceNo`) strategy |
| 0011 | [`adrs/0011-observability.md`](./adrs/0011-observability.md) | Logs / metrics |
| 0012 | [`adrs/0012-failure-modes.md`](./adrs/0012-failure-modes.md) | Failure modes |
| 0013 | [`adrs/0013-backup-and-recovery.md`](./adrs/0013-backup-and-recovery.md) | Backup & recovery |
| 0014 | [`adrs/0014-cfi-invariants.md`](./adrs/0014-cfi-invariants.md) | CFI invariants |

> Note: ADR 0008 is reserved for HMAC auth; the full rationale lives in
> [`api/openapi.yaml` §security](./api/openapi.yaml) (the doc itself cites the
> spec authoritatively for that topic).

---

## 6. End-to-end flow

### A. OPD invoice → CFI auto-create

```
HMS OPD billing tx
  └─ INSERT opd_billings + INSERT event_outbox  (same tx)
        │
        └─ worker.poll ── SELECT … FOR UPDATE SKIP LOCKED ── mark IN_PROGRESS
              └─ handler.opd-invoice-created
                    ├─ read HMS rows by id (opd_billing + service + doctor + counter)
                    ├─ INSERT consultation_fees_invoices (event_id UNIQUE → idempotent)
                    ├─ HINCRBY tenant:{id}:date:{YYYY-MM-DD}:counter:{id}:doctor:{id} amount
                    └─ mark outbox DONE
```

If the worker crashes mid-step, the stale-claim reaper resets rows whose
`locked_at > 5 min` back to `PENDING` so the next poll re-attempts.
Full sequence: [`diagrams/sequences.md` §Happy path](./diagrams/sequences.md).

### B. Admin summary load

```
client → HMS BFF → HMAC sign → POST :4000/cfi-list
   ↓
server.hmac-auth (rejects stale/replay/bad sig)
   ↓
server.tenant-guard (attaches req.prisma)
   ↓
cfi.routes → cfi.service
   ├─ unfiltered → redis-counters.read → on miss, recompute from Postgres, HSET
   └─ filtered   → Postgres only (Redis is unfiltered only)
   ↓
HMAC-stripped JSON + X-Cache-Status
```

### C. Status change (PAID)

```
PATCH /:id/status { status: "PAID" }
   └─ If-Match: <version>
        └─ cfi.service.changeStatus (transaction)
              ├─ WHERE id = ? AND version = ?   (optimistic lock)
              ├─ SET status = 'PAID', version = version + 1
              ├─ freeze payout_amount = amount - adjustment  (cte)
              ├─ INSERT consultation_fees_invoice_status_history
              └─ return new version

on lock loss: 409 with current version → client re-reads and retries
```

### D. Adjustment

```
POST /:id/adjustment { amount, reason }
   └─ If-Match: <version>
        └─ cfi.service.addAdjustment
              ├─ reject 409 ADJUSTMENT_LOCKED     when status != UNPAID
              ├─ reject 409 ADJUSTMENT_EXCEEDS_AMOUNT when amount > cfi.amount
              └─ append to consultation_fees_invoice_adjustment_history
```

---

## 7. Operational concerns (full ops package)

| Topic | File |
| --- | --- |
| Systemd unit (API) | [`ops/ycare-summary-api.service`](./ops/ycare-summary-api.service) |
| Systemd unit (worker) | [`ops/ycare-summary-worker.service`](./ops/ycare-summary-worker.service) |
| Env template | [`ops/env.template`](./ops/env.template) |
| Logs / metrics / logrotate | [`ops/observability.md`](./ops/observability.md) |
| Security review (STRIDE) | [`ops/security-review.md`](./ops/security-review.md) |
| Cutover plan | [`ops/cutover-plan.md`](./ops/cutover-plan.md) |
| Runbook | [`ops/runbook.md`](./ops/runbook.md) |
| Capacity plan | [`ops/capacity-plan.md`](./ops/capacity-plan.md) |

---

## 8. Diagrams

- [`diagrams/c4-context.md`](./diagrams/c4-context.md) — system context
- [`diagrams/c4-container.md`](./diagrams/c4-container.md) — container view
- [`diagrams/c4-component.md`](./diagrams/c4-component.md) — component view (inside the service)
- [`diagrams/c4-deployment.md`](./diagrams/c4-deployment.md) — on-prem deployment
- [`diagrams/sequences.md`](./diagrams/sequences.md) — four critical-flow sequence diagrams (happy path, worker crash + reaper, summary load, status update)

---

## 9. Doc ↔ code parity

The `summary-service/` folder was audited against the live code in **November
2026**. The audit closed **9 of 14 findings** (3 critical + 6 medium). Five
low-priority findings remain as backlog — tracked under the closed-audit
findings list, not in this SPEC.

If a route in `hms-summary-service/src/http/routes/cfi.routes.ts` diverges from
`api/openapi.yaml`, the YAML is right and the code should be brought back into
line. Same rule for `data-model/schema.sql` vs the Prisma subset.

---

## 10. How to update this SPEC

1. If you add/rename an endpoint → update §3 and `api/openapi.yaml` together.
2. If you add/remove an invariant → update §4 and append / supersede the
   relevant ADR. Do not edit §4 without an ADR.
3. If you change the worker polling, retry, or reaper semantics → update §6A
   and `adrs/0001` (trigger) or `adrs/0012` (failure modes).
4. **This SPEC is exempt from the workspace 500-line cap.** It must stay
   detailed and readable for both AI and Human audiences. If it grows past a
   comfortable read (e.g., > 1000 lines or more than ~25 sections), prefer
   extracting a self-contained topic into `spec/{topic}.md` rather than
   trimming. Keep §1–§10 as the stable index.

The originating brief is the **only** place a new contributor should read
first to understand *why* the design exists; this SPEC is the *what*.
