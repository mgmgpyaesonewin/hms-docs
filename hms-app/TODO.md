# hms-app — TODO

Source-of-truth list of work **still pending** for the `hms-app` Next.js
monolith. Each item is grounded in a current doc, ADR, or file in the
workspace. Date of this cut: 2026-07-07.

> Status legend. `- [ ]` = open; check off as work ships. Do not add items
> here without a source pointer — if the `why` cannot be grounded, drop it.

---

## 1. Required before summary-service can ship

These are the hms-app deliverables the summary-service blocks on. Until
they land, the summary-service v1 cannot process events from hms-app.

- [ ] **Add `tx.eventOutbox.create(...)` inside the existing OPD-billing Prisma transaction (`OpdBillingService.create`)**
  - **Why:** The summary-service worker consumes `event_outbox` rows written in the same Prisma tx as the OPD billing insert (R2 of SPEC §11.2). Without this insert the worker has no events; per ADR 0001 the trigger mechanism is "Postgres transactional outbox, no second consumer". Removing or splitting the outbox insert is a breaking change to the summary-service.
  - **Source:** `hms-docs/summary-service/adrs/0001-trigger-mechanism.md` ("Producer (HMS)"); `hms-docs/hms-app/SPEC.md` §11.2; `hms-app/src/app/(dashboard)/opd/opd-billing/TESTING.md` (explicitly notes the outbox emission has not yet been added at this site).

- [ ] **Mirror the new tables into `hms-app/prisma/schema.prisma` and run the DDL from `summary-service/data-model/schema.sql`**
  - **Why:** the summary-service tables live in the same Postgres and the HMS team owns the DDL per SPEC §8. The Prisma subset must include the `EventOutbox` model so step 1 can compile; the CHECK constraints and the `pg_trgm` GIN index cannot be expressed in Prisma and must run from the SQL file.
  - **Source:** `hms-docs/hms-app/SPEC.md` §8; `hms-docs/summary-service/data-model/schema.sql`; `hms-docs/summary-service/data-model/prisma-additions.prisma`.

- [ ] **Add a service-level test that asserts the `event_outbox` row shape emitted at OPD-bill creation**
  - **Why:** the existing `opd-billing/TESTING.md` already lists this as a TODO under the file's "not yet covered" section; shipping the writer without a test on the row shape leaves the contract unenforced.
  - **Source:** `hms-app/src/app/(dashboard)/opd/opd-billing/TESTING.md` (line referencing "When it lands, add a service-level test that asserts the `event_outbox` row shape").

- [ ] **Add the new `consultation_fees:write` RBAC permission to the HMS role/permission enum**
  - **Why:** the summary-service assumes the BFF-side admin endpoints are gated by this permission (per the brief's assumed defaults); if the summary-service ever needs to write through HMS (future evolution, e.g. doctor-payout workflow), HMS must already recognise the permission in `Action` × `Subject`.
  - **Source:** `hms-docs/summary-service/README.md` §"Assumed defaults" (#2 — "New `consultation_fees:write` permission following the existing HMS RBAC pattern"). Conflict flag: the brief marks this as an "assumed default", not a confirmed requirement — verify with the HMS team before implementing.

---

## 2. hms-app tech debt

Items grounded in the `hms-app` README caveats or in design-tree docs that
explicitly name the gap. Sorted by impact on production.

- [ ] **Stop ignoring type / lint errors at build time in `next.config.ts`**
  - **Why:** both `ignoreBuildErrors` and `ignoreDuringBuilds` are set to `true`, which means `next build` succeeds even with TS errors and ESLint failures. The README's Caveats section says `npm run tsc` and `npm run lint` are the source of truth — i.e. the build gate is currently a no-op, and CI cannot block on type or lint drift.
  - **Source:** `hms-app/README.md` (Caveats); `hms-app/next.config.ts` (settings in question).

- [ ] **Decide and publish a Prisma migration hygiene policy**
  - **Why:** `prisma/migrations/` has 467 forward-only migrations to date, and the SPEC §7 + the SA plan both note that the squash-vs.-forward-only decision is still pending. The longer the delay, the higher the cost of the eventual squash.
  - **Source:** `hms-docs/hms-app/SPEC.md` §7 ("Migration policy… pending — see SA plan §3"); `hms-docs/hms-app/onboarding/solution-architect-plan.md` Phase 3 ("Decide and publish a migration policy").

- [ ] **Decide the experimental-server path (`server.ts`, `dev:experimental` / `build:experimental` / `start:experimental`) — commit, complete, or remove**
  - **Why:** SPEC §13.4 says the experimental server sits in tree with status "commit, complete, or remove" and that production traffic must not flow through it until the decision lands. The scripts, `tsconfig.server.json`, and `server.ts` are all in the repo today, with no clear owner.
  - **Source:** `hms-docs/hms-app/SPEC.md` §13.4; `hms-docs/hms-app/onboarding/solution-architect-plan.md` Phase 2 ("Write ADR on the 'experimental' server path").

- [ ] **Migrate off the tRPC surface (marked deprecated in hms-app README) to Next.js API Routes**
  - **Why:** the project README itself flags tRPC as deprecated and recommends Next.js API Routes for new code. Both tRPC and server actions still coexist (SPEC §4); until the tRPC call-sites are replaced, the codebase carries two competing mutation paths.
  - **Source:** `hms-app/README.md` ("State Management & API" — tRPC _deprecated_); `hms-docs/hms-app/SPEC.md` §4 ("Replacing tRPC + server-action duplication… ADR pending").

- [ ] **Write and publish ADR-0001: tRPC vs. server actions**
  - **Why:** the SA plan lists this as the single highest-leverage doc to ship first. Without a written decision, every new mutation has to be argued in review.
  - **Source:** `hms-docs/hms-app/onboarding/solution-architect-plan.md` Phase 2 ("**Write ADR-0001: tRPC vs. server actions**… write it first").

- [ ] **Resolve uncommitted changes in the two private git submodules**
  - **Why:** `git status` shows modified + new + deleted files in `src/app/(dashboard)/opd` and `src/app/(dashboard)/appointment` that haven't been committed and pushed upstream to the submodule repos. The OPD submodule has modified tests plus an untracked `opd-billing/__tests__/features/schemas/` and `utils/`. The appointment submodule has the `book-appointment/__tests__/appointment.service.node.test.ts` deletion plus several untracked `TESTING.md` files.
  - **Source:** `git -C hms-app status --short` (run 2026-07-07).

- [ ] **Document or script the submodule bootstrap so new clones don't hit "module not found"**
  - **Why:** SA-plan session notes 2026-06-08 record that the dashboard failed to build with module-not-found errors for both submodules, and the fix (`gh auth setup-git && git submodule update --init`) is not encoded anywhere — every new dev hits the same error.
  - **Source:** `hms-docs/hms-app/onboarding/solution-architect-plan.md` §"Session Notes 2026-06-08".

- [ ] **Add a retention policy for the `_logs` (Winston Postgres transport) table**
  - **Why:** SPEC §14.3 says the `_logs` table has no retention policy today. The same section recommends pruning `timestamp < now() - interval '90 days'` to match the summary-service pruner cadence once size becomes a concern.
  - **Source:** `hms-docs/hms-app/SPEC.md` §14.3.

- [ ] **Backfill the OpenAPI docs for the modules listed `status: pending` in `api/manifest.yaml`**
  - **Why:** `ipd`, `lab`, `pharmacy`, and 12 `trpc-*` modules (purchase-orders, grn, stocks-summary, stock-expiry, inventory, stock-movement, stock-request, selling-price-groups, batch, stock-transfers, change-selling-price, banks) are documented against code that ships today but has no `paths/*.yaml` / `schemas/*.yaml` fragments yet — so `manifest.yaml` disagrees with itself.
  - **Source:** `hms-docs/hms-app/api/manifest.yaml` (modules with `status: pending`); `hms-docs/hms-app/README.md` §"Status of the API docs".

---

## 3. Open features

Section is intentionally narrow: only items with an explicit `ready-for-agent`
triage label in `hms-app/.scratch/` or with an explicit owner from the design
tree. Today that set is **empty**.

- [ ] _None at present._ The `.scratch/` tree currently holds a completed PR
      body (`pr-body-tests-psw.md`) and no triage-labelled issue files.
      When an issue file is opened under `.scratch/<feature>/issues/` with
      `Status: ready-for-agent` or `Status: ready-for-human`, add it here with
      its filename as source.

---

## 4. Deferred / nice-to-have

Items explicitly punted in ADRs or in `SPEC.md` §4. Track so they don't
get lost; do not pull forward without re-evaluating the original rationale.

- [ ] **Add `LISTEN/NOTIFY` acceleration on top of the outbox poller**
  - **Why:** ADR 0001 calls out `LISTEN 'event_outbox_new'` as the first upgrade path when sub-second latency becomes a problem (5–20 LOC, no new infra). v1 stays with pure polling.
  - **Source:** `hms-docs/summary-service/adrs/0001-trigger-mechanism.md` §"Open follow-ups".

- [ ] **Build the doctor-payout workflow (`doctor_payouts` table, v2+)**
  - **Why:** the summary-service README §"Future work" is explicit that the CFI tracks what is owed to the doctor, not what has been disbursed. v2 adds a new `doctor_payouts` table; the v1 `payout_amount` stays frozen at `PAID` and is referenced by FK from the new table.
  - **Source:** `hms-docs/summary-service/README.md` §"Future work"; `hms-docs/hms-app/SPEC.md` §4 ("Out of scope (v1)").

- [ ] **Replace build-time module toggles (`NEXT_PUBLIC_*_MODULE_ENABLED`) with a runtime flag system**
  - **Why:** SPEC §4 + §13.3 both flag this: today's toggles are env vars checked at build, not at request time. A Postgres-backed runtime flag is the proposed direction for in-progress modules (`cathlab`, `endo`, `emr`).
  - **Source:** `hms-docs/hms-app/SPEC.md` §4 and §13.3; `hms-docs/hms-app/onboarding/solution-architect-plan.md` Phase 3 ("Decide and publish a feature-flag story").

- [ ] **Build the outbox observability dashboard (`status × hour` rollup view)**
  - **Why:** ADR 0001 spells out the dashboard query (`SELECT date_trunc('hour', created_at), status, count(*) FROM event_outbox GROUP BY 1, 2 ORDER BY 1 DESC LIMIT 48;`). v2 ops view, no consumer in v1.
  - **Source:** `hms-docs/summary-service/adrs/0001-trigger-mechanism.md` §"Open follow-ups".

- [ ] **Cross-region HA / disaster-recovery posture**
  - **Why:** SPEC §4 lists this explicitly as out of scope for v1 — single on-prem host with on-prem Postgres backup only.
  - **Source:** `hms-docs/hms-app/SPEC.md` §4 ("Out of scope (v1)").

- [ ] **Decide on a soft-delete strategy for new Prisma models**
  - **Why:** SPEC §8 says "Soft-delete strategy not in use today — prefer hard delete + audit log". A new model that historically soft-deletes has to be caught and overridden on a case-by-case basis; the SA plan defers publishing a written convention to Phase 3.
  - **Source:** `hms-docs/hms-app/SPEC.md` §8; `hms-docs/hms-app/onboarding/solution-architect-plan.md` Phase 3 ("Soft delete strategy").

---

## How to update this file

When shipping an item: tick the box (`- [x]`) and leave a one-line commit/PR
reference. When new work surfaces: add it under the most-specific section,
ground the `why` in a doc, ADR, or file, and cite the source. If you cannot
cite a source, do not add the item — drop it instead.
