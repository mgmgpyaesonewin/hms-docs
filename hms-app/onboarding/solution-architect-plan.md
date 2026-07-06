# TODO — Solution Architect Onboarding & Operating Plan

This is a phased checklist for the Solution Architect role on YCare HMS. Tick items as you complete them. Items in **bold** are the highest-leverage; tackle those first.

---

## Phase 1 — Orient (Week 1)

Goal: build an accurate mental model of the current system before changing anything.

- [x] Read `README.md` and `CLAUDE.md` end-to-end; note the "Caveats" section (migration caution, peer consultation on deps, AI usage policy).
- [x] Read the four GitHub workflows (`.github/workflows/`) to understand CI gates and the deploy pipeline (dev → uat → demo tag → prod tag, all via ECR + Kubernetes).
- [x] Walk `src/app/(dashboard)/` and list every clinical module: `appointment`, `cathlab`, `daycare`, `ed`, `emr`, `endo`, `hd`, `imaging`, `ipd`, `lab`, `membership`, `opd`, `ot`, `pharmacy`, plus `common/` and `shared/`.
- [ ] For each module, note: route segment, primary domain entities, which other modules it depends on, and whether it appears production-ready or WIP.
- [ ] Read `src/app/(dashboard)/common/` and `src/app/(dashboard)/shared/` in full first — these contain the cross-cutting code (auth, user-management, set-up, reports).
- [ ] Trace one full user journey end-to-end (suggested: OPD visit → EMR entry → pharmacy sale). Document each layer crossed: middleware → auth → RSC layout → tRPC call → Prisma → any pg-boss job triggered.
- [ ] Read `src/lib/trpc/trpc.ts` and `src/lib/trpc/routers/` — catalogue the procedure types actually used (`publicProcedure`, `authProcedure`, `authorizeProcedure`, `storeCheckedProcedure`, `verifyPasswordProcedure`).
- [ ] Read `src/lib/safe-action.ts` and `src/hooks/use-action.ts` — understand the second API surface (server actions) and how it coexists with tRPC.
- [ ] Audit `prisma/schema.prisma` and `prisma/migrations/`:
  - [ ] Count migrations and date of most recent vs. oldest.
  - [ ] Flag unused or orphan models.
  - [ ] Check for missing indexes on hot queries (look at `prisma-errors.ts` and slow-query patterns in the codebase).
  - [ ] Note whether migrations have ever been squashed.
- [ ] Investigate the "experimental" track: `server.ts`, `dev:experimental`/`build:experimental`/`start:experimental` scripts, `tsconfig.server.json`, and any related docs. Determine current state and intent.
- [ ] Check `next.config.ts` for `ignoreBuildErrors` and `ignoreDuringBuilds` — confirm what is and isn't being enforced locally vs. in CI.
- [ ] Review `.env.example` and the env vars used in `build-and-deploy.yml` (e.g. `NEXT_PUBLIC_OPD_MODULE_ENABLED`, `NEXT_PUBLIC_IPD_MODULE_ENABLED`, `NEXT_PUBLIC_APPOINTMENT_MODULE_ENABLED`).
- [ ] Read the auth flow in `src/app/(dashboard)/common/auth/features/auth-service.ts` and the session-expiry logic in `features/utils/session-expiry.ts`.
- [ ] Read the role/permission model in `@common/user-management/roles/features/utils` (`Action`, `Subject`, `checkPermission`).
- [ ] Check the test setup: `jest.config.ts`, `jest.setup.ts`, `src/test-utils/`, `src/__mocks__/msw/`, and pick a representative test file to read.
- [ ] Check Cypress setup: `cypress.config.ts` and `cypress/` (if present) — what flows are covered?
- [ ] Talk to the current maintainers / team: get their mental list of known tech debts, planned rewrites, and pain points. Cross-check against your own findings.

## Phase 2 — Document (Weeks 2–3)

Goal: produce a shared, written record of the current architecture and the decisions that produced it.

- [ ] **Write ADR-0001: tRPC vs. server actions** — when to use which, including the decision criteria (e.g. "use tRPC for queries and cross-module calls; use server actions for form submissions on a single page"). This is the single highest-leverage doc — write it first.
- [ ] Write ADR for the custom session auth (Argon2 + DB-backed `Session` table + `sid` cookie) — why not NextAuth/Auth.js, what the trade-offs are, and the conditions under which we'd reconsider.
- [ ] Write ADR for pg-boss as the job queue (vs. BullMQ, Inngest, etc.) and where the boundaries between "in-request" and "background" work should be drawn.
- [ ] Write ADR for module toggles via build-time env vars — what's working, what's not, and whether runtime feature flags are needed.
- [ ] Write ADR on the "experimental" server path — commit, complete, or remove. Capture the decision with rationale.
- [ ] Produce a **one-page current-state architecture diagram** covering: client → middleware/auth → RSC layouts → tRPC + server actions → Prisma/Postgres + pg-boss + S3 + Winston. Mark what is *intended* vs. *de facto*.
- [ ] Produce a proposed (target) architecture diagram showing the changes you intend to drive over the next 6–12 months.
- [ ] Catalogue cross-cutting concerns and assess consistency:
  - [ ] Error handling: is `AppError` (`src/utils/errors.ts`) used uniformly in tRPC and server actions? Are there ad-hoc `throw new Error(...)` sites?
  - [ ] Logging context: does every long-running operation create a child logger with a context?
  - [ ] Audit trails: the `activity-logs` module — is it invoked on every state-changing action in every module?
  - [ ] Multi-tenancy: is `storeId` (from session) enforced in every Prisma query, or only some?
  - [ ] Idempotency / retries: which mutations are safe to retry and which aren't?
- [ ] Produce a **tech-debt register** with rough cost/impact for each item. Seed it with at minimum:
  - The 457+ Prisma migrations
  - `next.config.ts` `ignoreBuildErrors` and `ignoreDuringBuilds`
  - The experimental server path
  - tRPC + server-action pattern duplication
  - Module-toggle env vars (build-time only)
  - Test coverage gaps on billing, permissions, stock movement
- [ ] Publish all of the above in a discoverable location (e.g. `docs/architecture/` or a Notion space linked from `CLAUDE.md`).

## Phase 3 — Set Standards (Weeks 3–4)

Goal: give contributors clear, written rules so future choices don't require a meeting.

- [ ] **Publish the API surface rule** (tRPC vs. server action) — derived from ADR-0001 — and link it from `CLAUDE.md`.
- [ ] Publish the **authorisation rule**: when to use `authorizeProcedure` in tRPC, `<PermissionGuard>` / `WithPermission` on the client, and `checkPermission` directly in RSC. Include a worked example for each.
- [ ] Publish the **error-handling rule**: how to throw, how to surface to the user, how to log. Include a worked example for tRPC and one for server actions.
- [ ] Publish the **data-layer conventions** for new Prisma models:
  - Soft delete strategy (if any)
  - Required audit fields (`createdBy`, `updatedBy`, `createdAt`, `updatedAt`)
  - `storeId` scoping requirement
  - Indexing policy (foreign keys, frequently filtered columns)
  - Naming (`camelCase` fields, `PascalCase` models, plural route names)
- [ ] Decide and publish a **migration policy**: keep adding forward migrations, schedule a squash, or migrate by date. Whatever you pick, write down the trigger conditions.
- [ ] Decide and publish a **feature-flag story**:
  - Keep env-var toggles for build-time module enablement
  - Introduce a runtime flag system (Postgres-backed is fine) for in-progress modules like `cathlab`, `endo`, `emr`
  - Document how to read a flag in RSC vs. client
- [ ] Publish **naming and structural conventions** for tRPC routers, server actions, pg-boss jobs (queue + job name constants, handler file location), and Zustand stores.
- [ ] Publish the **test pyramid**:
  - Unit tests mandatory for: anything touching billing, permissions, stock movement, auth
  - Component tests for: form submissions, role-gated UI
  - Integration tests via MSW for: tRPC callers
  - E2E (Cypress) for: at least one full critical-path journey per module
  - Always use the custom `render` from `src/test-utils/render.tsx`
- [ ] Add a `docs/standards/` index (or update `CLAUDE.md` "Architecture" section) with links to all of the above.

## Phase 4 — Operate (Ongoing)

Goal: keep the architecture coherent as the codebase grows.

- [ ] **Review PRs for architectural fit, not just correctness** — does the change follow the published standards? Does it leak tenancy? Does it add a new pattern when an existing one would do? Does it touch billing/permissions/stock without adding a test?
- [ ] Drive the **roadmap in priority order** (revisit after Phase 3):
  1. Tenancy and authorisation correctness (audit every Prisma query that touches multi-tenant data)
  2. Remove the build/lint bypass in `next.config.ts` once the codebase is clean
  3. Make the call on the experimental server path
  4. Replace build-time module toggles with runtime flags where it matters
  5. Migration hygiene (prune, squash, or formalise forward-only)
  6. Close critical-path test coverage gaps
- [ ] **Quarterly architecture health-check**:
  - [ ] Dependency audit (`npm outdated`, security advisories)
  - [ ] Prisma schema review (unused models, missing indexes, N+1 patterns)
  - [ ] pg-boss queue health (stuck jobs, queue depth, error rate)
  - [ ] Winston error-log review (Postgres `winston` table)
  - [ ] Dead-code detection
  - [ ] Re-check the tech-debt register — close resolved items, re-rank remaining
- [ ] Maintain the **tech-debt register** as a living document: new debts get logged on discovery, closed debts get a brief post-mortem entry.
- [ ] Run a short **architecture office hour** (weekly, optional) so contributors can raise design questions before they become PRs.
- [ ] Keep `CLAUDE.md` accurate — if the standards change, update the doc in the same PR.

---

## Session Notes

### 2026-06-08 — Git submodule bootstrap for `appointment` and `opd`

The dashboard at `src/app/(dashboard)/common/dashboard/page.tsx` was failing to build with `Module not found` errors for three imports:

- `../../appointment/appointment-list/api/get-appointments` → `appointment/appointment-list/api/get-appointments.ts` (`makeFetchAppointments`)
- `../../appointment/appointment-type/features/api/get-appiontment-type.api` → `appointment/appointment-type/features/api/get-appiontment-type.api.tsx` (`makeGetAppointmentTypeApi`)
- `../../opd/opd-billing/features/api/get-opd-billings.api` → `opd/opd-billing/features/api/get-opd-billings.api.ts` (`makeFetchOpdBillingsQuery`)

**Root cause.** Both folders are git submodules registered in `.gitmodules` but were never initialized, so they were empty directories. The dashboard was authored assuming these modules are present.

**Setup performed.**

1. `gh auth setup-git` — wires git's HTTPS credential helper to the `gh` CLI token. Without this step, `git submodule update` prompts for a username and aborts because `gh` is configured for SSH protocol only, while the `.gitmodules` URLs are HTTPS.
2. `git submodule update --init` — cloned both submodules onto `heads/development`:
   - `src/app/(dashboard)/appointment` → `4994432620a993ce8d41f28e3b7fc3a2ddff8805`
   - `src/app/(dashboard)/opd` → `a64d53ef842d5e48b3bb1b81bd26a103b02a1ac8`

**Submodule map (private repos, `mgmgpyaesonewin` has access).**

| Path | URL |
|---|---|
| `src/app/(dashboard)/appointment` | `https://github.com/MyanCare/YCare-HMS-Appointment-Module.git` |
| `src/app/(dashboard)/opd` | `https://github.com/MyanCare/YCare-HMS-Service-Module.git` |

**Implication for onboarding.** Any new clone of the repo will hit the same empty-folder error. Document in the onboarding steps (or a README) that contributors must run `gh auth setup-git && git submodule update --init` after cloning, or that the modules be added to a project-level bootstrap script. Consider switching the `.gitmodules` URLs to SSH (`git@github.com:...`) so the `gh` SSH keychain works without the `setup-git` step.

**Type-check note.** The default `tsc --noEmit` invocation crashed mid-run with a Node native stack (`node::Realm::ExecuteBootstrapper`) on Node v25.2.0 — unrelated to the submodule issue, but worth revisiting. Use the project's own script `npm run tsc` (which sets `NODE_OPTIONS=--max-old-space-size=8192` and points at `tsconfig.typecheck.json`) when validating changes locally.
