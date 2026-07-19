# Code Review: PR #2938 — OPD Income Report
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `mpt/opd-income-report-new` → `development`
**Files changed:** 97 (+6524 / -53)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-16
**ClickUp:** https://app.clickup.com/t/9018849685/86exnvzhf

## Summary
The PR ships the headline **OPD Income Report** — a module×counter aggregation across 9 modules (OPD, Pharmacy, Lab, Imaging, HD, OT, Daycare, ED, Endo) — and lands the broader **fee-report infrastructure** underneath it: 6 sibling pages (Consultation, Tele Consultant, In-house Doctor, Round, Procedure, Reading Fees), a shared component kit (`fee-report-shared/`), 7 Prisma models + 9 SQL migrations, 28 new API route handlers (4 per fee report + 1 for OPD income), outbox event emitters for OPD/IPD/lab/imaging billing events, a new `summary-api` HMAC-less client, sidebar entries, and a new "Doctor Report" permission module. Money flows HMS → `event_outbox` → summary-service worker → report tables, with the HMS web app reading aggregated views back via the new API.

## Verdict
**Request changes**
Score: 42/100
Critical: 0 | High: 3 | Medium: 5 | Low: 5 | Nit: 4

## Issues

### Critical
None.

### High

**H1. `summary-api.ts` drops HMAC auth — silent deviation from the canonical design.**  
`src/lib/summary-api.ts:1-30` — the file comment admits *"Server-to-service auth was removed (summary-service v1). The summary-service tenant-guard middleware only requires a plain `X-Tenant-Id` header… until then the header is trusted on the wire."*  
This contradicts CLAUDE.md and the summary-service ADRs (ADR 0008 mandates HMAC-SHA256 with a 10k-entry replay cache, ±5-min skew). The summary-service was specifically designed *for* HMAC — the entire `hms-docs/summary-service/api/hmac-auth.md` doc and `src/lib/hmac.ts` exist for this. The HMS BFF→summary-api boundary now trusts a header alone. If HMAC is intentionally deferred, the deviation must be called out in the design docs, not buried in a `// Server-to-service auth was removed` comment. Either ship HMAC for v1 or update `hms-docs/summary-service/adrs/0008-*.md` to record the v1 carve-out.

**H2. Money stored as Prisma `Int` while the design mandates `NUMERIC(12,2)`.**  
`prisma/schema.prisma` — every fee column is `Int`: `consultationFee Int` (L54), `fee Int` (L133), `inHouseDoctorFee Int` (L227), `procedureFee Int` (L317), `roundFee Int` (L413), `readingFee Int` (L511), `amount Int` (L596) on the OPD income report. The summary-service design doc says money is `NUMERIC(12,2)`; CLAUDE.md warns *"the summary-service does not run migrations against the shared DB — the HMS team runs the DDL from `hms-docs/summary-service/data-model/schema.sql` (CHECK constraints and the pg_trgm GIN index cannot be expressed in Prisma alone)"*. If the HMS team runs the DDL as documented and ends up with `NUMERIC`, the summary-service Prisma client (which expects `Int`) will break at runtime. Either align the DDL to integer-cents *and* update `hms-docs/summary-service/data-model/schema.sql`, or use Prisma's `Decimal` everywhere.

**H3. 9 migrations committed across 3 weeks — coordinated atomicity risk.**  
`prisma/migrations/20260617091918_add_summary_service_tables` through `prisma/migrations/20260706000000_add_opd_income_report_tables` — 9 separate `prisma migrate dev` runs (Jun 17 → Jul 6). If even one migration has already been applied to a shared dev or staging DB, this PR cannot roll forward. There's no `migrate dev --create-only` consolidation, and the PR description doesn't acknowledge migration state. The PR should either: (a) squash to a single migration before merging, or (b) explicitly state which envs each migration has been applied to and whether `migrate deploy` is safe.

### Medium

**M1. 7 GET routes duplicate the URLSearchParams build verbatim.**  
`src/app/api/(common)/reports/*/route.ts` — every GET handler builds the same `new URLSearchParams` block, mapping `query.start→from`, `query.end→to`, plus optional `status`/`doctorId`/`invoiceType`/`storeId`/`search`. 7 near-identical copies. Add `buildReportQuery(params: Record<string, unknown>): string` once and call it from each route — the param-name mapping is the only variation.

**M2. `summaryApi` discards structured upstream error messages.**  
`src/lib/summary-api.ts:51-58` — when the summary-service returns a structured 409 (e.g. `ADJUSTMENT_LOCKED` or `ADJUSTMENT_EXCEEDS_AMOUNT`), the code reads `(json && (json.message as string)) ?? \`summary-api ${method} ${path} failed (${res.status})\``. If the body parses but lacks a top-level `message` (or uses `error.message`), the user sees the generic string — losing the actionable reason. The `pay`/`revert` flows benefit most from a clear upstream reason. Add a small `extractErrorMessage(json, fallback)` helper and call it consistently.

**M3. OPD income `module` / `measure` / `sourceType` are stringly-typed in Prisma, no TS enum.**  
`prisma/schema.prisma:585-600` — `OpdIncomeReport` uses `String` for `measure`, `module`, `sourceType`. CLAUDE.md explicitly warns *"the CFI status enum is exactly ('UNPAID', 'PAID', 'VOID') — do not add PAYABLE, DISBURSED, etc."* (i.e. enums are the team convention for this domain). The CHECK constraints exist in the migration (good), but the HMS Prisma client has no TS-level narrowing. A typo (`'OPD_INCOM'` instead of `'OPD'`) only blows up at insert time. Promote to a Prisma `enum` or at minimum define `OpdIncomeModule` / `OpdIncomeMeasure` const types in `src/lib/opd-income/constants.ts` for both sides to share.

**M4. `permission-ui-config.ts` registers "Doctor Report" but does not include "OPD Income".**  
`src/app/(dashboard)/common/user-management/roles/features/permission-ui-config.ts:898-922` adds the parent module with 6 subModules — all the sibling fee reports. Meanwhile, `opd-income-report/page.tsx:481` guards with `subject: "OPD Income"`, but no submodule of that name is registered in the UI config. Users cannot grant/revoke the OPD Income permission through the role editor and will get `UnauthorizedPage` for any role that's missing the JSON manually. Add `{ name: "OPD Income", excludeActions: ["add","edit","delete"] }` to the same parent module.

**M5. `useEffect`-driven URL rewrite race with `useSuspenseQuery`.**  
`opd-income-report/page.tsx:451-460` (and 6 sibling pages). On first mount, if no `start`/`end` is in the URL, the page kicks off `useSuspenseQuery(makeOpdIncomeReportQuery(...))` with `effectiveQuery.start/end` defaulted to today — and *simultaneously* calls `router.replace(...)` to write those defaults into the URL. On a slow link the user sees an empty table briefly before the URL rewrite triggers a re-fetch. Memoize `effectiveQuery` and ensure the first fetch uses the same default values the URL write will install. A `useDefaultDateRange()` hook would centralize this.

### Low / Nit

**L1. OPD income table React keys include array index.**  
`opd-income-report-table.tsx:285` — `key={\`${row.module}-${row.storeId ?? "none"}-${i}\`}`. Index-in-key is a React anti-pattern (animates wrong on reorder/filter). Drop the `${i}`; the `${module}-${storeId}` composite is already a stable id.

**L2. `FeeReportTable` footer "Grand Total" uses positional index.**  
`fee-report-shared/components/fee-report-table.tsx:773` — `if (idx === 1) content = <b>Grand Total</b>`. Couples to column order; if the user hides the first column (Select), the label slides left. Use the column id (e.g. `col.id === "Billing Date"` or whichever column is the "label" slot).

**L3. `money()` formatter reimplemented 3×.**  
`fee-report-columns.tsx:14`, `fee-report-table.tsx:46`, `opd-income-report-table.tsx:18-20`. Pull into `src/lib/format-money.ts` and reuse. Single source of truth for the `n == null ? "-" : n.toLocaleString("en-US")` rule.

**L4. OPD income `moduleLabel` silently falls through to raw code on unknown values.**  
`opd-income-report.types.ts:382` — `MODULE_LABELS[code as OpdIncomeModuleCode] ?? code`. A new module added to the CHECK constraint (but not the TS union) renders as the raw code with no UI affordance to spot it. Add `if (process.env.NODE_ENV !== "production" && !(code in MODULE_LABELS)) console.warn(...)` — dev-only.

**L5. `fetchActivityLogs` ref churns per render.**  
6 of 7 callers in `fee-report-shared/types.ts:67` and the per-report `*.api.ts` files pass a fresh arrow function for `fetchActivityLogs` on every render. React Query only invokes the function when `enabled`, so the runtime impact is zero, but the captured `queryKey` closure can drift. Memoize at the caller with `useCallback`.

**N1. `path` ternary noise in 7 route handlers.**  
`src/app/api/(common)/reports/*/route.ts` — `\`/${prefix}${sp.toString() ? \`?${sp.toString()}\` : ""}\`` is repeated 7 times. Trivial `buildPath(prefix, params)` helper.

**N2. Verbose JSDoc on the 4 `*-events.ts` files.**  
`src/lib/{opd-billing-events,ipd-daily-bill-events,lab-reading-events,imaging-reading-events}.ts` share ~90% of their structure. Could collapse to one `enqueueEvent(tx, type, aggregateId, extraPayload)` factory plus a single `events.ts` listing all event types — but the explicit per-domain wrappers are valuable documentation. Acceptable as-is.

**N3. `data-foo=undefined` URLSearchParams omission is hand-rolled.**  
All 7 GET handlers manually `if (query.x) sp.set("x", query.x)`. `Object.entries(query).filter(([, v]) => v != null && v !== "").forEach(([k, v]) => sp.set(...))` would be a one-liner. Style, not substance.

**N4. OPD income migration sorts indexes alphabetically — confirm convention.**  
`prisma/migrations/20260706000000_add_opd_income_report_tables/migration.sql:36-45` — indexes are declared in logical order (`uq_opd_income_source` first, then date, then module-store, then opd_billing). The other 6 fee-report migrations in this PR use a similar ordering. Consistent — no action needed, just noting.

## Recommendation
Address the three High findings before merge:

1. **Restore HMAC** between HMS BFF and summary-api (or document the v1 carve-out explicitly in `hms-docs/summary-service/adrs/`).
2. **Align the schema with the DDL** — either integer-cents end-to-end or `Decimal` end-to-end. Coordinate with whoever runs the SQL migrations (HMS team, per CLAUDE.md).
3. **Consolidate migrations** into one (or document their dev/staging state).

Once those are clear, the Medium items are reasonable to fold into follow-ups (the date-range race is the highest-impact). The Low/Nit items are taste.

Net ponytail opportunity: ~80 lines recoverable via `buildPath`, `useDefaultDateRange`, and a shared `format-money` util — not a blocker, just the obvious next cleanup pass.

---
**Ponytail summary:**  
`fee-report-shared/` is well-shaped (the kit is reused across 6 reports). The `FeeReportConfig<T>` pattern is the right abstraction. Main over-engineering smells are the duplicated `URLSearchParams` blocks (M1) and the per-page `useEffect`-rewrite (M5) — both worth one shared helper, neither worth blocking on.

`net: -~80 lines possible across helpers.`