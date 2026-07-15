# Code Review: PR #2938 — OPD Income Report
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `mpt/opd-income-report-new` → `development`
**Files changed:** 97 (+6524 / -53)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-11
**ClickUp:** https://app.clickup.com/t/9018849685/86exnvzhf

## Summary

This PR delivers the **OPD Income Report** as the first of seven report pages (OPD Income + six Doctor Fees reports) that share a common shape. The visible page groups income, payouts, refunds, receivable, cash and other payments by `(module × counter)` over a date range and shows a grand total. Underneath the page, this PR lays down the full fee-report subsystem:

1. **Seven Prisma `*FeeReport` / `OpdIncomeReport` models** with status-change and adjustment history tables, plus 10 new migrations (the OPD income migration is new; the other six were previously landed). Includes CHECK constraints and pg_trgm GIN indexes hand-added to the SQL because Prisma cannot express them.
2. **Six new report folders** (`*-fees-report`) plus the OPD Income folder, all sharing one `fee-report-shared` toolkit (`fee-report-table`, `fee-report-columns`, filter / pay / revert / activity-log modals, CSV export) wired to a generic `FeeReportConfig<T>` so each page is ~40 lines of config.
3. **The hms-app → summary-service outbox integration**: four new event enqueue helpers (`opd-billing-events.ts`, `ipd-daily-bill-events.ts`, `lab-reading-events.ts`, `imaging-reading-events.ts`) wired into the call sites where a bill line is created/changed/voided (OPD billing repo, OPD refund, IPD daily bill, ward service, service request, cathlab, CT add-on, proxy-bill template, EMR OPD service, imaging + lab repositories). All emit `*_reconciled` / `*_created` / `*refund_created` events into the new `event_outbox` table.
4. **The HMS-side proxy to summary-service** via `src/lib/summary-api.ts` — **with HMAC removed** ("v1: trusted on private network"), tenant header only.
5. **The new OPD Income Report endpoint** (`GET /api/reports/opd-income` → `/opd-income-reports` on summary-api) and its page.
6. **Sidebar + permission UI** additions for the seven new report subjects.

The OPD Income Report page itself is small (table + filter modal + API proxy + Zod schema + types). The 6,524 line additions are dominated by migrations, repetitive page/api boilerplate, and the shared fee-report toolkit — which is also where most of the findings below live.

## Verdict
**Request changes**
Score: 52/100
Critical: 0 | High: 1 | Medium: 7 | Low: 4 | Nit: 2

---

## Findings

### 1. [HIGH] `summaryApi.get` / `summaryApi.post` is untrusted on the wire — HMAC was removed
**Files:** `src/lib/summary-api.ts` (full file), every `src/app/api/(common)/reports/*/route.ts`

```ts
// Server-to-service auth was removed (summary-service v1). The summary-service
// tenant-guard middleware only requires a plain `X-Tenant-Id` header (validated
// as a UUID). v2 will reintroduce an auth context; until then the header is
// trusted on the wire (both services are on the same private network).
```

The summary-service design (`hms-docs/summary-service/api/hmac-auth.md`, ADR 0008) requires HMAC-SHA256 signatures with a 10k LRU replay cache and ±5 min skew. This PR **drops that** with a comment that promises v2 will fix it. Concrete risks today:

- `X-Tenant-Id` is computed from `process.env.DEFAULT_TENANT_ID` and sent on every request. Anything that can read process env (or `/proc/1/environ` on the host, or the Next.js `.env`) gets it; this is no longer a secret. A leaked env + a port-forwarded summary-api listener = full read access to every doctor's payout/income report across the whole tenant.
- The summary-service's HMAC middleware (`src/http/middleware/hmac-auth.ts`) was the only defense against a malicious caller that already has network reach. Removing it without replacing it is a downgrade.
- "Private network" is not a security boundary — it is a deployment choice that breaks the moment the on-prem HMS host is exposed (VPN, jump host, an admin's laptop on the LAN), or when a future change moves summary-api behind a different reverse proxy. The comment says "v2 will reintroduce" but there's no migration deadline, no ADR, no follow-up ticket.

**Fix:** re-add HMAC signing in `summaryApi`. The HMAC primitives in `hms-summary-service/src/lib/hmac.ts` are stable; signing `method + path + body + timestamp + tenant` and adding `X-Signature`/`X-Timestamp`/`X-Service-Id` headers is ~30 lines and matches the documented protocol. If v2 is a separate effort, fine — but don't ship v1 with no auth and a TODO. The fix is the easiest one in this PR; the rest is paperwork.

---

### 2. [MEDIUM] `DEFAULT_TENANT_ID` is read from process env and used for every multi-tenant boundary — silent single-tenant assumption
**Files:** `src/lib/summary-api.ts:74-78`, `src/lib/opd-billing-events.ts:41-49`, `src/lib/ipd-daily-bill-events.ts:90-99`, `src/lib/lab-reading-events.ts:141-149`, `src/lib/imaging-reading-events.ts:33-40`

```ts
const tenantId = process.env.DEFAULT_TENANT_ID?.trim();
if (!tenantId) {
  logger.warn("DEFAULT_TENANT_ID not set; skipping …", { … });
  return;
}
// …emits with that tenant id
```

The outbox `tenantId` is read from env on every enqueue and is the same value used for every request to summary-api (via `getTenantId()` in `summary-api.ts`). `.env.example` ships a placeholder `00000000-0000-0000-0000-000000000001`.

Two problems:

1. **This is a hard-coded single-tenant singleton** even though `hms-docs/summary-service/architecture-prompt.md` declares "multi-tenancy is defense-in-depth" (ADR 0007): HMAC-verified `X-Tenant-Id` at the edge → Prisma tenant-scope → Redis tenant-prefixed → tenant-id in logs. The HMS-side proxy breaks layer 1 (it constructs the tenant header from env, not from the user's session) and breaks layer 4 (no per-request tenant context in logs because the tenant is fixed).
2. **The "skip silently + warn"** is wrong for events that drive **financial reports** (a doctor is paid based on these numbers). Silent skip means the doctor doesn't get paid for a real cancellation until someone manually re-syncs, and there is no metric or alarm that surfaces it. The two viable positions are:
   - **Fail-closed**: the helper throws when `DEFAULT_TENANT_ID` is unset; the upstream transaction rolls back; the operator sees the error. Right answer when the report is the source of truth for payouts.
   - **Fail-open + observable**: warn-log + a `health.tenant_missing` counter; the upstream transaction succeeds; the report is eventually-consistent via a periodic reconciliation sweep.

Today this PR ships (2) silently with no counter and no dashboard.

**Fix:** either re-derive the tenant from the user's session at the request boundary and propagate it through (this is the design-correct path; it also fixes Finding 1), or pick fail-closed vs fail-open and instrument the chosen path.

---

### 3. [MEDIUM] `cancelOPDBilling` is wrapped in a transaction but `cancelOPDBillingLineItems` is not — same intent, divergent patterns
**Files:** `src/app/(dashboard)/shared/opd/repositories/opd-billing.repository.ts` (~line 635 `cancelOPDBilling`, ~line 2875 `cancelOPDBillingLineItems`)

```ts
// wrapped (cancelOPDBilling)
return await prisma.$transaction(async (tx) => {
  await tx.oPDBillingService.update({ … });
  await enqueueOpdBillingEvent(tx, "opd_billing.bill_reconciled", …);
  return …;
});

// not wrapped (cancelOPDBillingLineItems)
const trx = tx || prisma;
const result = await trx.oPDBillingService.updateMany({ … });
await enqueueOpdBillingEvent(trx, "opd_billing.bill_reconciled", …);
return result;
```

`cancelOPDBillingLineItems` is invoked without an enclosing tx in its only visible flow. The `updateMany` followed by `enqueueOpdBillingEvent` is two separate atomic writes — if the first succeeds and the second silently no-ops (e.g. `DEFAULT_TENANT_ID` unset, see Finding 2), the cancel took effect but the report never reconciles.

**Fix:** wrap it in a transaction when the caller didn't pass one, or document the precondition that every caller wraps it (the latter only works if `grep -r cancelOPDBillingLineItems` returns only well-behaved callers).

---

### 4. [MEDIUM] Ward-service delete captures `ipdDailyBillId` in a separate read before the delete, emits via base `prisma` after a non-tx delete
**File:** `src/app/(dashboard)/shared/ipd/services/ward-service.service.ts` (`deleteWardService`)

```ts
async deleteWardService(id: string, userId: string) {
  const existing = await this.getWardServiceById(id);
  const ipdDailyBillId = existing?.ipdDailyBillId ?? null;
  await this.deleteWardRequestItemsAndRefundDeposit(id, userId);
  await this.wardServiceRepository.deleteWardService(id);
  if (ipdDailyBillId) {
    await enqueueIpdDailyBillEvent(prisma, "ipd_daily_bill.bill_reconciled", ipdDailyBillId);
  }
}
```

Three issues:

1. **No transaction wrapping.** The read, the deletes, and the outbox emit are three separate atomic steps.
2. **Event emitted via base `prisma`, not the caller's tx.** Worker can race the cascade delete. The summary-service worker re-reads DB state so the race is "harmless eventual consistency", but the inline comment is a smell.
3. **`if (ipdDailyBillId)` silent skip.** If `existing` is `null` (row was deleted between user click and request) the event is silently dropped — same root-cause question as Finding 2.

**Fix:** if the function can't be wrapped in a transaction without surgery (because `deleteWardRequestItemsAndRefundDeposit` is not transactional itself), add a `// ponytail: best-effort event emit after non-tx delete; reconcile will catch missed events on next sweep` comment so the trade-off is intentional, and at minimum add a `health.event_emit_skipped` counter so missed emits are observable.

---

### 5. [MEDIUM] `bill_created` is emitted from `createWardService` and `createServiceRequest` even though those are not "first time" events — semantic mismatch
**Files:** `src/app/(dashboard)/shared/ipd/services/ward-service.service.ts` (`createWardService`), `src/app/(dashboard)/shared/ipd/services/service-request.service.ts`

`opd-billing-events.ts` exposes three event types (`bill_created`, `bill_reconciled`, `refund_created`). `createOpdBilling` and the CT add-on correctly distinguish "create" from "reconcile". But:

- `createWardService` emits `bill_created` even though it can be called repeatedly for the same daily bill (one row per service line). Workers that distinguish first-time from re-derive will get the wrong signal.
- `createServiceRequest` does the same.

Today the schema makes `bill_created` and `bill_reconciled` indistinguishable to a worker that only looks at `payload` shape, so the only consequence is "the worker code branches on eventType and could be subtly wrong." But over time the divergence will spread.

**Fix:** either drop the `bill_created` variant and emit `bill_reconciled` for everything (the worker re-derives truth either way; "first time" vs "re-derive" is derivable from `lastSyncedAt`), or add a `// ponytail: bill_created vs bill_reconciled matters because X` comment next to every emit that uses `bill_created` (the CT add-on already does the second — make it house style).

---

### 6. [MEDIUM] `fee-report-table.tsx` grand-total footer uses `idx === 1` for the "Grand Total" label — magic index, not column id
**File:** `src/app/(dashboard)/common/reports/fee-report-shared/components/fee-report-table.tsx` (~line 770)

```ts
{visibleColumns.map((col, idx) => {
  let content: React.ReactNode = "";
  if (idx === 1) content = <b>Grand Total</b>;
  else if (col.id === config.feeLabel) content = <b>{money(grandTotal.fee)}</b>;
  else if (col.id === "Payout Amount") content = <b>{money(grandTotal.payoutAmount)}</b>;
  …
}
```

The grand-total "Grand Total" label is placed at `idx === 1` — i.e. **the second column**. The first column is the row-selection checkbox. The other two conditions are id-based and safe. Adding any new column before "Doctor Name" (or removing the checkbox) silently shifts "Grand Total" into the wrong cell.

**Fix:** use `col.id === "Doctor Name"` (the convention column name in the shared `feeReportColumns`) — same length, immune to reordering. Better: add `grandTotalLabelColumnId` to `FeeReportConfig` so the convention is explicit.

---

### 7. [MEDIUM] `OPD Income` is referenced in `enhancedApiHandler` and `<PermissionGuard>` but is missing from `permissionModules`
**Files:** `src/app/api/(common)/reports/opd-income/route.ts`, `src/app/(dashboard)/common/reports/opd-income-report/page.tsx`, `src/app/(dashboard)/common/user-management/roles/features/permission-ui-config.ts`

The OPD Income Report page wraps with `<PermissionGuard action="View" subject="OPD Income">` and the API route declares the same subject. The new `permissionModules.DOCTOR_REPORT` block adds six sub-modules but **not OPD Income**:

```ts
{
  module: "Doctor Report",
  permissions: crudExport,
  subModules: [
    { name: "Consultation Fees", … },
    { name: "Tele Consultant Fees", … },
    { name: "In-house Doctor Fees", … },
    { name: "Round Fees", … },
    { name: "Procedure Fees", … },
    { name: "Reading Fees", … },
    // OPD Income is NOT here
  ],
},
```

Result:
- The role-management UI gives no way to grant the OPD Income permission to a role.
- Existing roles don't have it (no seed migration adds it).
- Every user with no special permission sees `UnauthorizedPage` for OPD Income.

**Fix:** add `{ name: "OPD Income", excludeActions: ["add", "edit", "delete"] }` to the sub-modules list, and seed `View` on `OPD Income` to the same role(s) that have `Consultation Fees` (verify with team).

---

### 8. [MEDIUM] The six `*FeesReport` pages, APIs, and 24 route.ts files are copy-pasted — should collapse to a factory
**Files:** All `src/app/(dashboard)/common/reports/{consultation,tele-consultant,in-house-doctor,round,procedure,reading}-fees-report/**`, all `src/app/api/(common)/reports/*/{,pay,revert,activity-logs}/route.ts`

Six report folders × (api + page + table + types + schema) plus 4 routes × 6 = 24 route files (~95% identical, differing by 4 strings: `BASE`, query key prefix, schema name, permission subject, activity-log entity). This is the heart of the PR and the worst copy-paste.

What is genuinely per-report:
- `*ReportRow` shape (different columns: `consultationFee` vs `inHouseDoctorFee` vs `roundFee` …)
- `source` enum values (`OPD|IPD` vs `LAB|IMAGING`)
- `invoiceType` filter presence
- The schema for `payPfReportSchema` is currently identical to `payCfReportSchema` (both are `adjustmentType ∈ {PLUS, MINUS, FULL}` + `adjustmentMode ∈ {PERCENT, AMOUNT} | null`).

What is **identical**:
- All 6 page.tsx (default date range to today; URL replace).
- All 6 api.ts (`buildListParams`, `fetch*Report`, `pay*Reports`, `revert*Reports`, `fetch*ActivityLogs`, `make*ReportQuery`).
- All 24 route.ts files.
- The per-report `*FeesReportTable.tsx` (~40 lines of a config object).
- The `pay*ReportSchema` + `revert*ReportSchema` (identical).
- Six copies of `useEffect(() => { … }, [])` with the same `eslint-disable-next-line` comment for "default date range to today."

The shared `fee-report-shared` toolkit is the right instinct; it just didn't go far enough. The next report will ship another ~700 lines of copy-paste.

**Fix (not in this PR — flag as follow-up):** collapse the 24 route.ts files to a single factory:

```ts
// src/app/api/(common)/reports/_factory.ts
export const buildFeeReportRoutes = <TRow extends BaseFeeReportRow>(c: {
  basePath: string;
  summaryPath: string;
  permissionSubject: string;
  querySchema: ZodSchema;
  paySchema: ZodSchema;
  revertSchema: ZodSchema;
  activityLogEntity: string;
}) => ({ GET: …, payPOST: …, revertPOST: …, activityLogsGET: … });
```

Then each `route.ts` becomes 5 lines. Also extract `useDefaultDateRange()` to a shared hook.

---

### 9. [LOW] Activity-log reads use `prisma.activityLog.findMany` directly with a string `entity` — multi-tenant blind spot
**Files:** all 6 `src/app/api/(common)/reports/*/activity-logs/route.ts`

```ts
const logs = await prisma.activityLog.findMany({
  where: { entity: "ProcedureFeesReport", entityId },
  …
});
```

The `entity` filter is a magic string. Risks:

- If the summary-service writes a different casing (`"procedureFeesReport"` vs `"ProcedureFeesReport"`) the modal will silently show zero rows. There is no shared constant enforcing the spelling.
- The HMS `activityLog` table almost certainly has a `tenantId` column (or `createdById.tenantId`). The route doesn't filter by tenant, so users in tenant A with access to a report's `entityId` could read activity logs from tenant B if the IDs collide. (This depends on how `activityLog` enforces tenancy — verify before assuming.)

**Fix:** define `ENTITY` constants in `fee-report-shared/types.ts` and import everywhere; add `tenantId` to the `where` if the table carries it.

---

### 10. [LOW] `OPD Income` page search box is wired to read URL but no input writes the URL — the search input has no effect
**File:** `src/app/(dashboard)/common/reports/opd-income-report/features/components/opd-income-report-table.tsx`

```ts
const search = (searchParams.get("search") ?? "").trim().toLowerCase();
…
<DataTableSearchbox placeholder="Search Module Name" />
…
const rows = useMemo(() => {
  if (!search) return items;
  return items.filter((r) => moduleLabel(r.module).toLowerCase().includes(search));
}, [items, search]);
```

`DataTableSearchbox` reads `?search=` from URL but nothing writes it. Typing "lab" produces no effect unless the user manually navigates with `?search=lab` in the URL. Additionally, the filter matches on `moduleLabel(r.module)` only — not on counter name — even though the placeholder says "Search Module Name" and the user might reasonably expect to also search across counters.

**Fix:** drop the searchbox (the server already groups by module and the filter modal exposes the only server-side filter — counter), or wire it properly with local state + URL sync.

---

### 11. [LOW] `PermissionGuard` checks `View` permission only — write routes (pay/revert) should require explicit `Pay`/`Revert` (or at least a write permission)
**Files:** all 6 `src/app/api/(common)/reports/*/pay/route.ts`, `revert/route.ts`

```ts
auth: {
  required: true,
  permissions: [{ action: "View", subject: "Procedure Fees" }],
},
```

Paying out a doctor's fee or reverting a payment is a write that touches money. The permission check is read-only. If the role-management UI only ever grants `View` (and the schema's `excludeActions: ["add", "edit", "delete"]` is the convention for these reports), then any user who can *see* the report can also *pay* it. That may be intentional (the only role that gets `View` is also the only role that can pay), but it's worth a comment confirming.

**Fix:** add explicit `action: "Pay"` / `action: "Revert"` permission subjects to `permissionModules.DOCTOR_REPORT` and gate the routes on those; or add a `// ponytail: View is the only permission for these reports by design` comment.

---

### 12. [LOW] `fee-filter-modal.tsx` always renders Status and Doctor selects — Procedure Fees has no Doctor filter in its schema
**File:** `src/app/(dashboard)/common/reports/fee-report-shared/components/fee-filter-modal.tsx`

The shared filter modal renders `Doctor` and `Status` always; only `invoiceType` and `source` are gated. Procedure Fees Report has no `doctorId` in `getPfReportSchema`, but the modal shows the Doctor select anyway. Setting it sets `?doctorId=null` in the URL, which bumps the filter count to 1 with no actual effect, confusing the user.

**Fix:** add `showDoctorFilter` and `showStatusFilter` toggles to `FeeReportConfig`, default `true`.

---

### 13. [NIT] `permissionModules` uses `module: "Doctor Report"` as both navigation label and conceptual grouping, with `excludeActions: ["add", "edit", "delete"]` repeated 6 times
**File:** `src/app/(dashboard)/common/user-management/roles/features/permission-ui-config.ts`

The `module: "Doctor Report"` is a UX grouping, not a permission entity (no `DoctorReport` Prisma model, no `doctor-report` route prefix). The `excludeActions: ["add", "edit", "delete"]` repetition smells like a missing constant:

```ts
const viewOnlyExport = { ...crudExport, excludeActions: ["add", "edit", "delete"] };
```

**Fix:** hoist the constant and apply once at the parent module.

---

### 14. [NIT] `OpdIncomeReportSchema` defaults to today when no date range — but the redirect-on-mount pattern uses `eslint-disable-next-line react-hooks/exhaustive-deps`
**File:** `src/app/(dashboard)/common/reports/opd-income-report/page.tsx`

The `useEffect(() => { … }, [])` with the disabled lint rule is a smell. Same pattern copy-pasted to all six `*-fees-report/page.tsx`. A `useDefaultDateRange(start, end)` hook (Finding 8) removes the need for both the lint disable and the duplication.

---

## Things that are good

- **Schema design.** `OpdIncomeReport` measures stored positive with `CHECK (amount >= 0)` and the deduction cells render in parens. CHECK constraints and pg_trgm GIN indexes correctly hand-added in SQL. The unique index `(tenant_id, source_type, source_id, module)` is the right grain for idempotent upsert.
- **`FeeReportConfig<T>` + `BaseFeeReportRow`** is the right level of abstraction for the per-report page itself. Six reports × 40 lines of config is fine; it's the 24 route.ts files that aren't.
- **Transactional outbox pattern.** Wiring `eventOutbox.create` inside the same `$transaction` as the bill edit is the correct shape. `cancelOPDBilling` and `deleteOPDBilling` correctly wrap their edits in a transaction. `ward-service.service.ts` is the only place this breaks (Finding 4).
- **Idempotent reconciliation.** The "worker re-derives truth from current DB state" semantics are robust against re-delivery. Good.
- **`StatusBadge` / `AdjustmentCell`** in `fee-report-columns.tsx` handle the `sourceVoided` tooltip and the +/- color treatment cleanly.

---

## What was deliberately not changed

- The summary-service changes (worker, services, HMAC middleware) live in a different repo and are out of scope.
- The 6 `*FeesReportTable.tsx` files (~40 lines of config) are at the right level of abstraction; the 24 route.ts files aren't.
- The OPD Income Report page itself is small enough that most findings above live in the **shared-infrastructure** concerns (HMAC, factories, magic `idx === 1`, missing OPD Income permission subject, DEFAULT_TENANT_ID pattern) — those aren't the OPD Income Report's fault but they show up here because this PR closes the loop on the whole fee-report subsystem.

## Score
- Start: 100
- −8 × 1 High (Finding 1 — HMAC removed)
- −4 × 7 Medium (Findings 2, 3, 4, 5, 6, 7, 8)
- −2 × 4 Low (Findings 9, 10, 11, 12)
- −1 × 2 Nit (Findings 13, 14)

**Score: 52 / 100** — **request changes.** The High (HMAC removed) is the security blocker and the easiest fix (~30 lines). The Mediums split into: (a) real bug-or-missing-feature items (Findings 2, 3, 7) that ship as broken/misconfigured on day one; (b) architectural smells (Findings 4, 5, 6, 8) the next PR will pay for in maintenance.

## Recommended action before merge
1. **Re-add HMAC signing** in `src/lib/summary-api.ts` (~30 lines, matches `hms-docs/summary-service/api/hmac-auth.md`). (Finding 1)
2. **Decide on `DEFAULT_TENANT_ID`**: either re-derive the tenant from the user's session (preferred; fixes Finding 1 + Finding 2), or document the fail-open position with an observable counter. (Finding 2)
3. **Add `OPD Income` to `permissionModules.DOCTOR_REPORT` sub-modules** and seed the `View` permission. (Finding 7)
4. **Wrap `cancelOPDBillingLineItems`** in a transaction when the caller didn't pass one. (Finding 3)
5. **Replace `idx === 1`** with `col.id === "Doctor Name"` in the shared grand-total footer. (Finding 6)
6. **Wire or drop the OPD Income searchbox**. (Finding 10)

After 1–4, this is shippable. Findings 5, 8, 9, 11–14 are cleanups that can land as follow-ups.
