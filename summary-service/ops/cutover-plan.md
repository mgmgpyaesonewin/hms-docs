# Cutover / Migration Plan

How the Summary Service goes from "code on disk" to "live in production serving the admin summary page". Phased rollout with a clear rollback path at each phase.

---

## Phase 0 — Pre-flight (no HMS change yet)

**Goal:** install the Summary Service and verify it runs.

**Steps:**

1. Apply the database migration (`prisma migrate deploy`):
   ```bash
   cd /opt/ycare-summary
   npx prisma migrate deploy
   ```
   This creates the new tables (event_outbox + CFI + audit tables) and the `pg_trgm` GIN index on `lower(invoice_no)`. Idempotent. The migration enables the `pg_trgm` extension if it isn't already.

2. Write `/etc/ycare-summary/env` from the template in `ops/env.template`. The HMS team owns this file.

3. Install the systemd units:
   ```bash
   cp ops/ycare-summary-api.service /etc/systemd/system/
   cp ops/ycare-summary-worker.service /etc/systemd/system/
   systemctl daemon-reload
   ```

4. Start the services:
   ```bash
   systemctl enable --now ycare-summary-api.service
   systemctl enable --now ycare-summary-worker.service
   ```

5. Verify they're running:
   ```bash
   systemctl status ycare-summary-api.service
   systemctl status ycare-summary-worker.service
   curl http://127.0.0.1:4000/healthz
   # Expected: {"status":"ok","uptimeSeconds":<n>}
   ```

6. **Verify the worker is polling the (empty) outbox:**
   ```bash
   journalctl -u ycare-summary-worker.service -n 50
   # Expected: log lines about poll claims, no events yet
   psql -d ycare_hms -c "SELECT status, count(*) FROM event_outbox GROUP BY status;"
   # Expected: 0 rows in all statuses
   ```

**Rollback:** stop and disable the services. The DB migration stays (harmless if unused). No user-facing impact.

**Duration:** ~15 minutes.

---

## Phase 1 — BFF integration, no HMS outbox writing yet

**Goal:** verify the BFF can talk to the Summary Service. The BFF makes requests but the HMS does NOT write to the outbox yet. The Summary Service receives queries and returns empty results.

**Steps:**

1. Update the HMS BFF to call the Summary Service for the new "Consultation Fee Report" page.
2. Use the BFF's existing admin permission system (`consultation_fees:write` per the brief assumption).
3. Deploy the BFF change. The page loads but shows "no data" (the database has 0 CFIs).
4. Manually create a test CFI row in the DB (for QA only, never in production):
   ```sql
   INSERT INTO consultation_fees_invoices (id, tenant_id, event_id, opd_invoice_id, ...)
   VALUES (...);
   ```
5. Verify the page renders the test row.

**Rollback:** revert the BFF deploy. No DB impact.

**Duration:** ~1 day (includes QA).

---

## Phase 2 — HMS writes to the outbox (canary)

**Goal:** the HMS inserts an `event_outbox` row in the same transaction as the OPD billing insert. A small percentage of OPD invoice creations exercise the path. The Summary Service creates CFIs from real data.

**Steps:**

1. Add the `EventOutbox` model to the HMS Prisma schema (see `data-model/prisma-additions.prisma`). Run `npx prisma migrate dev --name add_event_outbox` to apply the migration.

2. At the OPD invoice creation site (find it via `grep -rn "opdBilling.create" src/`), extend the existing transaction to also insert the outbox row:
   ```ts
   await prisma.$transaction(async (tx) => {
     const opdBilling = await tx.opdBilling.create({
       data: { /* ... existing fields ... */ }
     });

     await tx.eventOutbox.create({
       data: {
         id: crypto.randomUUID(),
         tenantId,
         eventType: "opd_invoice.created",
         aggregateId: opdBilling.id,
         payload: {
           eventId: crypto.randomUUID(),
           tenantId,
           opdInvoiceId: opdBilling.id,
           createdAt: opdBilling.createdAt.toISOString(),
         },
       },
     });

     return opdBilling;
   });
   ```

3. Deploy the HMS change behind a feature flag (`ENABLE_SUMMARY_OUTBOX`). Start with the flag OFF.

4. Test in a non-production environment end-to-end. Verify the worker creates CFIs. Verify the admin summary page shows them.

5. **Canary:** enable the flag for a specific counter (e.g., the main OPD counter only). Monitor for 1 hour:
   - CFI count grows at the expected rate.
   - `SELECT count(*) FROM event_outbox WHERE status='PENDING'` stays near 0.
   - No `DEAD` events appear.
   - No errors in the worker log.

6. **Full rollout:** enable the flag for all counters. Monitor for 1 day.

**Rollback:**

- Disable the feature flag. New OPD invoices no longer write to the outbox.
- Existing CFIs are unaffected.
- Existing outbox rows in `PENDING` continue to be processed (the worker doesn't know about the flag). If you want a hard stop, also stop the worker.
- The Summary Service is in a "no new data" state; the admin page shows the last set of CFIs from the canary.

**Duration:** ~1 week (1 day canary + 1 week observation + buffer).

---

## Phase 3 — Outbox + reaper validation

**Goal:** verify the outbox flow end-to-end, including the stale-claim reaper for worker crashes.

**Steps:**

1. Verify the basic flow: create a real OPD invoice in the HMS UI. Within 2 seconds, verify:
   - A row appears in `event_outbox` with `status = 'DONE'`.
   - A corresponding CFI appears in `consultation_fees_invoices`.
2. Verify the reaper: simulate a stuck claim by manually updating a row to `IN_PROGRESS` with an old `locked_at`:
   ```sql
   UPDATE event_outbox
   SET status = 'IN_PROGRESS', locked_at = now() - interval '10 minutes', locked_by = 'simulated-crash'
   WHERE id = '<some_event_id>';
   ```
3. Wait 5 minutes. Verify the row is reset to `PENDING` and re-claimed by the worker within the next poll.
4. Verify the worker's log contains a `reaper.reset` line for this event.
5. Verify idempotency: re-run the same event (re-set to PENDING, or wait for the reaper). The CFI insert is a no-op (the `ON CONFLICT (event_id) DO NOTHING` kicks in). The Redis `HINCRBY` is also a no-op (the `seen_events` set in the Lua script catches the duplicate).

**Rollback:** N/A — this is a validation step.

**Duration:** ~30 minutes.

---

## Phase 4 — Admin UI live, monitoring on

**Goal:** the admin uses the new "Consultation Fee Report" page in production. The hospital IT team monitors.

**Steps:**

1. Confirm the "Consultation Fee Report" tab is visible in the HMS admin navigation.
2. Confirm the page loads with the expected data.
3. Confirm the page filter (date, counter, doctor, status, search) works.
4. Confirm status updates work end-to-end.
5. Confirm adjustment updates work end-to-end (and are blocked once `PAID`).
6. **Daily check-in for 1 week:**
   - Outbox `PENDING` and `IN_PROGRESS` counts stay near 0 (worker is keeping up).
   - `DEAD` count is 0 (no poison events).
   - Worker CPU and memory are within expected ranges.

**Rollback:** disable the admin tab in the HMS UI. Keep the worker running to drain any in-flight events. After 1 day of inactivity, the worker can be stopped.

**Duration:** ~1 week of active monitoring.

---

## Phase 5 — Cleanup (after 30 days of stable operation)

**Goal:** remove the feature flag and any temporary instrumentation.

**Steps:**

1. Remove the `ENABLE_SUMMARY_OUTBOX` feature flag from the HMS code. The outbox insert is now always-on.
2. Remove the canary-specific logs / metrics.
3. Document the deployment in the HMS's `CLAUDE.md` or equivalent.
4. Move the Summary Service from "newly deployed" to "supported" in the on-call rotation.

**Rollback:** N/A — by this point, the system is stable.

**Duration:** ~1 day.

---

## Total rollout duration

- Phase 0: 15 minutes
- Phase 1: 1 day
- Phase 2: 1 week
- Phase 3: 30 minutes
- Phase 4: 1 week
- Phase 5: 1 day
- **Total: ~3 weeks from "code on disk" to "stable in production"**

---

## Data backfill

**No backfill in v1** (per brief assumption). Historical OPD invoices created before Phase 2 do not get CFIs. They are queryable through the existing HMS UI but do not appear in the "Consultation Fee Report" page.

If the hospital later wants a backfill (e.g., "we want to see last month's CFIs in the report"), it's a one-off script:

```sql
-- Backfill script (run manually, not in the normal flow)
INSERT INTO consultation_fees_invoices (id, tenant_id, event_id, opd_invoice_id, ...)
SELECT uuidv7(), ob.tenant_id, uuidv4(), ob.id, ...
FROM opd_billings ob
LEFT JOIN consultation_fees_invoices cfi ON cfi.opd_invoice_id = ob.id
WHERE cfi.id IS NULL
  AND ob.created_at BETWEEN '<from>' AND '<to>'
  AND ob.cancelled_at IS NULL;
```

This is a v2 feature.

---

## Communication plan

| Phase | Audience | Message |
|---|---|---|
| 0 | Hospital IT | "We're installing new services on the server. No user impact." |
| 1 | Hospital admin team | "We've added a new report page. It currently shows no data — testing the connection." |
| 2 (canary start) | Hospital admin team | "We're starting to test the new report with one counter. The data may be incomplete for 1 hour." |
| 2 (full rollout) | Hospital admin team | "The new 'Consultation Fee Report' is now showing all OPD consultations. Please report any anomalies." |
| 4 | Hospital IT | "Please monitor [list of dashboards/logs] for the next week." |
| 5 | Hospital IT + admin team | "The new feature is now stable and supported. Thank you for your patience during rollout." |

---

## Open questions for the cutover

- **Who owns the HMS code change at the OPD invoice insertion site?** The brief assumes the HMS team. If the Summary Service team owns it, the coordination changes.
- **What is the rollback SLA?** "Reverting the feature flag" takes <5 minutes. "Reverting the DB migration" takes longer (manual SQL). Decide in advance which is the rollback of record for each phase.
