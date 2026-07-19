# PR #11 — Discount Report

| | |
| --- | --- |
| Repo | MyanCare/YCare-HMS-Summary-Service |
| PR | [#11 — Discount Report](https://github.com/MyanCare/YCare-HMS-Summary-Service/pull/11) |
| Author | myopaingthu |
| Status | OPEN |
| Reviewer | mgmgpyaesonewin (requested) |
| Additions / deletions | +2406 / −58 across 29 files |
| Ticket | https://app.clickup.com/t/9018849685/86expkfg1 |

## TL;DR

**Request changes — 3 blocking issues, all tenant-data-integrity risks.** The Discount Report model and the OPD-Income write-back land a lot of spec work, but they still rely on the same `loadByGlobalId` pattern called out on PR #10: source rows are fetched by primary key from the worker without a tenant check, the backfill scripts select across tenants and write into one tenant's schema, and reconciliation is per-fact non-atomic — the same failures PR #10 flagged have shipped here. Ponytail pass found two near-identical cache modules (90% of `discount-report-cache.ts` is a duplicate of `opd-income-report-cache.ts`), a `startOfTodayUtcMs` reinvented in each, and a 175-line `PayoutRow` type-carrier normalizing six fee tables in place of a one-line helper.

## What the PR does

Adds a Discount Report read model and ships the OPD-Income ↔ doctor-payout write-back that PR #10 left as TODOs. Materializes a new `discount_reports` ledger (one row per discounted OPD/IPD voucher) from bill and IPD-final-bill events, and wires `cf-/tc-/pf-/ihd-/rf-/reading` pay/revert into the OPD-Income ledger through a new `doctor_payout.changed` outbox event. 135 lines of unit tests cover the pure mapping/allocation utils from PR #10; no new tests for the new write-back handlers or for the IPD final-bill reducer.

## Findings

### Blocking

**B1. Worker source reads are not tenant-bound — same defect as PR #10 B2.** — `src/services/discount-report.service.ts:1761-1764, 1801-1804`; `src/services/opd-income-report.service.ts:2071-2074, 2212-2216, 2370-2373, 2407`; `src/workers/handlers/opd-income-report.ts`; `src/workers/handlers/discount-report.ts`

`reconcileOpdDiscount`, `reconcileIpdDiscount`, `reconcileBill`, `syncRefund`, `loadBillContext`, and `loadPayoutRow` look up `OPDBilling`, `IPDFinalBill`, and the six fee tables by global id and write facts under the inbound event's `tenantId`. The `req.prisma` tenant extension does not protect raw worker Prisma access. Stale, replayed, or out-of-line events can copy another tenant's invoice number, store name, and amounts into the requesting tenant's ledger. Filter every source read by both `id` and `tenantId` (or via a tenant-scoped include), and reject mismatches as warnings instead of copying values. The fee tables (`cfFeeReport`, `tcFeeReport`, etc.) already carry `tenantId` — apply the same guard. See PR #10 B2; this PR repeats the pattern in six new places.

**B2. Backfills are not tenant-scoped — same defect as PR #10 B4.** — `src/scripts/backfill-discount-reports.ts:1405-1409, 1425-1429`; `src/scripts/backfill-opd-income-reports.ts:1483-1487, 1506-1525`

`prisma.oPDBilling.findMany({ where: { cancelledAt: null } })`, `prisma.iPDFinalBill.findMany({ where: { cancelledAt: null, isDeleted: false } })`, and `prisma.{cf,tc,pf,ihd,rf,reading}FeeReport.findMany({ where: { payoutStatus: "PAID" } })` select every tenant's rows and write them all under the script's `tenantId`. This is the highest-risk execution path because it operates over the full table — one CLI invocation copies tenants into each other. Add a tenant predicate; refuse to run if the schema cannot prove ownership on a table. Refactor the six near-identical `findMany` calls into one helper that takes the tenant-scoped where clause. See PR #10 B4.

**B3. Reconciliation is per-fact non-atomic — same defect as PR #10 B3.** — `src/services/discount-report.service.ts:1716-1746`; `src/services/opd-income-report.service.ts:1953-2005, 2012-2029`

`upsertFact` and `upsertDiscountRow` each do a separate `findUnique` → `create`/`update` (or `delete`); `removeStale` walks the loop removing rows one at a time outside any transaction. A partial failure leaves the ledger half-updated and observable to readers; concurrent workers can race the read-then-write pair. Wrap each reconciliation in a `prisma.$transaction` and use native `upsert`; defer Redis `invalidate` until after the tx commits.

### Important

**I1. `doctor_payout.changed` ordering/version gap is unchanged.** — `src/services/opd-income-report.service.ts:2392-2449`; `src/lib/events/doctor-payout-events.ts:1160-1184`

The handler still re-reads current state and either upserts or deletes a shared fact. Out-of-order or retried pay/revert events silently overwrite a newer transition. Include the fee row's post-mutation status + payout snapshot + a transition version in the event payload and ignore events older than the ledger's last applied version. (PR #10 I1.) Once B1 is fixed, a stale event from another tenant could now be applied to a legitimate row, escalating the risk.

**I2. New `ipd_final_bill.created` event has no unique-fan-out handling.** — `src/workers/outbox-poller.ts:2906-2912`; `src/workers/handlers/discount-report.ts:2800-2806`

The poller switches on `eventType` and dispatches `ipd_final_bill.created` directly to `onIpdFinalBillCreated`. There is no enforcement that this event name ever reaches the outbox — `enqueueIpD…` is not in this PR. If the HMS-side event type ever drifts (rename, casing, plural), every IPD discount silently stops materializing and the report goes stale. Pin the event name to a shared constant (`IPD_FINAL_BILL_CREATED`) and reject unknown event types in `dispatch()` rather than warning-and-returning.

**I3. Cash vs Other classification is name-based and case/punct brittle.** — `src/services/opd-income-report.service.ts:2165-2167`

```ts
if (pm.paymentMethod.name.trim().toLowerCase() === "cash") cashTotal += pm.receivedAmount;
```

If HMS ever adds another cash-named method ("Mobile Cash", "Cash Voucher") or a translation locale flips the names, the entire "Cash" column silently misattributes to "Other". Add a canonical `PaymentMethod.code` or a server-side enum and resolve once at seed/migration time, not on every reconcile. The same string is read once per voucher per event — a single mis-row reconciles wrong on every future re-reconcile until the cache TTL expires.

**I4. `Cache-Control` header is set after `res.send()`.** — `src/http/routes/discount-report.routes.ts:565-568, 599-604`; `src/http/routes/opd-income-report.routes.ts:725-728, 796-799`

The code sets `X-Cache-Status` and `Content-Type` before `res.send(hit)` — that part is fine. But the miss path also writes the body and `void setCached(...)` after headers — same fix from PR #10 I3 already considered. If the intent was "headers must reflect MISS before any byte of body," that is satisfied; if the intent was "headers must reflect MISS if `setCached` throws," that is not. Add an explicit assertion or note.

**I5. `cf-report.service.ts` and `tc-report.service.ts` enqueue a payout event for *every* pay/revert, but the CF/TC tables have no source/patientType gate.** — `src/services/cf-report.service.ts:1583-1587, 1599-1603`; `src/services/tc-report.service.ts:2627-2631, 2645-2648`

Compare with `pf-/ihd-/rf-/reading` which gate on `row.source === "OPD"` or `patientType === "OPD"`. CF and TC unconditionally enqueue. Per the comment in IPD, the CF/TC tables currently only carry OPD-bill consultations, but the gate must be there the day an IPD source is added (or risk an IPD CF payout flow into the OPD Income Report). Add the same `if (row.source === "OPD")` guard with a TODO comment naming the IPD Discharge Report destination.

**I6. Defensive `void` cast on `JSON.stringify`-then-hand-cache is hiding a missing JSON parse.** — `src/http/routes/discount-report.routes.ts:600`; `src/http/routes/opd-income-report.routes.ts:793`

We pre-stringify, send the same string to Redis, and re-send the same string to the client. If the schema ever adds a `BigInt` (and `tostringer` quietly corrupts or skips), the cached payload is wrong forever. Adding a Zod schema for the response + `JSON.parse` round-trip in tests catches this. At minimum, set `Content-Length` and `Content-Type: application/json; charset=utf-8`.

**I7. Both report routes have `no pagination` — operationally they can OOM the API tier.** — `src/http/routes/discount-report.routes.ts:553-554`; `src/http/routes/opd-income-report.routes.ts:713-715`

`findMany` with no `take` and the doc comment "*all matching rows returned*". A multi-year IPD discount search returns every row in production. Either add cursor pagination or cap the result with `take: 10000` + a `truncated: true` flag. Both reports cache the response, but stale cached entries still allocate the whole payload server-side.

**I8. `invalidateTenantCache` runs `SCAN` but ignores the `tenantId` of the worker event vs the cached tenant.** — `src/lib/caches/discount-report-cache.ts:1037-1057`; `src/lib/caches/opd-income-report-cache.ts:1125-1139`

The cache key is `${prefix}:${tenantId}:…`. The invalidator's pattern is `${prefix}:${tenantId}:*`. Fine. But the `redis.del(...keys)` in the loop calls `del` with a spread of keys — if the SCAN cursor returns more than ~100 keys in one batch (it can), the `del` call hits `KEYS`-style ceilings. `del` accepts an array of keys in ioredis since v4; spread or pass the array. Add a test that runs invalidate against >1000 cached entries.

### Nit

**N1.** `src/lib/caches/discount-report-cache.ts` is a 90-line near-duplicate of `src/lib/caches/opd-income-report-cache.ts`. Both modules: same `KEY_PREFIX`, same `TTL_ACTIVE_S = 30`, same `TTL_PAST_S = 300`, same `startOfTodayUtcMs`, same `getCached`/`setCached`/`invalidateTenantCache`, only the prefix and the query type differ. Promote a single `src/lib/caches/report-cache.ts` `makeXxxCache(prefix, query-type)` factory; delete both files. (Ponytail pass — see below.)

**N2.** `startOfTodayUtcMs` is duplicated verbatim in both cache files. Re-export from one place (or delete both with N1).

**N3.** `src/types/discount-report.type.ts` is 5 lines that export a 2-string enum. Just put the two strings inline in `discount-report.service.ts`. Same for `OpdIncomeModule`'s 10 values — fine as a const, but `OpdIncomeMeasure`, `OpdIncomeSourceType`, and `DoctorPayoutFeeType` are all single-source-of-truth and could live in one `src/types/opd-income-report.enum.ts`.

**N4.** `src/lib/opd-income-utils/index.ts:1304-1336` — `allocateByIncomeShare` is named "split" but is also the fallback path when there is no income. Rename to `allocateByIncomeShareOrFallback` or split into two functions. Documenting the dual-purpose via comment alone is the kind of thing a future reader debugs at 3am.

**N5.** `src/services/opd-income-report.service.ts:2314-2327` — `loadPayoutRow`'s `norm` helper accepts six different shapes and reads `r.payoutStatus`, `r.opdBillingId`, etc. through untyped field access. The fee tables share enough fields that a `Prisma.{Cf,Tc,Pf,Ihd,Rf,Reading}FeeReportSelect<{…}>` intersection would catch a column drift at compile time. Today, a typo on one column would only surface in production.

**N6.** `src/scripts/backfill-discount-reports.ts:1417, 1437` — mod-100 logging hard-coded. If `TOTAL_BILLS > 10000`, you only log at every 100th. Promote to a `process.stdout.isTTY` interval or accept `--log-every N`.

**N7.** `src/workers/handlers/opd-income-report.ts:2827-2834` — `onBillCreated` and `onBillReconciled` differ only by `allowRemovals`. Two-line helper. Fine to keep but worth collapsing.

**N8.** All four `enqueueDoctorPayoutEvent` call sites in `cf/tc/pf/ihd/rf/reading` services are identical (modulo `feeType`). One helper `enqueueDoctorPayout(tx, { feeType, feeReportId, sourceGated })` in `doctor-payout-events.ts` would shrink the call sites to one line and keep the source-gate logic discoverable.

**N9.** Schema: `BigInt` documentation matches `Integer`. We're already storing `amount: Int` (i32 ceiling ~2.1B) which is fine for retail OPD but if MMK amounts ever flow through with no minor-unit conversion they will overflow. Add a `CHECK (amount < 2_000_000_000)` constraint in the DDL.

**N10.** `prisma/schema.prisma:113-115` — `OpdIncomeReport.opdBillingId` is `Uuid?`, but `@@index([opdBillingId])`. Nullable unique indexes do not deduplicate nulls. Probably intentional, but a comment would help.

## Ponytail pass — what to delete

| File | What | Replace with |
| --- | --- | --- |
| `src/lib/caches/discount-report-cache.ts` (90 lines) | A near-exact clone of `opd-income-report-cache.ts`. Only `KEY_PREFIX` and `ListDiscountReportQuery` differ. | One `src/lib/caches/report-cache.ts` exporting `makeReportCache(prefix, ZodQuery)`. Both consumers import it. |
| `src/lib/caches/opd-income-report-cache.ts` lines for `startOfTodayUtcMs` | Stdlib reinvention. | `Date.now()` start-of-day math is one line: `new Date().setUTCHours(0,0,0,0)`. The custom helper is a copy of itself; move the one place that needs it (or delete with the merge above). |
| `src/lib/caches/{discount,opd-income}-report-cache.ts` `invalidateTenantCache` SCAN loop | ioredis already returns keys via SCAN; the manual `do { … } while (cursor !== "0")` is stdlib boilerplate. | Use `redis.scanStream({ match: pattern })`. ~40 lines → ~8. |
| `src/types/discount-report.type.ts` (5 lines) | Single 2-string enum in its own file. | Inline the two strings into `discount-report.service.ts` as `DiscountSource.OPD = "OPD"` etc. — drop the file. |
| `src/lib/events/doctor-payout-events.ts` (38 lines) | New event + helper. Reasonable, but the per-service enqueue blocks are 11 lines of identical body in 6 services (cf/tc/pf/ihd/rf/reading). | One helper `enqueueDoctorPayoutEvent(tx, { feeType, feeReportId })` already exists — push the source-gate logic (I5) into one place and the call sites shrink to one line. |
| `src/services/opd-income-report.service.ts` `loadPayoutRow` + `PayoutRow` (75 lines) | Six near-identical branches normalizing cf/tc/pf/ihd/rf/reading into one shape. | Branch on `feeType` only to select the model name; do the norm in one place via spread `{...r, isOpd: ..., readingModule: ...}`. The current `norm` double-reads fields. ~40 fewer lines. |
| `src/lib/__tests__/opd-income-utils.test.ts` `dominantModule` test | Tests a 6-line `for` loop that already had PR #10's `Math.max`-style winner-takes-all. | One assertion per behavior, not six tiny `it`s. Same coverage, ~30% fewer lines. |
| `src/scripts/backfill-opd-income-reports.ts` six `findMany` calls | Six similar blocks that differ only in the model name. | `await Promise.all(TABLES.map(t => t.prisma.findMany({ where: tenantGated, select: { id: true } })))`. |

**No new dependency was added.** The PR is dependency-clean.

## Test coverage gap

| Area | Coverage gap |
| --- | --- |
| `reconcileOpdDiscount` / `reconcileIpdDiscount` | Zero tests. PR #10 left `reconcileBill`, `syncRefund`, `syncPayout` untested; PR #11 added the same untested surface. All three handlers ship without a single assert. |
| `enqueueDoctorPayoutEvent` | No test of outbox write, idempotency, retry behavior. |
| `discount-report.routes` GET | No test for cache HIT short-circuit, no test for empty result, no test for date-filter boundaries (`from` inclusive / `to` exclusive). |
| `opd-income-report.routes` GET | Same as above, plus no test for the FILTER pivot (the SQL is the load-bearing piece). |
| `loadPayoutRow` six branches | Normalization tested via indirect opd-income-utils tests, not directly. A regression on the `r.source === "OPD"` ↔ `isOpd` mapping would not be caught. |
| `allocateByIncomeShare` edge cases | Covered. |
| `resolveLineModule` precedence | Covered. |

## Final recommendation

**Request changes.** The PR adds value (Discount Report model, the OPD-Income ↔ payout wiring) but ships known tenant-integrity defects (B1-B3) that PR #10 already flagged on a smaller surface. The fix is one PR: filter every source read by both `id` and `tenantId` in the worker, scope the backfill scripts, and wrap reconciliations in a transaction. While there, collapse the two cache modules into one factory (N1) and replace the `cf/tc/pf/ihd/rf/reading` six-block enqueue with a single helper (N8). Once those land, the remaining Important and Nit items can be a follow-up.
