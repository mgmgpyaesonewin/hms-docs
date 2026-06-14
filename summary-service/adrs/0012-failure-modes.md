# ADR 0012: Failure modes — exhaustive enumeration, one-line response per case

- **Status:** Accepted
- **Section in brief:** 7.11

## Context

An on-prem service has to be designed for the host going down, the network blipping, the DB rejecting connections, and Redis dying. The Summary Service has two roles (API and worker) with different failure profiles. The design must enumerate the realistic failure modes and specify the response for each.

## Decision

Exhaustive enumeration of failure modes. The response for each must be specified in `diagrams/sequences.md` and tested in the runbook (`ops/runbook.md`).

## Failure modes and responses

| # | Failure | Response |
|---|---|---|
| 1 | Worker crashes mid-event-processing — DB commit succeeded, Redis update not yet done | DB row is committed (CFI exists with the event's data); outbox row is NOT marked processed (the transaction is `INSERT cfi; UPDATE outbox SET status='DONE', completed_at=now()`; if the worker dies between the two, the outbox row stays unprocessed). On next poll, the event is reprocessed. The `event_id` unique constraint on CFI causes the re-insert to be a no-op; the outbox row is then marked processed. Redis update runs at the end and is safe under at-least-once (see ADR 0009). Net effect: no data loss, possibly one extra Redis write. |
| 2 | Outbox poll query times out / DB temporarily unavailable | Worker logs a warning, sleeps for an exponential-backoff interval (max 60s), retries. systemd does not restart the unit for transient DB issues. |
| 3 | Redis is down during event processing | The DB transaction commits; the worker catches the Redis exception, logs a warning, marks the outbox row as processed (so we don't loop forever), and continues. The Redis aggregate for that day is stale. The next read of that bucket misses (or has a stale value), recomputes from Postgres via cache-aside, and overwrites — self-healing. No reconciliation job is needed. |
| 4 | Redis is down during a read | The API falls back to computing the counter from Postgres (see ADR 0009). Response includes a `X-Cache-Status: bypass` header. |
| 5 | Status update requested on a CFI that is not `UNPAID` | API returns `409 Conflict` with `{ code: "INVALID_TRANSITION", currentStatus: "...", requestedStatus: "..." }`. The BFF translates to a user-friendly "this invoice has already been paid / voided" message. |
| 8 | Summary Service is offline for an extended period; large outbox backlog | The outbox grows. The HMS continues to write new events; nothing is lost. When the Summary Service comes back, the worker drains the backlog at its steady-state rate (~10 events/second; a week of backlog drains in a few minutes). Any Redis keys that expired during the outage are repopulated lazily on the next read. |
| 9 | A single outbox event causes the worker to crash every time (poison message) | The worker wraps each event in a `try / catch`; a poison event is logged with `level: error` and the outbox row is marked as `attempt_count = attempt_count + 1`. After N=5 attempts, the row's `status` is set to `DEAD` in the outbox (no separate table) and an alert is sent. The row stays in the outbox with a longer retention (30 days, vs 7 days for `DONE`) so the operator can inspect, fix the root cause, and reset to `PENDING` or `DELETE`. The worker continues processing the next event. |

## Consequences

- New `event_outbox` columns: `attempt_count INT NOT NULL DEFAULT 0` (already in the DDL).
- No new tables. DEAD rows stay in `event_outbox` with a longer pruner retention (30 days, configured via `OUTBOX_DEAD_RETENTION_DAYS`).
- The worker has a `tryProcessEvent(event)` function that wraps the whole flow in `try / catch`; any exception triggers the poison-message logic.
- The API has explicit `try / catch` blocks for Redis errors that fall back to Postgres (per ADR 0009).
- The runbook (`ops/runbook.md`) covers each of these failure modes with a "what to do" procedure.

## Edge cases (low likelihood, documented for completeness)

These cases have a defensive design but are not expected to fire under normal operation. They are not in the main table so the runbook stays focused on the likely cases.

| # | Failure | Response |
|---|---|---|
| 6 | Status update requested on a CFI from a different tenant | API returns `404 Not Found` (not `403 Forbidden` — don't leak the existence of a cross-tenant row). Defense comes from the HMAC `X-Tenant-Id` being part of the canonical string (ADR 0008), the `tenantId` on every query (Prisma extension, ADR 0007), and the per-tenant Redis key prefix. This case should be unreachable in practice. |
| 7 | Two workers running simultaneously (split-brain) | The outbox poll uses `FOR UPDATE SKIP LOCKED`, so two workers cannot process the same outbox row. The CFI insert uses the unique `event_id` constraint, so a race between two workers processing different events for the same OPD invoice (shouldn't happen, but defensively) results in one insert winning. No data corruption. v1 runs a single worker; this defense supports a future horizontal scale. |
| 10 | Host clock skew between BFF and service | The ±5-minute HMAC timestamp window (ADR 0008) tolerates up to 5 minutes of skew. Larger skew breaks auth. systemd-timesyncd (or chrony) is configured on the host to keep time in sync via NTP — the hospital's network setup is expected to provide an NTP source. |

## Related

- ADR 0009 (Redis cache model — covers failure modes 3, 4)
- ADR 0008 (HMAC auth — covers failure mode 10)
- ADR 0001 (Outbox — covers failure mode 8)
