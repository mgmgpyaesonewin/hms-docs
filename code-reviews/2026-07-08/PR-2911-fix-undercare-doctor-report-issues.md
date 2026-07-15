# Code Review: PR #2911 — fix: undercare doctor report issues
**Repository:** MyanCare/Ycare-HMS
**Author:** @Xkill119966
**Branch:** `fix/undercare-doctor-report-issues` → `development`
**Files changed:** 6 (+103 / -7)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-08
**ClickUp:** https://app.clickup.com/t/9018849685/86ey3vrf5

## Summary
Adds doctor specialization to the info card and join, adds a `Status` column + filter + `discharge_date_time` column to the under-care doctor admissions table, and bootstraps `?start`/`?end` to the current month when the URL has no dates. Also removes `AND adm.status = 'ACTIVE'` from the admissions CTE (now joins all admissions and adds `LEFT JOIN discharges dch`).

## Verdict
**Request changes**
Score: 53/100
Critical: 0 | High: 3 | Medium: 4 | Low: 1 | Nit: 0

## Issues

### Critical
None

### High
- **`router.replace` runs during render.** `src/app/(dashboard)/common/reports/under-care-doctor/page.tsx` lines 17–33 calls `router.replace(...)` in the function body of a client component. This is the wrong place for a side effect — it should be in a `useEffect(..., [])`. Calling it during render ties the side effect to render order, can fire twice across re-renders, and runs on the server under `DEFAULT_TIMEZONE` while the client runs under the user TZ. **Fix:** move into `useEffect`, or (better) bake the default into the zod schema with `.default(dayjs().startOf("month").toDate())` and delete the redirect entirely.
- **Browser-tz shift between server and client render causes hydration mismatch.** `dayjs().tz(DEFAULT_TIMEZONE).startOf("month").toISOString()` always emits UTC, so the first render after redirect still has no `start`/`end` in `searchParams`. The hook then fires `useSuspenseQuery` with no date filter before being cancelled, returning *all-time* data on the first paint. **Fix:** default the field inside `underCareDoctorReportQuerySchema.parse(...)` so the hook always reads `start`/`end`.
- **Removing `adm.status = 'ACTIVE'` from the CTE silently changes default semantics, and `total_patients` no longer agrees with the per-doctor admissions list.** `total_patients` (CTE around line 60) is still pinned to `adm.status = 'ACTIVE'`, while the admissions CTE now joins all admissions. A doctor with 3 active + 9 historical admissions now shows `totalPatients: 3` but 12 rows. The PR title says "fix doctor report issues" — this behaviour change is not in the title and is not explained in any commit or comment. **Fix:** either (a) drop the ACTIVE filter from `total_patients` so both queries agree, or (b) keep the ACTIVE filter and gate DISCHARGED behind an opt-in toggle. Confirm with the ticket owner before shipping.

### Medium
- **Status cell encodes colour in chained ternaries.** `under-care-doctor-admissions-columns.tsx` lines 86–101 use `status === "ACTIVE" ? "..." : status === "DISCHARGED" ? "..." : "text-yellow-600"`. Replace with a small `STATUS_STYLE` lookup map (`as const satisfies Record<string, string>`) and either restrict the type (`z.enum(["ACTIVE","DISCHARGED"])`) or throw on unknown so a new enum value surfaces in dev instead of silently turning yellow.
- **`statusOptions` hard-codes only two enum values.** `under-care-doctor-admissions-table.tsx` lines 123–126 inlines the filter list, and `columns.tsx` mirrors it. Three places (cell, filter, service cast) must stay in sync. Derive from a single shared enum source or add a TODO.
- **`DISTINCT ON (adm.id)` ordering deserves a comment.** `ORDER BY adm.id, adm.created_at DESC` picks the latest room log row per admission. With the new `LEFT JOIN discharges`, the choice is still legitimate, but a one-liner `# picks latest room log row per admission` prevents the next reader from "simplifying" it.
- **`Dot` icon imported for one status indicator.** If a `Badge variant="dot"` is already used nearby, prefer it for zero icon imports. Otherwise fine.

### Low / Nit
- **`searchParams.toString()` called twice with mutation.** `page.tsx` line 26 — minor; fine.

## Recommendation
Address the three High items before merge:
1. Move the date-default redirect into `useEffect` *or* (preferred) into the zod schema via `.default(...)` and delete the redirect.
2. Resolve the server/client hydration ambiguity by sourcing defaults from the schema, not from a render-time `router.replace`.
3. Decide and document whether the admissions CTE is now "all-time" by design; if so, fix `total_patients` to match. If not, restore the ACTIVE filter and surface DISCHARGED behind a toggle.

Medium items (status enum sync, color-map extraction, `DISTINCT ON` comment) can be follow-ups.