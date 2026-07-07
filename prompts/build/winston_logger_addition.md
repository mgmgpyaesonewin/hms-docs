# Add winston to hms-summary-service

Replace pino with winston in `hms-summary-service` so both containers emit logs
in the same format and style. `hms-app` already uses winston.

## Background

- Stack: `hms-summary-service` — Node 20 + Express + Prisma + pino (current).
- Stack: `hms-app` — Next.js 15 + winston (target format source of truth).
- Both services share the same Postgres; both run as their own container.
- Production: two systemd units (`ycare-summary-api`, `ycare-summary-worker`)
  on the on-prem HMS host. Docker is CI/test only.

## Goal

A detailed implementation spec (no code changes yet). The spec is the
deliverable. Do not write code in this phase.

## Context to read first (cite relevant lines in the spec)

- `hms-summary-service/src/lib/logger.ts` — current pino setup, level, redaction, default fields (tenantId, etc.).
- `hms-summary-service/src/workers/*` and `hms-summary-service/src/http/*` — every logger call site. Count them. List any non-default usage.
- `hms-app/` — find its winston config and log format definition. Copy the exact format string, level policy, and transport config into the spec verbatim.
- `hms-summary-service/package.json` — note pino + pino-pretty current versions (for removal).
- `hms-summary-service/.env.example` — list every log-related env var to add or rename.

## Required spec sections (markdown, in this order)

1. **Scope** — one paragraph: what changes, what does not.
2. **Current state** — pino usage in `hms-summary-service`: file list, call count, fields used.
3. **Target state** — winston config mirroring `hms-app`: line layout, severity policy, transports (stdout/file), redaction list, default fields (`tenantId`, `requestId`, `service`, `env`, `version`).
4. **File-by-file change list** — for each file: action (create/modify/delete), summary of diff. Include new `src/lib/logger.ts` winston wrapper that preserves the current exported API so call sites only need an `import` line change.
5. **Env vars** — add / rename / remove, with defaults.
6. **Test plan** — one Jest unit test verifying log line shape (JSON, required fields, redaction works) + one manual smoke-test command per mode (api, worker).
7. **Migration / cutover** — order of operations, rollback.
8. **Open questions** — anything that needs a human answer (e.g. log shipping destination, retention).

## Constraints

- Do not propose a new logging library other than winston.
- Do not change call sites except `import` lines; the logger wrapper preserves the current pino-like API (`logger.info({ tenantId, ... }, "msg")`).
- Do not propose splitting into a shared `@hms/logger` package in v1 — call it out as future work if relevant.
- Match `hms-app`'s line layout and severity style verbatim; if `hms-app` has any inconsistency, flag it and ask, do not silently normalize.

## Output contract

- Markdown only.
- No code blocks longer than 20 lines.
- Every section header from the list above must appear.
- At the end, print a one-line summary: `Spec length: <sections> sections, <words> words.`