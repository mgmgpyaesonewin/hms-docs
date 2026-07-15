# Workflow — Load/Stress Test Suite for `@hms-app`

> **Status:** Plan (not yet executed)
> **Date:** 2026-07-08
> **Author:** Claude (spec-driven workflow + senior skill orchestration)
> **Companion document:** [[hms-app/load-testing/spec|spec]] — the load/stress test spec under design
> **Out of scope of this doc:** the actual load tests. This document is the orchestration *plan*; the spec is the *contract*.
>
> **Related:** [[INDEX]] · [[hms-app/README]] · [[hms-app/SPEC]]

---

## 1. Purpose

The spec at `spec.md` defines *what* the load/stress test suite does. This workflow defines *how* the work gets done — which senior lens owns which decision, in what order, with what handoffs, against what quality gates. Five skills participate, split into two classes:

**Design roles (make decisions):**
- **`/senior-architect`** — system topology, capacity model, executor choice, host-side signals, SLO candidates, architectural risk surface.
- **`/senior-fullstack`** — code shape, package boundaries, tRPC/REST call verification, k6 + k6-reporter pipeline reality, auth/session gotchas, developer ergonomics.
- **`/senior-qa`** — test strategy, scenario coverage, edge cases, tiered quality gates, report design for non-engineers, CI badge, repeatability.

**Review roles (catch problems, then exit):**
- **`/code-reviewer`** — code-level correctness, complexity, SOLID violations, security smells, PR-style review. Fires on **the implementation** (post-Phase 5), not the spec.
- **`/ponytail:ponytail-review`** — over-engineering audit. Fires on **the spec** (post-Phase 4) and again on **the implementation** (post-Phase 5). Catches speculative abstractions, reinvented stdlib, dead flexibility, unneeded dependencies, and over-commented "lazy" stubs.

The five lenses are not interchangeable. Design roles own distinct decision classes and sign off on the slice they own before the spec advances. A spec change touching *both* executor choice (architect) and k6 pipeline (fullstack) needs both sign-offs. Review roles are gates — they do not propose design; they veto or accept, then exit. A `/ponytail:ponytail-review` finding ("drop §6.4, k6-reporter already does this") is binding; the design role that produced the slice must cut it.

---

## 2. Roles & Lenses

### 2.1 Design roles

| Role | Owns | Does NOT own |
| --- | --- | --- |
| **senior-architect** | "Where is the cliff? What does the test need to reveal about the system?" Executor choice, capacity model, host/sample signals, prod-mode vs dev-mode, SLO candidate critique, multi-tenant fairness, cold-start. | API call shape, package layout, report HTML styling. |
| **senior-fullstack** | "How does the code actually fit into hms-app?" REST/tRPC call verification, package shape (separate package vs workspace), k6 binary + k6-reporter pipeline, auth/session/cookie handling, dev ergonomics (script entry, .gitignore, env file). | Capacity model, scenario coverage, gate tiering. |
| **senior-qa** | "What does a non-engineer see? What failure modes are we testing for? What is the gate?" Scenario coverage additions, edge cases, tiered gate model, non-engineer report deltas, repeatability mitigations, CI badge / `summary.json`. | Where the bottleneck lives, what the call payload looks like. |

### 2.2 Review roles (gates, not owners)

| Role | Fires on | Owns (veto power) | Does NOT do |
| --- | --- | --- | --- |
| **`/ponytail:ponytail-review`** | `spec.md` v2 (Phase 4.5) **and** the implementation (Phase 5.5) | "Is this over-engineered?" Speculative abstractions, reinvented stdlib, dead flexibility, unneeded dependencies, over-commented "lazy" stubs, premature configurability. Output: a list of cuts, one line each (`location: cut what → replace with what`). | Propose new design. Don't add features. Don't suggest "for the future." |
| **`/code-reviewer`** | The implementation (Phase 5.5) — `load-tests/**/*.js`, `hms-app/load-tests/**`, `hms-app/package.json` changes, the `seed-verify.ts`, `render-index.js`, `run-all.sh`. | Correctness bugs, complexity, SOLID violations, security smells (cookie/secret handling, env file leaks), PR-style review with severity. Output: a finding list with severity (critical/major/minor/nit) and location. | Propose new design outside the spec. Don't redesign the spec — that's the design roles' job. |

### 2.3 Escalation rules

- **Disagreement on a slice the design role owns** → that role's decision wins; the disagreement is recorded in §8 Open Questions.
- **Disagreement across slices** → escalate to the user; both sides present options in the §8 format (Options A/B + recommendation).
- **A design role identifies a slice they don't own** → they hand it to the right role via the §4 handoff protocol; they do not decide.
- **A review role finds a problem in a slice they own** → the review's verdict is binding on that slice. The producing design role revises. Max 2 review cycles per slice before escalation.

---

## 3. Phases

> These are **workflow phases** (how the spec gets designed), not the load-test **scenarios** (load/stress/soak/spike). Don't confuse them — the spec's §2.4 already names the latter.

### Phase 0 — Reconcile current findings into the spec

**Goal:** Apply the three reviews already in hand to produce a `spec.md` v2.

**Inputs:** the three senior reviews (already produced) + the current `spec.md` v1.

**Activities:**
1. Senior-fullstack opens a PR-style change set against `spec.md` for the **REST correction** (the OPD billing read path is plain REST, not tRPC; only `auth.login` is tRPC; no `superjson`). This is the most consequential correction in the reviews.
2. Senior-architect layers on the **executor change** (`ramping-vus` for stress), **filter split inversion** (70% filtered, 30% unfiltered + deep cursor variant), and **host-side signals** (`pg_stat_activity`, `state_change` wait time, warmup exclusion, `NODE_ENV=production` requirement).
3. Senior-qa layers on the **tiered gate model**, **scenario additions** (coldstart, degraded-dependency), **EC-11..EC-16**, **`summary.json`** artifact, and **report deltas** (regression row, capacity headroom, latency-as-user-time).
4. A single coherent `spec.md` v2 is produced; the three reviews are filed under `archive/reviews/` (or kept inline as `spec.md` v2 appendix, depending on repo convention).

**Exit criteria:** `spec.md` v2 exists and addresses every "Top 3 concrete changes" item from each of the three reviews. Items deferred to v3 are explicitly listed in §9 of `spec.md` (Out of Scope).

**Gate:** all three roles sign off on v2 before Phase 1.

### Phase 1 — Architect deep-dive (capacity, signals, prod mode)

**Goal:** Lock down the architectural substrate the test runs against.

**Activities:**
1. Verify the staging host is `next start` (prod mode), not `next dev`. If it isn't, the test is invalid; this blocks Phase 4.
2. Confirm Prisma connection-pool sizing on staging (default `num_physical_cpus * 2 + 1`?). Document the number; this is the *expected* cliff.
3. Decide the final executor choices per scenario (load, stress, soak, spike) with the VU/RPS step values.
4. Decide the `host-sample.sh` signal set: `pg_stat_activity` (count + max `state_change` wait), Prisma pool wait, Node RSS, Next.js custom server socket count. Some of these need psql credentials — defer any that can't be wired.
5. Decide warmup window: first 60s of each scenario excluded from p95/p99.
6. Decide cold-start scenario knobs (1 RPS / 60s / 5 VUs / after `systemctl restart`).
7. Produce a **Capacity Model** document (1 page) describing: expected linear region, where the cliff is predicted to be (Prisma pool), how the stress test will reveal it, what success looks like.

**Deliverable:** `docs/load-testing/capacity-model.md` + a list of architectural invariants the spec's NFRs must enforce.

**Gate:** fullstack + qa sign off that the invariants are measurable from the test rig (i.e. we can actually observe `pg_stat_activity` from the host).

### Phase 2 — Fullstack deep-dive (REST correction, package, pipeline)

**Goal:** Make the spec's implementation realizable inside hms-app.

**Activities:**
1. Open `hms-app/src/lib/trpc/routers/auth.ts` and `hms-app/src/app/api/(opd)/opd-billings/route.ts` and confirm the exact call shapes (procedure names, input Zod schemas, response envelope). The fullstack review already did this — file the verified result.
2. Decide the package shape: `hms-app/load-tests/` is a separate `package.json` (k6-reporter only). Add the missing `hms-app/package.json` `loadtest` script delegation. Add `.gitignore` entries.
3. Decide the k6 + k6-reporter pipeline. **Critical:** the report pass/fail badge must be derived from the JSON summary block (`metrics['http_req_duration'].threshold[*].ok`), not from HTML scraping. Document the exact shape `render-index.js` should parse.
4. Decide the test-user pool: 1:1 with VUs, no sharing. Document the seed contract: `loadtest_<vuId>` for VU `vuId`, 50 users minimum, single-session invariant explicit in `seed-verify.ts`.
5. Decide cookie/header forwarding: k6 must forward `X-Forwarded-Proto` so the session cookie is `secure` when the staging is behind HTTPS (matches `createContext` in `trpc.ts`).
6. Decide the `lib/auth.js` shape: `login(vuId)` returns the cookie jar; **login happens once per VU, outside the iteration loop** (`ramping-arrival-rate` reuses VUs — verify the script structure keeps login out of `default()`).

**Deliverable:** edits to `spec.md` §3 (FR-1..FR-15), §6 (API Contracts), §10 (Implementation Plan Step 0, 1, 3, 7). New `docs/load-testing/dev-ergonomics.md` if needed.

**Gate:** architect + qa sign off that the call shapes are observably correct (curl-level smoke).

### Phase 3 — QA deep-dive (gates, scenarios, report, repeatability)

**Goal:** Make the spec's outputs trustworthy and CI-friendly.

**Activities:**
1. Decide the tiered gate model: Tier 1 = `load` blocks deploy; Tier 2 = `stress`/`soak` warn; Tier 3 = `spike` informational. Confirm the "first real run" caveat is documented (no calibrated baseline yet).
2. Decide which additional scenarios to add now vs. defer:
   - **Cold-start** — add now (catches JIT/Prisma warmup). New `scenarios/coldstart.js`.
   - **Degraded-dependency** — add now via `toxiproxy` toggle, optional (skip if `toxiproxy` not installed; documented as such).
   - **Realistic-mix replay** — defer to v3 (needs prod trace capture; OS-3).
   - **Multi-tenant contention** — defer to v3 (staging is single-tenant; spec §7).
3. Lock the edge cases: EC-11..EC-16 (schema migration, clock skew, tRPC version drift, large payload, login stampede, N+1 filter spread). Each becomes a `seed-verify.ts` assertion or a scenario knob.
4. Decide the `summary.json` shape (timestamp, tier1_pass, per-scenario metrics, per-scenario pass). Decide the GitHub Actions step that parses it for a PR status check.
5. Decide the HTML report deltas:
   - "Did we regress?" row (this run vs last run vs 7-run rolling median, with green/yellow/red pill).
   - Capacity headroom: declared threshold RPS vs stress `cliffs_found` RPS, "you are at 65% of declared capacity."
   - Plain-English latency translation ("p95 = 480ms ≈ 3 page reloads for a user").
6. Decide repeatability mitigations: warmup scenario (1 VU, 1 RPS, 60s, discard samples), `NODE_ENV=production` assertion, trend-line in report.
7. Decide CI: a weekly cron job running a 1-VU smoke against staging to catch drift.

**Deliverable:** edits to `spec.md` §4 NFR-1..NFR-12 (tier model, `summary.json`, warmup), §5 EC-1..EC-16, §6 (HTML report), §10 (Implementation Plan Step 7–8, Step 11). New `docs/load-testing/qa-charter.md` if needed.

**Gate:** architect + fullstack sign off that the gates are actionable (a `load` failure is a real regression, a `soak` failure isn't a bricked deploy).

### Phase 4 — Synthesis (spec v2)

**Goal:** Produce a single coherent `spec.md` v2 that incorporates Phases 1–3.

**Activities:**
1. Resolve cross-slice conflicts surfaced in Phases 1–3. Most likely: coldstart scenario's executor/host-sample needs both architect + qa sign-off.
2. Re-validate with the spec-driven workflow validator (`spec_validator.py --strict`).
3. Manually walk the self-review checklist from `/engineering-advanced-skills:spec-driven-workflow`.
4. Produce `spec.md` v2 and the `CHANGELOG.md` entry from v1 → v2.

**Gate:** all three design roles approve v2; the spec is `Status: Approved` (provisional, pending Phase 4.5).

### Phase 4.5 — `ponytail-review` of `spec.md` v2

**Goal:** Catch over-engineering in the spec before it becomes code. Cheap to cut now; expensive to cut later.

**Activities:**
1. Invoke `/ponytail:ponytail-review` against `spec.md` v2. The reviewer's deliverable is a list of cuts, one line each: `location: cut what → replace with what`.
2. Apply all "binding" cuts (cuts that, if not applied, would block Phase 5).
3. "Advisory" cuts (cuts that would improve the spec but are not blockers) go into the §5 backlog as DEFER items.
4. Re-validate with `spec_validator.py --strict` after cuts.
5. Bump spec to v2.1 (or v3 if v2 had cuts that the design roles' sign-off didn't anticipate).

**Output:** a `ponytail-cuts.md` archive in `archive/reviews/v2.1/` listing the cuts applied + the cuts deferred.

**Gate:** reviewer finds zero binding cuts → spec advances to Phase 5. If binding cuts are found, producing design role revises and the review re-runs. Max 2 cycles per slice.

### Phase 5 — Implementation kickoff (still NOT execution of the tests themselves)

**Goal:** Hand the approved spec to an implementer with full context.

**Activities:**
1. Generate the empty scaffolding (directories, `package.json` skeleton, `seed-verify.ts` skeleton) per `spec.md` §10 Step 1.
2. Run the spec through `test_extractor.py` to confirm each acceptance criterion maps to a runnable check.
3. Hand off to a `coder` agent (or human) for implementation per the spec's §10 plan.

**This is the first point at which code is written.** Until Phase 5 is reached, all work is spec design.

### Phase 5.5 — Dual review of the implementation

**Goal:** Two review lenses on the actual code. Each catches different problems.

**Activities:**
1. **5.5a — `ponytail-review` (over-engineering).** Invoke `/ponytail:ponytail-review` against the entire `load-tests/` tree + any changes to `hms-app/package.json` / `hms-app/.gitignore`. Same output format: list of cuts. The reviewer can call out things like: "the `lib/data.js` `pickUserCredentials(vuId)` function is reinventing `k6's __ENV` lookup with `LT_PASS_${vuId}` indirection — use `__ENV[\\`LT_PASS_${vuId}\\`]` directly." The implementing agent applies the cuts.
2. **5.5b — `code-reviewer` (correctness + SOLID).** Invoke `/code-reviewer` against the same scope, with `--comment` if posting inline. Output: findings with severity (critical/major/minor/nit). Critical findings block "done"; major findings are required fixes; minor/nit are follow-up.
3. **Order matters:** ponytail-review first (cheap, structural cuts), then code-reviewer (deeper, semantic). The code-reviewer reviews the post-ponytail state, so the implementer doesn't get duplicate findings for code that ponytail cut.
4. The implementer fixes critical + major; minor/nit are filed as a follow-up issue.

**Gate:** zero critical findings from `code-reviewer` + zero binding cuts from `ponytail-review` → implementation is `Status: Ready`.

### Phase 6 — Approval (spec v2 → ready for execution)

**Goal:** Final sign-off. Optional — for high-stakes changes, run the three design roles' sign-off again on v2.1 (post-ponytail-cuts) before declaring "ready."

**Activities:**
1. The three design roles re-read `spec.md` v2.1 (post-ponytail-cuts). One-line "I have read v2.1 and confirm my slice is intact" per role.
2. Bump spec to `Status: Ready for Implementation`.
3. Close the workflow.

**This is the last workflow phase.** Phase 7+ is execution of the load tests themselves — out of scope of this workflow document.

---

## 4. Coordination Protocol

### 4.1 Handoffs

Each phase ends with a handoff to the next role. The handoff is a short Markdown note in the PR/scratch dir containing:
- What was decided (1-line per decision).
- What is *not* decided (open items deferred to the next phase).
- Any new slice that surfaced and needs a different role's input.

### 4.2 Shared artifacts

| Artifact | Owner | Consumers |
| --- | --- | --- |
| `spec.md` | spec-driven workflow (this) | all three design roles edit slices they own |
| `docs/load-testing/capacity-model.md` | architect | fullstack + qa (sign-off) |
| `docs/load-testing/dev-ergonomics.md` | fullstack | qa (sign-off that shapes are observable) |
| `docs/load-testing/qa-charter.md` | qa | architect + fullstack (sign-off) |
| `docs/load-testing/CHANGELOG.md` | spec-driven workflow | all (audit trail) |
| `archive/reviews/v1/*.md` | spec-driven workflow | all (history of v1 design reviews) |
| `archive/reviews/v2.1/ponytail-cuts.md` | `ponytail-review` | implementer (post-Phase 5), code-reviewer (re-reviews after cuts applied) |
| `archive/reviews/v2.1/code-review-findings.md` | `code-reviewer` | implementer (fixes), team lead (sign-off on minor/nit deferral) |

### 4.3 Gating

- A design role cannot sign off on a slice they did not produce unless they have read the producing role's deliverable and recorded a one-line "I have read X and have no architectural objection" (architect) / "I have read X and the call shapes are correct" (fullstack) / "I have read X and the failure modes are testable" (qa).
- "No objection" is not the same as "approve." A design role can approve only after the producing role has answered their questions. If approval is withheld, the producing role revises; the loop is bounded (max 2 cycles per slice before escalation).
- A review role's finding on a slice they own (per §2.2) is **binding**. The producing design role revises. Max 2 review cycles per slice before escalation.
- Review roles do not produce new design; if a review surfaces a gap that the design roles didn't anticipate, the gap goes into the §5 backlog with a DEFER marker for v3 — it does not become a "fix in this PR."

---

## 5. Spec Change Backlog (consolidated from the three reviews)

> This is the working list of edits to apply to `spec.md` during Phase 0 / Phase 4. Each item cites the producing role and the target section in `spec.md`. Items marked **CRITICAL** are correctness bugs in v1; items marked **STRENGTHENING** are quality improvements; items marked **DEFER** are out of v2.

### 5.1 CRITICAL — fullstack

| # | Source review | Edit |
| --- | --- | --- |
| C1 | fullstack | **§6.2, §6.3, FR-10, FR-11, FR-12** — replace tRPC procedure names (`opdBilling.list`, `opdBilling.getById`) with REST endpoints. New: `GET ${BASE_URL}/api/opd-billings?...query...` (list) and `GET ${BASE_URL}/api/opd-billings/${id}` (detail, if `[id]/route.ts` exists; otherwise list-only for v1). Verify exact path against `hms-app/src/app/api/(opd)/opd-billings/route.ts`. |
| C2 | fullstack | **§6.1** — `auth.login` IS tRPC (confirmed `auth.ts:16`). Keep tRPC. Update response envelope description: no `superjson` (default `httpBatchLink`, no transformer — verified in `client.tsx:42-48`). Payload: `{ "0": { "json": { username, password } } }` in, `{ "0": { "result": { "data": { "json": <session> } } } }` out. |
| C3 | fullstack | **FR-7, AC-6** — add single-session enforcement caveat: cookie name is `sid` (`auth-service.ts:116-123`); the auth service hard-rejects the second concurrent login for the same user (403 "already in use on another device"). Test-user pool MUST be 1:1 with VU peak, and no two VUs may share a username. |
| C4 | fullstack | **Step 0 of §10 (Implementation Plan)** — add the verification of `isHttps` reading from `x-forwarded-proto` header in `trpc.ts:20`. Document in `load-tests/README.md` that k6 must forward `X-Forwarded-Proto: https` when behind a reverse proxy. |
| C5 | fullstack | **Step 1 of §10** — drop `node` from `engines` in `load-tests/package.json`; only `k6` is required at runtime (k6-reporter runs in Node only for HTML generation, not for the test itself). |
| C6 | fullstack | **FR-5, Step 1 of §10** — add the missing `hms-app/package.json` script delegation: `"loadtest": "npm --prefix load-tests run loadtest"`. Add `.gitignore` entries for `load-tests/reports/*.{html,json}`, `load-tests/node_modules/`, `load-tests/.env.test`, `load-tests/.snapshot.json`. |
| C7 | fullstack | **Step 7 / Step 8 of §10** — replace "parse HTML for threshold pass/fail" with deterministic JSON parsing: `JSON.parse(fs.readFileSync('reports/load-<ts>.json'))` → `root.metrics['http_req_duration'].threshold[*].ok`. Note: k6-reporter's HTML has no stable class/id contract across versions. |

### 5.2 STRENGTHENING — architect

| # | Source review | Edit |
| --- | --- | --- |
| A1 | architect | **FR-18** — change stress executor from `ramping-arrival-rate` to `ramping-vus` with VU steps `[10, 25, 50, 75, 100, 150]`, 3 min per step. Add a derived `rps_achieved_per_vu_step` metric so the capacity curve is visible. Reason: open-model hides the cliff (Prisma pool, not Node event loop). |
| A2 | architect | **FR-14** — invert to **70% filtered / 30% unfiltered** list calls; filters MUST always combine `doctorId + dateFrom/dateTo`. Add a deep-cursor variant at 10% of list calls (`cursor` past page 50). Reason: exercises composite indexes and the realistic doctor-filtered path; catches N+1. |
| A3 | architect | **FR-19** — change soak baseline from 5 RPS to **80% of measured peak RPS** (set after the first stress run). Reason: 5 RPS is too low to expose leaks in 2h. |
| A4 | architect | **NFR-4** — keep RSS backstop; add `pg_stat_activity` count + max `state_change` wait time sampled every 60s during stress + soak via `host-sample.sh`. Add a graceful-skip if psql creds unavailable (don't abort the run). |
| A5 | architect | **NFR-4** — add warmup exclusion: **first 60s of every scenario is excluded from p95/p99 calculations**. Reason: Next.js + Prisma engine + tRPC route warmup skews the first 30s catastrophically. |
| A6 | architect | **NFR-4** — add `NODE_ENV=production` requirement: `run-all.sh` MUST verify this before proceeding. Running against `next dev` gives meaningless numbers. |
| A7 | architect | **§5 EC** — add EC-11 (Prisma engine fork FD leak — sample `lsof -p <pid>` count during soak), EC-12 (Next.js custom server `server.ts` keep-alive timeout — pin `Connection: keep-alive` and `Keep-Alive: timeout=NN` from k6 side). |
| A8 | architect | **NFR-5** — `cliffs_found` MUST also fire on `pool_wait_p95 > 200ms` (derived from `pg_stat_activity.state_change`), not only on HTTP errors. Reason: by the time HTTP errors appear, you're past the architectural cliff. |
| A9 | architect | **§2.4** — add **cold-start scenario** (`scenarios/coldstart.js`): 1 RPS for 60s, 5 VUs, after `systemctl restart` of hms-app. Catches JIT/pg-boss warmup and connection-pool fill. |

### 5.3 STRENGTHENING — qa

| # | Source review | Edit |
| --- | --- | --- |
| Q1 | qa | **NFR-2/NFR-3** — introduce tiered gate model. **Tier 1 (block deploy):** `load` p95/p99/error-rate. **Tier 2 (warn):** `stress.cliffs_found`, `soak` RSS growth, `coldstart`. **Tier 3 (informational):** `spike` recovery delta. Edit AC-8: "exit non-zero only on Tier 1 (`load`) failures." Add new **NFR-11** declaring the gate tier per scenario. |
| Q2 | qa | **§5 EC** — add EC-13 (schema migration during soak — gate soak on no `ALTER TABLE`/DDL locks at start; sample `pg_locks`), EC-14 (clock skew — k6 runner NTP offset ≤ 1s, assert via `Date` header round-trip in `seed-verify.ts`), EC-15 (tRPC version drift — assert `Content-Type: application/json` and `result.data.json` present), EC-16 (large-payload OPD detail — at least 1 OPD billing with ≥ 50 line items in seed, hit at least once per 100 iterations), EC-17 (login stampede — 50 VUs all `POST auth.login` in first second; stage login across 5s ramp in scenario, not all at t=0), EC-18 (N+1 filter spread — assert filter distribution spans all 50 doctors, not just first 5). |
| Q3 | qa | **§2.4** — add **degraded-dependency scenario** (`scenarios/degraded.js`): extend spike.js OR new file, optional `toxiproxy` toggle. Skip if `toxiproxy` not installed; document as such. |
| Q4 | qa | **NFR-12** — `run-all.sh` MUST emit `reports/summary.json` with shape `{ ts, tier1_pass, scenarios: { load: { p95_ms, p99_ms, error_rate, pass, gate_tier }, ... } }`. This is the machine-readable artifact for CI. |
| Q5 | qa | **§6.4 / Step 8 of §10** — `render-index.js` MUST emit a "Did we regress?" row (this run vs last run vs 7-run rolling median, green/yellow/red pill at >10% worse) and a "Capacity headroom" block (declared threshold RPS vs stress `cliffs_found` RPS). |
| Q6 | qa | **NFR-6** — NFR-6's ±10% run-to-run is aspirational; rename to **NFR-13** and downgrade to a target, with explicit mitigations: (a) warmup scenario (1 VU, 1 RPS, 60s, discard samples) before load; (b) `NODE_ENV=production` assertion in `seed-verify.ts`; (c) trend-line in HTML report. |
| Q7 | qa | **§10 Step 11** — add a weekly cron smoke: 1 VU, 30s, no thresholds, run from GitHub Actions against staging. Catches drift between spec and reality. |
| Q8 | qa | **Step 0 of §10** — add a third verification item: k6 binary version on operator's host must match `engines.k6`. (Already in NFR-9; reinforce.) |

### 5.4 DEFER — to spec v3

| # | Source | Reason |
| --- | --- | --- |
| D1 | qa | **Realistic-mix replay** scenario. Requires prod trace capture (OS-3 in spec). |
| D2 | qa | **Multi-tenant contention** scenario. Staging is single-tenant per spec §7. |
| D3 | architect | **End-user SLOs** (clinic-branch LAN latency budget). Requires a network probe at a clinic; defer until SRE stands one up. (Already in OS-7.) |
| D4 | qa | **Per-tenant fairness latency**. Single-tenant staging can't measure this. |
| D5 | architect | **Redis hit rate sampling**. No Redis in hms-app read path. |

---

## 6. Quality Gates

### 6.1 Per phase

| Phase | Gate | Who decides |
| --- | --- | --- |
| 0 → 1 | Spec v2 covers all CRITICAL edits in §5.1 | fullstack |
| 1 → 2 | `capacity-model.md` exists, invariants are measurable | architect + fullstack + qa |
| 2 → 3 | `dev-ergonomics.md` exists, call shapes are curl-verified, package layout works | fullstack + qa |
| 3 → 4 | `qa-charter.md` exists, gates are actionable, scenarios are runnable | architect + qa + fullstack |
| 4 → 4.5 | `spec.md` v2 is `Status: Approved`; `spec_validator.py --strict` passes; manual checklist clean | all three design roles |
| 4.5 → 5 | `ponytail-review` finds zero binding cuts in `spec.md` v2; `ponytail-cuts.md` archived; spec bumped to v2.1 | `ponytail-review` (binding) |
| 5 → 5.5 | Empty scaffolding generated; `test_extractor.py` confirms each AC maps to a runnable check | implementer (sign-off) |
| 5.5 → 6 | (a) `ponytail-review` finds zero binding cuts in implementation; (b) `code-reviewer` finds zero critical findings; minor/nit filed as follow-up | `ponytail-review` + `code-reviewer` (binding) |
| 6 → execution | All three design roles re-read v2.1 and confirm their slice is intact after ponytail cuts; spec bumped to `Status: Ready for Implementation` | all three design roles |

### 6.2 Cross-slice conflict resolution

When a Phase 1 deliverable constrains a Phase 2 deliverable (or vice versa), the constrained role raises a one-line conflict note. Resolution rules:
- Capacity model says "stress must use `ramping-vus`" and fullstack says "k6-reporter doesn't graph VU step curves well" → qa is asked to design the report delta. qa's decision binds.
- Fullstack says "REST is `GET /api/opd-billings`" but architect wants the deep-cursor variant exercised → both win: architect defines *what* the load shape is, fullstack defines *how* the request is built.
- `ponytail-review` says "drop §6.4 health-check route, k6's precheck can use `auth.login` as the liveness probe" → producing design role (fullstack) revises. No further cross-slice discussion needed; ponytail-review's cut is structural, not architectural.

### 6.3 Review rejection protocol

When a review role rejects a slice:
1. The reviewer files the finding with location + cut/fix + severity.
2. The producing design role applies the cut/fix in the same PR (not a follow-up).
3. The review re-runs against the revised slice.
4. After 2 review cycles with no convergence, the disagreement is escalated to the user with both sides' positions and a recommendation.

The intent: reviews are **synchronous** with the producing role, not a backlog. A finding filed and forgotten is a finding the implementer has to rediscover during code-review (Phase 5.5) — much more expensive.

---

## 7. Decision Rules — when to re-invoke each role

Re-invoke **senior-architect** when:
- A spec change touches executor choice, host-side sampling, prod/dev mode, or capacity assumptions.
- A new architectural risk is identified (e.g. a new external dependency, a refactor of the custom server, a change to Prisma's connection-pool strategy).
- A scenario's expected cliff moves (e.g. we add a downstream service that changes the bottleneck).

Re-invoke **senior-fullstack** when:
- A spec change touches the call shape, package layout, k6 pipeline, auth/cookie handling, or developer ergonomics (scripts, .gitignore, env files).
- A new dependency is added to hms-app that the test should cover.
- A new build artifact path is introduced (e.g. moving to Turbopack).

Re-invoke **senior-qa** when:
- A spec change touches scenario coverage, edge cases, gate tiering, report content, repeatability mitigations, or CI integration.
- A new failure mode is observed in production that the suite should catch.
- The CI platform changes (e.g. moving from GH Actions to Jenkins).

Re-invoke **`/ponytail:ponytail-review`** when:
- `spec.md` is at a version boundary (v1 → v2, v2 → v2.1, v2.1 → v3) — fire as a gate (Phase 4.5 / equivalent).
- A new file or module is added to the implementation that wasn't in the previous ponytail-cuts (Phase 5.5 re-run on the diff).
- A design role's deliverable grows by > 30% lines without a corresponding scope expansion in the §5 backlog — this is a yellow flag, fire the review out-of-band.

Re-invoke **`/code-reviewer`** when:
- The implementation lands for the first time (Phase 5.5).
- A subsequent PR touches `load-tests/`, `hms-app/package.json`'s `loadtest` script, the seed-verify contract, or `run-all.sh` — re-run on the diff.
- A bug is found in production that the suite should have caught (post-mortem → the absence of a test is a `code-reviewer` finding, not a `ponytail-review` finding).

**Default:** keep all five in the loop for the first run. After the suite is "stable" (no changes for one quarter), full re-invocation is only triggered by the rules above. Both review skills are cheap to fire (no implementation work, just analysis) — default to firing them, not skipping them.

---

## 8. Open Questions (to resolve before Phase 4)

> Items the three reviews surfaced that the workflow itself does not decide. Each needs an explicit user/SRE answer before spec v2 is `Status: Approved`.

1. **OQ-1.** Staging is `next start` (prod mode) — confirmed? Or do we need to add a "set `NODE_ENV=production`" step to the staging deploy? *(architect)*
2. **OQ-2.** psql creds for `host-sample.sh` — available on the staging host? If not, do we run `host-sample.sh` from a sidecar? *(architect + SRE)*
3. **OQ-3.** Single-session enforcement (fullstack C3) — is "1 user per VU, 50 users seeded" an acceptable seed cost, or do we need a different test user strategy? *(SRE / data team)*
4. **OQ-4.** toxiproxy availability on the staging host (qa Q3) — install it for the degraded-dependency scenario, or skip and document the gap? *(SRE)*
5. **OQ-5.** The "first real run will fail" caveat (qa Q1) — do we accept Tier-1 failures on the first run and re-calibrate, or do we ship the suite with a "calibration mode" that disables Tier-1? *(product owner / SRE)*
6. **OQ-6.** The "did we regress" comparison requires persisting the previous run's results — where? Local file? A sidecar DB? S3? *(SRE)*
7. **OQ-7.** GitHub Actions weekly cron (qa Q7) — is there an Actions workflow in `hms-app/.github/workflows/` we can extend, or do we create a new one? *(fullstack + repo maintainer)*
8. **OQ-8.** The spec assumes `k6 v0.50+`. What's the version on the staging host? *(fullstack + ops)*

---

## 9. References

- **Spec under design:** [`spec.md`](./spec.md) (v1 — to become v2 after Phase 0, v2.1 after Phase 4.5)
- **Spec-driven workflow skill:** `/engineering-advanced-skills:spec-driven-workflow`
- **Design role skills:** `/senior-architect`, `/senior-fullstack`, `/senior-qa`
- **Review role skills:** `/code-reviewer`, `/ponytail:ponytail-review`
- **Three senior skill reviews (v1):** see §5 of this doc; full text archived under `archive/reviews/v1/`
- **hms-app tRPC router registry:** `hms-app/src/lib/trpc/routers/` (27 routers, none named `opdBilling`)
- **hms-app OPD billing REST handler:** `hms-app/src/app/api/(opd)/opd-billings/route.ts` (verified by fullstack review)
- **hms-app auth tRPC procedure:** `hms-app/src/lib/trpc/routers/auth.ts:16` (`auth.login`, publicProcedure, `loginSchema`)
- **hms-app auth service:** `hms-app/src/app/(dashboard)/common/auth/features/auth-service.ts:81-93, 123` (single-session enforcement, `sid` cookie set)
- **hms-app tRPC bootstrap:** `hms-app/src/lib/trpc/trpc.ts:20` (`createContext` reads `x-forwarded-proto` for `isHttps`)
- **hms-app custom server:** `hms-app/server.ts` (Next.js + Express wrapping; keep-alive timeout is a concern)
- **Project context:** `hms-system/CLAUDE.md`, `hms-app/CLAUDE.md`
