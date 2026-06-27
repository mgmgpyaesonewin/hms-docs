# Onboarding — `infra/` (local dev orchestration)

> Docker Compose for the full stack: Postgres + Redis + HMS + summary-api + summary-worker. **Dev-only** — production deploys are ECR/k8s for `hms-app` and two systemd units for `hms-summary-service`.

---

## 1. Layout

```
infra/
├── docker-compose.yml         the full stack
├── db/                        Postgres init scripts (run once on first boot)
│   ├── 01-hms-schema.sql      236 HMS tables (dumped from prod RDS)
│   ├── 02-summary-dev-bridge.sql  plpgsql uuidv7() + pgcrypto
│   ├── 03-summary-schema.sql  (superseded — tables live in HMS Prisma migrations)
│   ├── 04-import-hms-data.sh  FK-trigger-disabling loader
│   └── 05-hms-data.dmp        gitignored ~140MB prod-data dump
└── scripts/
    └── dump-hms-data.sh       generates 05-hms-data.dmp from prod RDS
```

`/docker-entrypoint-initdb.d/` runs these in alphabetical order **only on first init** (empty volume). Re-running `docker compose up` against an existing volume does NOT re-apply them — `docker compose down -v` to re-bootstrap.

---

## 2. One-time setup

```bash
cd infra
cp ../hms-app/.env.example ../hms-app/.env      # edit DATABASE_URL, module toggles
cp .env.example .env                            # optional infra overrides
docker compose up -d
```

Service → host port map:

| Service          | Host port | Notes |
| --- | --- | --- |
| `postgres`       | 5433 | matches the legacy `hms-app/docker-compose.yml` |
| `redis`          | 6379 | local dev only |
| `hms-app`        | 3000 | Turbopack dev server, hot-reload |
| `summary-api`    | 4000 | Express, hot-reload via `tsx watch` |
| `summary-worker` | — | outbox poller; same image, `--mode=worker` |

First boot = a few minutes (cold `npm ci`). Subsequent boots are instant.

---

## 3. Common commands

```bash
docker compose -f infra/docker-compose.yml up -d               # start
docker compose -f infra/docker-compose.yml logs -f             # tail all
docker compose -f infra/docker-compose.yml logs -f summary-api summary-worker
docker compose -f infra/docker-compose.yml exec postgres \
  psql -U admin -d ycare_hms_dev                                # psql
docker compose -f infra/docker-compose.yml exec redis redis-cli
docker compose -f infra/docker-compose.yml exec summary-api sh  # shell into a service

# DESTRUCTIVE — wipes ALL volumes (DB, node_modules, etc.)
docker compose -f infra/docker-compose.yml down -v
```

---

## 4. Things that bite

- **`DATABASE_URL` in `hms-app/.env` is overridden by the compose file** (intentionally). Inside the compose network, `postgres:5432` is the right target; `localhost` would point at the container itself. Don't "fix" the compose value to match your local `.env`.
- **Hot-reload only works for source edits.** Adding a dep doesn't re-run `npm ci`. Fix: `docker volume rm infra_hms-app_node_modules infra_summary-api_node_modules` then `up -d`.
- **`BIND_ADDRESS` is `0.0.0.0` in this stack** so both hms-app and the host can reach the summary service. Production binds to `127.0.0.1` (ADR 0002).
- **No HMAC in v1 dev.** Hitting `http://localhost:4000` with `curl` works without headers. The BFF passes `X-Tenant-Id` as a plain header; real HMAC is a v2 follow-up.
- **No `event_outbox` rows on first boot** — the HMS doesn't yet insert outbox rows at OPD-billing time (Phase 3 of the summary service). To exercise the summary worker in isolation, insert rows via `psql` (see `infra/README.md` §"Smoke test the summary service").
- **Data volume carries over if you DON'T pass `-v`.** If you switched from the legacy `hms-app/docker-compose.yml`, your old data lives in a `hms-app_postgres_data` volume and will NOT show up in `infra_postgres_data`.

---

## 5. Reset recipes

```bash
# Reset DB only (DESTRUCTIVE)
docker compose -f infra/docker-compose.yml down
docker volume rm infra_postgres_data
docker compose -f infra/docker-compose.yml up -d

# Reset node_modules after editing package.json
docker compose -f infra/docker-compose.yml down
docker volume rm infra_hms-app_node_modules \
               infra_summary-api_node_modules \
               infra_summary-worker_node_modules
docker compose -f infra/docker-compose.yml up -d

# Nuclear option — wipe EVERYTHING
docker compose -f infra/docker-compose.yml down -v
```