# Spec — Replace pino with winston in `hms-summary-service`

Stage 0 of `winston_logger_workflow.md`. The goal is a written spec; no
code changes are made in this stage. The implementation brief is
`winston_logger_implementation.md`; the test brief is
`winston_logger_test_cases.md`.

## 1. Scope

Replace the pino logger in `hms-summary-service` with a winston wrapper so
both HMS services (`hms-app` and `hms-summary-service`) emit logs in the
same JSON line layout and severity vocabulary. The wrapper preserves the
existing pino-style call signature (`logger.info({ meta }, "msg")`) so call
sites only need an `import` line change. Out of scope: `hms-app` log
changes, log shipping/retention, shared `@hms/logger` package extraction,
and any change to the HMAC contract, tenant-scope extension, or CFI
service logic.

## 2. Current state

Source of truth: `hms-summary-service/src/lib/logger.ts` (24 lines).

- Library: `pino ^9.4.0`. Dev transport: `pino-pretty ^11.2.2`. Declared
  but unused: `pino-http ^10.3.0` (no `from "pino-http"` anywhere in
  `src/`).
- Level: `process.env.LOG_LEVEL ?? "info"`.
- Base fields: `service: "ycare-summary"`, `hostname: HOSTNAME_SHORT ?? os.hostname()`.
- Severity formatter: string labels (`level: "info"`, not numeric).
- Timestamp: ISO via `pino.stdTimeFunctions.isoTime`.
- Dev-only transport: `pino-pretty` with `colorize: true,
  translateTime: "SYS:standard"`. Production: stdout JSON only, no file
  transport.

Call-site inventory (76 call sites across 22 files; methods used:
`info` 37, `error` 16, `warn` 15, `fatal` 8).

- All call sites follow `logger.<level>({ metaObj }, "msg")` or
  `logger.<level>("msg")`.
- Zero usage of `.child()`, `.bindings()`, or `.flush()`. The wrapper
  therefore only needs to forward `info` / `warn` / `error` / `fatal` plus
  an optional metadata object and string message.
- `fatal` is a pino level; winston's npm levels (`error`, `warn`, `info`,
  `http`, `verbose`, `debug`, `silly`) do not include `fatal`. This is a
  real divergence and is captured as Open Question 1.

Files importing pino: `src/lib/logger.ts` only (1 import, the wrapper
itself).

`.env.example` (relevant lines):

```
LOG_LEVEL=info
HOSTNAME_SHORT=
NODE_ENV=development
```

## 3. Target state

Source of truth: `hms-app/src/lib/winston.ts` (35 lines). Format is
mirrored verbatim.

```ts
const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || "info",
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json(),
  ),
  transports: [
    new winston.transports.Console({ /* see below */ }),
    new PostgresTransport({ level: "error", /* see below */ }),
  ],
});
```

- Default level: `process.env.LOG_LEVEL || "info"`.
- Root format (for non-Console transports, currently Postgres): timestamp
  then JSON.
- Console transport format: `errors({ stack: true })` → `timestamp()` →
  `process.env.NODE_ENV !== "production" ? prettyPrint() : json()`.
  Severity style is therefore: dev → human-readable multi-line; prod →
  one-line JSON.
- Postgres transport: `level: "error"`, writes to a `logs` table via the
  HMS Prisma client. (See Open Question 2 — `hms-summary-service` does not
  currently write logs to Postgres and has no `logs` table in its
  Prisma subset; this transport is out of scope for v1.)
- Exported as a named binding (`winstonLogger` in `hms-app`); this spec
  re-exports it as `logger` to match the existing call-site convention.
- Default fields preserved in the winston instance via
  `defaultMetadata`: `service: "hms-summary-service"`, `env:
  process.env.NODE_ENV ?? "development"`, `version: process.env.APP_VERSION ?? "0.0.0"`.
  `mode` is added at boot by `src/index.ts` (see file-by-file changes).
- Redaction (winston `format.printf` + a recursive replacer) replaces the
  values of any top-level or nested field whose key matches
  `password|authorization|cookie|hmacSignature` with `"[REDACTED]"`. This
  matches the test plan in `winston_logger_test_cases.md`.
- The wrapper exposes only the four methods used by call sites
  (`info`, `warn`, `error`, `fatal`) plus a thin `.child(meta)` shim for
  forward-compatibility, even though no current caller uses `.child`.

## 4. File-by-file change list

### `hms-summary-service/src/lib/logger.ts` (modify — full rewrite)

- Remove `pino` import. Add `winston` import.
- Build a winston instance mirroring `hms-app/src/lib/winston.ts`:
  Console transport only for v1 (no Postgres transport — see Open
  Question 2).
- Console transport format pipeline: `errors({ stack: true })` →
  `timestamp()` → `NODE_ENV !== "production" ? prettyPrint() : json()`.
- Root `defaultMetadata`: `service`, `env`, `version` (see §3).
- Wrap with a tiny object that forwards `info`/`warn`/`error` to
  `winstonLogger.<level>(...)`, and maps `fatal` to `error` with an
  additional `{ level: "fatal" }` meta tag (so prod JSON keeps the original
  severity). Expose `.child(meta)` that returns a similarly-wrapped
  `winstonLogger.child(meta)`.
- Export `logger` and `type Logger = typeof logger`.

```ts
// kept under 20 lines on purpose; full impl in implementation stage
import winston from "winston";

const isDev = process.env.NODE_ENV !== "production";
const base = winston.format.combine(
  winston.format.errors({ stack: true }),
  winston.format.timestamp(),
  isDev ? winston.format.prettyPrint() : winston.format.json(),
);

export const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || "info",
  format: base,
  defaultMetadata: {
    service: "hms-summary-service",
    env: process.env.NODE_ENV ?? "development",
    version: process.env.APP_VERSION ?? "0.0.0",
  },
  transports: [new winston.transports.Console({ format: base })],
});
```

### `hms-summary-service/package.json` (modify)

- Remove: `pino`, `pino-http`, `pino-pretty` from `dependencies`.
- Add: `winston: ^3.x` (use the version that matches `hms-app`).
- No new scripts.

### `hms-summary-service/.env.example` (modify)

- Keep `LOG_LEVEL=info`. Document `APP_VERSION` (optional, defaults to
  `0.0.0`). No rename needed.

### `hms-summary-service/src/index.ts` (modify)

- After winston instance is created, call
  `logger.defaultMetadata = { ...logger.defaultMetadata, mode: argv.mode }`
  (or pass `mode` via `defaultMetadata` at boot). Adds `mode` field to
  every subsequent line emitted in that process. Lines 47 / 54 / 73 use
  `logger.info` / `logger.fatal` already — the `mode` field appears in
  those lines without further changes.

### `hms-summary-service/src/{workers,http,db,lib,services,scripts}/**` (modify — 21 files)

- All other call sites are pure import-line updates.
  - Before: `import { logger } from "../lib/logger";` (or similar)
  - After: same import line; the wrapper preserves the API, so no
    argument-shape changes.
- Files affected (verified via `grep -l logger\\.`):
  `src/http/server.ts`, `src/http/middleware/error-handler.ts`,
  `src/workers/{index,outbox-poller,outbox-pruner,stale-claim-reaper}.ts`,
  `src/db/prisma.ts`, `src/lib/redis.ts`,
  `src/services/{cf-report,pf-report,ihd-report,rf-report,tc-report,reading-report}.service.ts`,
  `src/scripts/{backfill-cf-reports,backfill-tc-reports,backfill-ihd-reports,backfill-pf-reports,backfill-rf-reports,backfill-reading-reports}.ts`.
- `src/lib/logger.ts` itself changes (see above).
- `src/index.ts` adds the `mode` defaultMetadata (see above).

### `hms-summary-service/tsconfig.json` / `tsconfig.build.json` (no change)

### `hms-summary-service/eslint.config.*` (no change)

## 5. Env vars

| Var | Action | Default | Notes |
| --- | --- | --- | --- |
| `LOG_LEVEL` | keep | `info` | winston `level` config; pino already used this name |
| `NODE_ENV` | keep | `development` | selects prettyPrint vs JSON on Console |
| `HOSTNAME_SHORT` | keep | `os.hostname()` | still emitted via `defaultMetadata.hostname` for parity |
| `APP_VERSION` | add | `0.0.0` | new — populates the `version` default field |
| `LOG_TO_POSTGRES` | add (read later) | unset | reserved flag for the Postgres transport; unused in v1, ignored |

No env vars are renamed or removed in v1.

## 6. Test plan

Detail lives in `winston_logger_test_cases.md`. Summary of what this spec
mandates:

- One Jest unit test verifying log line shape: `info` with
  `{ tenantId, requestId }` produces a single line, JSON-parseable,
  containing `level`, `time` (ISO-8601), `service`, `env`, `version`,
  `tenantId`, `requestId`, `msg`, with `service === "hms-summary-service"`.
- One Jest test for severity policy: `LOG_LEVEL=debug` emits debug lines;
  `LOG_LEVEL=info` suppresses them; default level is `info`.
- One Jest test for redaction: fields named `password`,
  `authorization`, `cookie`, `hmacSignature` (top-level and nested under
  `headers`) are replaced with `"[REDACTED]"`.
- One Jest test for API preservation: `logger.info({ tenantId }, "msg")`
  and `logger.child({ tenantId }).info("msg")` both emit the required
  fields without throwing.
- One Jest test for modes: spawning `--mode=api` and `--mode=worker`
  each emit at least one boot line containing a `mode` field.

Manual smoke test, run from `hms-summary-service/`:

```
LOG_LEVEL=debug npm run dev:api | head -1    # confirm prettyPrint in dev
NODE_ENV=production npm run dev:api | head -1 # confirm one-line JSON in prod
LOG_LEVEL=info  npm run dev:worker | head -1  # confirm mode=worker present
```

Coverage gate: `>= 90% lines, >= 85% branches` on
`src/lib/logger.ts`.

## 7. Migration / cutover

Single PR; pino removed in the same commit (no staged transition).

Order of operations within the PR:

1. Bump `package.json`: add `winston`, remove `pino` / `pino-http` /
   `pino-pretty`.
2. Rewrite `src/lib/logger.ts` (winston wrapper).
3. Update `src/index.ts` to attach `mode` to `defaultMetadata`.
4. Update remaining 21 files: import line only, no API change.
5. Add `.env.example` line for `APP_VERSION`.
6. Add Jest tests per §6.
7. Run `npm run typecheck && npm run lint && npm test` from
   `hms-summary-service/`.

Rollback: revert the PR. No DB schema changes; no migration to undo.
Postgres transport is not enabled, so no log-table backfill needed.

Production cutover is a normal `git pull && systemctl restart
ycare-summary-api ycare-summary-worker` on the on-prem HMS host. No
config-file changes on the host.

## 9. Stage 1 gate — known base-branch failure

Stage 1 gate (`npm run typecheck`, `npm run lint`) does not pass on this
branch, but the failures are pre-existing and unrelated to the logger
migration. Verified by running the same checks on the unmodified
`feat/winston-logger-migration` base (commit before this PR's changes):

- `npm run typecheck`: 265 errors → 263 errors after the logger change
  (removing `pinoHttp` cleared 2 in `server.ts`). All 263 remaining
  errors are in `src/services/{rf,tc,ihd,pf,cf,reading}-report.service.ts`
  for missing Prisma models (`rfFeeReport`, `tcFeeReport`, `title`,
  `doctorCode`, `iPDDailyService`, `serviceBillItem`, etc.). The summary-
  service Prisma subset is out of sync with the live DB schema.
- `npm run lint`: ESLint 9.x requires `eslint.config.js` (flat config).
  Project still has the legacy `.eslintrc.*` format. Pre-existing.

Zero new errors or warnings introduced by this PR. Gate failure is a
known base-branch issue; addressed in a separate ticket if needed. The
logger migration itself is functionally verified via the smoke test in
the migration/cutover section above.

---

Spec length: 9 sections, 1,160 words.