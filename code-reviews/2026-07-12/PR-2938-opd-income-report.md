# Code Review: PR #2938 — OPD Income Report
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `mpt/opd-income-report-new` → `development`
**Files changed:** 97 (+6524 / -53)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-12
**ClickUp:** https://app.clickup.com/t/9018849685/86exnvzhf

## Summary
Adds the OPD Income Report and the surrounding summary-service integration to the HMS monolith. The PR does six things in one go: (1) introduces `event_outbox` plus seven new fee-report tables (cf/tc/ihd/pf/rf/reading/opd-income) via hand-edited migrations with CHECK constraints and pg_trgm indexes; (2) adds `src/lib/summary-api.ts`, an outbound HTTP client from HMS to the existing `hms-summary-service`; (3) wires 8 new feature modules (api/schema/types/table/page) and a `fee-report-shared` component layer; (4) adds ~28 Next.js Route Handlers (`/api/reports/{cf,tc,ihd,pf,rf,reading}/...` and `/api/reports/opd-income`); (5) instruments the OPD/IPD/imaging/cath-lab/proxy-bill/refund repositories to emit transactional-outbox events; (6) registers permission subjects and sidebar entries. The shared `FeeReportTable<T>` component handles pay/revert/activity-log for 6 of the 7 reports; OPD Income uses its own table because its row shape (module × counter aggregates) does not match.

## Verdict
**Request changes**
Score: 65/100
Critical: 1 | High: 2 | Medium: 3 | Low: 2 | Nit: 2

## Issues

### Critical

- **HMAC server-to-server auth was removed and replaced with header trust.** `src/lib/summary-api.ts:23-29` ships with the comment "Server-to-service auth was removed (summary-service v1). The summary-service tenant-guard middleware only requires a plain `X-Tenant-Id` header (validated as a UUID). v2 will reintroduce an auth context; until then the header is trusted on the wire (both services are on the same private network)." This directly contradicts ADR 0008 and `hms-docs/summary-service/api/hmac-auth.md`, which require HMAC-SHA256 with `X-Service-Id`, `X-Signature`, `X-Timestamp`, `X-Tenant-Id`. The summary-service HMAC middleware (`src/http/middleware/hmac-auth.ts`) still runs — so the summary-service is currently *rejecting* every call from the new HMS client. The PR will not work end-to-end on the deployed stack. Fix: keep HMAC in `src/lib/summary-api.ts` (the `hms-docs/summary-service/build-prompt.md` shows the wire shape) and update the summary-service docs only if the design has actually changed — and only with an ADR.

### High

- **Massive copy-paste duplication across 7 near-identical report modules.** `src/app/(dashboard)/common/reports/{consultation-fees,tele-consultant-fees,in-house-doctor-fees,procedure-fees,round-fees,reading-fees}-report/` each contain their own `api/<x>-report.api.ts`, `schemas/get-<x>-report.schema.ts`, `types/<x>-report.types.ts`, `features/components/<x>-<fee>-report-table.tsx`, and `page.tsx` (~80 lines each) — the same `buildListParams`/`fetchReport`/`makeReportQuery`/`payReports`/`revertReports`/`fetchActivityLogs`/`makeActivityLogsQuery` skeleton appears 6 times with the entity name swapped. Same pattern repeats across 24 route handlers under `src/app/api/(common)/reports/{cf,tc,ihd,pf,rf,reading}/{route,pay,revert,activity-logs}.ts` (each ~35 lines, identical structure). The `fee-report-shared/` directory exists and has the right abstractions for *the table*, but the API/schemas/types/routes layer is still per-module boilerplate. Fix: extract a generic `createFeeReportApi(basePath)` factory, a single `makePayHandler/factory` and `makeRevertHandler/factory`, and collapse the 6 report api/schema/types folders into one config object per report (~50 lines each instead of ~250).

- **Permission subject mismatch on PAY / REVERT / activity-logs routes.** Every pay and revert route uses `permissions: [{ action: "View", subject: "<Fee>" }]` (e.g. `procedure-fees/pay/route.ts:21`, `reading-fees/revert/route.ts:21`, all 6 of them). The action is a money-moving mutation; tying it to "View" is incorrect for any future audit and trips the principle-of-least-privilege. Fix: register a "Mark Paid" / "Revert" action or use the existing "Pay" / "Revert" actions in the permission-ui-config (which is the convention per existing reports).

### Medium

- **Migrations are 7 separate files where one would do.** `prisma/migrations/20260617091918_add_summary_service_tables/`, `..._add_tc_fee_report_tables/`, `..._add_ihd_fee_report_tables/`, `..._add_ihd_ward_service_ref/`, `..._add_ihd_proxy_cathlab_refs/`, `..._add_pf_fee_report_tables/`, `..._add_rf_fee_report_tables/`, `..._add_reading_fee_report_tables/`, `..._add_opd_income_report_tables/` — eight migrations, each created the same 3-table pattern (parent + status_changes + adjustments) plus hand-edited CHECK constraints. The CLAUDE.md for hms-app warns "tread carefully with migrations; consult peers before installing new dependencies"; eight sibling migrations on the shared HMS DB across June dates is the kind of noise that causes peer review to merge one and forget another. Fix: squash to one migration per logical event (`add_summary_service_tables` already exists; the others should be a single `add_fee_report_tables` migration plus one or two follow-ups only if schema really changed after the first ship).

- **Client-side search bypasses server filtering.** `opd-income-report-table.tsx:42-47` filters by `moduleLabel(r.module)` client-side because the server "groups by module *code*". This is fine for ≤9 modules × N counters, but the per-row search will not match counters and the comment is misleading. Either route `search` through the server (the Zod schema already supports it for other reports), or document why OPD income is the exception. Same comment in `opd-income-report.schema.ts:9-12` acknowledges the asymmetry.

- **OPD Income page hardcodes date default to "today" on every render via `useEffect`.** `opd-income-report/page.tsx:30-38` calls `router.replace` to set `?start=&end=` when missing. This causes an SSR/CSR mismatch warning (the URLSearchParams diverge between the server-rendered and client-hydrated tree until the redirect lands) and an extra round trip. Fix: compute defaults inside the Zod schema's `.transform()` or pre-populate from URL in the route handler so the first render already has the right params.

### Low / Nit

- **Low:** `summary-api.ts:39-43` — when JSON parse fails on a non-2xx response, the error message falls back to `summary-api ${method} ${path} failed (${res.status})` but does not include the response body, which makes 4xx debugging hard. Include `text.slice(0, 500)` in the message when `safeJson` returns null.
- **Low:** `imaging-reading-events.ts`, `ipd-daily-bill-events.ts`, `lab-reading-events.ts`, `opd-billing-events.ts` are four near-identical event enqueue helpers (one per source type). The differences (event-type string + aggregate-id shape) could collapse into a single `enqueueEvent(tx, eventType, aggregateId, payload?)` with a const map at the top.
- **Nit:** `.env.example:6` — `SUMMARY_API_URL` uses `http://` in an example; for any non-local deployment this should be `https://` and the docker-compose hostname `summary-api:4000` is fine for dev but easy to miss.
- **Nit:** `opd-income-report.types.ts:17-27` — the `MODULE_LABELS` map covers 9 codes, but `moduleLabel` silently returns the raw code for unknowns (e.g. a future module added by the API). Use an exhaustive switch and TS-strict the call site.

## Recommendation
1. **Block merge on the HMAC removal.** Either restore HMAC client-side (and confirm with the summary-service owner that the middleware still enforces it), or land an ADR + docs change first that explains the design shift. Do not merge a PR that intentionally drops a security control without those artifacts.
2. After the HMAC fix, extract the per-report API/schema/routes duplication into a factory and per-report config — at the current scope this PR adds ~1,500 lines of pure boilerplate; the lazy version is ~400.
3. Verify in CI that all 8 migrations apply cleanly against a fresh DB (the README flags migrations as a high-risk area).
4. Split the permissions subjects: PAY and REVERT should not be guarded by `View`.
5. Squash the migration set to ≤3 files before merge.