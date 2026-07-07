# Implement winston in hms-summary-service

Invoke the **`/senior-backend`** skill. The implementation sub-agents execute
this brief after the spec (`winston_logger_addition.md`) is approved.

## Goal

Implement the spec end-to-end. The deliverable is a working branch where
`hms-summary-service` logs via winston in the same format as `hms-app`, with
`npm run typecheck`, `npm run lint`, and `npm test` all green.

## Inputs

- **Approved spec**: `hms-docs/prompts/build/winston_logger_addition.md`.
- **Source of truth for format**: `hms-app/` winston config (read first; copy verbatim where the spec says "mirror").
- **Target service**: `hms-summary-service/` (current logger: `src/lib/logger.ts`, current call sites under `src/workers/*` and `src/http/*`).

## Sub-agent dispatch (one agent per concern, parallelize where independent)

| Agent | Skill | Owns |
| --- | --- | --- |
| `coder-logger` | `/senior-backend` | New `src/lib/logger.ts` (winston wrapper preserving pino-like API), env config, `.env.example` updates, `package.json` swap (remove pino + pino-pretty, add winston + winston transports). |
| `coder-call-sites` | `/senior-backend` | Update every `import { logger } from ...` call site; no API-shape changes. |
| `coder-tests` | `/senior-qa` (see `winston_logger_test_cases.md`) | Jest unit tests for log line shape, redaction, required fields. |
| `reviewer-overbuild` | `/ponytail:ponytail-review` (see `winston_logger_review.md`) | Over-engineering audit. |
| `reviewer-correctness` | `/code-reviewer` (see `winston_logger_review.md`) | Correctness + reuse review. |

`coder-logger` and `coder-call-sites` must run sequentially — the wrapper
has to exist before call sites import it. Reviewers run after both coders.

## Constraints (carry over from spec, do not relax)

- Wrap winston so call sites keep `logger.info({ tenantId }, "msg")` style.
- No new shared package in v1.
- Match `hms-app` line layout and severity style verbatim.
- No silent normalization — flag and ask if `hms-app` is inconsistent.

## Definition of done

- `npm run typecheck`, `npm run lint`, `npm test` all green from `hms-summary-service/`.
- `grep -r "from \"pino\"" hms-summary-service/src` returns nothing.
- One-line sample log line from `npm run dev:api` matches the `hms-app` line layout byte-for-byte (excluding service name and timestamp).
- `winston_logger_review.md` passes both reviewers with zero blocker findings.
- Migration / rollback section of the spec is honored (pino removed in the same commit, not staged).

## Out of scope

- Log shipping destination, retention, alerting.
- Migrating any `hms-app` logs.
- Shared `@hms/logger` package extraction.