# Capacity Plan

Sizing analysis for the on-prem deployment. Verifies the assumed host specs (4 vCPU, 16 GB RAM, 100 GB SSD) against expected workload. Shows the levers if the host is undersized.

---

## Assumed workload

| Metric | Expected value | Notes |
|---|---|---|
| OPD invoices per day | 200 | Typical mid-size hospital. 50-500 range covers 80% of customers. |
| Peak hour multiplier | 3x | Most OPD invoices are generated in 09:00-12:00 and 14:00-17:00. |
| Peak events per hour | 600 | 200/day × 3x peak |
| Peak events per second | 0.2 | 600 / 3600 |
| Concurrent admin users | 10 | The hospital has ~10 staff with admin access. |
| Summary page loads per admin per day | 20 | Checking the report throughout the day. |
| Status updates per admin per day | 5 | Marking invoices as paid/voided. |
| Adjustments per admin per day | 2 | Less frequent than status changes. |
| CFI rows in DB (year 1) | 73,000 | 200/day × 365 |
| CFI rows in DB (year 5) | 365,000 | 200/day × 365 × 5 |
| Average CFI row size | ~1 KB | All columns, indexes included (overestimate). |
| Year 1 DB growth from CFI | ~70 MB | 73,000 × 1 KB |
| Year 5 DB growth from CFI | ~350 MB | 365,000 × 1 KB |
| Audit rows in DB (year 1) | ~25,000 | ~5 status changes + ~2 adjustments per CFI over its life |
| Total year 1 DB growth (incl. audit + indexes) | ~150 MB | |
| Redis aggregate keys | ~10,000 | 1 key per (tenant, date, counter) per day; 30 days × 100 counters × 1 tenant |

The on-prem install is **single-tenant in practice** (one hospital), so the tenant key is a single value. If multi-tenant, multiply by N.

---

## Resource sizing

### CPU

| Component | Steady-state CPU | Peak CPU |
|---|---|---|
| HMS Next.js | 0.5 vCPU | 1.5 vCPU (page loads, tRPC calls) |
| Summary Service — API | 0.1 vCPU | 0.3 vCPU (admin requests) |
| Summary Service — Worker | 0.1 vCPU | 0.2 vCPU (event processing) |
| PostgreSQL | 0.3 vCPU | 0.8 vCPU (commits, joins) |
| Redis | 0.05 vCPU | 0.1 vCPU (HINCRBY, HGETALL) |
| OS, systemd, etc. | 0.1 vCPU | 0.2 vCPU |
| **Total steady-state** | **~1.2 vCPU** | |
| **Total peak** | | **~3.1 vCPU** |

**Verdict:** the assumed 4 vCPU has **~30% headroom** at peak. ✅

### RAM

| Component | Steady-state RAM | Peak RAM |
|---|---|---|
| HMS Next.js | 600 MB | 1.2 GB (request handling, Prisma client) |
| Summary Service — API | 80 MB | 150 MB (Prisma client, request handlers) |
| Summary Service — Worker | 50 MB | 100 MB (Prisma client, ioredis) |
| PostgreSQL | 2 GB | 4 GB (shared_buffers, work_mem, connections) |
| Redis | 100 MB | 200 MB (10k keys × ~10 KB) |
| OS, kernel, etc. | 500 MB | 800 MB |
| **Total steady-state** | **~3.3 GB** | |
| **Total peak** | | **~6.5 GB** |

**Verdict:** the assumed 16 GB has **~60% headroom** at peak. ✅

### Disk

| Component | Year 1 | Year 5 |
|---|---|---|
| PostgreSQL data (incl. CFI + audit + indexes) | 200 MB | 1 GB |
| PostgreSQL WAL (7-day retention) | 5 GB | 5 GB |
| Redis (RDB not used; data in memory) | 0 | 0 |
| Application logs (90-day rotation) | 500 MB | 500 MB |
| Postgres logs | 1 GB | 1 GB |
| Redis logs | 100 MB | 100 MB |
| Application binary + node_modules | 500 MB | 500 MB |
| OS, kernel, etc. | 10 GB | 10 GB |
| **Total** | **~17 GB** | **~18 GB** |

**Verdict:** the assumed 100 GB SSD has **~80% headroom**. ✅

---

## Bottleneck analysis

### What's the first thing to hit a limit?

1. **Postgres connections** if you add more services or more workers. Default Postgres `max_connections` is 100. Current usage: ~10 (HMS + Summary Service API + Summary Service Worker + a few admin sessions). Plenty of room.

2. **Postgres work_mem** if a single query needs to sort a large result set. The summary list page with `LIMIT 25` doesn't sort the full table; the index does. Should be fine.

3. **Redis memory** if the number of `(tenant, date, counter)` combinations grows. At 10,000 keys × 10 KB = 100 MB, well within the 200 MB allocation. Even at 100,000 keys (10x growth), it's 1 GB, still under the headroom.

4. **API request rate** if the hospital suddenly has 100 concurrent admins. At 10 concurrent admins × 20 page loads/day = 200 requests/day = ~0.003 req/s average. Even at 100 concurrent admins, it's 0.03 req/s. The API is nowhere near saturation.

5. **Worker event-processing rate** if OPD invoice creation spikes. At 0.2 events/sec average, 0.6 events/sec peak, the worker has a CPU budget of ~50x. Even if event creation goes 100x, the worker can keep up.

### Scaling levers (in order of cost)

1. **Tune Postgres.** Default settings are conservative. Bumping `shared_buffers` to 4 GB and `effective_cache_size` to 12 GB gives the planner more room. Requires a Postgres restart, low risk.
2. **Tune the API CPU/memory limits** in the systemd units. Default is 100% CPU / 512 MB. Bump to 200% / 1 GB.
3. **Upgrade the host.** Add CPU cores and RAM. Cheapest and safest.
4. **Add a second host for the API.** Read-only scale-out: the API is stateless. Requires the HMAC secret to be shared between hosts.
5. **Shard by tenant.** If the hospital wants to deploy multi-tenant in the future, each tenant's data can go to a separate Postgres schema. The data model supports this with a small change.

---

## What if the workload is 10x?

If OPD volume grows to 2,000/day (10x):

- **Steady-state CPU:** ~3 vCPU. Still under 4 vCPU. ✅
- **Steady-state RAM:** ~5 GB. Still under 16 GB. ✅
- **Disk (year 1):** ~30 GB. Still under 100 GB. ✅

If it grows to 10x (20,000/day):

- **Steady-state CPU:** ~12 vCPU. **Over 4 vCPU.** ❌ Need to scale out or upgrade.
- **Steady-state RAM:** ~15 GB. Approaching 16 GB. ⚠️
- **Disk (year 1):** ~150 GB. **Over 100 GB.** ❌

At 10x, the host needs to be upgraded. Two options:
- **Vertical:** 8 vCPU, 32 GB RAM, 500 GB SSD. ~$1-2k one-time cost.
- **Horizontal:** add a second host for the API. Worker stays on the primary. Requires shared HMAC secret.

---

## What if the hospital has many counters (e.g., 500)?

Each counter is a `counter_id` in the data model. The summary list page filters by counter. The Redis aggregate has one key per `(tenant, date, counter)` — 500 counters × 30 days × 1 tenant = 15,000 keys. At 10 KB each, 150 MB. Still under headroom.

The Postgres indexes include `(tenant_id, counter_id, billing_date)` which is still selective (500 distinct counters). No degradation.

---

## What if a single report query is slow?

The summary list page with a search query goes through the `pg_trgm` GIN index on `lower(invoice_no)`. At 1M rows:
- The trigram GIN index lookup is O(K) where K is the number of trigrams matching the query. For a 5-character query, K is small (a few hundred trigrams). Fast.
- The `ORDER BY billing_date DESC` is O(M log M) where M is the matching set. If 1,000 rows match, the sort is fast. The `(tenant_id, billing_date DESC)` B-tree index is used to limit the row read.
- The LIMIT 25 stops the scan early.

Expected p95: < 200ms even at 1M rows. No special tuning needed.

If substring search becomes a bottleneck (e.g., very common search terms producing large matching sets), consider:
- Adding a materialized view of `(tenant, billing_date, status, amount, payout_amount, doctor_id, invoice_no)` pre-aggregated by day.
- Adding a B-tree on `lower(doctor_name) text_pattern_ops` and `lower(invoice_no) text_pattern_ops` to accelerate 1-2 character prefix matches (currently falls back to a sequential scan).

Out of scope for v1.

---

## Capacity planning procedure

When the workload changes (e.g., new hospital, multi-tenant deployment):

1. **Measure current workload** for 1 week. Use the operational queries in `runbook.md` to baseline:
   - CFI rows per day (from Postgres).
   - Status changes per day (from the audit table).
   - Peak API request rate (from access logs).
   - Redis memory usage (`INFO memory`).
2. **Project 1-year and 5-year growth.** Use the assumptions in this document, adjusted for the new workload.
3. **Compare to the assumed host specs.** If over 80% of any resource, plan to scale.
4. **Update the capacity plan** with the new numbers.

The capacity plan is a living document. Re-evaluate it annually or when the workload changes significantly.
