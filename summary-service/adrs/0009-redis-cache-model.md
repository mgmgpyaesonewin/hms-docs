# ADR 0009: Redis cache model — aggregate counters only, with HINCRBY updates

- **Status:** Accepted
- **Section in brief:** 7.8

## Context

The admin summary dashboard's "totals" panel must load in <100ms. Computing totals from the `consultation_fees_invoices` table with `GROUP BY status` and `GROUP BY date` is O(N) over potentially hundreds of thousands of rows; it's not fast enough for a dashboard. The filterable list, by contrast, has good Postgres indexes and is fast without a cache.

## Options considered

- **(a) Cache only the aggregate counters in Redis** — Redis `HSET` per `(tenant, date, counter)`; updated incrementally with `HINCRBY` on every event.
- **(b) Cache the full summary list in Redis** — cache the filterable list (with all filter combinations) in Redis. Simpler reads, complex invalidation.
- **(c) Materialized view in Postgres** — `REFRESH MATERIALIZED VIEW CONCURRENTLY` on a schedule. Standard SQL, no new infra.
- **(d) No cache, accept the slow dashboard** — let the dashboard do the GROUP BY every time.

## Decision

**(a) Cache only the aggregate counters in Redis.**

## Rationale

- The aggregate counters are the only thing that benefits from a cache. The filterable list is well-indexed in Postgres and is fast enough.
- HINCRBY updates are atomic, O(1), and survive at-least-once delivery because **idempotency is enforced at the DB level, not Redis**: the `(event_id) UNIQUE` and `(tenant_id, opd_invoice_id) UNIQUE` constraints on `consultation_fees_invoices` ([[0003-idempotency|ADR 0003]], [[0004-uniqueness-for-cfis|ADR 0004]]) cause re-delivery of the same outbox event to fail with Prisma P2002, which the service catches and treats as a no-op (`cfi-service.ts:102`). So the CFI is never created twice, and the Redis counter is therefore updated exactly once per actual CFI row.
- Cache invalidation is straightforward: the source of truth is Postgres; the cache is rebuildable.
- (c) Materialized views work but require refresh jobs and locking. Redis is faster for this read pattern.
- (d) Unacceptable — the dashboard is the headline feature.

## Consequences

- Key shape (v1, per-day only): `summary:consultation_fees:{tenantId}:{YYYY-MM-DD}:all` → HSET with fields:
  - `total` (Int — total consultation fees for the day)
  - `paid_total`, `paid_count`
  - `unpaid_total`, `unpaid_count`
  - `void_total`, `void_count`
  - `payout_total` (sum of `payout_amount` for the day)
  - v1 only ships a single `:all` bucket per (tenant, day). Per-counter bucketing (`{counterId|"all"}`) was a v1+ idea that was deferred — `cfi.routes.ts:104-106` only consults Redis when the request is unfiltered; any filter (`counterId`, `doctorId`, `status`, `from`/`to`) bypasses the cache and runs the GROUP BY in Postgres.
- Updates: after every CFI insert or status change, the worker issues a Redis pipeline of `HINCRBY` / `HINCRBYFLOAT` calls (see `src/lib/redis-counters.ts`). Plain HINCRBY, no Lua. Idempotency is provided by the DB UNIQUE constraints, not by the cache (see Rationale).
- Read fallback: if Redis is down, or the key is missing, the API computes the counter from Postgres on demand (`SELECT status, COUNT(*), SUM(amount) FROM ... WHERE ... GROUP BY status`). Slower but correct. The API response includes a `X-Cache-Status: hit | bypass` header for observability.
- TTL: every key has an expiry — `EXPIRE 86400` (24h) for the active day's buckets, `EXPIRE 604800` (7d) for past-day buckets. The TTL forces periodic refresh from Postgres via cache-aside; cold days are eventually re-read and refreshed; the active day is bounded against drift.
- **No reconciliation job.** Drift heals itself on the read path: if a key is missing, expired, or stale, the next read misses (or has a stale value), recomputes from Postgres, and overwrites. A "Redis was down for a weekend" event costs the first admin page-load per affected day a Postgres GROUP BY — acceptable. This is deliberately simpler than a daily cron rebuilding Redis, which can race with active writes.

## Related

- [[0001-trigger-mechanism|ADR 0001]] (Trigger mechanism)
- [[0003-idempotency|ADR 0003]] (Idempotency)
- [[0010-search-strategy|ADR 0010]] (Search strategy)
- Section 3.3 in the brief
