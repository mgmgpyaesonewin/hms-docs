# Summary Service — Build Prompt

> **Audience:** senior-fullstack (engineering-skills)
> **Source of truth:** the existing design in this folder. This prompt
> is a build/implementation distillation — it tells the implementer
> *what to write and in what order*. The design decisions live in
> [`../summary-service-architecture-prompt.md`](../summary-service-architecture-prompt.md)
> and the 13 ADRs in [`adrs/`](adrs/). When this prompt and a design
> doc disagree, the design doc wins.

---

## Read these first (do not skip)

1. [`../summary-service-architecture-prompt.md`](../summary-service-architecture-prompt.md) — the brief: background, requirements, NFRs, and the 21 resolved/assumed decisions.
2. `adrs/0001-trigger-mechanism.md` — the worker is a **Postgres transactional outbox** poller. Not BullMQ, not Redis Streams, not pg-boss. ADR 0001 explains why.
3. `adrs/0002-service-decomposition.md` — single Express binary with `--mode=api` or `--mode=worker`; one codebase, two systemd units.
4. `adrs/0007-multi-tenancy-enforcement.md` — `tenantId` discipline at the edge, query layer, Redis keys, and logs.
5. `adrs/0008-service-to-service-auth.md` + `api/hmac-auth.md` — HMAC-SHA256 signing and verification.
6. `adrs/0009-redis-cache-model.md` — Redis is **aggregate counters only** (cache-aside, no reconciliation job).
7. `data-model/schema.sql` and `data-model/prisma-additions.prisma` — the tables to migrate and the Prisma models to add.
8. `api/openapi.yaml` — the HTTP surface to implement.
9. `ops/ycare-summary-api.service`, `ops/ycare-summary-worker.service` — the systemd units the runtime must satisfy.
10. `ops/env.template` — the env vars to support. `ops/observability.md` — log fields and (optional) metric names.

## Stack (locked by the design — do not substitute)

- **Runtime:** Node.js 20 LTS, TypeScript strict, ES2022 target
- **HTTP:** Express 4 + helmet + cors + pino-http
- **Validation:** Zod (request bodies, query params, env)
- **DB:** Prisma against the **existing HMS Postgres** — same DB, same Prisma client, add the new models from `data-model/prisma-additions.prisma`
- **Cache:** ioredis client. Redis runs locally on `127.0.0.1:6379`, used **only** for aggregate counters (ADR 0009)
- **Logger:** pino, structured JSON to stdout and `/var/log/ycare-summary/app.log` (logrotate)
- **Worker loop:** `SELECT ... FOR UPDATE SKIP LOCKED LIMIT N` against `event_outbox`, claim → process → mark `DONE` (or `DEAD` after 5 attempts). Stale-claim reaper every 5 min resets rows whose `locked_at` is > 5 min old (ADR 0001).
- **Auth:** HMAC-SHA256 over `(method, path, body, timestamp)` with shared secret at `/etc/ycare-summary/shared-secret` (mode 0400). Reject requests with timestamp skew > 5 min.
- **Process supervision:** systemd, two units. **No docker-compose.** The service binds to `127.0.0.1` only.
- **Test framework:** Jest (matches HMS conventions)

## Repo layout (new standalone repo)

  summary-service/
    package.json
    tsconfig.json
    .env.example
    Dockerfile                  # CI / local dev only; NOT the production deploy path
    src/
      config/                   # env loading (Zod-validated) + typed config
      http/
        server.ts               # express bootstrap (--mode=api)
        middleware/
          hmac-auth.ts          # HMAC verification (per api/hmac-auth.md)
          tenant-guard.ts       # tenantId enforcement (per ADR 0007)
          error-handler.ts      # central error formatter
        routes/
          summary.routes.ts     # GET endpoints from openapi.yaml
          cfi.routes.ts         # status + adjustment endpoints
      workers/
        outbox-poller.ts        # the polling loop (--mode=worker)
        stale-claim-reaper.ts   # resets stuck rows every 5 min
        handlers/
          opd-invoice-created.ts  # the CFI creation handler
      services/
        cfi-service.ts          # CFI business logic (create, status change, adjustment)
        cfi-payout.ts           # payout formula: payout = amount - adjustment
        redis-counters.ts       # HINCRBY logic for aggregate buckets
      db/
        prisma.ts               # Prisma client singleton
        outbox.ts               # claim / mark-done / mark-dead helpers
        tenant-scope.ts         # Prisma extension enforcing tenantId
      lib/
        logger.ts               # pino instance, child loggers
        errors.ts               # AppError + status code mapping
        hmac.ts                 # signing + verification primitives
      cli.ts                    # entrypoint: parses --mode=api|worker

The brief is silent on repo shape but the design has its own systemd units and own deploy (ADR 0002), so a separate repo is the natural fit. If the implementation lands inside the YCare-HMS monorepo instead, mirror the layout under `src/app/(services)/summary/` and reuse the existing `src/lib/db.ts` Prisma singleton.

## Two entrypoints, one binary

`cli.ts` reads `--mode=api` or `--mode=worker` and boots the corresponding role. The systemd unit files in `ops/` invoke the binary with the right flag.

- One `npm run build` produces one `dist/`
- `dist/cli.js --mode=api` starts the HTTP server on `127.0.0.1:4000`
- `dist/cli.js --mode=worker` starts the outbox poller + reaper
- API and worker share the same build — only the boot mode differs
- A worker crash does not take down the API and vice versa

## Phase 1 — Repo scaffold + DB migration + HTTP skeleton

**Stop after Phase 1 for review before moving to Phase 2.**

1. Create the repo (per layout above) with `package.json`, `tsconfig.json` (strict, ES2022), `.env.example` (copy from `ops/env.template`), `.gitignore` (node_modules, dist, .env, *.log), `.dockerignore`.
2. Add the Prisma models from `data-model/prisma-additions.prisma` to the schema. Run `prisma migrate dev --name summary-service-init` to generate the migration SQL — **verify the generated SQL matches `data-model/schema.sql` line-for-line** before committing. Any delta is intentional and must be documented.
3. Implement the HTTP skeleton: `server.ts` boots Express, mounts helmet + cors + pino-http + the central error handler + a `/health` route that returns 200 only if Prisma + Redis are reachable. No business routes yet.
4. Implement `cli.ts --mode=api` and `cli.ts --mode=worker` so both boot modes start cleanly (worker is a no-op loop for now).
5. Copy `ops/ycare-summary-api.service` and `ops/ycare-summary-worker.service` into the repo at `ops/systemd/` and verify the `ExecStart` paths match the build output.
6. README at repo root documenting: env vars (from `ops/env.template`), how to run locally (`npm run dev` for both modes), how to point at a local Postgres + Redis, how the systemd units map to commands.

## Phase 2 — Outbox worker + CFI service + HTTP routes

1. Implement `outbox.ts` (claim, mark-done, mark-dead) and `outbox-poller.ts` (poll loop with the per-claim transaction described in ADR 0001). Implement `stale-claim-reaper.ts`.
2. Implement `cfi-service.createFromOpdInvoice(event)`:
   - Compute the consultation fee: sum of `OPDBillingService` rows where `isCancel = false` AND joined `Service.isConsultationService = true` (per ADR 0014).
   - Insert the `consultation_fees_invoices` row with denormalized fields (`invoice_no`, `patient_name`, `doctor_name`, `counter_name`, `amount`).
   - Compute `payout_amount = amount - adjustment` (`cfi-payout.ts`, brief §7.14).
   - Update Redis aggregate counters via HINCRBY (per ADR 0009).
3. Implement the HTTP routes per `api/openapi.yaml`:
   - `GET /summary/consultation-fees` (list with filters, paginated)
   - `GET /summary/consultation-fees/{id}` (detail)
   - `POST /consultation-fees-invoices/{id}/status` (status change with audit row, optimistic-lock `version`)
   - `POST /consultation-fees-invoices/{id}/adjustment` (adjustment with audit row, locked when status ≠ `UNPAID`)
4. Implement HMAC verification middleware per `api/hmac-auth.md`. Reject requests missing `X-Service-Id`, `X-Signature`, `X-Timestamp`, or `X-Tenant-Id`. Reject timestamp skew > 5 min.
5. Implement multi-tenant defense-in-depth (ADR 0007):
   - `tenant-guard` middleware injects `tenantId` from the verified header into `req.tenantId`.
   - `tenant-scope.ts` Prisma extension forces every query to filter by `tenantId`. Add a test that asserts no query can omit it.

## Acceptance criteria (both phases)

1. `npm run typecheck` and `npm run lint` pass with zero errors.
2. The Prisma migration produces schema identical to `data-model/schema.sql` (or its delta is intentional and documented).
3. `cli.ts --mode=api` boots and `curl http://127.0.0.1:4000/health` returns 200 with `{ status: "ok", db: "up", redis: "up" }`.
4. `cli.ts --mode=worker` starts the outbox poll loop; inserting a row into `event_outbox` with status `PENDING` results in a `consultation_fees_invoices` row within 2 poll cycles.
5. The stale-claim reaper resets an `IN_PROGRESS` row whose `locked_at` is older than 5 min back to `PENDING`.
6. HMAC middleware rejects a request with a missing signature (401), bad signature (401), and stale timestamp (401).
7. Cross-tenant access (request with `X-Tenant-Id: A` querying a row owned by tenant B) returns 404.
8. Status change from `UNPAID → PAID` writes an audit row and updates Redis counters; subsequent change attempts return 409 (terminal state).
9. Adjustment on a `PAID` CFI returns 409 `ADJUSTMENT_LOCKED`.
10. Every env var in `ops/env.template` is documented in `.env.example`; no secrets are committed.
11. You list any assumptions you had to make.

## Out of scope for this build (do not implement)

- Doctor payout workflow (v1 schema leaves room, no payout table)
- In-app notifications on status change
- Backfill of historical OPD invoices (clean cutover)
- Pub/sub, Redis Streams, BullMQ, or any second consumer
- Cloud deployment artifacts (Dockerfile is CI/test only, not a production deploy path on the on-prem host)
- Patient-facing UI
