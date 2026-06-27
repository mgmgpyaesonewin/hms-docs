# Onboarding — `hms-app` (Next.js monolith)

> The HMS you see in the browser. Next.js 15 + App Router, Mantine v7, Prisma/Postgres, custom session auth, pg-boss for jobs.

---

## 1. What's where

```
hms-app/
├── src/
│   ├── app/
│   │   ├── (auth)/             login / logout routes
│   │   ├── (dashboard)/        feature-grouped UI (opd, ipd, pharmacy, …)
│   │   ├── api/                REST route handlers (the canonical API surface)
│   │   ├── layout.tsx          root layout (Mantine provider, theme, error boundary)
│   │   ├── global-error.tsx    Sentry-aware root error boundary
│   │   ├── providers.tsx       client-side context providers
│   │   └── unauthorized.tsx    403 page
│   ├── components/             shared UI primitives
│   ├── lib/
│   │   ├── db.ts               PrismaClient singleton (HMR-safe)
│   │   ├── safe-action.ts      next-safe-action clients (authActionClient)
│   │   ├── trpc/               legacy tRPC routers (see §6)
│   │   ├── pg-boss/            background job queue (Postgres-backed)
│   │   ├── winston.ts          structured logger
│   │   ├── theme.tsx           Mantine theme tokens
│   │   ├── tokens.ts           design tokens (colors, typography)
│   │   ├── api-client.ts       fetch wrapper
│   │   └── navigation-progress.tsx
│   ├── utils/                  general helpers (action-utils, errors, date utils, …)
│   ├── contracts/              shared API contract types
│   └── instrumentation.ts      server entry hooks (Sentry, monitoring)
├── prisma/
│   ├── schema.prisma           canonical schema (236 models)
│   ├── client.ts               PrismaClient export
│   └── migrations/             timestamped SQL migrations
├── server.ts                   custom Express wrapper around Next.js (optional)
├── next.config.ts              Next.js config (ignores ESLint/TS errors at build)
├── cypress.config.ts           E2E tests
└── .env                        local secrets (gitignored)
```

Path aliases (see `tsconfig.json`): `@/*`, `@common/*`, `@opd/*`, `@pharmacy/*`, `@appointment/*`, `@shared/*`, `@ipd/*`. Use them — relative imports across feature folders are a smell.

---

## 2. Setup (5 min)

```bash
cd hms-app
cp .env.example .env             # edit DATABASE_URL at minimum

docker compose up -d db          # legacy compose, Postgres only
# — or —
cd ../infra && docker compose up -d   # full stack (Postgres + Redis + summary)

npm install
npm run prisma:generate          # generates the typed client
npm run migrate:deploy           # apply migrations to the dev DB
npm run db:seed                  # optional: seeds reference data

npm run dev                      # http://localhost:3000
```

**Verify:**

- `http://localhost:3000` loads the login page.
- `docker compose exec db pg_isready -U admin` → `accepting connections`.
- `npm run test:unit` passes (the curated fast subset — see `package.json` `test:unit` script).

---

## 3. Scripts you'll actually use

| Script | What it does |
| --- | --- |
| `npm run dev` | Turbopack dev server on `:3000` |
| `npm run dev:experimental` | Express wrapper around Next.js (`server.ts`) — useful when you need custom Express middleware |
| `npm run build` | `next build` — **does not** type-check (see caveats) |
| `npm run tsc` | `tsc --noEmit` against `tsconfig.typecheck.json` — **the source of truth for type safety** |
| `npm run lint` | `next lint` |
| `npm run migrate:dev` | Create + apply a new migration in dev |
| `npm run migrate:deploy` | Apply existing migrations (CI / prod) |
| `npm run db:seed` | Seed reference data |
| `npm run test` / `test:ci` | Full Jest suite |
| `npm run test:unit` | Curated subset — runs in seconds, run before pushing |
| `npm run cypress:open` | E2E browser tests |

---

## 4. Auth model

- **Login** goes through `src/app/(auth)/` route handlers → sets a signed session cookie.
- **Server actions** must use `authActionClient` from `src/lib/safe-action.ts`, **not** the bare `actionClient`. The auth client calls `verifyAuth()` and injects `ctx.session`.
- **Route handlers** call `verifyAuth()` (or `authorizeProcedure(action, subject)` for tRPC) explicitly.
- Password hashing: Argon2.
- Roles: `isSuperadmin` on `User`, plus `roleId` → `Role` table.

See `src/lib/safe-action.ts` for the canonical pattern.

---

## 5. Data access

- **Always** go through the Prisma client in `src/lib/db.ts`. That singleton survives Next.js HMR — don't import `@prisma/client` directly in route handlers.
- **Multi-tenancy:** the DB is shared with the summary service but tenant-scoping is enforced at the summary service edge (HMAC `X-Tenant-Id` → Prisma extension). The HMS itself does not need tenant scope in queries because it owns the schema.
- **Migrations** are timestamped and live in `prisma/migrations/`. The HMS team runs them; the summary service never migrates the shared DB.

---

## 6. Legacy: tRPC

`tRPC` is deprecated but still around (`src/lib/trpc/`). New endpoints should be **Next.js Route Handlers** in `src/app/api/`. If you must add a tRPC procedure:

- Add the procedure under `src/lib/trpc/routers/<domain>.ts`.
- Register it in `src/lib/trpc/server.ts`.
- Mirror the contract in `hms-docs/api/manifest.yaml` (the manifest is the source of truth, not the code).

Do not introduce new tRPC routers without a written reason.

---

## 7. Background jobs (pg-boss)

- Worker entry: `src/lib/pg-boss/pg-boss.ts`.
- pg-boss stores queues in Postgres — no extra infra.
- Queue handlers go alongside their callers (co-located under `src/app/(dashboard)/<module>/`).
- If you add a queue, document it in `infra/README.md` if it crosses services (it shouldn't).

---

## 8. Feature module conventions

Each feature under `src/app/(dashboard)/<module>/` follows this shape:

```
<module>/
├── page.tsx                   list page
├── [id]/page.tsx              detail page
├── add/page.tsx               create page (or modal in list)
├── features/
│   ├── api/                   server-only data access (Prisma + Zod)
│   ├── components/            UI components
│   ├── schemas/               Zod schemas (shared between client + server)
│   └── utils/                 pure helpers
└── __tests__/                 colocated tests (.node.test.ts / .dom.test.ts)
```

Look at `src/app/(dashboard)/opd/` or `src/app/(dashboard)/pharmacy/` as canonical examples — both have Zod schemas, server actions, and table components following the same pattern.

---

## 9. Caveats (read these before your first PR)

- **`next.config.ts` ignores ESLint and TS errors at build time.** Always run `npm run tsc` and `npm run lint` locally before pushing.
- **Migrations are a team sport.** `prisma migrate dev` works locally; for shared changes, post the migration file in the PR and ping a teammate before merging.
- **Don't add npm dependencies without a heads-up.** The bundle is budgeted.
- **Module toggles** (`NEXT_PUBLIC_OPD_MODULE_ENABLED`, `NEXT_PUBLIC_IPD_MODULE_ENABLED`, `NEXT_PUBLIC_APPOINTMENT_MODULE_ENABLED`) gate top-level nav. Default all three `true` for local dev.
- **`LOG_LEVEL`** defaults to `info`; bump to `debug` to see Prisma query logs and tRPC traces.

---

## 10. Troubleshooting

| Symptom | First check |
| --- | --- |
| `PrismaClientInitializationError` | `docker compose ps` — is the DB up? Is `DATABASE_URL` right? |
| Login loops back to `/login` | Cookie domain mismatch — check `NEXT_PUBLIC_URL` matches the URL in the browser bar |
| Build passes locally but CI fails type-check | You skipped `npm run tsc` — fix the errors, don't disable them |
| Mantine component not styled | Check the provider chain in `src/app/providers.tsx` |
| tRPC router not found | Did you register it in `src/lib/trpc/server.ts`? |
| pg-boss job silently dropped | Job handler threw — check `winston` logs under `context: "pg-boss"` |