# Runbook

Operational procedures for the Summary Service. Each section is a self-contained recipe: "if you see X, do Y".

**Audience:** hospital IT, on-call admin, anyone responsible for keeping the HMS up.

**Conventions:**
- `HOST` = the on-prem server (single host in v1).
- Run commands as `root` unless noted.
- `journalctl` and `redis-cli` and `psql` are the main tools.

---

## 1. Service is down (systemd unit failing)

**Symptom:** `systemctl status ycare-summary-api.service` or `ycare-summary-worker.service` shows `failed`. The operator notices via `journalctl` monitoring or because the admin page is unresponsive.

**Steps:**

1. Check the recent logs:
   ```bash
   journalctl -u ycare-summary-api.service -n 200 --no-pager
   journalctl -u ycare-summary-worker.service -n 200 --no-pager
   ```
2. Identify the last error before the crash.
3. Common causes:
   - **Postgres is unreachable:** see section 2.
   - **Redis is unreachable:** see section 3.
   - **Missing env file:** `/etc/ycare-summary/env` doesn't exist or has wrong permissions.
   - **Missing HMAC secret:** `/etc/ycare-summary/shared-secret` doesn't exist.
   - **Bad config:** typo in `DATABASE_URL` or `REDIS_URL`.
4. Once the root cause is fixed, the systemd unit will auto-restart. To force a restart:
   ```bash
   systemctl restart ycare-summary-api.service
   systemctl restart ycare-summary-worker.service
   ```
5. Verify the services are healthy:
   ```bash
   systemctl status ycare-summary-api.service
   curl http://127.0.0.1:4000/healthz
   ```

**Verify:** `healthz` returns `{"status":"ok"}`. The worker is consuming the stream (see section 8).

---

## 2. Postgres is down

**Symptom:** API requests return 500 with `error.code: "POSTGRES_UNREACHABLE"`. Worker logs show `prisma` connection errors.

**Steps:**

1. Check Postgres status:
   ```bash
   systemctl status postgresql.service
   ```
2. If Postgres is not running, try to start it:
   ```bash
   systemctl start postgresql.service
   ```
3. If it won't start, check the Postgres logs:
   ```bash
   journalctl -u postgresql.service -n 200 --no-pager
   tail -100 /var/log/postgresql/postgresql-15-main.log
   ```
4. Common causes:
   - Disk full (`df -h`).
   - Corrupted WAL (recovery needed; call DBA).
   - Out of memory (OOM killer; check `dmesg | grep -i oom`).
5. Once Postgres is back, the Summary Service will reconnect automatically (the Prisma client has connection pooling with retry).
6. **The outbox drains automatically** when the worker is back. The HMS continues to write new events to `event_outbox`; those events sit in the table until the worker drains them. No manual replay is needed.

**Verify:** API requests return 200. The admin summary page loads.

---

## 3. Redis is down

**Symptom:** Worker logs show `ECONNREFUSED 127.0.0.1:6379` repeatedly. API responses include `X-Cache-Status: bypass` in the aggregates response.

**Note:** Redis is now a **read-side cache only**. The HMS does not publish to Redis. CFI creation continues to work normally via the Postgres outbox even when Redis is down — only the dashboard counters degrade to the Postgres fallback.

**Steps:**

1. Check Redis status:
   ```bash
   systemctl status redis-server.service
   ```
2. Try to start Redis:
   ```bash
   systemctl start redis-server.service
   ```
3. Check the Redis logs:
   ```bash
   journalctl -u redis-server.service -n 200 --no-pager
   tail -100 /var/log/redis/redis-server.log
   ```
4. **Do NOT restart the worker.** The worker's main loop is the Postgres outbox poll; while Redis is down, it logs warnings on the `HINCRBY` calls and continues processing events. Restarting it doesn't help.
5. Once Redis is back, the worker reconnects automatically. The next admin page-load of any affected day's dashboard repopulates that bucket via cache-aside (Postgres `GROUP BY` → Redis `HSET`). No startup hook, no cron — the read path is the recovery.

**Verify:** Worker log shows `msg: "redis.reconnected"`. API responses show `X-Cache-Status: hit`. Daily counter values match the Postgres aggregate.

---

## 4. CFI creation is lagging behind OPD invoice creation

**Symptom:** the admin summary page shows fewer CFIs than the HMS shows OPD invoices created in the same window. The lag is more than ~5 seconds.

**Steps:**

1. Check the outbox depth:
   ```sql
   SELECT status, count(*),
          min(created_at) AS oldest,
          max(created_at) AS newest
   FROM event_outbox
   WHERE created_at > now() - interval '1 hour'
   GROUP BY status;
   ```
2. Expected in a healthy system: `PENDING` and `IN_PROGRESS` together are ≤ 10. `DONE` grows at the OPD invoice rate.
3. If `PENDING` is large and growing, the worker is the bottleneck — see section 9.
4. If `DONE` is small relative to recent `opd_billings` count, check:
   ```sql
   SELECT count(*) FROM opd_billings WHERE created_at > now() - interval '1 hour';
   SELECT count(*) FROM event_outbox WHERE created_at > now() - interval '1 hour' AND status = 'DONE';
   ```
   These should be approximately equal. If `opd_billings` is much higher, the HMS is not writing to the outbox.
5. If the HMS is not writing to the outbox, this is an HMS bug. Get the HMS team to investigate the OPD billing insertion site. The HMS code change is in their codebase (see `cutover-plan.md` Phase 2 for the diff).
6. If the worker is processing but events are being reset by the reaper repeatedly, see section 9b.

**Verify:** the `PENDING` and `IN_PROGRESS` counts stay near 0. The `DONE` count grows at the OPD invoice rate.

## 5. Outbox is accumulating `DEAD` events

**Symptom:**
```sql
SELECT count(*) FROM event_outbox WHERE status = 'DEAD';
```
returns > 0 and is growing.

**Steps:**

1. Inspect the dead events:
   ```sql
   SELECT id, event_type, aggregate_id, attempt_count,
          left(last_error, 200) AS error_preview,
          created_at, completed_at
   FROM event_outbox
   WHERE status = 'DEAD'
   ORDER BY completed_at DESC
   LIMIT 20;
   ```
2. For each event, the `last_error` and `payload` columns tell you what failed. Common causes:
   - The OPD billing referenced by `aggregate_id` was cancelled or doesn't exist (rolled back in HMS). These can be safely deleted:
     ```sql
     DELETE FROM event_outbox WHERE id = '<event_id>';
     ```
   - A non-retryable error from the CFI insert (e.g. CHECK constraint violation). Fix the data and reset to `PENDING`:
     ```sql
     UPDATE event_outbox
     SET status = 'PENDING', attempt_count = 0, last_error = NULL
     WHERE id = '<event_id>';
     ```
3. If many events have the same symptom, there's a systemic issue. Get the recent `DEAD` rows and send to the dev team:
   ```sql
   \copy (SELECT * FROM event_outbox WHERE status = 'DEAD' ORDER BY completed_at DESC LIMIT 100) TO '/tmp/dead-events.csv' CSV HEADER
   ```

**Verify:** the `DEAD` count returns to 0 (or a stable, low number after manual cleanup).

---

## 6. "ADJUSTMENT_LOCKED" errors in the API log

**Symptom:** API returns 409 with `code: ADJUSTMENT_LOCKED`. Admin says "I can't add an adjustment to a paid invoice."

**This is by design.** Per ADR 0014, once a CFI is `PAID` or `VOID`, the adjustment is locked. The admin must:

- For a `PAID` invoice: corrections are handled through the hospital's separate accounting workflow (out of band). Explain to the admin that the CFI is frozen.
- For a `VOID` invoice: the hospital issues a new OPD billing for the corrected consultation, which the worker picks up as a new CFI.

If the admin disputes this and the hospital's policy is different, this is a v2 feature change. Do not bypass the constraint.

---

## 7. Rotate the HMAC shared secret

**When:** every 90 days, or on suspected compromise.

**Steps:**

1. Generate a new secret on a workstation:
   ```bash
   openssl rand -hex 32
   ```
2. On the host, install the new secret as the "current":
   ```bash
   echo "<new-secret>" > /etc/ycare-summary/shared-secret.new
   chmod 0440 /etc/ycare-summary/shared-secret.new
   chown root:ycare-summary /etc/ycare-summary/shared-secret.new
   ```
3. **Plan a brief outage** (5-10 seconds is enough). Notify any in-flight BFF requests to retry.
4. Restart the Summary Service and the HMS BFF:
   ```bash
   systemctl restart ycare-summary-api.service
   systemctl restart ycare-summary-worker.service
   # Restart the HMS app per its own process model (e.g., pm2 restart, systemctl restart nextjs-hms)
   ```
5. **In-flight requests during the restart will fail with `BAD_SIGNATURE`** if they were signed with the old secret. The BFF should retry on `401`; the UI should show a brief "reconnecting" message.
6. Once both are restarted, the new secret is in use. Old secret is forgotten.
7. Clean up:
   ```bash
   rm /etc/ycare-summary/shared-secret.new
   ```

**Verify:** the API accepts a request signed with the new secret. A request signed with the old secret returns `401 BAD_SIGNATURE`.

**For zero-downtime rotation** (e.g., if the hospital cannot tolerate a 10-second outage), see the dual-secret procedure in `api/hmac-auth.md` (not yet implemented in v1; v1 requires a brief restart).

---

## 8. Verify the worker is processing the outbox

**Steps:**

1. Check the worker is alive:
   ```bash
   systemctl status ycare-summary-worker.service
   ps -ef | grep "summary.*worker"
   ```
2. Check the outbox is draining:
   ```sql
   SELECT status, count(*)
   FROM event_outbox
   GROUP BY status;
   ```
   Expected: a small number of `PENDING` and `IN_PROGRESS` rows (typically 0-10), no growth. `DONE` rows accumulate over time (they're pruned after 7 days).
3. Check the most recent outbox activity:
   ```sql
   SELECT id, status, attempt_count, locked_by, locked_at, completed_at
   FROM event_outbox
   ORDER BY created_at DESC
   LIMIT 20;
   ```
4. If `PENDING` is large and growing, the worker is stuck. See section 9.
5. If `IN_PROGRESS` rows are stuck (locked_at is hours/days old and not being reset), the reaper isn't running. See section 9b.

---

## 9. Worker is stuck (outbox is growing)

**Symptom:** `SELECT count(*) FROM event_outbox WHERE status='PENDING'` returns > 100 and is growing. The admin summary page shows fewer CFIs than expected.

**Steps:**

1. Check the worker process is running:
   ```bash
   systemctl status ycare-summary-worker.service
   ps -ef | grep "summary.*worker"
   ```
2. If the process is running but not processing:
   - Check the worker log for repeated errors:
     ```bash
     journalctl -u ycare-summary-worker.service -n 200 --no-pager
     ```
   - Common cause: a single event is causing the worker to crash on every retry. The event is now `DEAD` (after 5 attempts) but the worker may be looping on a different one.
3. Look for events with high `attempt_count`:
   ```sql
   SELECT id, event_type, aggregate_id, attempt_count, left(last_error, 200)
   FROM event_outbox
   WHERE status = 'IN_PROGRESS'
   ORDER BY attempt_count DESC
   LIMIT 10;
   ```
   If `attempt_count >= 5` and the row is still `IN_PROGRESS` (not `DEAD`), there's a bug — the worker is not transitioning the row.
4. Restart the worker:
   ```bash
   systemctl restart ycare-summary-worker.service
   ```
5. The restart triggers a fresh poll. The reaper (every 5 min) will reset stuck `IN_PROGRESS` rows. The new worker picks them up.

**Verify:** the `PENDING` count returns to 0-10 within 1 minute.

---

## 9b. Reaper is not resetting stuck `IN_PROGRESS` rows

**Symptom:** `SELECT count(*) FROM event_outbox WHERE status='IN_PROGRESS' AND locked_at < now() - interval '5 minutes'` returns > 0.

**Steps:**

1. Check the worker log for reaper activity:
   ```bash
   journalctl -u ycare-summary-worker.service --since "1 hour ago" | grep reaper
   ```
2. If no reaper log lines, the reaper isn't running:
   - Is the worker process up? See section 1.
   - If the worker is up, it may be stuck in the main poll loop. Restart the worker (section 9, step 4).
3. Manually run the reaper query:
   ```sql
   UPDATE event_outbox
   SET status = 'PENDING', locked_by = NULL, locked_at = NULL,
       last_error = coalesce(last_error, '') || ' [manual reap]'
   WHERE status = 'IN_PROGRESS'
     AND locked_at < now() - interval '5 minutes';
   ```
4. After the manual reap, the next poll picks up the rows. The next reaper run will keep them flowing.

**Verify:** the reaper log shows resets every 5 minutes. The `IN_PROGRESS` count stays near 0.

---

## 10. Add a new OPD counter (a new `counterId` in CFIs)

**No action needed.** The data model is keyed on `counter_id` from the start. New counters will appear in CFIs automatically. The Redis aggregates are also keyed on `counter_id` and will populate on first event.

**Verify:** the admin summary page's counter filter shows the new counter.

---

## 11. Disk usage is high

**Symptom:** `df -h` shows > 80% on the data volume.

**Steps:**

1. Identify the largest consumers:
   ```bash
   du -sh /var/lib/postgresql/* /var/lib/redis/* /var/log/ycare-summary /var/log/postgresql /var/log/redis 2>/dev/null
   ```
2. **Redis dump.rdb:** if `/var/lib/redis/dump.rdb` is large, Redis is consuming a lot of memory. The aggregate counters are small; check what's growing. Likely a runaway event or test data.
3. **Postgres WAL:** if `/var/lib/postgresql/15/main/pg_wal/` is large, the WAL archive is not being pruned. This is the hospital's existing backup process — coordinate with the DBA.
4. **Logs:** `journalctl --vacuum-time=7d` cleans systemd journals. The logrotate config in `observability.md` keeps `/var/log/ycare-summary/` to 90 days.

**Verify:** disk usage drops below 70%.

---

## 12. Build a new version of the service

**Steps:**

1. On the dev workstation:
   ```bash
   git pull
   npm install
   npm run build
   ```
2. The build outputs `dist/`. Tar it up:
   ```bash
   tar czf ycare-summary-<version>.tar.gz dist/ package.json
   ```
3. Copy to the host (USB stick, scp, etc. — hospital IT's choice):
   ```bash
   scp ycare-summary-<version>.tar.gz root@<host>:/tmp/
   ```
4. On the host:
   ```bash
   cd /opt/ycare-summary
   systemctl stop ycare-summary-api.service
   systemctl stop ycare-summary-worker.service
   # Save the current version
   mv dist dist.old
   tar xzf /tmp/ycare-summary-<version>.tar.gz
   systemctl start ycare-summary-api.service
   systemctl start ycare-summary-worker.service
   ```
5. **Rollback** if the new version has issues:
   ```bash
   systemctl stop ycare-summary-api.service
   systemctl stop ycare-summary-worker.service
   rm -rf dist
   mv dist.old dist
   systemctl start ycare-summary-api.service
   systemctl start ycare-summary-worker.service
   ```
6. Clean up the old version after a week of stable operation:
   ```bash
   rm -rf /opt/ycare-summary/dist.old
   ```

**Verify:** the new version is healthy (section 1).

---

## 13. Disaster: full server loss

**Symptom:** the on-prem server is destroyed (hardware failure, theft, fire). A backup exists.

**Steps:**

1. Provision a new server with the same OS (Ubuntu 22.04 LTS) and the assumed specs (4 vCPU, 16 GB RAM, 100 GB SSD).
2. Restore Postgres from the latest backup:
   ```bash
   systemctl start postgresql.service
   # Restore per the hospital's existing Postgres restore procedure.
   ```
3. Install Redis:
   ```bash
   apt install redis-server
   systemctl enable --now redis-server
   ```
4. Install Node.js 20 LTS:
   ```bash
   # Use the NodeSource binary distribution
   ```
5. Install the Summary Service (section 12).
6. Restore `/etc/ycare-summary/` from the config backup. This includes the HMAC secret — if the BFF on the new server doesn't have the matching secret, all requests will fail. Coordinate with the HMS team.
7. Start the services. The first admin page-load of each affected day repopulates Redis via cache-aside. No startup hook, no cron.

**Verify:** the admin summary page shows the recent CFIs. The OPD counter flow works end-to-end.

**Recovery time:** depends on the hospital's backup restore SLA. Typically 1-4 hours.

---

## Reference: useful one-liners

```bash
# Today's CFI count
psql -d ycare_hms -c "SELECT count(*) FROM consultation_fees_invoices WHERE billing_date::date = current_date;"

# Today's status breakdown
psql -d ycare_hms -c "SELECT status, count(*), sum(amount), sum(payout_amount) FROM consultation_fees_invoices WHERE billing_date::date = current_date GROUP BY status;"

# Outbox health
psql -d ycare_hms -c "SELECT status, count(*), min(created_at) AS oldest FROM event_outbox GROUP BY status;"

# Stuck IN_PROGRESS rows (reaper should reset these within 5 min)
psql -d ycare_hms -c "SELECT id, locked_by, locked_at, attempt_count FROM event_outbox WHERE status='IN_PROGRESS' AND locked_at < now() - interval '5 minutes';"

# DEAD events (need operator action)
psql -d ycare_hms -c "SELECT id, event_type, aggregate_id, attempt_count, left(last_error, 100) FROM event_outbox WHERE status='DEAD' ORDER BY completed_at DESC LIMIT 10;"

# Recent errors
journalctl -u ycare-summary-{api,worker}.service --since "1 hour ago" -p err

# Aggregate count for today, for a specific tenant
redis-cli HGETALL summary:consultation_fees:<tenant-uuid>:$(date +%Y-%m-%d):all

# Tail the API log
tail -f /var/log/ycare-summary/api.log | jq -c .

# Tail the worker log
tail -f /var/log/ycare-summary/worker.log | jq -c .
```
