# Code Review: PR #2798 — Inhouse doctor fees report for ipd and opd
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `pr-2798-inhouse-doctor-fees-report-for-ipd-and-opd` → (target branch not exposed by `gh pr view`)
**Files changed:** 62 (+5243 / -21)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07
**ClickUp:** https://app.clickup.com/t/86exqc30g

## Summary

Ships three doctor-fees reports (Consultation Fees, Tele Consultant Fees, In-house Doctor Fees) backed by a brand-new `summary-api` microservice contract. Adds four Prisma migrations introducing `event_outbox`, `cf_fee_reports`, `tc_fee_reports`, `ihd_fee_reports` plus their status-change and adjustment child tables; wires the existing OPD/IPD/proxy-bill/cathlab services to emit outbox events transactionally; exposes three new HMS BFF route groups that proxy to the summary service and write per-row activity logs. Adds a complete UI per report: schemas, types, react-query api, columns, table, filter/pay/revert/activity-log modals, page wrapper, sidebar entry, and permission config. The title mentions in-house only but the diff is the full CF + TC + IHD bundle.

## Verdict
**Request changes**
Score: 38/100
Critical: 1 | High: 4 | Medium: 6 | Low: 5 | Nit: 4

## Issues

### Critical

1. **Server-to-server auth between HMS and summary-service is absent, contradicting ADR 0008.** `src/lib/summary-api.ts` documents the omission ("Server-to-service auth was removed (summary-service v1)… until then the header is trusted on the wire (both services are on the same private network)"). CLAUDE.md treats HMAC-signed requests with `X-Service-Id=hms-bff`, `X-Signature`, `X-Timestamp (±5 min)`, `X-Tenant-Id` as a **load-bearing invariant** (ADR 0008 + `hms-docs/summary-service/api/hmac-auth.md`). Shipping the IHD PR through this proxy is the first prod path where the HMS can mutate shared DB state via summary-api from a route with no peer authentication. A misconfigured `SUMMARY_API_URL` (DNS poisoning, sidecar squatting, accidental public bind) becomes a one-step payout-mutation primitive. Either reinstate HMAC before merge or call out the ADR deviation explicitly in the PR description so reviewers can sign off knowingly.

### High

2. **Three feature folders are ~95% copy-paste with only field names and titles swapped.** `consultation-fees-report/`, `tele-consultant-fees-report/`, `in-house-doctor-fees-report/` each ship a near-identical set of: page (`71` lines), report table (`~370` lines), columns (`164` lines), pay modal (`112`), revert confirm (`72`), activity-log modal (`80`), filter modal (`69-87`), schema (`39-43`), types (`59-66`), react-query API wrapper (`114-116`), and three API routes per report (`33+61+62`). End-to-end duplication is well over 2,500 lines. The "In-house Doctor Fees for IPD and OPD" work in the title would shrink by ~70% if a single `<DoctorFeesReport entity={…}>` parameterized the entity-specific bits (fee column id, activity-log entity string, summary-api path, the `invoiceType` filter dimension). Recommend extracting the common shell first and shipping the per-entity configuration only.

3. **Activity-log writes are non-transactional with the state change.** Each `src/app/api/(common)/reports/{cf,ihd,tc}-fees/pay/route.ts` and `revert/route.ts` calls `summaryApi.post(...)` then `prisma.activityLog.createMany(...)` in a separate implicit transaction. If the activity log write fails (FK violation, DB blip, schema drift), the row is already PAID in summary-service but has no HMS audit trail; the UI surfaces `activityLogFailed: true` as a yellow toast that the user can dismiss. For an audit-of-payouts surface this is the wrong failure mode. Wrap the upstream call and the activity log write in a single outbox event the worker consumes, or write the activity log synchronously inside the summary-api call's success path (i.e. extend the summary-api to do it). Without one of these, the audit log can silently desync.

4. **`cancelOPDBilling` and `deleteOPDBilling` were made transactional in this PR, but their callers weren't audited for the implicit-tx change.** `src/app/(dashboard)/shared/opd/repositories/opd-billing.repository.ts:635-650` wraps the update in `prisma.$transaction`. The previous version wasn't transactional; any caller that previously passed its own `tx` now silently loses that wrapping (the `tx` parameter on these methods is unused — the new `$transaction` shadows it). Audit every caller in the diff (`refund.service.ts`, `service-request.service.ts`, `proxy-bill-template.service.ts`, `ct-add-on-billing.service.ts`) for whether they relied on the old implicit-standalone behavior. At minimum, add a regression note that the methods are now always-atomic and reject a caller-provided `tx`.

5. **Outbox `tenant_id` is sourced from `process.env.DEFAULT_TENANT_ID` in `src/lib/opd-billing-events.ts:34` and `src/lib/ipd-daily-bill-events.ts:36`**, which contradicts the ADR 0007 defense-in-depth design. The summary-service is built around HMAC-verified `X-Tenant-Id` at the edge, but every emit in the HMS reads a global env var. The system ships single-tenant today so this works, but it means a future multi-tenant deployment will write every event into one tenant_id bucket silently — no error, no log line, just incorrect routing. If multi-tenant is on the roadmap, push tenant resolution into the per-request context now (CLAUDE.md says "logs carry tenantId" — today the outbox does not even log it). If single-tenant is permanent, delete the ADR 0007 multi-tenant code in the summary-service to keep the design honest.

### Medium

6. **`summaryApi` defaults `SUMMARY_API_URL` to `http://summary-api:4000` (`src/lib/summary-api.ts:24`).** Silently falling back to a docker-network hostname in a Next.js server binary that also runs on bare metal in production (per CLAUDE.md: "no Docker in production") means a missing env var in prod becomes an undebuggable `502`. The OPD/IPD emit helpers already `logger.warn` on missing `DEFAULT_TENANT_ID` — apply the same pattern here, or require the var (throw on startup).

7. **`lastSyncedAt` is declared on every fee-report model and every migration but never read or written by application code.** Dead column. The summary-service worker is the natural owner; if it doesn't write it, the field should be removed from HMS-side Prisma schema and the migrations. Three near-identical mistakes made three times.

8. **`src/lib/opd-billing-events.ts:39-41` always stores `tenantId, opdBillingId` in the JSONB payload even though `tenant_id` is already a top-level column.** Same in `ipd-daily-bill-events.ts:39-41`. Either drop the column from the payload (use the column) or drop the column and keep only the payload. Having both invites drift.

9. **`proxy-bill-template.service.ts:289-308` admits in a comment that `proxyBill.ipdDailyBillId` is null after `createProxyBillLines` and has to be re-read from the DB to enqueue the outbox event.** The author wrote a comment instead of fixing the data flow. Either return the linked id from the create, or move the outbox emit into the same code path that links the proxy bill to the daily bill. A second helper-query that re-reads what the create method should have returned is a code smell.

10. **`ward-service.service.ts:511-517` reads `existing?.ipdDailyBillId ?? null` before the cascade delete, then emits an outbox event using the base `prisma` client (not a tx) at line 522-527.** Two issues: (a) if `getWardServiceById` returns null (race, already-deleted) the event is silently dropped — acceptable for idempotency but the comment doesn't say so; (b) the outbox row is committed in a separate transaction from the actual delete, so a process kill between them loses the reconcile signal and the IHD report keeps stale rows until the next CRUD event for that daily bill.

11. **Permission gating is inconsistent.** `page.tsx` uses `PermissionGuard action="View" subject="Consultation Fees"`, and the API routes use the same. But the CSV `DataTableExportAction` (used in every report table) is not gated by any permission check — anyone with View permission can bulk-download invoice numbers and amounts. `permission-ui-config.ts:891-906` advertises `crudExport` but the only checked action is `View`. If export is meant to require an explicit grant, gate it server-side on `POST /api/reports/{entity}/export` (which doesn't exist yet) and on the client before calling `DataTableExportAction`. If export is open, drop the misleading permission name.

### Low / Nit

12. **`useEffect(() => { ... }, [])` with `eslint-disable-next-line react-hooks/exhaustive-deps` appears in all three `page.tsx` files.** The effect writes URL params derived from `effectiveQuery` whose values come from the same render. With `[]` deps, a fast re-render between mount and effect execution could write a stale URL. Either include `effectiveQuery` in deps and guard against writing the same URL, or compute the params from `searchParams` directly inside the effect.

13. **`makeFetchDoctorsQuery({ status: "ACTIVE", limit: 0, offset: 0, page: 1 })`** in all three filter modals fetches the entire active doctor list on every report page load. Acceptable for a small clinic, not for a hospital with hundreds. The existing `makeFetchDoctorsQuery` is already paginated; pass `limit: 100` and an autocomplete-style select, or use the existing `/api/doctors/search` if any. Minor for v1 but flag for follow-up.

14. **Schema duplication: `payCfReportSchema`, `payTcReportSchema`, `payIhdReportSchema` are byte-identical apart from the export name.** Same for revert. One shared `payDoctorFeeReportSchema` and `revertDoctorFeeReportSchema` would shrink the diff by ~30 lines and eliminate three places to keep in sync.

15. **`useFetchDoctorsQuery`'s positional defaults (`limit: 0, offset: 0, page: 1`)** are a footgun — `limit: 0` reads as "no limit" but a future caller who passes `limit: 0` to disable fetching would silently get all rows. Document or rename.

16. **`buildListParams` in each `*-report.api.ts` is a hand-rolled URLSearchParams builder.** Three copies. Either accept this is fine for three reports, or use `URLSearchParams`'s constructor with an object and a 1-liner filter. Minor.

17. **`@default(now())` on `lastSyncedAt`** in `prisma/schema.prisma` (lines 562, 641, 735) sets the field on insert but `updatedAt @updatedAt` already does the same job. The redundancy contributes to the "lastSyncedAt is unused" finding above.

### Nit

18. **`extraPayload: Record<string, unknown> = {}` parameter** on `enqueueOpdBillingEvent` / `enqueueIpdDailyBillEvent` is only used once (the refund's `serviceIds`). YAGNI default — drop until a second caller appears.

19. **`containerRef + barLeft/barWidth state + resize listener`** in all three report tables is reinventing what `position: sticky; left: 0; right: 0` does for free. The bar wants to span the table's horizontal extent; CSS sticky inside the existing scroll container would remove ~15 lines per table × 3.

20. **`adjustmentExport` and `AdjustmentCell` exist as two parallel implementations of "format the adjustment column".** In `*-columns.tsx` (cell renderer) and `*-report-table.tsx` (CSV export), the logic is duplicated. A single `formatAdjustmentFor(row)` helper per report, or a shared one for all three, would prevent drift.

21. **`activityLogColumns()` is rebuilt on every render of `*ActivityLogModal`** (`useMemo`-less `activityLogColumns()` called inline). Wrap with `useMemo` or hoist to module scope so React doesn't recreate the array each render.

## Recommendation

1. Restore HMAC for the HMS → summary-api call before merging, or document the deviation in the PR body with explicit sign-off from the summary-service owners.
2. Extract the three duplicated report trees into a single parameterized `DoctorFeesReport` (entity config drives API path, fee column id, activity-log entity name, the `invoiceType` filter dimension). Per-entity shims only where behavior genuinely diverges.
3. Make activity-log writes atomic with the summary-api state change (outbox event consumed by a small worker, or push the log write into summary-api itself).
4. Audit `OPDBillingRepository.cancelOPDBilling` / `deleteOPDBilling`'s new transactions vs. every caller; reject caller-provided `tx` explicitly.
5. Drop `lastSyncedAt` from the schema and migrations (or wire it from the worker).
6. Remove `tenantId`/`opdBillingId`/`ipdDailyBillId` duplication between outbox payload and column.
7. Fix the proxy-bill create-then-re-link pattern in one place rather than documenting it.
8. Gate the CSV export on a real permission check or drop the misleading `crudExport` label.
9. Stop defaulting `SUMMARY_API_URL` to a docker hostname; throw on missing config.
10. Resolve `tenant_id` from request context, not `process.env`, before this hits a second tenant.

Once 1–3 are addressed (the three that touch invariants), this is a large but otherwise conventional report bundle. The architectural direction (event-outbox + summary-service + thin HMS UI) is sound; the execution is bogged down in copy-paste and one missing security boundary.