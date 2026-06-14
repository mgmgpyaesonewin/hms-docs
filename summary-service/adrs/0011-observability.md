# ADR 0011: Observability — pino structured logs, audit table, no metrics in v1

- **Status:** Accepted
- **Section in brief:** 7.10

## Context

The Summary Service runs on a single on-prem host with no external observability stack. The operator (hospital IT) needs to know: is the service running, are errors happening, what state is the queue in, who changed what on which CFI. The design must be useful for daily operations without requiring new infrastructure (Prometheus / Grafana / Loki / etc.).

## Options considered

- **(a) Pino structured logs to stdout + a rotation-friendly log file; audit table in Postgres; no metrics in v1**
- **(b) Add Prometheus metrics on a `/metrics` endpoint** (port 4001) scraped by a local Prometheus + Grafana.
- **(c) Ship logs to an external SaaS** (Datadog, Sentry, etc.) — not viable on-prem with no internet.

## Decision

**(a) Pino structured logs + Postgres audit table. No metrics in v1.**

## Rationale

- Structured JSON logs are easy to grep, easy to feed to `logrotate`, and the hospital's existing IT tooling can handle them.
- The audit trail for state changes is the database itself (`consultation_fees_invoice_status_changes`, `consultation_fees_invoice_adjustments`) — a richer source than logs.
- Prometheus + Grafana (option b) is the right answer at cloud scale. On a single on-prem host with no scraping infrastructure, it's overkill. If the hospital later wants metrics, the Prometheus client is a small addition; the `/metrics` endpoint can be added in v2.
- External SaaS (option c) is not viable on-prem.

## Consequences

- **Logger:** `pino` with `pino-pretty` for development, plain JSON in production. Log level configurable via `LOG_LEVEL` env var (default `info`).
- **Required fields on every log line:** `timestamp`, `level`, `tenantId`, `requestId` (UUID per request), `service` ("summary-api" or "summary-worker"), `msg`. Optional fields: `eventId`, `invoiceId`, `userId`, `durationMs`, `error.code`, `error.message`.
- **Log files:**
  - `/var/log/ycare-summary/api.log` — API logs
  - `/var/log/ycare-summary/worker.log` — worker logs
  - `/var/log/ycare-summary/error.log` — error-level lines from both, for grep-friendly alerting
- **Log rotation:** `logrotate` config in `ops/observability.md`. Daily rotation, 90-day retention, gzip compression. Reopen-on-rotate via `pino` + `logrotate`'s `copytruncate` directive (or `SIGUSR1`-based reopen — `pino` supports this).
- **Audit tables:** `consultation_fees_invoice_status_changes` and `consultation_fees_invoice_adjustments` are the audit trail. Indefinite retention (covered by Postgres backup).
- **No automated alerting in v1.** systemd's `Restart=on-failure` brings the unit back on a crash; the operator monitors health via `journalctl -u ycare-summary-api -u ycare-summary-worker -f` and the structured log files under `/var/log/ycare-summary/`. If the hospital later wants push-based alerts (webhook, email, pager), they can drop in `monit`, a healthchecks.io ping, or a Nagios check against `/healthz` — none of which are designed now. The system already produces the right signal in logs; the alerting delivery is a v2 concern.
- **No metrics in v1.** If the operator needs a counter (e.g., "how many CFIs created today"), they query Postgres directly: `SELECT count(*) FROM consultation_fees_invoices WHERE created_at::date = current_date;`. Good enough for v1.

## Related

- `ops/observability.md` for the full spec
- ADR 0012 (Failure modes — the structured logs are how we diagnose these)
