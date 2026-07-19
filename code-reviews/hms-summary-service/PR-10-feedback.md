# PR #10 — OPD Income Report

| | |
| --- | --- |
| Repo | MyanCare/YCare-HMS-Summary-Service |
| PR | [#10 — Opd Income Report](https://github.com/MyanCare/YCare-HMS-Summary-Service/pull/10) |
| Author | myopaingthu |
| Status | OPEN |
| Base / head | (default branch) ← `opd-income-report` (per PR #10 link) |
| Reviewer | mgmgpyaesonewin (requested) |
| Additions / deletions | +1738 / −36 across 22 files |
| Ticket | https://app.clickup.com/t/9018849685/86exnvzhf |

## TL;DR

**Request changes — 4 blocking issues (one a tenant-data-leakage risk).** Solid spec work and well-tested utils, but the ledger grain collides across fee tables, raw source-table reads skip the tenant guard, reconciliation is non-atomic, and the backfill can silently mis-attribute data across tenants. Ponytail pass found a large pile of redundant stdlib/scaffolding that should be deleted in the same pass.

## What the PR does

Adds an OPD Income Report read model. Materializes a new `opd_income_reports` ledger (income / receivable / cash-other / refunds / 5 doctor-payout measures) from existing outbox events plus a new `doctor_payout.changed` event. Introduces a `GET /opd-income-reports` route (cache-aside, tenant-scoped), a one-shot backfill script, a hand-maintained Prisma subset for the read tables, and a 5-service write-back hook into the existing fee pay/revert paths. 135 lines of unit tests cover the pure mapping/allocation utils.

## Findings

### Blocking

**B1. Payout facts collide across fee tables** — `src/services/opd-income-report.service.ts:1655-1675, 1698-1707`; `prisma/schema.prisma:44`

Every payout row carries `sourceType = FEE_REPORT` and `sourceId = feeReportId`. The unique constraint is `(tenantId, sourceType, sourceId, module)`. Six fee tables each mint their own UUIDs; if any two ever collide, one upsert overwrites the other, and the module-agnostic `deleteMany` in `deleteFact()` can then wipe a sibling row. Use a per-fee-type source type (`CF_FEE_REPORT`, `TC_FEE_REPORT`, …) or add `feeType` to both the persisted columns and the unique key, and key the delete on the complete grain.

**B2. Source-table reads are not tenant-bound** — `src/services/opd-income-report.service.ts:1331-1334, 1472-1475, 1630-1633`

`reconcileBill`, `syncRefund`, and `loadBillContext` look up `OPDBilling` by global ID and write facts under the inbound event's tenant. A stale or out-of-line event can copy another tenant's store name, invoice number, and amounts into the requesting tenant's ledger — the inbound API's tenant guard does not protect raw worker Prisma access. Resolve the bill through its tenant-scoped relation, or include a canonical tenant field on the model and filter by both `id` and `tenantId`. Apply the same check in `loadBillContext`.

**B3. Bill reconciliation is not atomic** — `src/services/opd-income-report.service.ts:1213-1265, 1272-1288, 1432-1441, 1538-1544`

Each fact is written via a separate `findUnique` → `create`/`update` and stale rows are removed one-by-one outside any transaction. A partial failure leaves the ledger half-updated and observable to readers; concurrent workers can also race between the `findUnique` and the `create`. Move all upserts + stale deletion into one short Prisma transaction, use native `upsert`, and only invalidate Redis after the transaction commits.

**B4. Backfill bill selection is not tenant-scoped** — `src/scripts/backfill-opd-income-reports.ts:964-969`

`prisma.oPDBilling.findMany({ where: { cancelledAt: null, opdBillingPaymentStatus: { not: "CANCEL" } } })` selects every tenant's bills and writes them all under the script's `tenantId`. This is the highest-risk execution path because it operates over the full table. Add a tenant predicate via the canonical ownership field/relation; refuse to run if the schema cannot prove ownership.

### Important

**I1. `doctor_payout.changed` has no ordering / version protection** — `src/services/opd-income-report.service.ts:1655-1675`; `src/lib/events/doctor-payout-events.ts:754-765`

The handler re-reads current state and either upserts or deletes a shared mutable fact. Out-of-order or retried pay/revert events can silently overwrite a newer transition. Include the fee row's post-mutation status + payout snapshot + a transition version in the payload, and ignore events older than the ledger's last applied version. Add an out-of-order test.

**I2. Backfill silently succeeds after per-row failures** — `src/scripts/backfill-opd-income-reports.ts:973-983, 1020-1029, 1037-1046`

Per-record errors are logged and swallowed; `main` always exits 0. Operators can report a successful backfill while the ledger is incomplete. Count failures and throw / set a nonzero exit code at the end so CI/ops sees the gap.

**I3. Backfill performs unbounded in-memory N+1 writes** — `src/scripts/backfill-opd-income-reports.ts:964-1008`

Loads every bill and every paid fee ID into memory, fans out six parallel `findMany` calls, then processes jobs serially with per-fact reads + writes. Process per-source using cursor/keyset batches; use bulk upserts; record a resumable cursor.

**I4. `allowRemovals=false` makes create-event replay non-self-healing** — `src/services/opd-income-report.service.ts:1314-1319, 1436-1441`; backfill `952-953, 975`

If a partially-processed create or first backfill run inserted facts that no longer apply, retries only refresh — stale rows persist forever. Either reconcile the full bill state on every event (remove the `allowRemovals` flag) or document a separate cleanup phase and stop calling the backfill fully idempotent.

**I5. Zero / negative payout amounts are persisted** — `src/services/opd-income-report.service.ts:1667-1676, 1698-1705`

Only `null` is rejected. A zero or negative `payoutAmount` silently increases net income (negatives) or pollutes the pivot with zero rows. Reject/delete unless `payoutAmount > 0` and add a CHECK constraint at the DB.

**I6. No DB CHECK constraints in this diff** — `prisma/schema.prisma:22-49`; `src/types/opd-income-report.type.ts:1920-1923`

`measure`, `module`, `sourceType` are unrestricted strings; `amount` has no positivity constraint. The TS comment says these mirror migration CHECK constraints, but the migration is not part of this PR. Land the canonical HMS migration in the same change set with CHECKs for the value sets and amount policy; verify Prisma + DDL names match.

**I7. Cache writes are fire-and-forget** — `src/http/routes/opd-income-report.routes.ts:468`

`void setCached(...)` leaves the promise unobserved. Refactors or new Redis errors can become unhandled rejections. Await the write, or attach an explicit `.catch`.

**I8. Cache invalidation scans Redis on every ledger change** — `src/lib/caches/opd-income-report-cache.ts:703-721`; handler `2022-2050`

Each write does an O(keyspace) `SCAN` to delete matching entries, plus is susceptible to keys added during traversal. Use a per-tenant cache generation in the key and `INCR` one counter on mutation; old entries expire by TTL.

**I9. Search input is unbounded leading-wildcard** — `src/lib/validators/opd-income-report.ts:931-936`; route `411-413`

`search` has a min length but no max; `%term%` cannot use a B-tree index. Module is a closed 9-value set — replace with an enum filter, or cap length and add the pg_trgm index.

**I10. Date-range validation is unbounded and uninverted-tolerant** — `src/lib/validators/opd-income-report.ts:931-936`; route `405-407`

Missing bounds become `epoch … Date(8640000000000000)` (full-table scan); inverted ranges silently return empty. Add a refinement `from < to` and a maximum/default range.

**I11. Service-category classification is nondeterministic** — `src/services/opd-income-report.service.ts:1308-1312, 1482-1492`; schema `234-242`

`moduleMappings[0]` is read without ordering or uniqueness. The same bill can land in different modules across runs. Enforce one mapping per category with a UNIQUE constraint, or define an explicit deterministic priority.

**I12. No integration tests cover money / tenant / concurrency paths** — `src/lib/__tests__/opd-income-utils.test.ts:505-640`

Tests cover only the pure utils. Add DB-backed tests for: tenant isolation, complete reconcile after edit/cancel, refund replacement, pay/revert idempotency, out-of-order events, two-fee-table source-id collision, payment splits summing exactly, and raw-SQL pivot correctness.

**I13. Outbox payload validation is a bare truthy check** — `src/workers/outbox-poller.ts:2094-2106`

Payload is `as Partial<DoctorPayoutEventPayload>` and only `feeType` truthiness is checked. UUID format, allowed enum, and payload tenant are not validated. Parse with a Zod discriminated schema; throw on invalid events so they retry → DEAD with diagnostics.

**I14. The 556-line service file is a multi-responsibility hotspot** — `src/services/opd-income-report.service.ts:1154-1710`

Persistence + bill projection + refund projection + payout polymorphism + tenant-sensitive reads + stale deletion + module classification all in one file. Exceeds the project's 500-line cap. Split into one shared transactional ledger writer + three projectors (bill / refund / payout).

### Nit

**N1. `dominantModule` docstring lies** — `src/lib/opd-income-utils/index.ts:857-877`

Now used only as a no-income fallback. Rename to `fallbackModuleForBill` and drop the max-income loop.

**N2. Cache-key serialization can collide** — `src/lib/caches/opd-income-report-cache.ts:663-667`

Search text may contain `:`, producing ambiguous keys. Encode each component or hash a stable JSON serialization.

**N3. `X-Cache-Status` casing differs from the documented convention** — `src/http/routes/opd-income-report.routes.ts:399, 470`

Emits `HIT`/`MISS`; the existing CFI contract documents lowercase `hit`. Reuse the documented helper/convention.

**N4. `storeName` / `opdBillingId` / `invoiceNo` not in equality check** — `src/services/opd-income-report.service.ts:1225-1231`

Counter renames or corrected invoice metadata stay stale when monetary fields are unchanged. Compare all mutable fields, or use an unconditional atomic upsert (preferred — see B3).

**N5. Open-ended date sentinel is hard to read** — `src/http/routes/opd-income-report.routes.ts:405-407`

`new Date(0)` / `Date(8640000000000000)` obscure the SQL. Build optional Prisma SQL predicates only for supplied bounds.

## Ponytail pass — what to delete / simplify

Reuse of existing helpers is the biggest miss.

- **Collapse 6 near-duplicate cache modules into one generic `listCache.ts`** — `opd-income-report-cache.ts` (76 LOC) is verbatim the reading / cf / pf / rf / ihd / tc cache modules in shape, differing only in prefix + query type.
- **Delete `allocateByIncomeShare` + `dominantModule` + their tests (~60 LOC)** — `Math.round` + leftover-to-dominant is enough for an internal report; penny-precise allocation then summed in Postgres is theatre.
- **Replace `upsertFact` find/update/create chain with `prisma.upsert`** — drop the `changed` return-value chain (handler can invalidate unconditionally).
- **Replace `removeStale` select-then-N-deletes with one `deleteMany({ where: { NOT: { OR: [...currentKeys] } } })`** — one round trip.
- **Delete `doctor-payout-events.ts` (38 LOC)** — a one-call wrapper for `eventOutbox.create()`. Inline at the call sites or fold into the OPD income service.
- **Inline `wardModuleFromAppointment` + its 5-entry map** — `apptModules?.find(m => m in WARD)` does it; the case-insensitive test is for one input.
- **Inline `netIncome` / `ZERO_TOTALS` / `pushSplit` micro-helpers in the route** — netIncome is a single subtraction; grandTotal reduce is 3 lines with `Object.fromEntries`.
- **Delete the `opdIncomeReport` entry in `tenant-scope.ts`** — every read goes through raw `$queryRaw` or the unscoped `prisma`; the extension never fires. (Once B2 is fixed and reads move to tenant-scoped Prisma, re-add.)
- **Collapse the 5 fee-service `enqueueDoctorPayoutEvent` blocks** — identical shape, 10 sites; inline the `eventOutbox.create` or expose a 3-line `emit(tx, feeType, row, tenantId)`.
- **Unify the three refund-item loops (pharmacy/service/procedure)** — one loop driven by a per-item-type config table.
- **Hoist `DEFAULT_TENANT_ID ?? argv[2]` to a shared helper** — now duplicated in 5 backfill scripts.
- **Compress backfill payouts loop** — six `findMany` + flatMap into `jobs[]` is one `[{feeType, model, sourceFilter}, ...]` table-driven loop (~15 LOC vs 40).
- **Inline `loadPayoutRow`'s `norm` closure and 6-case switch** — it's six near-identical `findFirst` calls. Table-driven.
- **Inline `onDoctorPayoutChanged` into the poller switch** — one caller, three lines.

## Test coverage gap

- Integration tests: tenant isolation, complete reconcile after edit/cancel, refund replacement, pay/revert idempotency, out-of-order events, two-fee-table source-id collision, payment splits summing exactly, raw-SQL pivot correctness, cache miss/hit/invalidation. Currently 0% of these are exercised; only the pure utils are unit-tested.
- Backfill has no test that proves it materializes the correct rows; combined with B4 (no tenant filter) this is the highest-confidence-debt gap in the PR.

## Final recommendation

**Request changes.** The blocking four (B1 collision, B2 cross-tenant reads, B3 non-atomic reconcile, B4 backfill tenant miss) are must-fixes before merge. Address the ponytail deletes in the same pass — most of them are 5-line wins, and several (notably B3's atomic-upsert, B7's awaited cache, and the `opdIncomeReport` tenant-scope entry) line up with the deletions. Re-request review after the four blockers land and a small integration test (tenant isolation + pay/revert idempotency) is added.
