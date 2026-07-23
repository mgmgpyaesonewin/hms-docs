# Code Review: PR #3032 — Show service name instantly, remove first-add delay
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `mpt/fix-service-request-loading-behaviour` → `development`
**Files changed:** 8 (+89 / -16)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86eyaxdy0

## Summary
Fixes a UX wart where adding the first service row in a service-request form would briefly render an empty `name` and `category.name` while the row component's own `useQuery` cold-fetched the services + doctor-services lookup tables. The PR does this in three coordinated moves:

1. **Cache warming in the parent form.** `EmrStandardServiceRequestForm`, `IpdEmrStandardServiceRequestForm`, and `StandardServiceRequestForm` each add two `useQuery` calls (services + doctor-services) at mount, using a new exported `SERVICE_LOOKUP_QUERY = { limit:0, page:1, offset:0, search:"" }`. These queries fire the same fetches the row components would issue, so when a row is later added the cache is already warm.
2. **Export the constant.** The row components (`EmrServiceRequestTableItemRow`, `IpdEmrServiceRequestTableItemRow`, `ServiceRequestTableItemRow`) rename their private `EMPTY_QUERY` to exported `SERVICE_LOOKUP_QUERY` so the parent form and row agree on a single queryKey shape.
3. **Denormalize `categoryName` into the form row.** A new optional field `categoryName: z.string().nullable().optional()` is added to both `base-emr-service-request-form.schema.ts` and `base-service-request-form.schema.ts`. The three forms populate it when appending a service (`service.category?.name ?? null`), and the row components compute `serviceName` from `[service.name || selectedService?.name, service.categoryName || selectedService?.category?.name].filter(Boolean).join(" - ")` so the label renders immediately even before `servicesData` resolves.

## Verdict
**Approve with suggestions**
Score: 84/100
Critical: 0 | High: 0 | Medium: 2 | Low: 3 | Nit: 2

## Issues

### Critical
None

### High
None

### Medium

**M1. Duplicate services fetch on every form mount in the IPD paths.**
`StandardServiceRequestForm` (IPD) and `IpdEmrStandardServiceRequestForm` already run `useQuery(makeFetchServicesQuery(query))` where `query` defaults to `INITIAL_QUERY = { page:1, limit:10, offset:0, search:"", status:serviceStatus.ACTIVE, module:"" }`. This PR then adds a second `useQuery(makeFetchServicesQuery(SERVICE_LOOKUP_QUERY))` with `limit:0`. The two queryKeys differ (`limit:10, status:ACTIVE, module:""` vs `limit:0`), so React Query treats them as distinct and **fires two services requests on every mount** — even when no service row exists yet.

The row components only mount once the user has added a row, so the warming is only useful in that branch. Cheaper alternatives:
- Reuse the existing `servicesData` from `useQuery(makeFetchServicesQuery(query))` (already fetched with `limit:10` — usually enough for the dropdown lookups by id). The row component can read it via a context/prop or a derived selector rather than issuing its own `useQuery`.
- Or move the `SERVICE_LOOKUP_QUERY` warming to the row component itself and gate it behind a render-only-after-first-row condition (e.g. lazy `enabled`).
- Or accept that the row's own `useQuery` will dedupe against the parent's already-warmed cache — and drop the warming line in the IPD forms entirely. The parent's `query.search=""` plus `limit:0` shape equals `SERVICE_LOOKUP_QUERY`, but with `limit:10` the keys differ, so currently no dedup.

The EMR OPD form (`emr-standard-service-request-form.tsx`) does **not** have an existing services query, so its two new warming lines are necessary — that one is fine.

**M2. `categoryName` schema field is denormalized state that can drift.**
The row's `serviceName` now reads `[service.name || selectedService?.name, service.categoryName || selectedService?.category?.name].filter(Boolean).join(" - ")`. The form sets `service.name` and `service.categoryName` at append time from `selectedService.name` / `selectedService.category?.name`. If a service's category is ever renamed, existing rows in saved drafts will continue to show the stale `categoryName` even though the row's own `servicesData` (now cached) would return the fresh value.

This is acceptable as a perf-only denormalization for the "instant" goal — but the schema now has two sources of truth (denormalized `service.categoryName` and authoritative `selectedService.category?.name`). If category renames ever matter, this will silently mislabel. Document the trade-off in the schema comment, or scope the denormalization to "render-only, never re-saved": currently the form passes the whole `service` object (including `categoryName`) on submit, which means the denormalized value is also what gets persisted downstream. Worth a one-line schema comment noting that `categoryName` is render-cache-only.

### Low / Nit

**L1. Two `useQuery` calls in EMR OPD parent but no existing services fetch there.**
`emr-standard-service-request-form.tsx` adds two warming queries. The new `makeFetchDoctorServicesQuery` import is consistent with the other two forms. Good — no issue, but the `useQuery` import had to be added (`useSuspenseQuery` was already imported). Confirmed correct.

**L2. `selectedService?.category?.name` is now safely optional.**
Old code: `${selectedService?.category.name || ""}` — would throw if `selectedService` was undefined. New code: `[..., service.categoryName || selectedService?.category?.name, ...]` — safe. Genuine bug fix, not a regression.

**L3. QueryKey object identity.**
`SERVICE_LOOKUP_QUERY` is exported as a single `const` object reference, so both the parent form and row component pass the **same** reference into `makeFetchServicesQuery`/`makeFetchDoctorServicesQuery`. The queryKey built inside those factories is `["services", params]` / `["doctor-services", params]`, and React Query does structural equality on queryKey arrays — but using a single shared reference for the `params` slot also means referential equality holds if anyone ever does `===` comparisons. Good practice; no action needed.

**N1. `serviceName` filter+join is fine.**
`[a || x, b || y].filter(Boolean).join(" - ")` is idiomatic enough. Skip.

**N2. The export rename `EMPTY_QUERY` → `SERVICE_LOOKUP_QUERY` is a breaking import for any external consumer.**
None found via grep (the symbol was previously `const`/un-exported). Safe rename. Nit-level only because it's worth noting the symbol is now part of the public API surface of the row component.

## Recommendation
- **M1 (duplicate fetch):** simplest fix — in the two IPD forms, drop the new `useQuery(makeFetchServicesQuery(SERVICE_LOOKUP_QUERY))` and instead expose the already-fetched `servicesData` to the row component via a prop or a small context. Or, if the prop wiring is too invasive, accept the duplicate fetch as the cost of the warming guarantee and move on (it's two fetches on mount, not per-row). Either way, leaving it as-is means two `/api/services` requests fire on every form mount.
- **M2 (denormalization):** add a one-line schema comment on `categoryName` clarifying "render-cache; treat as denormalized snapshot at row-add time, not authoritative." If the schema is also persisted downstream (it likely is — these forms submit the whole row), consider whether downstream consumers should ignore `categoryName` and re-derive from the service id.
- **L1–L3, N1–N2:** no action required; these are informational.

The PR's core idea (cache warming + denormalize the label fields) is sound and addresses a real UX defect. The two Mediums are the only things blocking full-throated approval, and both are local mechanical fixes — not blockers, but worth a follow-up commit.