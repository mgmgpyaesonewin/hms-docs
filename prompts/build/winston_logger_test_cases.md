# Test cases for winston in hms-summary-service

Invoke the **`/senior-qa`** skill. Test-authoring sub-agents execute this
brief after implementation lands.

## Goal

Cover the log contract defined in `winston_logger_addition.md` with Jest
tests that fail loudly if any of the invariants break.

## Inputs

- Approved spec: `hms-docs/prompts/build/winston_logger_addition.md`.
- Implementation branch (post-`coder-logger` + `coder-call-sites`).
- Test framework: Jest (already configured in `hms-summary-service/`).
- Mirror target for expected line shape: `hms-app/` winston output.

## Required tests

One test file per concern under `hms-summary-service/src/lib/__tests__/`
(or `src/lib/__tests__/logger/`):

1. **`logger.test.ts` — log line shape**
   - `info` with `{ tenantId, requestId }` produces a single line.
   - Line is valid JSON.
   - Required fields present: `level`, `time` (ISO-8601), `service`, `env`, `version`, `tenantId`, `requestId`, `msg`.
   - `service` equals `hms-summary-service`.
2. **`logger.test.ts` — severity policy**
   - `LOG_LEVEL=debug` shows `debug` lines; `LOG_LEVEL=info` suppresses them.
   - Default level is `info` when `LOG_LEVEL` unset.
3. **`logger.test.ts` — redaction**
   - Any field named `password`, `authorization`, `cookie`, or `hmacSignature` is replaced with `"[REDACTED]"`.
   - Nested redaction works (`{ headers: { authorization: "x" } }` redacts).
4. **`logger.test.ts` — pino-like API preserved**
   - `logger.info({ tenantId }, "msg")` and `logger.child({ tenantId }).info("msg")` both emit the same required fields without throwing.
5. **`modes.test.ts` — api vs worker boot**
   - Spawning `--mode=api` and `--mode=worker` each emit at least one boot line containing the mode in a `mode` field.

## Constraints

- Use Jest only (no new framework). Mock stdout capture via `jest.spyOn(process.stdout, 'write')`.
- Tests must not depend on real env vars — inject via `process.env` in `beforeEach` / `afterEach`.
- Tests must not flake on timing; assert on shape, not line count.
- Do not add tests for behaviors not in the spec. If you spot a gap, file it as an **Open question** in the spec, do not silently expand scope.

## Definition of done

- All five files exist and pass under `npm test` from `hms-summary-service/`.
- Coverage on `src/lib/logger.ts` ≥ 90% lines, ≥ 85% branches.
- One-line test report at the end of the run: `Tests: <pass>/<total> passed, coverage: <lines>% lines / <branches>% branches.`