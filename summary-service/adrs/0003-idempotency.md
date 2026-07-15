# ADR 0003: Idempotency — unique event_id on the CFI row

- **Status:** Accepted
- **Section in brief:** 7.3

## Context

The outbox delivers events at-least-once. The worker may receive the same `event_id` twice (worker crash after inserting the CFI but before marking the outbox row processed; or a polling overlap). The system must not double-create a CFI from a single event.

## Options considered

- **(a) Unique constraint on `event_id` in `consultation_fees_invoices`** — insert collision is treated as "already processed" and the worker advances.
- **(b) Worker-side dedup table** — separate table tracking processed event_ids; checked before insert.
- **(c) Idempotency token in the Redis aggregate** — store the last processed event_id in Redis, skip if seen.

## Decision

**(a) Unique constraint on `event_id` in `consultation_fees_invoices`.**

## Rationale

- Postgres does the dedup; the worker is a 5-line `try / catch (unique violation) / advance`.
- No new table or new dependency. The constraint is part of the schema.
- The unique key is `event_id` itself, not `(tenant_id, opd_invoice_id)` — see [[0004-uniqueness-for-cfis|ADR 0004]] for that decision.

## Consequences

- Schema: `event_id UUID NOT NULL UNIQUE` on `consultation_fees_invoices`.
- Worker code: `INSERT INTO consultation_fees_invoices (event_id, ...) VALUES (...) ON CONFLICT (event_id) DO NOTHING RETURNING id;` — if no row returned, the event was already processed; the worker marks the outbox row as processed and moves on.
- This relies on `ON CONFLICT DO NOTHING` semantics being safe in a transactional context with subsequent side effects. The worker wraps the insert and the `event_outbox.status = 'DONE' / completed_at = now()` update in a single transaction so that if the insert is a no-op, the mark-processed still happens.
- Redis updates are NOT inside this transaction (Redis is not transactional with Postgres). The Redis update runs after the DB commit, with its own at-least-once delivery. See [[0009-redis-cache-model|ADR 0009]] for the Redis idempotency strategy.

## Related

- [[0001-trigger-mechanism|ADR 0001]] (Trigger mechanism)
- [[0004-uniqueness-for-cfis|ADR 0004]] (Uniqueness for CFIs)
- [[0009-redis-cache-model|ADR 0009]] (Redis cache model)
