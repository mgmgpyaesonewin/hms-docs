# ADR 0001: Trigger mechanism — Postgres transactional outbox

- **Status:** Accepted
- **Section in brief:** 7.1

## Context

The HMS must reliably emit an "OPD invoice created" event to the Summary Service whenever an OPD billing row is inserted. The Summary Service depends on this event to create the corresponding `consultation_fees_invoices` row. Hard requirements:

- The HMS must not silently drop an event.
- The event must not double-create on retry.
- Failure of the Summary Service must not block OPD invoice creation in the HMS.
- The trigger must be observable and debuggable from SQL — ops needs to be able to list pending jobs, find stuck jobs, and requeue dead ones without touching application code.

We considered three patterns:

1. **Redis Streams pub/sub** — HMS `XADD`s after commit, worker uses `XREADGROUP` + reconciliation. Sub-second latency, but the `XADD` is a separate step from the DB commit; a crash between the two loses the event. Reconciliation is the safety net.
2. **pg-boss** — the HMS's existing job library. Operational familiarity, but requires the Summary Service to run its own pg-boss instance pointing at the same DB; larger footprint; harder to inspect arbitrary jobs in flight.
3. **Postgres transactional outbox** — HMS inserts an `event_outbox` row in the **same transaction** as the OPD billing. The Summary Service worker polls the outbox with `SELECT ... FOR UPDATE SKIP LOCKED`. True atomicity: the OPD invoice and the outbox row commit together or not at all. Jobs are queryable SQL.

The user chose the **Postgres outbox** because it is easier to search and debug jobs (every job is a row; ops can `SELECT * FROM event_outbox WHERE status='DEAD'`, no need to learn a new tool).

## Decision

**Postgres transactional outbox.** The HMS writes a row to `event_outbox` in the same transaction as the OPD billing insert. The Summary Service worker polls the outbox and processes rows to completion.

### Outbox table

```sql
CREATE TABLE event_outbox (
    id              UUID        PRIMARY KEY DEFAULT uuidv7(),
    tenant_id       UUID        NOT NULL,
    event_type      TEXT        NOT NULL,                -- e.g. 'opd_invoice.created'
    aggregate_id    UUID        NOT NULL,                -- e.g. the opd_invoice_id
    payload         JSONB       NOT NULL,
    status          TEXT        NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING', 'IN_PROGRESS', 'DONE', 'DEAD')),
    attempt_count   INT         NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_by       TEXT,                                -- worker hostname + pid
    locked_at       TIMESTAMPTZ,
    last_error      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at    TIMESTAMPTZ
);

-- The hot-path index for the worker poll
CREATE INDEX idx_outbox_pending
    ON event_outbox (next_attempt_at)
    WHERE status = 'PENDING';

-- The operator-friendly indexes (search/filter)
CREATE INDEX idx_outbox_tenant_created
    ON event_outbox (tenant_id, created_at DESC);
CREATE INDEX idx_outbox_status
    ON event_outbox (status);
CREATE INDEX idx_outbox_aggregate
    ON event_outbox (aggregate_id);
```

Rows are retained for **7 days after `completed_at`** for debugging, then pruned by a daily job.

### Producer (HMS)

At the existing OPD invoice creation site, the HMS already opens a transaction to insert into `opd_billings`. Extend that transaction to also insert the outbox row:

```ts
await prisma.$transaction(async (tx) => {
  const opdBilling = await tx.opdBilling.create({
    data: { /* ... existing fields ... */ }
  });

  await tx.eventOutbox.create({
    data: {
      id: crypto.randomUUID(),
      tenantId,
      eventType: "opd_invoice.created",
      aggregateId: opdBilling.id,
      payload: {
        eventId: crypto.randomUUID(),     // stable; same value the worker uses to dedupe
        tenantId,
        opdInvoiceId: opdBilling.id,
        createdAt: opdBilling.createdAt.toISOString(),
      },
    },
  });
});
```

The outbox row commits atomically with the OPD billing. There is no window where the OPD invoice exists without an outbox event. The HMS does not need Redis at the publish path.

### Consumer (Summary Service worker)

The worker runs a tight poll loop:

```ts
while (!shutdownRequested) {
  // 1. Claim a batch atomically
  const claimed = await prisma.$transaction(async (tx) => {
    const rows = await tx.$queryRaw<OutboxRow[]>`
      SELECT id, tenant_id, event_type, aggregate_id, payload, attempt_count
      FROM event_outbox
      WHERE status = 'PENDING'
        AND next_attempt_at <= now()
      ORDER BY next_attempt_at ASC
      LIMIT ${BATCH_SIZE}
      FOR UPDATE SKIP LOCKED
    `;
    if (rows.length === 0) return [];
    await tx.$executeRaw`
      UPDATE event_outbox
      SET status = 'IN_PROGRESS',
          locked_by = ${WORKER_ID},
          locked_at = now(),
          attempt_count = attempt_count + 1
      WHERE id = ANY(${rows.map(r => r.id)})
    `;
    return rows;
  });

  // 2. Process each event independently (no transaction spans the batch)
  for (const row of claimed) {
    try {
      await processEvent(row);                  // creates CFI; updates Redis
      await markDone(row.id);
    } catch (err) {
      await handleFailure(row, err);            // retry-with-backoff, or move to DEAD
    }
  }

  if (claimed.length === 0) await sleep(POLL_INTERVAL_MS);   // idle backoff
}
```

Key properties:

- **`FOR UPDATE SKIP LOCKED`** lets multiple workers (or a future second host) run safely without double-processing.
- **Each event is processed in its own transaction.** The CFI insert and the outbox status update commit independently. The outbox status update is what marks the event "done"; the CFI row has its own `event_id` UNIQUE for additional safety.
- **Bounded latency** at ~`POLL_INTERVAL_MS` (default 1000ms = 1s). Lower is possible (e.g. 100ms) at the cost of idle DB load.
- **Hot-path index** (`idx_outbox_pending`) is a partial index on `status = 'PENDING'`, so the poll query stays fast as the table grows.

### Failure handling

| Failure | What the worker does |
|---|---|
| `processEvent` throws a transient error (DB timeout, Redis down) | `UPDATE event_outbox SET status = 'PENDING', next_attempt_at = now() + interval '2^attempt_count seconds', last_error = $err WHERE id = $1`. Backs off exponentially up to 5 minutes. |
| `processEvent` throws a non-retryable error (parse failure, schema violation) | `UPDATE event_outbox SET status = 'DEAD', last_error = $err, completed_at = now() WHERE id = $1`. The event is no longer polled; an operator can inspect it and either fix the cause and reset to `PENDING` or `DELETE`. |
| `attempt_count >= 5` | Move to `DEAD` regardless of error type. Caps infinite retry storms. |
| Worker crashes between claim and `markDone` | The row stays in `IN_PROGRESS` forever. A **stale-claim reaper** (see below) resets it to `PENDING` after 5 minutes of `locked_at` age. |
| Worker is down for an extended period | The outbox grows. A reaper and an alert keep the queue bounded. |

### Stale-claim reaper (every 5 minutes)

The reaper resets rows that are stuck in `IN_PROGRESS` (e.g. the worker crashed):

```sql
UPDATE event_outbox
SET status = 'PENDING',
    locked_by = NULL,
    locked_at = NULL,
    last_error = coalesce(last_error, '') || ' [reaper: stale claim reset at ' || now()::text || ']'
WHERE status = 'IN_PROGRESS'
  AND locked_at < now() - interval '5 minutes';
```

This is the outbox-equivalent of the Redis Streams `XAUTOCLAIM` recovery. Because the original CFI insert is gated by the `(tenant_id, opd_invoice_id)` UNIQUE constraint, the reap+reprocess flow is safe — at worst we get a no-op insert.

### Daily pruning (every day at 03:30)

```sql
DELETE FROM event_outbox
WHERE status = 'DONE'
  AND completed_at < now() - interval '7 days';
```

7 days of history is enough to investigate a customer report ("yesterday's OPD invoice didn't get a CFI"). 7 days of `DONE` rows × ~250 events/day = ~1,750 rows — trivial size.

## Why outbox (and not Redis Streams, not pg-boss)?

- **Atomicity.** The OPD billing insert and the outbox row commit in the same DB transaction. There is no window where one exists without the other. Redis Streams had a "crash between commit and XADD" window that required a reconciliation safety net.
- **Debuggability.** `SELECT * FROM event_outbox WHERE status='DEAD'` finds stuck jobs. `SELECT * FROM event_outbox WHERE aggregate_id='<opd_invoice_id>'` finds every event for a given OPD invoice. `SELECT count(*), status FROM event_outbox GROUP BY status` is the health dashboard. None of these require learning a new tool.
- **No new infra.** The HMS already has Postgres. pg-boss would require running a second job-runtime pointed at the same DB; Redis Streams would require Redis to be available for the publish path.
- **At-least-once + idempotency = exactly-once effect.** The outbox is at-least-once (a claim can be reaped and re-processed). The `(tenant_id, opd_invoice_id)` UNIQUE constraint on the CFI (ADR 0004) plus the `event_id` UNIQUE constraint (ADR 0003) make re-processing a no-op.

The trade-off accepted: **1-second poll latency** instead of sub-second `XREADGROUP` delivery. For an admin summary dashboard, 1s is invisible.

## Consequences

- **New HMS table:** `event_outbox`. Lives in the HMS Postgres, owned by the HMS team.
- **HMS code change:** at the OPD billing insertion site, add one `tx.eventOutbox.create(...)` call inside the existing transaction. No new client library required (uses the existing Prisma client).
- **HMS does not depend on Redis for the publish path.** Redis is purely a read-side cache.
- **Worker code:** ~150 lines for the poll loop, plus the stale-claim reaper and the daily pruner. Uses raw SQL for the `FOR UPDATE SKIP LOCKED` claim (Prisma's query API does not expose `SKIP LOCKED` directly).
- **Polling latency:** ~1s in steady state. Tunable via `POLL_INTERVAL_MS`.
- **Outbox size:** with daily pruning, the table stays under 2,000 rows in steady state. Even at 100x growth it's under 200,000 rows — the partial index keeps the poll query fast.
- **Multi-tenant safety:** the outbox carries `tenant_id`; the worker reads it and includes it in the CFI payload. The `payload` JSONB includes the full event context, so the worker can re-create the CFI without an additional query to `opd_billings` (though it does query to compute the consultation fee; see ADR 0002 for the fee-computation flow).
- **No "lost event" failure mode.** The outbox either committed with the OPD billing or it didn't. The previous Streams design had to add a 5-minute reconciliation job to compensate for the lost-event window; that is no longer needed.

## Future evolution: when to add pub/sub

The outbox is the **foundation**, not the ceiling. It is intentionally chosen over Redis Streams today so that we have a durable, queryable, replayable event log to build on — without locking into a specific streaming technology. Pub/sub enters the picture only when a concrete second consumer justifies the operational cost.

### When NOT to add pub/sub

- **When there is only one consumer.** v1 has one consumer: the Summary Service worker. Pub/sub's value is fan-out to multiple subscribers. With one subscriber, every claim about "low-latency streaming" is unused capacity.
- **When the consumer doesn't need sub-second latency.** An admin summary dashboard refreshing every few seconds does not. The 1s poll latency is invisible. Add `LISTEN/NOTIFY` first (see "Open follow-ups" below) before reaching for a streaming platform.
- **When "event-driven" is the goal in name only.** Adopting Redis Streams today would buy a marketing term, not a capability we use. The Summary Service does not push to a notification feed, an analytics warehouse, or an audit log in v1.

### When to add pub/sub (and how)

The trigger is concrete: **a second consumer with different latency, replay, or fan-out needs.** Likely candidates in this product's roadmap:

| Future consumer | Why it wants pub/sub | Upgrade path |
|---|---|---|
| Doctor payout workflow (v2+) | Needs to react to `PAID` events in real time to disburse; outbox poll is fine for minutes, but not for the "doctor just got paid" UX | Outbox + `LISTEN/NOTIFY` first; if it grows to many payout subscribers, Debezium CDC. |
| Real-time admin notification feed | WebSocket/SSE push to the admin UI when a CFI status changes; needs < 100ms latency | `LISTEN/NOTIFY` on the outbox, or Debezium if history-replay is needed. |
| Analytics / BI export | Nightly or hourly rollup of consultation fees by doctor, counter, department | Outbox nightly batch read; no pub/sub needed unless it becomes real-time. |
| Audit log forwarder | Stream every state change to a separate audit DB or external SIEM | Debezium CDC. |

For each of these, the outbox is the **source of truth** — and the new consumer is added on top of it, not instead of it. Two upgrade paths exist:

1. **`LISTEN/NOTIFY` on the outbox.** 5-20 lines of code. The Postgres trigger fires `NOTIFY` on insert; a new consumer `LISTEN`s. Latency drops from ~1s to ~10ms. Good for "a few subscribers that all want low latency". No new infra.

2. **Debezium CDC → Kafka / Kinesis / a real stream.** Runs Debezium against the `event_outbox` table; Postgres turns into a logical event stream that any number of consumers can subscribe to. You get outbox's durability (rows are persisted before consumers see them) + the fan-out of a streaming platform. Use this when you have 3+ subscribers, or when you need exactly-once, replay-from-history-beyond-`MAXLEN`, or cross-region replication.

### Why not start with pub/sub from day one?

- **Plain Redis pub/sub is fire-and-forget** — no durability. It fails the "no lost CFI" requirement outright and is not on the table.
- **Redis Streams** (durable pub/sub) is the real alternative. It would buy us:
  - Sub-second latency (vs. outbox's 1s poll — but `LISTEN/NOTIFY` closes that gap without new infra).
  - A consumer-group / `XACK` model (but `FOR UPDATE SKIP LOCKED` is equivalent in SQL).
  - Multiple consumers on the same stream (but we have one consumer; the second is hypothetical).

  At the cost of:
  - Coupling HMS correctness to Redis uptime on the publish path.
  - Replacing SQL-queryable jobs with `XINFO` / `XRANGE` for debugging.
  - A new operational subsystem (consumer groups, `MAXLEN` trimming, dead-letter streams) for what is currently one row in one table.

The outbox gives us a more durable, more queryable, less-coupled foundation than locking into Redis Streams now. The migration cost of "add pub/sub on top of the outbox" is small; the migration cost of "remove Redis Streams and replace with outbox because we outgrew it" is large.

### Decision

Stay with outbox for v1. Re-evaluate when the second consumer lands, not before. The future upgrade path is `outbox` → `outbox + LISTEN/NOTIFY` → `outbox + Debezium CDC → streaming platform`, in that order, only as far as the use case requires.

## Open follow-ups (not blocking v1)

- **LISTEN/NOTIFY acceleration.** The poll loop wakes up every second. Postgres `LISTEN 'event_outbox_new'` (with `NOTIFY` on insert) could wake the worker instantly, falling back to poll on missed notifications. v1 stays with pure polling; v2 can add `LISTEN/NOTIFY` for sub-100ms latency. This is the **first** upgrade to make if latency becomes a problem.
- **Multiple workers.** v1 runs a single worker. The `FOR UPDATE SKIP LOCKED` design supports N workers; just need to ensure each has a unique `WORKER_ID`.
- **Outbox observability dashboard.** A v2 ops view: `SELECT date_trunc('hour', created_at), status, count(*) FROM event_outbox GROUP BY 1, 2 ORDER BY 1 DESC LIMIT 48;` is the health rollup.

## Related

- ADR 0002 (Service decomposition — the worker is the consumer of this outbox)
- ADR 0003 (Idempotency — the `event_id` UNIQUE constraint on the CFI)
- ADR 0004 (Uniqueness for CFIs — the `(tenant_id, opd_invoice_id)` constraint that makes re-processing safe)
- ADR 0012 (Failure modes — the "stuck IN_PROGRESS" case)
- ADR 0011 (Observability — outbox counters in logs)
- `diagrams/sequences.md` — the "create CFI" sequence diagram uses this design
- Section 3.1, 7.1 in the brief
