# Code Review: PR #2920 — Feat: opd emr services
**Repository:** MyanCare/Ycare-HMS
**Author:** @Xkill119966
**Branch:** `feat/opd-emr-services` → `development`
**Files changed:** 23 (+3430 / -1)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-09
**ClickUp:** https://app.clickup.com/t/9018849685/86ey4prkg

## Summary
Adds an "OPD Services" tab to the OPD EMR Tabs panel. Introduces a new `OpdEmrServicesTabComponent` with full create/edit/view/delete flow for OPD "proxy bills" that mix pharmacy + services + procedures, plus a new `OpdProxyBillService` that extends the shared `ProxyBillTemplateService`, three new server actions (create-from-EMR, create-standalone, update-from-EMR), and a new GET `/api/opd/[id]` route. Includes shared services-collapsing context (`opd-service-bill.context`), a form-binding hook (`use-bind-form`), and a per-row service bill editor with team-fee toggle and first-visit pricing. Wires the new tab into `OpdEmrTabsComponent` behind a `PermissionGuard subject="OPD Services"`, registers `OPD` as a bill-type module option, and turns on `includeEdProxyBillJoints` in `opdEmrService` so the tab can locate the linked proxy bill.

## Verdict
**Request changes**
Score: 64/100
Critical: 1 | High: 4 | Medium: 4 | Low: 2 | Nit: 1

## Issues

### Critical

1. **`fetchActivitesByOpd` calls an API route that does not exist.** `src/app/(dashboard)/emr/opd/features/api/fetch-activites-by-opd-id.ts:7` calls `GET /api/opd/${id}/activities`, but the PR only adds `src/app/api/(opd)/opd/[id]/route.ts` (the parent `GET /api/opd/:id`). There is no `[id]/activities/route.ts` anywhere in `src/app/api/(opd)/`. The activity-log modal will 404 at runtime whenever a user clicks "View Activity Logs." Add the missing route (e.g. `src/app/api/(opd)/opd/[id]/activities/route.ts` wired to `opdProxyBillService.getProxyBillActivities`) or change the client URL to an existing endpoint.

### High

1. **Permission UI label does not match server-side enforcement.** `permission-ui-config.ts:275` registers the module as `"OPD Services"` with `excludeActions: ["export"]`. The `PermissionGuard` in `opd-emr-tabs-component.tsx:254` and the delete button in `confirm-delete-modal.tsx:59` both use subject `"OPD Services"`. However, the new GET route `src/app/api/(opd)/opd/[id]/route.ts` only enforces `auth.required: true` with no `permissions` clause, so any logged-in user (including non-clinical roles) can fetch any proxy bill by id. Either add `permissions: [{ action: "View", subject: "OPD Services" }]` to the route, or document the intent to leave it open. Without an explicit permission check on the GET endpoint the UI permission guard is performing only cosmetic gating.
2. **Race condition: `getOpdEmByPatientAppointmentId` runs outside the transaction that creates the joint.** `src/app/(dashboard)/shared/opd/services/opd-proxy-bill.service.ts:96-117` does the EMR lookup/insert before `super.createProxyBill(...)`. The parent transaction is acquired with `prisma.$transaction(async (tx) => {...})` and the lookup is `await opdEmrService.getOpdEmByPatientAppointmentId(payload.patientId, appointmentId)` (presumably on the global `prisma`). If two requests for the same `(patientId, appointmentId)` land concurrently, both will see no EMR and both will attempt `createOpdEmr` — first one wins, second one fails on a unique constraint (or creates a duplicate depending on schema). Pass `tx` to the lookup, or rely on the unique constraint plus `tx.eDEMRProxyBillJoints.upsert` to converge.
3. **`use-bind-form.tsx` swallows `servicePackage.price` into an empty `{}` and writes that to form state.** Line 558: `servicePackagePrice: itm.servicePackage.price && {},` — a conditional that evaluates to either the truthy price object or `{}`. Any downstream code that reads `servicePackagePrice` will see `{}` for every row whose `price` is not falsy in the JS truthy sense, and pass through the truthy object otherwise. This is almost certainly a bug: either remove the field from the schema or assign `itm.servicePackage.price` directly. As written, two separate services with the same falsy-but-defined `price` will get `servicePackagePrice: {}`, silently corrupting the billed amount basis.
4. **3-step state machine (`isDetailMode` / `isUpdateMode` / deletion flag) is fragile and has a covered-up empty branch.** `opd-emr-services-tab.tsx:276-280` introduces `allowLockedEdit = !isBillPaid || isBillUnpaid`. Since `isBillPaid === !isBillUnpaid` for an OPD bill (`paymentStatus ∈ {UNPAID,PAID,VOID}`), this reduces to `allowLockedEdit = !isBillPaid || !isBillPaid = !isBillPaid`. The dead branch hides a logic contradiction — when payment status is VOID, `allowLockedEdit` evaluates to `true`, meaning a voided (terminal) bill becomes editable. Fix: `allowLockedEdit = isBillUnpaid`.

### Medium

1. **`isDeletedLocally` resets only when `existingProxyBillId` becomes a new valid value, but the dependency array is `[existingProxyBillId]`.** `opd-emr-services-tab.tsx:74-76`. If `existingProxyBillId` transitions `A → undefined → B`, the effect runs on `undefined` first (no-op), then on `B` (resets local delete state) — fine; but if `A → B` happens mid-render without an intermediate `undefined`, React does not guarantee re-renders will pick up the new id before a stale `useQuery(['opd-bill', A])` returns cached data. Either reset state when the id changes *or* keeps `existingProxyBillId` stable across navigations. At minimum, document the assumption.
2. **`OpdServiceBillProvider` re-fetches `getServices` with `debounced: ""` on first render, hitting the API for every tab open even when the patient has no service lines yet.** `opd-service-bill.context.tsx:30-37`. The default `searchedService=""` is debounced to `""` and triggers `getServices({search:""})` immediately. Add an `enabled: !!searchedService` guard so the Select does not query on mount.
3. **Server action `createOpdBillFromEmrAction` does not bind `emrType` or surface `opdEmrId` back to the UI consistently.** `opd-emr-services.actions.ts:30-39` returns `result` plus `opdEmrId` (line 84 of `opd-proxy-bill.service.ts`); `OpdEmrServicesTabComponent` reads `result.data?.id` for cache invalidation but never reads the new `opdEmrId`. After a standalone create-and-route, the user lands on the EMR edit page using `result.opdEmrId` — fine — but the tab-level cache invalidation only invalidates `["opd-bill", result.data.id]`, not the EMR query (which is keyed by `emrId` derived from `opdBillId` upstream). Add an explicit `queryClient.invalidateQueries(['opd-emr-by-id', createdOpdEmrId])` after the redirect path to keep the EMR page header in sync.
4. **`onError` in `confirm-delete-modal.tsx:50` reports the wrong entity on failure.** `toast.error({ message: ... invoice ${proxyBilling?.bill?.invoiceNo}` — but the new "OPD Services" entity is not the same as "OPD Bill" with an invoice number. If the parent `opd-bill` does not yet have a linked bill, the toast will read "undefined." Either drop the invoice number reference or look it up from `proxyBilling?.bill?.invoiceNo ?? proxyBilling?.id`.

### Low / Nit

- **Low:** Two imports of `useMantineTheme` and duplicate hard-coded `bg-slate-50 w-full rounded-md flex justify-center text-sm` in `opd-collapse.tsx:26` should move to a shared class so other detail-page accordions can reuse it.
- **Nit:** `opd-services.tsx:1740-1754` ships a `TODO: Uncomment this when team fees are implemented` followed by the comment `/* <OpdTeamFeesSection /> */`. Either ship team fees or remove the now-defined but unused section component (~80 lines of row editor and `OpdTeamFeesSection` export).

## Recommendation
1. Add the missing `/api/opd/[id]/activities` route handler so the activity-log modal works, or stop calling that endpoint.
2. Add a `View` permission check on `GET /api/opd/[id]` so the UI `PermissionGuard` is not just cosmetic.
3. Move the EMR lookup into the transaction (`tx`) and use upsert semantics to converge concurrent standalone creates.
4. Fix the `servicePackagePrice: itm.servicePackage.price && {}` typo (line 558 of `use-bind-form.tsx`).
5. Resolve the `allowLockedEdit`/`isBillPaid`/`isBillUnpaid` contradiction — use `isBillUnpaid` directly.
6. Re-enable (or delete) the unused `OpdTeamFeesSection` to avoid shipping a half-implemented feature behind a comment.
7. Defer the cosmetic activity-log/missing-endpoint issue to "must fix before merge"; the rest is polish for a follow-up.
