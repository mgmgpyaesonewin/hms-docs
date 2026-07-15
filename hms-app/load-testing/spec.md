# Load & Stress Test Suite — `@hms-app`

> **Status:** Draft
> **Author:** Claude (spec-driven workflow)
> **Date:** 2026-07-08
> **Reviewers:** HMS app team, SRE/clinic ops
> **Target service:** `hms-app` (Next.js 15 monolith) running on the pre-prod host
> **Out of scope (this spec):** the `hms-summary-service` Express binary — separate spec
>
> **Related:** [[INDEX]] · [[hms-app/README]] · [[hms-app/SPEC]] · [[hms-app/load-testing/workflow|companion workflow]]

---

## 1. Context

The HMS handles OPD billing, appointments, pharmacy, lab, EMR, and IPD workflows. Clinic staff use it during operating hours; performance regressions on the read path (OPD list/detail) directly block doctors and billing staff from seeing today's queue. The app currently has zero automated load or stress testing — capacity is implicit and discovered by incident.

This spec defines a four-scenario suite (load, stress, soak, spike) for the read-heavy OPD surface using **k6** + **k6-reporter**, executed against a pre-prod host that mirrors production sizing. Goals:

1. Detect throughput/latency regressions before they reach prod.
2. Find the breaking point of the current single-host deployment.
3. Catch memory leaks, connection-pool exhaustion, and pg-boss queue backlogs.
4. Produce HTML reports a non-engineer (clinic ops, product owner) can read.

Baseline numbers are documented as **assumptions** because no production telemetry is available yet; thresholds are intentionally conservative and tagged for re-calibration after the first real run.

---

## 2. Functional Requirements

### 2.1 Tooling & layout

- **FR-1.** The suite MUST be implemented in [k6](https://k6.io/) (Go engine, JS test scripts).
- **FR-2.** The suite MUST produce a self-contained HTML report per run via [`k6-reporter`](https://github.com/benc-uk/k6-reporter). No external report server.
- **FR-3.** The suite MUST live under `hms-app/load-tests/` with this layout (ponytail: single binary, no extra services):
  ```
  hms-app/load-tests/
  ├── lib/
  │   ├── http.js              # k6 http helpers + tRPC caller
  │   ├── auth.js              # login + cookie/header capture
  │   ├── config.js            # env-driven BASE_URL, VU counts, thresholds
  │   └── data.js              # seed tenant/doctor/patient ID lookups
  ├── scenarios/
  │   ├── load.js              # 10-min sustained peak
  │   ├── stress.js            # step-ramp to cliff
  │   ├── soak.js              # 2-hr moderate
  │   └── spike.js             # 60s 10× burst
  ├── scripts/
  │   ├── run-all.sh           # runs all four in sequence, writes reports/
  │   └── seed-verify.ts       # asserts pre-seeded data is in place; halts on miss
  ├── reports/                 # .gitkeep; HTML/JSON output (gitignored)
  ├── package.json             # k6 + @benc-uk/k6-reporter pinned versions
  └── README.md                # how to run; how to read the report
  ```
- **FR-4.** All scenario scripts MUST source thresholds, VU counts, and durations from `lib/config.js` (env-driven). No magic numbers inside scenario files.
- **FR-5.** The suite MUST depend only on: `k6` (system binary) and the `k6-reporter` npm package used by a thin Node post-processor. **No new runtime dependency may be added to `hms-app/package.json`.**

### 2.2 Authentication & session handling

- **FR-6.** Each virtual user MUST authenticate exactly once per scenario, then reuse the session cookie for the duration of that VU's iterations.
- **FR-7.** Login MUST go through the tRPC `auth` router at `POST ${BASE_URL}/api/trpc/auth.login` (form-encoded body, JSON in `input`). On 200, the response sets a session cookie — k6 MUST capture and replay it.
- **FR-8.** Login credentials MUST come from a pre-seeded pool of N test users (N ≥ VU peak) in the staging DB. **Plaintext credentials MUST NOT be committed.** Read from `load-tests/.env.test` (gitignored) or from a k6 environment variable file. See §8 Data Models.
- **FR-9.** If a login response is not 200, the VU MUST abort its iteration and emit a tagged metric `auth_failures` so the failure is visible in the report.

### 2.3 Scenarios (read-heavy OPD)

- **FR-10.** All four scenarios MUST target the OPD read path: **list** (paginated, with filters) and **detail** (single record by id).
- **FR-11.** The OPD list procedure MUST be invoked as a tRPC call: `POST ${BASE_URL}/api/trpc/opdBilling.list?batch=1` with a `superjson`-serialized input `{ pageSize, cursor?, filters? }`.
- **FR-12.** The OPD detail procedure MUST be invoked as: `POST ${BASE_URL}/api/trpc/opdBilling.getById?batch=1` with input `{ id: <uuid> }`. IDs MUST be drawn from the pre-seeded OPD billings (§8).
- **FR-13.** The list/detail mix in every scenario MUST be **80% list / 20% detail** by iteration count.
- **FR-14.** Filter usage on the list call MUST be exercised. 50% of list calls MUST include at least one filter (e.g. `doctorId`, `dateFrom`/`dateTo`); the remaining 50% MUST be unfiltered. This stresses both the cache-friendly and cache-bypass code paths.
- **FR-15.** The script MUST NOT exercise any write path (create OPD billing, payment, etc.). Writes are out of scope for this spec (§9).
- **FR-16.** The script MUST NOT call any procedure from the summary-service. That service is a separate binary with separate auth (HMAC) and is not in scope.

### 2.4 Scenario definitions

> Baseline VU/RPS numbers are tuned for **clinic peak hours** (single-clinic scale). See §4 NFRs for thresholds.

- **FR-17. Load scenario** (`scenarios/load.js`): 10 minutes sustained, 50 VUs, `ramping-arrival-rate` executor targeting 10 RPS. Goal: confirm production peak is safe.
- **FR-18. Stress scenario** (`scenarios/stress.js`): `ramping-arrival-rate` stepping 1 → 5 → 10 → 20 → 40 → 60 RPS, 3 min per step. Goal: find the cliff (first step where `http_req_failed` > 1% OR `http_req_duration` p99 > 3s for 30s consecutive).
- **FR-19. Soak scenario** (`scenarios/soak.js`): 2 hours sustained, 30 VUs, constant 5 RPS. Goal: detect Node heap growth, Postgres connection-pool leaks, pg-boss queue backlog.
- **FR-20. Spike scenario** (`scenarios/spike.js`): `ramping-arrival-rate` baseline 5 RPS for 2 min → spike to 50 RPS for 60s → back to 5 RPS for 2 min. Goal: model clinic opening / shift change.

### 2.5 Reporting

- **FR-21.** Each scenario run MUST write:
  - `${reports}/<scenario>-<timestamp>.json` — raw k6 output
  - `${reports}/<scenario>-<timestamp>.html` — k6-reporter HTML
- **FR-22.** The HTML report MUST surface at the top: pass/fail status per threshold, a per-scenario summary card, and a latency distribution chart. (This is the non-technical-friendly requirement; the default k6-reporter output already meets this.)
- **FR-23.** `scripts/run-all.sh` MUST execute all four scenarios sequentially and emit a combined `reports/index.html` linking to the four individual reports. The index MUST mark each scenario pass/fail by parsing each report's threshold summary.

### 2.6 CI & execution

- **FR-24.** Running the suite MUST be a single command: `npm run loadtest` from `hms-app/`. Under the hood it calls `bash load-tests/scripts/run-all.sh`.
- **FR-25.** The suite MUST be runnable on the staging host by an operator with `ssh` access. It MUST NOT require any new infrastructure (no Grafana, no InfluxDB, no k8s job runner). k6 binary + Node 20 LTS are the only prerequisites.
- **FR-26.** The suite MUST fail fast (`--exit-on-error` semantics via k6 thresholds) if the seed-verify precheck fails.

---

## 3. Non-Functional Requirements

> All numbers in this section are **assumptions** to be re-calibrated after the first real run on staging. They are flagged as such in §9.

### 3.1 Performance thresholds (k6 `thresholds`)

- **NFR-1.** Load scenario: `http_req_duration` p95 MUST be `< 500ms`, p99 `< 1500ms`.
- **NFR-2.** All scenarios: `http_req_failed` rate MUST be `< 0.5%` (i.e. > 99.5% success).
- **NFR-3.** All scenarios: `http_req_duration` for `opdBilling.list` MUST have p95 `< 500ms` (tagged threshold using k6 group/metric tags).
- **NFR-4.** Soak scenario: Node process RSS on the target host (sampled every 5 min via `ps` on the host) MUST NOT grow by more than **25%** over the 2-hour window. Sampling is done by `scripts/host-sample.sh` invoked by `run-all.sh` before/after.
- **NFR-5.** Stress scenario: the suite MUST emit a `cliffs_found` custom summary metric listing the first RPS step at which NFR-2 or NFR-3 failed for ≥ 30s consecutive. This is the actionable output for the SRE.

### 3.2 Reliability & repeatability

- **NFR-6.** Re-running the suite against the same staging DB MUST produce results within ±10% of the previous run, provided the staging host is not concurrently serving other load.
- **NFR-7.** The suite MUST NOT mutate the pre-seeded data. List/detail are read-only; the seed-verify script MUST re-assert the row counts of `Patient`, `Doctor`, `OpdBilling` before each run.
- **NFR-8.** The suite MUST tolerate a single VU failing its login (NFR-7's precheck does not depend on the run succeeding once). It MUST NOT tolerate a scenario-wide login failure — abort and report.

### 3.3 Operability

- **NFR-9.** The k6 binary version MUST be pinned in `hms-app/load-tests/package.json` `engines` and a `load-tests/.tool-versions` file. Documented minimum: k6 v0.50+.
- **NFR-10.** The `README.md` MUST explain, in < 10 lines of non-engineer English, what each HTML report's pass/fail badge means.

---

## 4. Acceptance Criteria

> All ACs are machine-verifiable. Each references an FR or NFR.

- **AC-1.** *Given* the staging host is up and the pre-seeded DB has ≥ 5,000 `OpdBilling` rows, *when* an operator runs `npm run loadtest` from `hms-app/`, *then* `load-tests/scripts/run-all.sh` executes all four scenarios sequentially without manual intervention. (FR-24)
- **AC-2.** *Given* the load scenario completes, *when* the operator opens `reports/load-<timestamp>.html`, *then* the report's header shows a pass/fail badge for the NFR-1 thresholds and a latency distribution chart. (FR-22, NFR-1)
- **AC-3.** *Given* the stress scenario completes, *when* the operator reads its report, *then* the report surfaces the `cliffs_found` summary metric indicating the breaking-point RPS step. (NFR-5, FR-18)
- **AC-4.** *Given* the soak scenario completes, *when* the operator inspects `reports/soak-<timestamp>.html` together with `host-sample.log`, *then* the suite flags a fail if the target Node process grew > 25% over 2 hours. (NFR-4)
- **AC-5.** *Given* the spike scenario completes, *when* the report's per-step latency is inspected, *then* the report must show a visible recovery: latency during the post-spike baseline MUST be within 10% of the pre-spike baseline. (FR-20)
- **AC-6.** *Given* a pre-seeded DB with 50 test users, *when* the load scenario runs at 50 VUs, *then* 50 distinct user sessions MUST be in flight concurrently (verifiable via `auth.active_sessions` gauge emitted by k6). (FR-6, FR-8)
- **AC-7.** *Given* a successful load scenario, *when* the seed-verify script is re-run immediately after, *then* the row counts of `Patient`, `Doctor`, and `OpdBilling` MUST match the pre-run counts exactly. (NFR-7)
- **AC-8.** *Given* any scenario exceeds its `http_req_failed` threshold (NFR-2), *when* the k6 run exits, *then* the exit code MUST be non-zero so CI/operators can detect failure. (NFR-2, k6 default behavior)
- **AC-9.** *Given* a non-engineer (e.g. clinic ops) opens the combined `reports/index.html`, *when* they read the pass/fail row, *then* they can identify which scenarios passed and which failed without reading k6 internals. (FR-23, NFR-10)
- **AC-10.** *Given* the staging DB lacks the required seed (fewer than 5,000 `OpdBilling` rows), *when* `seed-verify.ts` runs, *then* it MUST exit non-zero with a clear message naming the missing table/row-count, and the scenario scripts MUST NOT run. (FR-26, NFR-7)

---

## 5. Edge Cases

- **EC-1.** Staging host is unreachable → `seed-verify.ts` fails with network error; scenarios do not run. (FR-26)
- **EC-2.** Staging DB is reachable but seed data is missing → see AC-10. (FR-26)
- **EC-3.** Login endpoint returns 500 → VU tags the iteration with `auth_failures` and continues. After 5 consecutive auth failures, scenario aborts to avoid wasting load. (FR-9, NFR-8)
- **EC-4.** tRPC batch endpoint rejects the request format (e.g. server-side regression) → the failure surfaces as `http_req_failed` and is captured by the threshold (NFR-2). Reporter will surface the failed group.
- **EC-5.** tRPC response is 200 but `result.data` contains a tRPC error code (`PARSE_ERROR`, `INTERNAL_SERVER_ERROR`) → the VU's check function MUST count it as a failure. Implement via k6 `check()` with custom assertion on response body. (NFR-2)
- **EC-6.** Postgres connection pool on the target is exhausted under stress → the symptom is increased `http_req_duration` and rising 500-rate. Stress scenario's `cliffs_found` will identify the RPS step at which this manifests. (NFR-5)
- **EC-7.** k6 binary version on the operator's host is older than pinned minimum → `package.json` `engines` check (or `run-all.sh` version check) MUST fail fast with the required version. (NFR-9)
- **EC-8.** Staging host runs another load test concurrently (operator double-launch) → out of scope; `run-all.sh` is not expected to prevent this. Documented in README.
- **EC-9.** pg-boss queue (background jobs) is backlogging during soak → host-sample script MAY include a `pg-boss:queue_size` snapshot via `psql` if credentials permit; otherwise out of scope and noted in §9.
- **EC-10.** HMAC call to `hms-summary-service` from the HMS BFF slows the response path (indirect dependency) → indirectly observable as increased OPD list latency, surfaced by NFR-1 threshold.

---

## 6. API Contracts (under test)

> k6 calls these directly over HTTP. The agent implementing this spec MUST verify the exact procedure names and input shapes against `hms-app/src/lib/trpc/routers/` and the OPD billing procedures before writing the script.

### 6.1 Login

```http
POST ${BASE_URL}/api/trpc/auth.login?batch=1
Content-Type: application/json

{
  "0": {
    "json": { "username": "<test_user_n>", "password": "<test_password>" }
  }
}
```

- **Success (200):** response body shape per tRPC batch protocol; `Set-Cookie` header on the same response carries the session cookie. k6 captures it via `http.cookieJar` (default in k6 v0.50+).
- **Failure (401/403):** body contains `{ "0": { "error": { "json": { ... } } } }`. k6's check function asserts `response.status === 200`.

### 6.2 OPD billing list

```http
POST ${BASE_URL}/api/trpc/opdBilling.list?batch=1
Content-Type: application/json
Cookie: <session from login>

{
  "0": {
    "json": {
      "pageSize": 20,
      "cursor": null,
      "filters": { "doctorId": "<uuid>" }   // present in 50% of list calls
    }
  }
}
```

- **Success (200):** `{ "0": { "result": { "data": { "json": { "items": [...], "nextCursor": "..." } } } } }` (superjson-wrapped — k6 MUST parse with `JSON.parse` and navigate).
- **Failure:** tRPC error inside `result.data` (e.g. `UNAUTHORIZED`) → k6 check treats as failure.

### 6.3 OPD billing detail

```http
POST ${BASE_URL}/api/trpc/opdBilling.getById?batch=1
Content-Type: application/json
Cookie: <session from login>

{
  "0": { "json": { "id": "<opd_billing_uuid>" } }
}
```

- **Success (200):** single record with line items, doctor ref, patient ref.
- **Failure:** 404 (record not found — k6 should never see this if seed is correct; surfaces as test bug).

### 6.4 Server identification

```http
GET ${BASE_URL}/healthz
```

- Returns 200 with `{ "status": "ok" }` or similar. Used by `seed-verify.ts` as a basic liveness check before the run. **Note:** if `hms-app` does not expose `/healthz`, replace with a lightweight auth-less route (e.g. `/api/trpc/health.ping?batch=1`) and document the choice. **Verification needed before implementation** — see §10 plan, step 1.

---

## 7. Data Models (seed)

> The staging DB is pre-seeded by ops/SRE; this spec does NOT define the seeding process, only the shape the load tests depend on.

| Table | Minimum rows | Notes |
| --- | --- | --- |
| `Tenant` | 1 | Single-tenant staging; tests run within this tenant. |
| `User` | 50 (1 per VU peak + buffer) | Username pattern `loadtest_<n>`; passwords stored in `load-tests/.env.test` (gitignored), NOT in DB. Role: at least `opd.billing.read` permission. |
| `Doctor` | 50 | Used in `filters.doctorId` to vary list responses. |
| `Patient` | 5,000 | Realistic patient pool so list queries don't over-cache. |
| `OpdBilling` | 5,000 | Spread across last 90 days. `doctorId` and `patientId` FKs valid. |
| `EventOutbox` | n/a | Read path does not touch this; out of scope. |

### 7.1 Seed-verification contract

`scripts/seed-verify.ts` MUST `prisma db execute` (or `psql`) the following assertions before each run and abort on any miss:

```sql
SELECT COUNT(*) FROM "User" WHERE username LIKE 'loadtest_%';  -- >= 50
SELECT COUNT(*) FROM "Doctor";                                  -- >= 50
SELECT COUNT(*) FROM "Patient";                                 -- >= 5000
SELECT COUNT(*) FROM "OpdBilling";                              -- >= 5000
SELECT 1 FROM "User" WHERE username = 'loadtest_1';             -- exact
```

Pre- and post-run row counts of `OpdBilling` MUST match (NFR-7).

---

## 8. Out of Scope

- **OS-1.** The `hms-summary-service` Express binary. Separate spec. (Reason: different process, different auth, different port; load testing it would conflate two systems' capacity.)
- **OS-2.** Write paths (creating OPD billing, payments, pharmacy, lab orders). (Reason: this spec is explicitly read-heavy per user direction. Writes need their own seed strategy and would also load the outbox table — separate concern.)
- **OS-3.** Production traffic capture / replay. (Reason: requires prod access and a different toolchain — not requested.)
- **OS-4.** Synthetic data generation. (Reason: the user specified a pre-seeded staging DB; generation scripts belong to a separate seeding effort owned by SRE.)
- **OS-5.** Multi-host / horizontal scaling tests. (Reason: staging is a single host; horizontal scaling needs a k8s target — not in scope.)
- **OS-6.** Frontend (browser) performance — that is Lighthouse, not k6. (Reason: different tool, different question.)
- **OS-7.** Calibrating the baseline numbers (50 VUs, 5–10 RPS) from real production telemetry. (Reason: no telemetry available. After the first real run, ops should re-run with actual peak numbers and update §3 + §2.4. This is documented as a follow-up in §10.)
- **OS-8.** pg-boss queue-depth sampling. (Reason: requires `psql` access with appropriate creds; can be added later as a host-sample extension. EC-9 captures this.)
- **OS-9.** SLO/SLA definitions for the HMS overall. (Reason: this spec defines load-test thresholds, not contractual SLOs. That is a separate product/ops conversation.)

---

## 9. Implementation Plan (handoff to next agent)

> This section is the "pick-up cold" plan. Another agent should be able to implement the suite top-to-bottom from this section + the requirements above, without re-deriving design choices.

### Step 0. Confirm prereqs (one-time, ~10 min)

- [ ] **Verify `BASE_URL` and the health check route.** The `hms-app` Next.js server runs on `PORT=3000` (per `hms-app/server.ts`). Confirm whether `/healthz` exists; if not, identify a lightweight auth-less route and document the choice in `load-tests/README.md`. **Do not skip — this is the seed-verify liveness probe.**
- [ ] **Verify the exact tRPC procedure names** for:
  - `auth.login` — should be in `hms-app/src/lib/trpc/routers/auth.ts`
  - `opdBilling.list` and `opdBilling.getById` — likely in `hms-app/src/app/(dashboard)/opd/...` or registered in `hms-app/src/lib/trpc/routers/`. **This spec assumes the names; the agent MUST verify and correct the call sites in `lib/http.js`.**
- [ ] **Verify tRPC batch protocol payload shape.** Next.js 15 + tRPC v11 uses `?batch=1` with inputs keyed by string index (`"0": { "json": ... }`). Confirm against `hms-app/src/lib/trpc/`. (The spec's §6 reflects the expected shape; verify before writing the script.)

### Step 1. Initialize the package (~20 min)

```bash
cd hms-app
mkdir -p load-tests/{lib,scenarios,scripts,reports}
cat > load-tests/package.json <<'EOF'
{
  "name": "@hms-app/load-tests",
  "version": "0.1.0",
  "private": true,
  "engines": { "k6": ">=0.50.0", "node": ">=20" },
  "scripts": {
    "loadtest": "bash scripts/run-all.sh",
    "loadtest:load":   "k6 run scenarios/load.js   --out json=reports/load.json && k6-reporter reports/load.json",
    "loadtest:stress": "k6 run scenarios/stress.js --out json=reports/stress.json && k6-reporter reports/stress.json",
    "loadtest:soak":   "k6 run scenarios/soak.js   --out json=reports/soak.json && k6-reporter reports/soak.json",
    "loadtest:spike":  "k6 run scenarios/spike.js  --out json=reports/spike.json && k6-reporter reports/spike.json"
  },
  "devDependencies": { "@benc-uk/k6-reporter": "latest" }
}
EOF
touch load-tests/reports/.gitkeep
```

Install k6 binary per the project's preferred install method (apt on the staging host, or via `nfpm`/`brew` on the operator's dev box). Document in `load-tests/README.md`.

### Step 2. Write `lib/config.js` (~15 min)

Single source of truth for all tunable values. Read from env vars with defaults:

```js
// load-tests/lib/config.js
export const BASE_URL    = __ENV.BASE_URL    || 'http://127.0.0.1:3000';
export const LOAD_VUS    = parseInt(__ENV.LOAD_VUS    || '50', 10);
export const LOAD_RPS    = parseInt(__ENV.LOAD_RPS    || '10', 10);
export const SOAK_VUS    = parseInt(__ENV.SOAK_VUS    || '30', 10);
export const SOAK_DURATION = __ENV.SOAK_DURATION || '2h';
export const STRESS_STEPS = JSON.parse(__ENV.STRESS_STEPS || '[1,5,10,20,40,60]');
export const STRESS_STEP_DURATION = __ENV.STRESS_STEP_DURATION || '3m';
export const SPIKE_BURST_RPS = parseInt(__ENV.SPIKE_BURST_RPS || '50', 10);
export const THRESHOLDS = {
  p95_ms:        parseInt(__ENV.THRESHOLD_P95_MS        || '500', 10),
  p99_ms:        parseInt(__ENV.THRESHOLD_P99_MS        || '1500', 10),
  error_rate:    parseFloat(__ENV.THRESHOLD_ERROR_RATE  || '0.005'),
  soak_growth:   parseFloat(__ENV.THRESHOLD_SOAK_GROWTH || '0.25'),
};
```

### Step 3. Write `lib/auth.js` and `lib/http.js` (~30 min)

- `auth.js`: exports `login(vuId)` that POSTs to `${BASE_URL}/api/trpc/auth.login?batch=1` with credentials `loadtest_<vuId>` from `__ENV`, captures the cookie via k6's built-in cookie jar (no manual `Set-Cookie` parsing), returns the response object. On non-200, returns `null` and tags iteration with `auth_failures`.
- `http.js`: exports `trpcCall(procedureName, input, cookie)` that POSTs to `${BASE_URL}/api/trpc/${procedureName}?batch=1` with the tRPC batch payload shape (§6), returns the response. Exports a `checkTrpcOk(res)` helper that asserts `res.status === 200` AND `JSON.parse(res.body)[0].result.data.json` does NOT contain an `error` key.

### Step 4. Write `lib/data.js` (~20 min)

- `data.js`: exports `pickOpdBillingId()` that reads from a pre-loaded array of UUIDs populated at scenario start. The array is populated via a tRPC list call (one-time, before VU loop) to avoid hardcoding IDs. If the list call returns < 100 rows, abort with clear error (NFR-7).
- `pickDoctorId()`: similar, but for filter variation (pre-load 50 doctor IDs).
- `pickUserCredentials(vuId)`: returns `{ username: \`loadtest_${vuId}\`, password: __ENV[`LT_PASS_${vuId}`] }`. The env file is generated by ops, not by this script.

### Step 5. Write the four scenarios (~60 min total)

Each follows the same skeleton:

```js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { BASE_URL, ... } from '../lib/config.js';
import { login } from '../lib/auth.js';
import { trpcCall, checkTrpcOk } from '../lib/http.js';
import { pickOpdBillingId, pickDoctorId } from '../lib/data.js';

export const options = {
  scenarios: { /* per-scenario executor config */ },
  thresholds: { /* per-NFR */ },
  summaryTrendStats: ['avg', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  const session = login(__VU);  // FR-6
  if (!session) { return; }
  // 80% list, 20% detail
  if (Math.random() < 0.8) {
    const filters = Math.random() < 0.5 ? { doctorId: pickDoctorId() } : null;
    const res = trpcCall('opdBilling.list', { pageSize: 20, cursor: null, filters }, session.cookie);
    checkTrpcOk(res);
  } else {
    const res = trpcCall('opdBilling.getById', { id: pickOpdBillingId() }, session.cookie);
    checkTrpcOk(res);
  }
  sleep(Math.random() * 2 + 1);  // 1–3s think time
}
```

Per-scenario options:

| Scenario | Executor | Stages |
| --- | --- | --- |
| load | `ramping-arrival-rate` | target 10 RPS, 50 pre-allocated VUs, 10m |
| stress | `ramping-arrival-rate` | start 1 RPS, steps per `STRESS_STEPS`, 3m each, 50 pre-allocated VUs |
| soak | `constant-arrival-rate` | 5 RPS, 2h, 30 VUs |
| spike | `ramping-arrival-rate` | 5 RPS 2m → 50 RPS 60s → 5 RPS 2m |

Stress custom summary: emit `cliffs_found` (NFR-5) by computing the first RPS step where `http_req_failed` rate exceeded `THRESHOLDS.error_rate` for ≥ 30s. Implement in a `handleSummary` function.

### Step 6. Write `scripts/seed-verify.ts` (~30 min)

A standalone Node script (uses Prisma) that:
1. Pings `${BASE_URL}/healthz` (or the verified alternative from Step 0).
2. Connects to the staging DB using `DATABASE_URL` from `load-tests/.env.test`.
3. Runs the row-count checks from §7.1.
4. Records pre-run row counts in `load-tests/.snapshot.json` for the post-run check.
5. Exits non-zero on any failure with a clear message.

A second script `scripts/seed-snapshot-verify.ts` re-runs the same checks and asserts post == pre (NFR-7).

### Step 7. Write `scripts/run-all.sh` (~30 min)

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> k6 version:"; k6 version

echo "==> seed precheck"
node scripts/seed-verify.ts || { echo "FATAL: seed precheck failed"; exit 1; }

TS=$(date -u +%Y%m%dT%H%M%SZ)
declare -A RESULTS

for SCENARIO in load stress soak spike; do
  echo "==> running $SCENARIO"
  if k6 run "scenarios/${SCENARIO}.js" \
        --out "json=reports/${SCENARIO}-${TS}.json" \
        --summary-trend-stats="avg,p(50),p(90),p(95),p(99)"; then
    RESULTS[$SCENARIO]="pass"
  else
    RESULTS[$SCENARIO]="fail"
  fi
  k6-reporter "reports/${SCENARIO}-${TS}.json" \
        --out "reports/${SCENARIO}-${TS}.html" || true
done

node scripts/seed-snapshot-verify.ts || RESULTS[soak]="fail-data-mutated"

if [ -f scripts/host-sample.sh ]; then
  bash scripts/host-sample.sh >> "reports/host-sample-${TS}.log" || true
fi

# Render combined index
node scripts/render-index.js "${RESULTS[@]}" "reports/index.html"

echo "==> done. See reports/index.html"
```

### Step 8. Write `scripts/render-index.js` (~30 min)

A trivial Node script that reads the four HTML reports' threshold badges (the reporter writes them as plain text near the top — verified by inspecting one k6-reporter output) and produces a `reports/index.html` with one row per scenario showing pass/fail. (ponytail: no React, no framework — just template literals.)

### Step 9. Write `load-tests/README.md` (~20 min)

Sections (all < 1 page each):
- "What this does" (non-engineer friendly — 5 lines).
- "How to read the report" (5 lines + 1 screenshot).
- "Prerequisites" (k6 binary install command for the staging host's OS).
- "How to run" (`npm run loadtest`).
- "Adding a new scenario" (point to `lib/config.js` as the single source of truth).
- "Limitations" (link to §8 of the spec).

### Step 10. End-to-end smoke test (~30 min)

Run the load scenario only against the staging host with a 1-VU / 1-RPS override:
```bash
LOAD_VUS=1 LOAD_RPS=1 npm run loadtest:load
```
- Verify login works and a session cookie is captured.
- Verify one list and one detail call return 200.
- Open the HTML report; confirm pass badge.

If any step fails, do NOT proceed to the full suite. Fix the script and re-run smoke.

### Step 11. Run full suite, capture first-run numbers, recalibrate (~4 hours wall clock)

Run all four scenarios end-to-end. After the run:
- Compare actual latency numbers to the assumed NFR-1 / NFR-3 thresholds.
- If actual p95 is, say, 200ms, NFR-1 is correctly calibrated. If actual p95 is 800ms, the NFR is wrong and the suite will keep failing — update §3 to reflect reality.
- Open a follow-up issue / scratch note to recalibrate after every quarter or after any infra change.

---

## 10. References

- **k6 docs:** https://k6.io/docs/
- **k6-reporter:** https://github.com/benc-uk/k6-reporter
- **tRPC batch protocol:** https://trpc.io/docs/client/links/httpBatchLink
- **hms-app tRPC server entry:** `hms-app/server.ts` (Next.js custom server, port 3000)
- **hms-app tRPC routers:** `hms-app/src/lib/trpc/routers/`
- **hms-app OPD read path:** `hms-app/src/app/(dashboard)/opd/...` (verify procedure names in Step 0)
- **Project context:** `hms-system/CLAUDE.md` (workspace layout), `hms-app/CLAUDE.md` (hms-app conventions)
