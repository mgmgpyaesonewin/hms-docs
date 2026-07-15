# YCare HMS — Workspace Onboarding

> On-call-ready orientation for the YCare HMS monorepo. Two services share one Postgres; the design repo (`hms-docs/`) is the source of truth for the *why*, sibling repos hold the code.

**Audience:** engineers, tech leads, contractors joining the HMS team.
**Time to first running stack:** ~10 min on a clean laptop.

## Related concepts

Use the Obsidian graph view (`Ctrl/Cmd+G`) to navigate between these nodes:

- [[INDEX|Vault index]] — Map of Content for the design vault.
- [[summary-service/README|Summary Service]] — Express microservice for OPD consultation-fee invoicing.
- [[summary-service/adrs/0001-trigger-mechanism|Outbox trigger (ADR 0001)]]
- [[summary-service/adrs/0005-state-machine|CFI state machine (ADR 0005)]]
- [[summary-service/adrs/0007-multi-tenancy-enforcement|Multi-tenancy (ADR 0007)]]
- [[summary-service/adrs/0009-redis-cache-model|Redis cache model (ADR 0009)]]
- [[hms-app/api/manifest|HMS REST manifest]] — documented routes for the monolith.
- [[onboarding/hms-app]] · [[onboarding/hms-summary-service]] · [[onboarding/infra]] — per-service packets.
- [[ops/README|Ops]] · [[code-reviews/README|Code reviews]] · [[prompts/README|Prompts]]

---

## 1. What this repo is

```
hms-system/
├── hms-app/                Next.js 15 monolith — the HMS UI + REST + BFF
├── hms-summary-service/    Express + TS microservice — Consultation Fees Invoices
├── infra/                  Local dev orchestration (docker-compose)
└── hms-docs/               This repo — ADRs, schemas, OpenAPI, runbooks
```

Two services, one Postgres. `hms-app` is the source-of-truth writer for OPD billings; `hms-summary-service` polls a transactional outbox (`event_outbox`) and materializes `consultation_fees_invoices` rows. The HMS does **not** call the summary service directly in v1 — both run on the same host and share the DB.

---

## 2. Quick start (full stack)

```bash
# from hms-system/
cd infra
cp ../hms-app/.env.example ../hms-app/.env   # edit DATABASE_URL, module toggles
docker compose up -d                        # postgres + redis + hms-app + summary-api + summary-worker

# verify
curl http://localhost:3000                  # HMS login page
curl http://localhost:4000/healthz          # {"status":"ok","db":"up","redis":"up"}
```

First boot takes a few minutes (cold `npm ci` inside containers). Subsequent boots are instant. **Data is empty by default** — see `infra/README.md` §"Populating real data" for the optional prod-data dump.

### Single-service dev

If you only need the HMS UI:

```bash
cd hms-app
docker compose up db          # legacy compose — Postgres only
npm install
npm run dev                   # http://localhost:3000, Turbopack
```

If you only need the summary service against a real DB:

```bash
cd hms-summary-service
npm install
npm run prisma:generate
npm run dev:api               # 127.0.0.1:4000
# second terminal:
npm run dev:worker            # outbox poller + reaper + pruner
```

---

## 3. Tech stack at a glance

| Layer | HMS (`hms-app`) | Summary (`hms-summary-service`) |
| --- | --- | --- |
| Runtime | Next.js 15 (App Router) + custom Express server | Node 20 + Express 4 |
| Language | TypeScript | TypeScript |
| UI | Mantine v7, Tailwind, custom design tokens | n/a (HTTP only) |
| API style | Next.js Route Handlers (`src/app/api/`); legacy tRPC kept around | REST + OpenAPI 3 |
| Auth | Custom session-based (Argon2) + `next-safe-action` `authActionClient` | HMAC-SHA256 service-to-service (see ADR 0008) |
| Data | Prisma + Postgres 17, pg-boss jobs | Prisma subset + Postgres + Redis (counters) |
| Background | pg-boss | Outbox poller, reaper, pruner (in-process) |
| Tests | Jest, Cypress | Jest (tenant-scope, unit) |
| Logs | Winston | pino + pino-http |
| Deploy | Docker → ECR + k8s | Two systemd units on-prem (`ycare-summary-api`, `ycare-summary-worker`) |

---

## 4. Day-1 reading order

1. `hms-system/CLAUDE.md` — workspace map.
2. `hms-docs/summary-service/README.md` — the most active design folder (14 ADRs).
3. `hms-app/CLAUDE.md` *(if present)* — HMS-specific guardrails.
4. `infra/README.md` — dev stack contract.
5. Then the per-service onboarding: [`onboarding/hms-app.md`](./onboarding/hms-app.md), [`onboarding/hms-summary-service.md`](./onboarding/hms-summary-service.md), [`onboarding/infra.md`](./onboarding/infra.md).

---

## 5. The "do not" list

- **Do not** install new npm dependencies in `hms-app` without consulting a teammate. The lockfile is sacred; the bundle is budgeted.
- **Do not** change `prisma/schema.prisma` without a peer review. Migrations are tested against prod-shaped data.
- **Do not** change the summary service schema outside the agreed CHECK constraints in `hms-docs/summary-service/data-model/schema.sql`. The Prisma file is a subset.
- **Do not** introduce BullMQ / Redis Streams / pg-boss as a second consumer of `event_outbox`. The outbox is the contract.
- **Do not** commit `.env`, `infra/db/05-hms-data.dmp`, or anything that smells like prod data. The data dump is gitignored for a reason (real patient records).
- **Do not** skip running `npm run tsc` + `npm run lint` locally before opening a PR — `next build` ignores both.

---

## 6. Common contributor tasks

| Task | Where to start |
| --- | --- |
| Add an HMS REST route | `hms-app/src/app/api/<resource>/route.ts` + update `hms-docs/api/manifest.yaml` |
| Add a feature module | `hms-app/src/app/(dashboard)/<module>/` (mirror existing modules: `opd`, `pharmacy`, `ipd`, `appointment`, …) |
| Add a tRPC router | `hms-app/src/lib/trpc/routers/` *(legacy — prefer Route Handlers)* |
| Add a background job | `hms-app/src/lib/pg-boss/` (existing pattern) |
| Change CFI behaviour | `hms-summary-service/src/services/cfi-service.ts` — first read ADR 0005, 0006, 0014 |
| Add an HTTP endpoint | `hms-summary-service/src/http/routes/cfi.routes.ts` + OpenAPI in `hms-docs/summary-service/api/openapi.yaml` |
| Write an ADR | `hms-docs/summary-service/adrs/NNNN-short-title.md` (use `summary-service/adrs/_template.md` if present) |

---

## 7. Where to get help

| Question | Go to |
| --- | --- |
| "Why is X built this way?" | `hms-docs/summary-service/adrs/` (14 ADRs) or grep the relevant folder for `ADR` references |
| "How do I deploy / roll back?" | `hms-docs/summary-service/ops/` (systemd units, runbook, cutover plan) |
| "What's the API contract?" | `hms-docs/api/manifest.yaml` (HMS REST) or `hms-docs/summary-service/api/openapi.yaml` (summary service) |
| "Where's the DDL?" | `hms-docs/summary-service/data-model/schema.sql` |
| "What's the runtime topology?" | `hms-docs/summary-service/diagrams/` (C4 + sequence) |
| "How do I test a thing locally?" | `infra/README.md` for the full stack; per-service onboarding for single-service dev |

---

## 8. Audience-specific entry points

- **Junior engineer:** start with `hms-app/CLAUDE.md` + the OPD module (`hms-app/src/app/(dashboard)/opd/`) end-to-end. Follow tests as executable specs. Don't touch the schema alone.
- **Senior engineer:** read the ADRs first (`hms-docs/summary-service/adrs/`), then `hms-app/src/lib/db.ts` + the `pg-boss` setup. Validate perf/auth assumptions before refactoring.
- **Contractor / scoped contributor:** stay inside one feature module or one microservice. The two services have **separate Prisma schemas**, **separate test suites**, and **separate deploy pipelines** — you should rarely need to touch more than one.

---

## 9. Service health at a glance

```bash
# HMS
curl -sI http://localhost:3000 | head -1                    # 200
# Postgres
docker compose -f infra/docker-compose.yml exec postgres \
  pg_isready -U admin -d ycare_hms_dev
# Redis
docker compose -f infra/docker-compose.yml exec redis redis-cli ping
# Summary service
curl -s http://localhost:4000/healthz | jq                  # {"status":"ok","db":"up","redis":"up"}
```

If anything is degraded, the summary service `/healthz` returns **503** with the failing component named.