# C4 — Container View

The container view shows the deployable units: the two Summary Service processes (API and worker), the existing HMS Next.js process, Postgres, and Redis.

```mermaid
C4Container
    title Container View: Summary Service on a single on-prem host

    Person(admin, "Admin", "")

    System_Boundary(c1, "On-Prem Hospital Server") {
        Container(nextjs, "Next.js HMS", "Node.js, React, Prisma, tRPC", "User-facing app + BFF. Existing. Inserts into opd_billings + event_outbox in one tx.")
        Container(api, "Summary Service — API", "Node.js, Express, TypeScript, Prisma", "Read summary; update status; update adjustment. systemd: ycare-summary-api")
        Container(worker, "Summary Service — Worker", "Node.js, Express, TypeScript, Prisma, ioredis", "Polls event_outbox with FOR UPDATE SKIP LOCKED; creates CFIs; updates Redis. systemd: ycare-summary-worker")
        ContainerDb(postgres, "PostgreSQL", "Postgres 15+", "Shared DB. Contains: opd_billings, event_outbox, consultation_fees_invoices, ... audit tables")
        ContainerDb(redis, "Redis", "Redis 7+", "Aggregate counter cache. Keys prefixed by tenant.")
    }

    Rel(admin, nextjs, "Uses", "HTTPS")

    Rel(nextjs, postgres, "INSERT INTO opd_billings + event_outbox in one transaction", "Prisma / 127.0.0.1:5432")
    Rel(nextjs, api, "Reads CFI; updates status/adjustment", "HTTP / 127.0.0.1:4000 (no auth in v1)")

    Rel(api, postgres, "Reads CFI; updates status/adjustment", "Prisma / 127.0.0.1:5432")
    Rel(api, redis, "HGET aggregate counters", "ioredis / 127.0.0.1:6379")

    Rel(worker, postgres, "SELECT ... FOR UPDATE SKIP LOCKED on event_outbox; INSERT CFI", "Prisma + raw SQL / 127.0.0.1:5432")
    Rel(worker, redis, "HINCRBY aggregate counters", "ioredis / 127.0.0.1:6379")

    UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## Container responsibilities

| Container | Role | Port | Restart policy |
|---|---|---|---|
| **Next.js HMS** | User-facing app + BFF | 3000 | (existing) |
| **Summary Service — API** | HTTP API for reads + status/adjustment writes | 4000 (127.0.0.1 only) | `Restart=on-failure`, 5s delay |
| **Summary Service — Worker** | Outbox poller, CFI creator, Redis updater | n/a (no HTTP) | `Restart=on-failure`, 5s delay |
| **PostgreSQL** | Shared DB | 5432 | (existing) |
| **Redis** | Aggregate cache | 6379 (127.0.0.1 only) | (existing post-install) |

## Inter-container communication

- **Next.js → Postgres:** HMS writes `opd_billings` and `event_outbox` in a single transaction. This is the only way the HMS talks to the Summary Service's data layer (ADR 0001).
- **Next.js → Summary API:** HTTP. v1 has no auth; the BFF and the API trust the localhost bind. (v2 will add a real service-to-service auth.)
- **Worker → Postgres:** `SELECT ... FOR UPDATE SKIP LOCKED` on `event_outbox` to claim a batch; `INSERT` to create a CFI; periodic reaper to reset stuck claims; periodic pruner to delete old `DONE` rows.
- **API / Worker → Redis:** ioredis. Localhost only. Read-side cache only; Redis is never on the publish path.

## Why a single host?

The on-prem install is a single server in the hospital. The HMS already runs there. The Summary Service shares the host. This is intentional — operational simplicity wins over modest performance gains from separation. If the host becomes a bottleneck (see `ops/capacity-plan.md`), a second host can be added with Postgres replication.
