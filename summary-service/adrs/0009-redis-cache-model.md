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
- HINCRBY updates are atomic, O(1), and survive at-least-once delivery if we use a Redis Lua script that compares event_id before mutating (see Consequences).
- Cache invalidation is straightforward: the source of truth is Postgres; the cache is rebuildable.
- (c) Materialized views work but require refresh jobs and locking. Redis is faster for this read pattern.
- (d) Unacceptable — the dashboard is the headline feature.

## Consequences

- Key shape: `summary:consultation_fees:{tenantId}:{YYYY-MM-DD}:{counterId|"all"}` → HSET with fields:
  - `total` (Int — total consultation fees for the day)
  - `paid_total`, `paid_count`
  - `unpaid_total`, `unpaid_count`
  - `void_total`, `void_count`
  - `payout_total` (sum of `payout_amount` for the day)
- Updates: after every CFI insert or status change, the worker issues a Redis pipeline of `HINCRBY` calls. Idempotency: the worker uses a Redis Lua script that checks the event_id against a per-key `seen_events` set before mutating; if the event_id was already seen, the script no-ops. This makes HINCRBY safe under at-least-once delivery.
- Read fallback: if Redis is down, the API computes the counter from Postgres on demand (`SELECT status, COUNT(*), SUM(amount) FROM ... WHERE ... GROUP BY status`). Slower but correct. The API response includes a `X-Cache-Status: hit | bypass` header for observability.
- TTL: every key has an expiry — `EXPIRE 86400` (24h) for the active day's buckets, `EXPIRE 604800` (7d) for past-day buckets. The TTL forces periodic refresh from Postgres via cache-aside; cold days are eventually re-read and refreshed; the active day is bounded against drift.
- **No reconciliation job.** Drift heals itself on the read path: if a key is missing, expired, or stale, the next read misses (or has a stale value), recomputes from Postgres, and overwrites. A "Redis was down for a weekend" event costs the first admin page-load per affected day a Postgres GROUP BY — acceptable. This is deliberately simpler than a daily cron rebuilding Redis, which can race with active writes.

## Related

- ADR 0001 (Trigger mechanism)
- ADR 0003 (Idempotency)
- ADR 0010 (Search strategy)
- Section 3.3 in the brief
