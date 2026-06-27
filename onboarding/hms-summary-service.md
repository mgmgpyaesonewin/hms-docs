# Onboarding — `hms-summary-service` (Express microservice)

> Polls the HMS `event_outbox` and materializes `consultation_fees_invoices` rows. One binary, two systemd units (api + worker). HMAC-authenticated REST API for the admin UI.

**Read first:** `hms-docs/summary-service/README.md` and the 14 ADRs under `hms-docs/summary-service/adrs/`. The design docs win when code and docs disagree.

---

## 1. What's where

```
hms-summary-service/
├── src/
│   ├── index.ts                          entry: parses --mode=api | --mode=worker
│   ├── config/index.ts                   Zod-validated env (cached)
│   ├── lib/
│   │   ├── logger.ts                     pino
│   │   ├── redis.ts                      ioredis singleton (lazy, transient-safe)
│   │   ├── redis-counters.ts             HINCRBY for daily aggregates (cache-aside)
│   │   ├── hmac.ts                       HMAC-SHA256 primitives
│   │   ├── errors.ts                     AppError, NotFoundError, ConflictError, ValidationError
│   │   └── validators/cfi.ts             Zod schemas for query/body
│   ├── db/
│   │   ├── prisma.ts                     base PrismaClient
│   │   ├── outbox.ts                     claim / markDone / handleFailure / reapStaleClaims / pruneOldRows
│   │   ├── tenant-scope.ts               Prisma extension forcing tenantId on every CFI query
│   │   └── __tests__/tenant-scope.test.ts
│   ├── services/
│   │   ├── cfi-payout.ts                 pure: payout = amount - adjustment
│   │   └── cfi-service.ts                createFromOpdInvoice (idempotent), changeStatus (optimistic lock), addAdjustment (locked when ≠ UNPAID)
│   ├── http/
│   │   ├── server.ts                     Express bootstrap (rawBody, HMAC, tenant, routes, central error handler)
│   │   ├── routes/
│   │   │   ├── health.routes.ts          GET /healthz (public, no HMAC)
│   │   │   └── cfi.routes.ts             5 business endpoints
│   │   └── middleware/
│   │       ├── hmac-auth.ts              6-step verification, 10k-entry LRU replay cache, ±5-min skew
│   │       ├── tenant-guard.ts           attaches req.prisma (tenant-scoped)
│   │       └── error-handler.ts          (legacy; inlined handler in server.ts subsumes it)
│   ├── workers/
│   │   ├── index.ts                      worker entry: poller + reaper + pruner
│   │   ├── outbox-poller.ts              SELECT … FOR UPDATE SKIP LOCKED, retry-with-backoff, DEAD after 5
│   │   ├── stale-claim-reaper.ts         resets IN_PROGRESS rows whose locked_at > 5 min
│   │   ├── outbox-pruner.ts              deletes old DONE/DEAD rows
│   │   └── handlers/opd-invoice-created.ts
│   └── types/express.d.ts                Request augmentation (tenantId, rawBody, prisma, serviceId)
├── prisma/
│   └── schema.prisma                     HAND-MAINTAINED SUBSET of HMS models — sync per ADR 0011
├── ops/systemd/                          copies of the canonical unit files
├── jest.config.js
├── tsconfig.json / tsconfig.build.json
└── .env.example                          every var documented inline
```

---

## 2. Setup (5 min)

```bash
cd hms-summary-service
cp .env.example .env                  # fill in DATABASE_URL, REDIS_URL, HMAC_SECRET_PATH
npm install
npm run prisma:generate               # generates the typed Prisma client
npm run dev:api                       # 127.0.0.1:4000
# second terminal:
npm run dev:worker
```

**Verify:**

- `curl http://127.0.0.1:4000/healthz` → `{"status":"ok","db":"up","redis":"up"}` (503 if degraded).
- `npm run typecheck` clean.
- `npm test` passes (the tenant-scope test is the only one for now; integration tests live in the runbook).

---

## 3. Env vars (every one is in `.env.example`)

| Var | What | Notes |
| --- | --- | --- |
| `DATABASE_URL` | Same HMS Postgres | must point at the shared dev DB |
| `REDIS_URL` | Local Redis | `redis://127.0.0.1:6379/0` default |
| `PORT` / `BIND_ADDRESS` | API listen | defaults `4000` / `127.0.0.1` — **prod binds to 127.0.0.1 only** |
| `HMAC_SECRET_PATH` | Path to the shared secret file | mode `0400`, owned by the service user |
| `OUTBOX_*` | Poller / reaper / pruner tuning | batch size, poll interval, claim TTL, retry attempts |

---

## 4. Two modes, one binary

```bash
node dist/index.js --mode=api      # HTTP server only
node dist/index.js --mode=worker   # poller + reaper + pruner, no HTTP
```

In dev, `npm run dev:api` and `npm run dev:worker` use `tsx watch`. In prod, systemd runs both from `dist/` — see `hms-docs/summary-service/ops/ycare-summary-{api,worker}.service`.

**Never** run more than one worker process per host. The `SELECT ... FOR UPDATE SKIP LOCKED` pattern makes horizontal scaling safe in theory, but `redis-counters` HINCRBY would double-count without a `seen_events` set (ADR 0009 §"Known gaps").

---

## 5. The HTTP API (HMAC-only, except `/healthz`)

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/consultation-fees-invoices` | list w/ filters, cursor pagination, `sort` enum |
| GET | `/consultation-fees-invoices/aggregates` | unfiltered → Redis; filtered → Postgres; emits `X-Cache-Status` |
| GET | `/consultation-fees-invoices/:id` | detail + `statusHistory` + `adjustmentHistory` |
| PATCH | `/consultation-fees-invoices/:id/status` | requires `If-Match: <version>`; `body.status ∈ {PAID, VOID}` |
| POST | `/consultation-fees-invoices/:id/adjustment` | requires `If-Match`; `409 ADJUSTMENT_LOCKED` when status ≠ `UNPAID`; `409 ADJUSTMENT_EXCEEDS_AMOUNT` when amount > cfi.amount |

**Route declaration order matters** — `GET /aggregates` is registered before `GET /:id` so the literal "aggregates" is not parsed as a UUID.

**HMAC headers required** (see ADR 0008 + `hms-docs/summary-service/api/hmac-auth.md`):
- `X-Service-Id` must equal `hms-bff`
- `X-Signature` (HMAC-SHA256 over canonical string)
- `X-Timestamp` ±5 min skew
- `X-Tenant-Id` (UUID, validated UUID format)

---

## 6. State machine (do not change)

```
   UNPAID ────────► PAID   (terminal)
     │
     └──────────► VOID    (terminal)
```

- `PAID` and `VOID` are terminal. Status changes use an optimistic `version` column (enforced via `If-Match`).
- Adjustment is **locked** when status ≠ `UNPAID`.
- `payout_amount = amount - adjustment`, frozen at the moment of `PAID` transition.
- v1 must not preclude v2 doctor-payout workflow — no `PAYABLE`/`DISBURSED` columns, no payout table.

---

## 7. Outbox loop (the heart of the service)

The poller (`src/workers/outbox-poller.ts`) does:

```
SELECT ... FROM event_outbox
WHERE status = 'PENDING' AND next_attempt_at <= now()
ORDER BY id
LIMIT <batch>
FOR UPDATE SKIP LOCKED;
```

For each row:

1. `UPDATE ... SET status = 'IN_PROGRESS', locked_at = now(), attempt = attempt + 1`
2. Dispatch to handler (`handlers/opd-invoice-created.ts` for v1)
3. On success → `markDone` (status `DONE`)
4. On failure → `handleFailure` (retry-with-backoff, `DEAD` after 5 attempts)

The **reaper** resets `IN_PROGRESS` rows whose `locked_at > 5 min` (worker crashed mid-flight). The **pruner** deletes old `DONE`/`DEAD` rows.

Idempotency is enforced by `consultation_fees_invoices.event_id` UNIQUE — a re-delivered event is a no-op.

---

## 8. Multi-tenancy (defense in depth)

| Layer | Where | What |
| --- | --- | --- |
| 1 — Edge | `http/middleware/hmac-auth.ts` | HMAC-verified `X-Tenant-Id` |
| 2 — Query | `db/tenant-scope.ts` | Prisma extension forces `tenantId` on every CFI query |
| 3 — Cache | `lib/redis-counters.ts` | Redis keys tenant-prefixed |
| 4 — Logs | `lib/logger.ts` | `tenantId` on every log line |

**Cross-tenant access returns 404** (never 403, to avoid leaking existence). See ADR 0007.

Route handlers must use `req.prisma!.consultationFeesInvoice.*` — the tenant-scoped client. Do not import unscoped `prisma` from `db/prisma.ts` in route handlers.

---

## 9. Build, test, deploy

```bash
npm run typecheck        # tsc --noEmit
npm run lint             # eslint src --ext .ts
npm test                 # jest
npm run build            # tsc -p tsconfig.build.json → dist/index.js
npm run start:api        # node dist/index.js --mode=api
npm run start:worker     # node dist/index.js --mode=worker
```

Deploy: two systemd units on the on-prem host. Canonical units are in `hms-docs/summary-service/ops/`; copies in `hms-summary-service/ops/systemd/`. Production env file at `/etc/ycare-summary/env`. Service binds to `127.0.0.1` only. CORS closed.

---

## 10. Things that bite (read these)

- **The HMS Prisma schema sync is hand-maintained.** To regenerate from the live DB: `npx prisma db pull` from the HMS repo and copy the relevant models into `prisma/schema.prisma`. Comment block at the top of that file explains.
- **The summary service does not run migrations against the shared DB.** The HMS team runs the DDL from `hms-docs/summary-service/data-model/schema.sql`. CHECK constraints and the pg_trgm GIN index cannot be expressed in Prisma alone.
- **Redis HINCRBY is best-effort.** Worst case: slightly inflated aggregate, self-heals on next read (per ADR 0009 §"Read fallback"). True at-least-once safety is a Phase 3 candidate (Lua script + `seen_events` set).
- **`output: "standalone"` does NOT apply here.** Plain Express binary, built to `dist/`.
- **The `errorHandler` import is intentionally referenced as `void errorHandler`** in `server.ts` to keep the import live while the inline handler subsumes it. Don't delete either.
- **CFI state mutations happen inside a Postgres transaction; Redis is touched outside.** The `event_id` UNIQUE is the ultimate idempotency guard.

---

## 11. Troubleshooting

| Symptom | First check |
| --- | --- |
| `/healthz` returns 503 `db: down` | `DATABASE_URL`, is Postgres up? Same network namespace as the HMS? |
| `/healthz` returns 503 `redis: down` | `REDIS_URL`, `redis-cli ping` from the host |
| 401 on every business route | HMAC headers missing or signature wrong; check `HMAC_SECRET_PATH` and the timestamp skew |
| Worker idle even though rows are `PENDING` | Worker process alive? Check `next_attempt_at` (backoff after failures) and `locked_at` (reaper threshold) |
| `CONSULTATION_FEES_INVOICES_EVENT_ID_unique violation` | The outbox event was re-delivered — this is fine, the row already exists. Check the worker logs to confirm the second insert was a no-op, not a bug. |
| `ADJUSTMENT_LOCKED` returned | The CFI is `PAID` or `VOID` — adjustment is locked by design. |