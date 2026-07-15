# ADR 0013: Backup and recovery — Postgres is the backup, Redis is rebuildable

- **Status:** Accepted
- **Section in brief:** 7.12

## Context

The new tables (`consultation_fees_invoices`, `consultation_fees_invoice_status_changes`, `consultation_fees_invoice_adjustments`, `event_outbox`) live in the existing HMS Postgres database. Redis is a new dependency that holds only derived state (aggregate counters). The design must specify how to back up and recover from the loss of either.

## Options considered

- **(a) Postgres backup covers everything (existing policy); Redis is rebuildable from Postgres on demand**
- **(b) Add a separate Redis backup (RDB snapshots) for fast warm-start**
- **(c) Run a Redis replica for HA** (overkill — single host, no HA in v1)

## Decision

**(a) Postgres backup covers everything; Redis is rebuildable from Postgres on demand.**

## Rationale

- The new tables are in the same DB as the HMS — the existing backup policy covers them by default. No new backup configuration needed.
- Redis state is entirely derivable from Postgres. Losing Redis means: empty cache, repopulated lazily on first read via cache-aside (slow but correct). No reconciliation job, no startup hook — the next admin page-load per affected day triggers a Postgres `GROUP BY` and the bucket is warm again. TTL on keys forces periodic refresh.
- A Redis backup (option b) would speed up cold starts, but on a single on-prem host with no HA, the cost of an extra cron job and the disk space for RDB snapshots is not justified. The dashboard's "slow" first page load after a Redis loss is acceptable.

## Consequences

- **Postgres backup:** no change. The existing hospital backup policy (whatever it is — daily `pg_dump` and/or WAL archiving) covers all new tables.
- **Redis backup:** none. Redis is treated as ephemeral.
- **Redis disaster recovery procedure:**
  1. Restart Redis (or restore from a fresh install).
  2. No action needed in the worker. The first read of each bucket that the admin visits will recompute from Postgres via cache-aside and write the Redis key. The dashboard is fully warm within minutes of normal use.
- **Postgres disaster recovery:** the hospital's existing Postgres restore procedure covers everything. No new procedure.
- **Outbox table cleanup:** a daily pruner deletes `DONE` rows older than 7 days and `DEAD` rows older than 30 days (configurable via `OUTBOX_DONE_RETENTION_DAYS` and `OUTBOX_DEAD_RETENTION_DAYS`). The pruner is the worker's responsibility and runs on a configurable interval (default 24h) alongside the outbox poll and the reaper.

## Related

- [[0009-redis-cache-model|ADR 0009]] (Redis cache model)
- [[0011-observability|ADR 0011]] (Observability)
- [[ops/runbook|ops/runbook.md]] — "rebuild Redis" procedure
