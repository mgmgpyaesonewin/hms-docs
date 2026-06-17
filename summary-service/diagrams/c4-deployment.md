# C4 — Deployment View

A single on-prem host running the entire stack. The deployment is bare-metal (Ubuntu 22.04 LTS) with systemd supervision.

```mermaid
C4Deployment
    title Deployment View: Single on-prem host, Ubuntu 22.04 LTS

    Deployment_Node(host, "Hospital Server", "Ubuntu 22.04 LTS, 4 vCPU, 16 GB RAM, 100 GB SSD") {
        Deployment_Node(systemd, "systemd (PID 1)", "Ubuntu systemd") {
            Container_Node(api_unit, "ycare-summary-api.service", "systemd unit") {
                Container(api_proc, "summary-api process", "Node.js 20 LTS, --mode=api") {
                    Component(api_code, "Express HTTP API", "src/api/")
                }
            }
            Container_Node(worker_unit, "ycare-summary-worker.service", "systemd unit") {
                Container(worker_proc, "summary-worker process", "Node.js 20 LTS, --mode=worker") {
                    Component(worker_code, "Outbox poller, reaper, pruner", "src/worker/")
                }
            }
            Container_Node(hms_unit, "nextjs-hms.service", "systemd unit, existing") {
                Container(nextjs_proc, "Next.js server", "Node.js 20 LTS") {
                    Component(nextjs_code, "Next.js + tRPC BFF", "src/app/")
                }
            }
            Container_Node(redis_unit, "redis-server.service", "systemd unit") {
                Container(redis_proc, "redis-server", "Redis 7") {
                    ComponentDb(redis_data, "Aggregate counters", "summary:consultation_fees:*")
                }
            }
            Container_Node(postgres_unit, "postgresql.service", "systemd unit, existing") {
                Container(postgres_proc, "postgres", "PostgreSQL 15") {
                    ComponentDb(pg_data, "HMS + summary tables", "consultation_fees_invoices, event_outbox, ...")
                }
            }
        }

        Deployment_Node(fs, "Filesystem", "ext4 / btrfs") {
            ContainerDb(logs, "/var/log/ycare-summary/", "api.log, worker.log, error.log. logrotate daily, 90d retention")
            ContainerDb(env, "/etc/ycare-summary/env", "DATABASE_URL, REDIS_URL, LOG_LEVEL, HOSTNAME_SHORT, OUTBOX_*, PRUNER_*")
        }
    }
```

## Network topology

```
[ Hospital LAN, private 192.168.0.0/16 ]
                        │
                        │  admin browsers
                        ▼
            ┌──────────────────────┐
            │  Hospital Server      │
            │  192.168.x.x          │  ◀── single NIC, single IP
            │                       │
            │  localhost (127.0.0.1):│
            │    :3000  Next.js      │  ◀── accessed by admin via :3000 from LAN
            │    :4000  Summary API  │  ◀── 127.0.0.1 only, NOT exposed to LAN
            │    :5432  Postgres     │  ◀── 127.0.0.1 only
            │    :6379  Redis        │  ◀── 127.0.0.1 only
            │                       │
            │  Filesystem:          │
            │    /etc/ycare-summary │
            │    /var/log/ycare-summary
            │    /opt/ycare-summary │  ◀── app install dir
            └──────────────────────┘
```

**No port is exposed to the LAN except 3000 (Next.js).** The Summary Service API binds to 127.0.0.1:4000. The HMS BFF calls it via `http://127.0.0.1:4000`. An external attacker on the LAN cannot reach the Summary Service directly.

## systemd unit responsibilities

- `ycare-summary-api.service` — `ExecStart=/usr/bin/node /opt/ycare-summary/dist/index.js --mode=api`, `Restart=on-failure`, `RestartSec=5`, `EnvironmentFile=/etc/ycare-summary/env`, `User=ycare-summary`, `Group=ycare-summary`, `LimitNOFILE=65536`.
- `ycare-summary-worker.service` — `ExecStart=/usr/bin/node /opt/ycare-summary/dist/index.js --mode=worker`, `Restart=on-failure`, `RestartSec=5`, same env file and user.
- **No automated alerting in v1.** systemd's `Restart=on-failure` brings the unit back; the operator monitors health via `journalctl -u ycare-summary-api -u ycare-summary-worker -f` and the structured log files under `/var/log/ycare-summary/`. If the hospital later wants push-based alerts, they can drop in `monit`, a healthchecks.io ping, or a Nagios check against `/healthz` — none of which need to be designed now.

## Filesystem layout

| Path | Owner | Mode | Purpose |
|---|---|---|---|
| `/opt/ycare-summary/` | `root:ycare-summary` | 0750 | App install dir |
| `/opt/ycare-summary/dist/` | `root:ycare-summary` | 0750 | Compiled JS |
| `/etc/ycare-summary/env` | `root:ycare-summary` | 0640 | Env vars (DATABASE_URL etc.) |
| `/var/log/ycare-summary/` | `ycare-summary:ycare-summary` | 0750 | Log files |

## Backup hooks

- A backup of `/etc/ycare-summary/` is taken nightly.
- A backup of `/var/log/ycare-summary/` is taken weekly (longer retention than the on-host logrotate).
- The Postgres backup (existing hospital policy) covers all DB state.

## Scaling

If the host becomes a bottleneck (see `ops/capacity-plan.md`):

- **Vertical:** upgrade CPU/RAM. Easiest.
- **Horizontal (read API only):** add a second Summary API process on a second host. The API is stateless (the DB has all the data). The worker stays on the primary to avoid two workers racing on the outbox.
- **Horizontal (worker):** possible with `FOR UPDATE SKIP LOCKED` guaranteeing no double-processing, but Postgres connection count becomes the bottleneck before worker count does. Only worth it if outbox processing rate is the constraint.
