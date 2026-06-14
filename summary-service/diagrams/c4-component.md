# C4 — Component View (inside the Summary Service)

The two Summary Service processes (API and worker) share a `shared/` library. The component view below shows the modules within a single Express codebase.

```mermaid
C4Component
    title Component View: Summary Service (single codebase, two systemd units)

    Container_Boundary(c1, "Summary Service codebase") {
        Component(http_api, "HTTP API", "Express routes", "GET /summary, POST /status, POST /adjustment. Mounted under --mode=api")
        Component(inbox_worker, "Inbox Worker", "Outbox poller loop", "Polls event_outbox with FOR UPDATE SKIP LOCKED; creates CFIs; updates Redis. Mounted under --mode=worker")
        Component(hmac_auth, "HMAC Auth Middleware", "Express middleware", "Validates X-Signature, X-Timestamp, X-Service-Id, X-Tenant-Id")
        Component(tenant_guard, "Tenant Guard", "Prisma extension", "Injects tenantId filter on every query")

        Component(routes_summary, "Summary Routes", "Express handlers", "List + aggregates. Uses Postgres + Redis.")
        Component(routes_status, "Status Routes", "Express handlers", "POST /status. Uses Postgres only.")
        Component(routes_adjustment, "Adjustment Routes", "Express handlers", "POST /adjustment. Uses Postgres only.")

        Component(cfi_service, "CFI Service", "Domain logic", "computePayoutAmount, transition guards, version check")
        Component(audit_logger, "Audit Logger", "DB writes", "Inserts into status_changes and adjustments tables")

        Component(outbox_poller, "Outbox Poller", "Postgres poll loop", "FOR UPDATE SKIP LOCKED claim; call CFI service; mark DONE / DEAD; stale-claim reaper; outbox pruner")

        Component(cfi_repo, "CFI Repository", "Prisma", "Reads/writes consultation_fees_invoices")
        Component(outbox_repo, "Outbox Repository", "Prisma + raw SQL", "Reads/updates event_outbox. Raw SQL for FOR UPDATE SKIP LOCKED claim.")
        Component(redis_cache, "Redis Cache", "ioredis", "HSET/HINCRBY/HGET aggregate counters; Lua scripts for idempotency")
        Component(pino_logger, "Pino Logger", "Logger", "Structured JSON logs to stdout + /var/log/ycare-summary/*.log")
    }

    ContainerDb_Ext(postgres, "PostgreSQL", "")
    ContainerDb_Ext(redis, "Redis", "")

    Rel(http_api, hmac_auth, "Wraps every request")
    Rel(http_api, tenant_guard, "Applies on every Prisma call")
    Rel(http_api, routes_summary, "Mounts")
    Rel(http_api, routes_status, "Mounts")
    Rel(http_api, routes_adjustment, "Mounts")

    Rel(routes_summary, cfi_repo, "Reads list")
    Rel(routes_summary, redis_cache, "Reads counters")
    Rel(routes_status, cfi_service, "Transitions")
    Rel(routes_adjustment, cfi_service, "Updates adjustment")

    Rel(cfi_service, cfi_repo, "R/W")
    Rel(cfi_service, audit_logger, "Writes audit row")
    Rel(cfi_service, redis_cache, "HINCRBY delta")

    Rel(inbox_worker, outbox_poller, "Owns the loop")
    Rel(outbox_poller, outbox_repo, "Claims/updates event_outbox")
    Rel(outbox_poller, cfi_service, "Calls create()")

    Rel(cfi_repo, postgres, "")
    Rel(outbox_repo, postgres, "")
    Rel(redis_cache, redis, "")

    Rel(http_api, pino_logger, "Every request")
    Rel(inbox_worker, pino_logger, "Every event")

    UpdateLayoutConfig($c4ShapeInRow="4", $c4BoundaryInRow="1")
```

## Module map (file layout)

```
src/
  api/                          ← HTTP layer (--mode=api)
    index.ts                    ← Express app bootstrap
    middleware/
      hmac-auth.ts
      request-id.ts
      pino-http.ts
    routes/
      summary.ts
      status.ts
      adjustment.ts
      health.ts                 ← GET /healthz (no auth)
  worker/                       ← inbox worker (--mode=worker)
    index.ts                    ← bootstrap + main loop
    outbox-poller.ts            ← FOR UPDATE SKIP LOCKED claim + status update
    reaper.ts                   ← periodic stale-claim reset
    pruner.ts                   ← periodic deletion of old DONE rows
  shared/                       ← imported by both modes
    db/
      prisma.ts                 ← Prisma client singleton
      tenant-extension.ts       ← Prisma extension injecting tenantId
    redis/
      client.ts                 ← ioredis singleton
      lua/                      ← atomic Lua scripts
        apply-event.lua
    domain/
      cfi.ts                    ← CFI types, status enum, transition table
      payout.ts                 ← computePayoutAmount(amount, adjustment)
      filters.ts                ← Zod schemas for filter inputs
    audit/
      status-logger.ts
      adjustment-logger.ts
  lib/
    logger.ts                   ← pino instance with required fields
    config.ts                   ← env-var parsing
    errors.ts                   ← AppError, TransitionError, AdjustmentLockedError
  index.ts                      ← entry: parse args, branch on --mode
```

## Mode switching

`src/index.ts` is the single binary entry point:

```ts
const mode = process.argv.includes('--mode=api') ? 'api'
           : process.argv.includes('--mode=worker') ? 'worker'
           : (() => { throw new Error('Missing --mode') })();

if (mode === 'api') {
  await import('./api/index.ts');
} else {
  await import('./worker/index.ts');
}
```

The two systemd units differ only in their `ExecStart` flag.
