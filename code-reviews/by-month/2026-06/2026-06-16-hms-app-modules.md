# hms-app Code Review — 2026-06-16

**Scope.** All 15 feature modules under `hms-app/src/app/(dashboard)/` plus the parallel `src/app/api/(...)` route groups. Combined `common` + `shared` + `auth` into a single "platform" review.

**Method.** 15 parallel reviewer agents (`general-purpose`, background, read-only). Each prompt was module-specific (state machines, cross-service touchpoints, domain risks) and constrained to a 5–10 finding ranked report. All 15 ran concurrently; no source files were modified.

**Bottom line.** **7 🚨, 8 ⚠️, 0 ✅.** The single most important finding is that the **transactional outbox required by ADR 0001 does not exist in the HMS code** — the `event_outbox` table that the `hms-summary-service` worker polls is never written, so the CFI auto-creation pipeline is broken at production today. Three further project-wide convention gaps (missing `permissions` on API routes, missing `authorize` on server actions, multi-step writes outside `$transaction`) account for the majority of the remaining P0/P1 risk.

---

## Start here — the 5 most important findings

| # | Where | Severity | Why it matters |
|---|---|---|---|
| 1 | **OPD outbox not implemented** — `hms-app/src/app/(dashboard)/shared/opd/services/opd-billing.service.ts:106-133` | 🔴 P0 | Cross-service pipeline broken. The hms-summary-service worker is polling `event_outbox` for rows the HMS never inserts. No `consultation_fees_invoices` are being auto-created. |
| 2 | **3 ED API routes ship with `auth.required: false`** — `src/app/api/(ed)/ed-bills/route.ts:11`, `appointments-for-ed/route.ts:9`, `patients-for-ed/route.ts:9` | 🔴 P0 | Unauthenticated PII leak: any caller can list patient names, phone numbers, and appointment metadata. |
| 3 | **EMR central API has no per-route authorization** — `src/app/api/(emr)/emr/**` (~10 routes) | 🔴 P0 | Any authenticated user can read any patient's full EMR. No PHI access audit trail. |
| 4 | **Platform: `trpc.auth.getSession` is a public procedure that returns full user + `role.permissions`** — `common/auth/features/auth-service.ts:137-158` + `auth.ts:19` | 🔴 P0 | Password-hash field relies on Prisma `omit` as the last transform; one serializer change leaks the hash. |
| 5 | **Platform: no login throttling + Argon2 timing oracle** — `common/auth/features/auth-service.ts:56-79` | 🔴 P0 | Single Argon2 verify is the only brake; "user not found" vs "bad password" have different timings. Credential stuffing is trivial. |

---

## Module health matrix

| # | Module | Health | Headline risk |
|---|---|---|---|
| 1 | platform (common + shared + auth) | ⚠️ | Public tRPC session, no login throttling, header-driven cookie `secure` |
| 2 | appointment | 🚨 | Slot-booking TOCTOU race; no DB unique index backing it |
| 3 | daycare | 🚨 | `getDayCareList` returns `undefined` — list page is dead |
| 4 | ed | ⚠️ | 3 unauthenticated PII-leaking API routes; soft-delete filter bypassed |
| 5 | emr | ⚠️ | No per-route auth, no PHI read-audit, stored-XSS in clinical notes |
| 6 | ipd | 🚨 | Room-transfer TOCTOU race; `editPatientData` drops the transaction |
| 7 | membership | ⚠️ | `createMemberCardBilling` no `$transaction`; 2 routes skip auth |
| 8 | ot | ⚠️ | **No room/surgeon double-booking check**; no state-machine centralization |
| 9 | pharmacy | 🚨 | Stock read-then-write race; can double-sell, over-return |
| 10 | **opd** | 🚨 | **Outbox not implemented; cross-service pipeline broken** |
| 11 | lab | ⚠️ | No critical-value alerts; result audits silent; no role check on release |
| 12 | cathlab | ⚠️ | Double-billing race; 5 API routes with no role gate; no vitals range check |
| 13 | endo | ⚠️ | `/** TODO: Implement transaction handling */` shipped in billing create; IDOR on report upload |
| 14 | imaging | ⚠️ | IDOR on presigned-URL signing; `inline` flag is dead code (DICOMs download) |
| 15 | hd | ⚠️ | `combineDateWithTime` DST bug; commented-out 404 in OPD-billing path |
| 16 | lab (also covered) | ⚠️ | — |

---

## P0 ship-stoppers — fix before next release

Cross-cutting and per-module, ranked by severity × reach.

### Cross-service

1. **OPD outbox missing entirely** — `opd-billing.service.ts:106-133`. The `$transaction` wrapper is correct; the `CreateOutboxEventStep` simply doesn't exist. `OPDBilling` model has no `EventOutbox` relation. `grep -rn "event_outbox\|Outbox" hms-app/src` returns zero hits. **Fix sketch:** add `model EventOutbox` to `prisma/schema.prisma` (matches `hms-docs/summary-service/data-model/schema.sql`), add a `CreateOutboxEventStep` as the last entry in the `steps` array, executed inside the existing `$transaction`. Apply the canonical DDL from `hms-docs/summary-service/data-model/schema.sql`.
2. **OPDBilling has no `tenantId` column** — `prisma/schema.prisma:1442-1501`. summary-service ADR 0007 mandates defense-in-depth tenant scoping. **Fix:** add `tenantId String @db.Uuid` + index `(tenantId, createdAt DESC)`.

### Security perimeter (Platform)

3. **`trpc.auth.getSession` returns full user including password-hash field** (relies on Prisma `omit` as the only protection). **Fix:** strip at the type level; gate behind `authProcedure`.
4. **No login throttling; `findUnique({ where: { username } })` + `argon2.verify` is a timing oracle** — `auth-service.ts:56-79`. **Fix:** run a dummy `argon2.verify` against a known-bad hash when the user is missing; add `failedLoginAttempts`/`lockedUntil` column; add edge-side rate limit.
5. **Cookie `secure` driven by `x-forwarded-proto` request header** — `trpc.ts:20`. Any proxy misconfig exposes the cookie over HTTP. RSC path always sets `secure: false` (header unreadable). **Fix:** default `secure: true` in production; use `__Host-` prefix; gate logout behind `authProcedure`.
6. **`getSession` loads full permission graph on every tRPC call** — `trpc.ts:18-29` + `verify-auth.ts:15-48`. 5–10 calls per page nav = 5–10 full permission loads. **Fix:** cache `{permissions: Subject[]}` keyed by `user.roleId`; bust on `role.permission` mutation.
7. **`getSessionFromRequest` deletes expired session row but never clears the cookie** — `// await this.clearSessionCookie();` commented out at `auth-service.ts:169`. **Fix:** uncomment the cookie clear.
8. **`AuthService.login` race: TOCTOU between `findFirst` and the `$transaction`** — `auth-service.ts:80-112`. Two parallel logins from two devices both succeed; the "single-session" policy is not enforced. **Fix:** wrap cleanup + delete + create in one `$transaction`; or add UNIQUE partial index on `userId WHERE expiresAt > now()`.
9. **`storeId` typed but never explicitly selected** — `auth-service.ts:141-156`. Silent type/runtime divergence; store-scoped queries fall through to `null` filter. **Fix:** `select: { storeId: true }` explicit; make `storeCheckedProcedure` mandatory for store-scoped routers.

### PII / PHI leaks

10. **ED: 3 API routes with `auth.required: false`** — `api/(ed)/ed-bills/route.ts:11`, `appointments-for-ed/route.ts:9`, `patients-for-ed/route.ts:9`. **Fix:** `auth.required: true` + `permissions: [{ action: "View", subject: "Emergency List" }]`.
11. **ED: soft-delete filter bypassed** — `ed-bill.repository.ts:419, 806` (`getEdBillById`, `getEdBillActivities`). **Fix:** add `isDeleted: false` filter.
12. **ED: detail/activity routes have no permission gate** — `ed-bills/[id]/route.ts:8`, `activities/route.ts:7`. IDOR. **Fix:** add `permissions` + `assertStoreId: true`.
13. **ED: patient list not store-scoped** — `ed-bill.repository.ts:914`. Page already has `session.storeId`; plumb it through.
14. **EMR: ~10 central API routes with no `permissions` array** — `api/(emr)/emr/patient-profile/[id]/route.ts` + 8 siblings. IDOR on full PHI. **Fix:** `permissions: [{ action: "View", subject: "Patient EMR" }]` + tenant/clinic-scope check in service.
15. **EMR: stored-XSS via Tiptap HTML** — `emr-doctor-note-form.tsx:108-118` writes raw Tiptap HTML; `view-imaging-report-content.tsx:121` renders with `dangerouslySetInnerHTML` and no sanitiser. **Fix:** server-side DOMPurify on persist + client-side on render.
16. **EMR: no audit trail for EMR *reads*** — `activityLogger` is only called on writes. PHI access has no traceability. **Fix:** emit `activityLogger.log` after every read.
17. **Imaging: IDOR on presigned-URL signing endpoint** — `api/(common)/uploads/signed-urls/route.ts:10-52`. Any authenticated user can sign 1-hour URLs for any S3 key. **Fix:** require `resourceId` + `resourceType`, look up ownership server-side, derive the key.
18. **Imaging: `uploadCTAttachmentsAction` is hand-rolled `verifyAuth()`-only, not `authActionClient`** — `ct-result.actions.ts:12-56`. No size cap, no MIME allowlist server-side. **Fix:** `authActionClient` + Zod; per-`ctServiceId` S3 prefix; pg-boss cleanup of uncommitted uploads.
19. **Endo: `uploadEndoReportAttachmentsAction` + `changeEndoReportStatusAction` accept raw IDs with no tenant/store guard** — `endo-report.actions.ts:12-43`. **Fix:** `authorizeProcedure("Edit", "ENDO List")` + transition validation in service.
20. **Membership: 2 routes call `new PrismaClient()` directly + bypass `verifyApiAuth()` and `apiHandler`** — `api/(membership)/member-card/usage-count/route.ts:5`, `room-usage-count/route.ts:5`. **Fix:** `enhancedApiHandler({ auth: { required: true, ... })` with tenant/caller gate.
21. **Membership: 2 member-card routes skip `verifyApiAuth()` entirely** — `member-card-list/[id]/route.ts:7-17`, `member-card-type/[id]/route.ts:7-17`. Direct IDOR.
22. **Cathlab: 5 API routes have no `authorizeProcedure` / role gate** — `cathlab/route.ts:6-25`, `[id]/route.ts:5-22`, `audits/route.ts:5-22`, `cathlab-requests/[id]/route.ts:5-22`, `cathlab-infection-screening/route.ts:10-31`, `cath-lab-requests-for-billing/route.ts:11-33`.
23. **HD: server actions have no role/permission gate** — `hd.action.ts:12-37`, `hd-request.actions.ts:12-40`. Page-level `PermissionGuard` is bypassable by direct POST. **Fix:** `authorizeProcedure` middleware.
24. **OT: all routes ship with `auth.required: true` only, no `permissions`** — `ot/list/route.ts:11`, `ot/[id]/route.ts:7`, `ipd-ot-requests/route.ts:6`, etc. IDOR across the entire OT API.
25. **Daycare: all 6 routes + `createDaycareBill` action have no `permissions` array** — `api/(daycare)/*/route.ts` + `daycare/features/daycare.action.ts:12-19`.
26. **OPD: `cancelOPDBillingAction` has `verifyAuth()` commented out** — `opd-billing.actions.ts:74`. A logged-out caller can cancel a bill. **Fix:** uncomment + convert to `authActionClient`.

### Broken functionality

27. **Daycare: `getDayCareList` returns `undefined`** — `repositories/daycare.repository.ts:284-333`. The whole `/daycare` list page is dead. **Fix:** add `return await this.prisma.proxyBill.findMany({ where: whereClause, ... })` + `count`.
28. **Imaging: `inline` flag in S3 is dead code** — `s3.service.ts:209-212`, `if (inline) {}` is empty; `ResponseContentDisposition: 'inline'` is never set. DICOMs/PDFs download instead of preview. **Fix:** implement the if-branch.

### Money / billing integrity

29. **OPD money fields are `Int` (cents) but no cents-only helper** — `schema.prisma:1451-1462`. `* 100` / `/ 100` mismatch silently loses money. **Fix:** enforce cents-only math helper; Prisma middleware rejecting `Float` on these columns; unit test the rounding path.
30. **OPD: date-range filter uses wrong column** — `opd-billing.repository.ts:1475-1479` filters on `createdAt` but the UI shows `OPDBilling.date` (`:1455`). Wrong rows returned.
31. **Membership: `createMemberCardBilling` no `$transaction`** — `member-card-billing.repository.ts:64-129`. Three separate Prisma calls. Crash mid-way → paid invoice but no enrollment row.
32. **Membership: `validTo` computed from `new Date()` not `validFrom`** — `member-card-billing.repository.ts:111-115`. Validity window can drift.
33. **Membership: invoice number sequence can collide** with OPD billing (`OPD-MM-YY-000001` may be issued twice) — `member-card-billing.service.ts:27`. **Fix:** DB sequence or `@@unique` on date prefix, or separate `MCARD-` prefix.
34. **Pharmacy: stock read-then-write race** — `stock.repository.ts:586-612`. `findUnique` → in-memory check → `update({ decrement })`. With 2+ dispensaries on the same batch, both decrement from `qty=5` to `4/4`. **Fix:** `UPDATE stocks SET qty = qty - $n WHERE id = $id AND qty >= $n RETURNING qty` or `SELECT ... FOR UPDATE` before decrement.
35. **Pharmacy: GRN-return approval races** — `grn-returns.service.ts:107-164`. Same pattern.

### Concurrency

36. **Appointment: slot-booking TOCTOU** — `appointment.service.ts:362-371` + `appointment.repository.ts:782-812`. Two concurrent requests for the same `(doctorId, start, appointmentDate)` both pass the availability check, both insert. **Fix:** wrap in `$transaction` at SERIALIZABLE; partial unique index on `(doctor_id, start, appointment_date) WHERE status != 'CANCELLED'`.
37. **IPD: room-transfer TOCTOU** — `room-transfer.service.ts:52-101`. Three non-atomic steps. **Fix:** wrap in `$transaction` + `updateMany({ where: { id, roomStatus: fromStatus } })`, or add `Room.version`.
38. **IPD: `editPatientData` drops the transaction** — `admission.service.ts:260`. **Fix:** pass `tx`.
39. **IPD: `DischargeService.updateDischargeWardClearanceStatus` writes outside `$transaction`** — `discharge.service.ts:692-696`. Double deposit deduction race. **Fix:** wrap in `$transaction`.
40. **Cathlab: no uniqueness check on `cathLabRequestId`** in `createCathLab` — `cathlab.service.ts:122-249`. Two cardiologists can both create a bill. **Fix:** in-tx `findFirst({ cathLabRequestId, isDeleted: false })` or `SELECT ... FOR UPDATE`.
41. **Endo: `createEndoProxyBill` ships with `/** TODO: Implement transaction handling */`** — `endo.service.ts:60, 176`. Three separate Prisma calls. **Fix:** wrap in `prisma.$transaction`.
42. **OT: no room/surgeon double-booking check** — `ipd-ot-request.service.ts:50-112`. The headline risk for an OT module.

### State machines

43. **Lab: critical-value / panic-range alerts absent** — `lab-result-entry.repository.ts:919-940`, `lab-result-verification.repository.ts:881-900`. Numeric result not compared against reference ranges. Life-safety risk. **Fix:** add `flag` column; emit notification; persist reference + critical thresholds.
44. **Lab: state machine unenforced** — `lab-result-entry.repository.ts:893-901` blindly sets `ENTERED` regardless of prior state. A result can be "entered" before the sample is collected. **Fix:** precondition `findFirst` with expected prior status.
45. **Lab: audit trail is write-once append; result amendments are silent** — `lab-result-entry.repository.ts:902-910`. Regulatory gap. **Fix:** add `previousResult`, `amendedById`, `amendedAt`; write audit row on every overwrite.
46. **OT: state machine is split between schema and service, drifting** — `create-ipd-ot-request.schema.ts:124-131` accepts 6 values; runtime supports 4. `BOOKED`/`CONFIRMED` get stored as free-form strings. **Fix:** single state-machine map; add optimistic-lock `version`.
47. **EMR: no optimistic lock on note updates** — `opd-emr.service.ts:451-483`. Silent overwrites on concurrent edits. **Fix:** add `version`; `If-Match` header; CFI-style guard.
48. **HD: `updateHDProxyBill` allows editing a PAID bill (guard commented out)** — `hd.service.ts:198-203`.
49. **HD: `createHDRequest` deletes an existing HD request without re-validating ownership/status** — `hd-request.service.ts:88-93`. Silently destroys other users' requests.

### Clinical data safety

50. **Lab: numeric coercion + reference-range validation only client-side** — server writes whatever string the client posts. **Fix:** Zod `z.coerce.number().refine(...)` at action boundary.
51. **Cathlab: vitals accepted as 0 / NaN / 9999** — `base-cathlab-form.schema.ts` uses `nonnegative` + `min(1)` only. No clinical bounds. **Fix:** Zod refinements per field.
52. **Endo: drugAllergy, sedation (no dose validation), procedure time-slot — all unvalidated** — `create-endo-request.schema.ts:47` and missing entirely.
53. **HD: `combineDateWithTime` constructs wall-clock time in server-local zone, not `getTimezone()`** — `hd-request.repository.ts:212-237`. DST misalignment of ±1h. **Fix:** `datePart.hour(h).minute(m).tz(timezone).toDate()`; store as `timestamptz`.
54. **Imaging: state machine missing `IN_PROGRESS` / `REPORTED` / `DRAFT`** — `imaging.helper.ts:9-30`. **Fix:** Prisma enum change (mirror in summary-service subset if relevant).

### Logging / PII in logs

55. **Lab: `console.log` left in 7 production files** with PHI in cleartext — `lab-result-entry.action.ts:12-14`, `lab-result-entry/[id]/enter-results/page.tsx:116,121`, `lab-report/[id]/page.tsx:185,209`, etc. **Fix:** delete.
56. **Imaging: `console.log("⚠️")` in production hot path** — `imaging.repository.ts:1707`.
57. **Cathlab: `console.log` in API route leaks the id** — `cathlab/get-by-request-id/[cathLabRequestId]/route.ts:18`.
58. **HD: `console.log("Here", services)` left in production** — `hd.repository.ts:601`.
59. **OT: not flagged directly, but pattern present in `ot-form.tsx`.** Sweep all `*.tsx` + `*.action.ts` for `console.log`.
60. **EMR: PHI fields in `winstonLogger` payload** — `patient-emr.service.ts:239-241`, `opd-emr.service.ts:99-152`. PII ends up in Sentry. **Fix:** split — audit events to `activityLogger`; diagnostic events to `winstonLogger` with structured fields and no note text.

---

## Cross-cutting patterns (project-wide)

These three issues account for the majority of P0/P1 risk across the codebase. **Each is one mechanical sweep, but the permission matrix and the lock pattern need to be designed first.**

### Pattern 1 — Missing authorization layer

Modules confirmed: ED, Daycare, OT, EMR, IPD, Cathlab, Endo, Imaging, Membership, Platform, HD, Cathlab, OPD.

- **API routes:** `enhancedApiHandler({ auth: { required: true } })` with **no `permissions` array**. The `api-handler.ts:139-164` shape supports `permissions: [{ action, subject }]` but the array is consistently empty.
- **Server actions:** `authActionClient.schema(...).action(...)` with **no `.use(authorize(...))` step**. The auth wrapper provides session only; the role check lives only in the client (`checkPermission` in forms).
- **tRPC procedures:** `publicProcedure` is used where `protectedProcedure` or `roleCheckedProcedure` should be.

**Fix:** introduce a single role-checking helper (e.g. `requireRole(action, subject)`) and a single permission matrix. Mechanical sweep across `app/api/**`, `*.action.ts`, and tRPC routers. The auth reviewer's note: a single `Role.hasPermission` middleware is the safest place because it centralises the policy.

### Pattern 2 — Multi-step writes outside `$transaction`

Modules confirmed: Cathlab, Endo, OT, Daycare, IPD, Pharmacy, Appointment, HD, Membership, OPD.

- `super.createProxyBill` → `createProxyBillRequestLink` → `markRequestAsBilled` patterns.
- "Clean up inactive + delete existing + create" sequences (login).
- "Read availability + insert" sequences (appointment, room transfer).
- Stock read-then-write (no `SELECT ... FOR UPDATE`).

**Fix:**
- For invariant-preserving single-row updates: `updateMany({ where: { id, version: expected } })` or `@@unique` partial index.
- For multi-row arithmetic: `UPDATE stocks SET qty = qty - $n WHERE id = $id AND qty >= $n RETURNING qty` (Pharmacy).
- For multi-entity writes: wrap in `prisma.$transaction([...])` or interactive `tx`.
- For scheduler conflicts: `SELECT ... FOR UPDATE` on the resource row before insert.

### Pattern 3 — Logging in production code (PHI risk)

Modules confirmed: Lab, Imaging, Cathlab, HD, OT (likely), EMR.

- `console.log` left in production hot paths.
- `winstonLogger` payload carries PHI fields.
- A pre-commit hook + ESLint rule banning `console.log` in `src/app/**` and `src/lib/**` would be a one-line defence.

---

## Per-module findings (compact, top 5 each)

> Numbers below correspond to the 15 reviewer reports. File paths are absolute under `hms-app/`.

### 1. Platform (common + shared + auth) — ⚠️

- **F1** [P0] `trpc.auth.getSession` public + returns full user — `common/auth/features/auth-service.ts:137-158`
- **F2** [P0] No login throttling + Argon2 timing oracle — `auth-service.ts:56-79`
- **F3** [P0] Cookie `secure` driven by `x-forwarded-proto` — `lib/trpc/trpc.ts:20`
- **F4** [P0] Full permission graph loaded on every tRPC call — `lib/trpc/trpc.ts:18-29`, `common/auth/features/utils/verify-auth.ts:15-48`
- **F5** [P0] `getSessionFromRequest` deletes row on expiry but never clears cookie — `auth-service.ts:169` (commented out)
- **F6** [P1] `storeId` typed but never explicitly selected — `auth-service.ts:141-156`
- **F7** [P1] `AuthService.login` race — `auth-service.ts:80-112`
- **F8** [P1] `Math.random()` for default doctor passwords — `common/doctors/features/doctors.service.ts:23,27`
- **F9** [P2] `safe-action.ts` always logs full stack on 4xx — `lib/safe-action.ts:9-21`
- **F10** [P2] `enhancedApiHandler` has no body-size cap — `utils/api-handler.ts:177-184`
- **F11** [P2] `auth-service.spec.ts` is `expect(true).toBe(true)` — empty test file
- **F12** [P2] `pg-boss.ts` reads `process.env.DATABASE_URL!` with no Zod validation
- **F13** [P2] `clearSessionCookie` missing `secure` flag — `auth-service.ts:24-32`
- **F14** [P3] Dead `verify-password.ts` re-export; `tokens.ts` misnamed (colors, not tokens)
- **F15** [P3] No env validation across the app (no `src/lib/env.ts`)

### 2. Appointment — 🚨

- **F1** [P0] Slot-booking TOCTOU race — `shared/appointment/services/appointment.service.ts:362-371`
- **F2** [P0] No DB unique index backing F1 — `prisma/schema.prisma:2139-2177`
- **F3** [P1] `/appointments/[id]` lacks auth + validation — `api/(appointment)/appointments/[id]/route.ts:1-18`
- **F4** [P1] `editAppointmentSchema` reaches into Zod internals (`._def.schema`) — `shared/appointment/schemas/appointment/edit-appointment-schema.ts:4`
- **F5** [P1] `isDoctorAvailable` skipped in `editAppointment` when `timeslotId` unchanged — `appointment.service.ts:178-183` (doesn't compare `appointmentDate` / `doctorId`)
- **F6** [P2] `console.log` in form error handler — `appointment/doctor-time-slot/features/components/doctor-time-slot-form.tsx:138`
- **F7** [P2] Referral cross-table lookup runs outside transaction
- **F8** [P2] `existingAppointment` validation in `updateAppointmentStatus` reads outside tx
- **F9** [P2] N+1 / over-fetch in list endpoint; missing `(appointmentDate, doctorId)` composite index
- **F10** [P2] `flattenDoctorSpecialization` uses `as unknown as Appointment`

### 3. Daycare — 🚨

- **F1** [P0] `getDayCareList` builds whereClause but never queries — `repositories/daycare.repository.ts:284-333` (returns `undefined`; UI throws on `.length`)
- **F2** [P0] `paymentStatus` filter silently dropped (empty `if` body) — `:325-329`
- **F3** [P0] Silent error swallowing masks errors as "no data" — `:330-333`
- **F4** [P1] All 6 daycare API routes + `createDaycareBill` action have no `permissions` array
- **F5** [P1] N+1 on confirmed-patients list
- **F6** [P1] Admit/discharge state machine doesn't exist at data layer
- **F7** [P2] `Promise.all` over already-awaited values
- **F8** [P2] Validator inconsistency (duplicate `getAppointmentForDaycareSchema`)
- **F9** [P2] `appointmentId` not UUID-validated on create
- **F10** [P2] Stray `appointment-select.bak.tsx` in components

### 4. ED — ⚠️

- **F1** [P0] 3 API routes ship with `auth.required: false` (PII leak) — `api/(ed)/ed-bills/route.ts:11`, `appointments-for-ed/route.ts:9`, `patients-for-ed/route.ts:9`
- **F2** [P0] Soft-delete filter bypassed on `getEdBillById` + `getEdBillActivities` — `ed-bill.repository.ts:419, 806`
- **F3** [P1] Detail/activity routes have no permission gate — `ed-bills/[id]/route.ts:8`, `activities/route.ts:7`
- **F4** [P1] Patient list not store-scoped — `ed-bill.repository.ts:914`
- **F5** [P1] Delete path is broken — `ed-bill.service.ts:175-214`; `prisma.transaction` (no `await`); orphan FKs
- **F6** [P2] N+1 in stock validation; heavy `edBillValidator` include
- **F7** [P2] `getAppointmentForEd` returns `transformKeysToCamel` (inconsistent)
- **F8** [P2] Pharmacy-sale update silently keeps prior items (no reversal)

### 5. EMR — ⚠️

- **F1** [P0] No per-route authorization on central EMR API (~10 routes) — `api/(emr)/emr/**`
- **F2** [P0] Stored-XSS via Tiptap HTML — `emr-doctor-note-form.tsx:108-118`; `view-imaging-report-content.tsx:121` (raw `dangerouslySetInnerHTML`)
- **F3** [P0] No audit trail for EMR reads — PHI access has no traceability
- **F4** [P1] No patientId-vs-session scoping in central service
- **F5** [P1] Note body rendered as raw HTML in detail/list views
- **F6** [P1] PII/PHI fields in `winstonLogger` payload
- **F7** [P2] N+1 in `patient-emr.service.ts:362-370`; pagination in app after fetching every record
- **F8** [P2] No optimistic-lock on doctor/nurse note updates
- **F9** [P2] Dead try/catch wrappers everywhere (`opd-emr.service.ts:386-388, 446-448, ...`)
- **F10** [P3] `api-handler.ts:1` blanket `eslint-disable @typescript-eslint/no-explicit-any`

### 6. IPD — 🚨

- **F1** [P0] `RoomTransferService.createRoomTransfer` TOCTOU race — `room-transfer.service.ts:52-101`
- **F2** [P0] `editPatientData` drops the transaction — `admission.service.ts:260`
- **F3** [P0] All IPD routes have no `permissions` array
- **F4** [P1] `DischargeService.updateDischargeWardClearanceStatus` writes outside `$transaction` — `discharge.service.ts:692-696`
- **F5** [P1] `RoomLogService.updateRoomLog` creates two RoomCharge rows on the same room — `room-log.service.ts:229-244`
- **F6** [P1] `completeDischarge` is large and partially outside the discharge tx — `discharge.service.ts:54-336`
- **F7** [P1] `getIpdList` builds giant OR of `(admissionId, occupiedAt)` pairs — `room-log-reposity.ts:198-228`
- **F8** [P2] `handleRoomAllocation` has no read of current `room.roomStatus` (admit-time race)
- **F9** [P2] `select-room-modal.tsx` makes N+1 calls; deep include on bed board
- **F10** [P2] `api-handler.ts:36-46` swallows all errors as 500
- **F11** [P2] `newBornBaby.service.ts:27-47` — no `motherId` uniqueness check
- **F12** [P3] Logging raw `payload` to winston; dead try/catch wrappers
- **F13** [P3] `room-transfer.service.ts:59` throws raw `new Error(...)`; bypasses AppError
- **F14** [P3] No composite index on `Room(wardId, roomNumber)` or `RoomLog(admissionId, roomStatus, isActive)`

### 7. Membership — ⚠️

- **F1** [P0] 2 routes call `new PrismaClient()` + bypass `verifyApiAuth()` and `apiHandler` — `api/(membership)/member-card/usage-count/route.ts:5`, `room-usage-count/route.ts:5`
- **F2** [P0] `createMemberCardBilling` no `$transaction` — `member-card-billing.repository.ts:64-129`
- **F3** [P0] 2 member-card routes skip `verifyApiAuth()` entirely — `member-card-list/[id]/route.ts:7-17`, `member-card-type/[id]/route.ts:7-17`
- **F4** [P1] `validTo` computed from `new Date()` not `validFrom` — `member-card-billing.repository.ts:111-115`
- **F5** [P1] Money paths use `Int` columns with `Math.round` (no `Decimal`); admin can enter overflow values
- **F6** [P1] Missing indexes on `MemberList.createdAt`, `MemberCard.memberCardTypeId`
- **F7** [P2] `createMemberCardType` `editMemberCardType` issues single Prisma `update` (not `$transaction`)
- **F8** [P2] `as unknown as MemberCard` casts (and other type-erasure smells)
- **F9** [P2] Invoice number sequence can collide with OPD billing
- **F10** [P3] `member-card-by-patient` route has no `authorize` predicate (exposes patient card to any logged-in user)

### 8. OT — ⚠️

- **F1** [P0] No room/surgeon double-booking check — `ipd-ot-request.service.ts:50-112`
- **F2** [P0] All routes have no `permissions` array; safe-actions have no `authorize` middleware
- **F3** [P0] State machine is split between schema and service, drifting — `create-ipd-ot-request.schema.ts:124-131`
- **F4** [P1] Multi-step writes outside `$transaction` — `ot.service.ts:58-81`; `ot-bill.service.ts:133-196`
- **F5** [P1] N+1 in `getOTRequests`; missing composite indexes `(roomId, operationDate)` + `(operationDate, status)`
- **F6** [P1] Infection-screening: stale snapshot, no PII guard, race — `ipd-ot-request.repository.ts:549-581`
- **F7** [P2] `fieldIsDisabled = otBillId ? true : false` too coarse — `ot-form.tsx:451-453`
- **F8** [P2] Schema drift between `OTRequest` Prisma model and Zod enum
- **F9** [P2] Proxy-bill update and EMR-link paths can desync
- **F10** [P2] `void createdById` silences intent in `ipd-ot-request.service.ts:129`

### 9. Pharmacy — 🚨

- **F1** [P0] Stock read-then-write race in dispense/adjustment/return — `shared/pharmacy/repositories/stock.repository.ts:586-612`
- **F2** [P0] GRN-return approval races too — `grn-returns.service.ts:107-164`
- **F3** [P1] Stock-adjustment approval read outside tx — `stock-adjustment.service.ts:88-96`
- **F4** [P1] CSV importer aborts on first bad row — `utils/parse-and-validate-csv.ts:35-49`
- **F5** [P1] Stock-list N+1 + missing composite index `(storeId, itemId, qty)`
- **F6** [P2] `prisma.$queryRaw` for stock list, not tenant-scoped
- **F7** [P2] `validateSameExpiry` checks against stock read pre-tx
- **F8** [P2] Sale-update re-deduct runs in a single `for…of` over `$transaction` callback
- **F9** [P3] `validateStockQtyForInventoryUpdate` is called in service but not in repo (consistency)
- **F10** [P3] `compareGrnItemToStock` re-implements uniqueness (drift risk)

### 10. OPD — 🚨

- **F1** [P0] **Outbox not implemented — pipeline-killer** — `opd-billing.service.ts:106-133` (no `CreateOutboxEventStep`; `OPDBilling` has no `EventOutbox` relation; zero hits for `event_outbox` in `hms-app/src`)
- **F2** [P0] `OPDBilling` has no `tenantId` column — `prisma/schema.prisma:1442-1501`
- **F3** [P1] `cancelOPDBillingAction` has `verifyAuth()` commented out — `opd-billing.actions.ts:74`
- **F4** [P1] `cancelOPDBillingAction` not using `authActionClient` (sibling actions do)
- **F5** [P1] `findAndCount` `where.patientType` is `// @ts-expect-error` + wrong date column — `opd-billing.repository.ts:1475-1479`
- **F6** [P1] Money fields as `Int` but no cents-only helper — `schema.prisma:1451-1462`
- **F7** [P2] N+1 risk in `getById` — `opd-billing.service.ts:139-172` (6 sequential awaits)
- **F8** [P2] `backFilledPharmacyItemsInCreditState` silently overwrites pharmacy items — `:230-251`
- **F9** [P2] `createOpdBillingAction` swallows `handleActionError` but doesn't log input payload
- **F10** [P3] Dead copy-paste: `cathlab-request-list`, `endo-request-list`, `hd-request-list`, `ot-request-list` in `opd-billing/`

### 11. Lab — ⚠️

- **F1** [P0] Critical-value / panic-range alerts absent — `shared/lab/repositories/lab-result-entry.repository.ts:919-940`
- **F2** [P0] No role check on result entry/verification/release — `api/(lab)/lab-result-entry/route.ts:7-9`, `lab-result-verification/[id]/route.ts:6-8`
- **F3** [P0] Audit trail is write-once append; result amendments silent — `lab-result-entry.repository.ts:902-910`
- **F4** [P1] State machine unenforced — `lab-result-entry.repository.ts:893-901`
- **F5** [P1] Swallowed errors on result entry — `:943-949`
- **F6** [P1] Numeric coercion + reference-range validation only client-side — `lab-service-item-result-entry-status-form.tsx:502, 617`
- **F7** [P1] `console.log` left in 7 production files (PHI in cleartext)
- **F8** [P2] Inconsistent safe-action pattern (`lab-sample-collection.action.ts:8-30` is hand-rolled)
- **F9** [P2] N+1 in microbiology verify
- **F10** [P2] Inconsistent create vs. update audit log target

### 12. Cathlab — ⚠️

- **F1** [P0] `createCathLab` race: no uniqueness check on `cathLabRequestId` — `cathlab.service.ts:122-249`
- **F2** [P0] State-machine bypass via direct Prisma update (status drift) — `:208-215`
- **F3** [P0] Side-effect calls outside create transaction (deposit helper not in $tx) — `:224-237`
- **F4** [P0] `deleteCathLab` doesn't soft-delete pharmacy/catheter sale FKs — `:523-634`
- **F5** [P1] 5 API routes have no `authorizeProcedure` / role gate
- **F6** [P1] Vitals accepted as 0 / NaN / 9999 — `base-cathlab-form.schema.ts`
- **F7** [P1] N+1 + unbounded payload on detail read — `cathlab.repository.ts:386-428`
- **F8** [P1] `console.log` in API route leaks the id — `cathlab/get-by-request-id/[cathLabRequestId]/route.ts:18`
- **F9** [P2] Large commented-out dead code blocks
- **F10** [P2] `deleteCathLab` writes via unscoped `prisma.iPDDailyBill` (pattern drift)

### 13. Endo — ⚠️

- **F1** [P0] `createEndoProxyBill` + `deleteEndoProxyBill` ship with `/** TODO: Implement transaction handling */` — `endo.service.ts:60, 176`
- **F2** [P0] IDOR + missing role check on report upload (status change / S3 upload) — `endo-report.actions.ts:12-43`, `endo-report.service.ts:33-53`
- **F3** [P0] No procedure/sedation state machine or time-slot conflict check
- **F4** [P1] S3 upload trusts client MIME type and filename — `endo-report.actions.ts:22-33`
- **F5** [P1] Heavy `endoReportValidator` over-include on every read — `endo-report.repository.ts:9-90`
- **F6** [P1] S3 PDF signed-URLs fetched as comma-joined string (split misroutes on commas in keys) — `fetch-uploaded-signed-urls.ts:6-9`
- **F7** [P2] Report validator throws raw `Error`, not `AppError` — `endo-report.repository.ts:113, 246`
- **F8** [P2] `EndoReportStatusCell` client-side only guard for DELIVERED
- **F9** [P2] Form `useEffect` dep list omits `setValue` watcher inputs — `endo-form.tsx:250-277`
- **F10** [P3] Dead `EndoTeamFeesSection` commented out in 2 places

### 14. Imaging — ⚠️

- **F1** [P0] IDOR on presigned-URL signing endpoint — `api/(common)/uploads/signed-urls/route.ts:10-52`
- **F2** [P0] `uploadCTAttachmentsAction` is hand-rolled `verifyAuth()`-only, not `authActionClient` — `imaging/ct/result/features/ct-result.actions.ts:12-56`
- **F3** [P0] `inline` flag in S3 is dead code (DICOMs/PDFs download instead of preview) — `common/aws/s3.service.ts:209-212`
- **F4** [P1] No `authorize()` calls anywhere in the imaging module (6 modalities)
- **F5** [P1] `console.log("⚠️")` in production hot path — `shared/imaging/repositories/imaging.repository.ts:1707`
- **F6** [P1] Status state machine missing `IN_PROGRESS` / `REPORTED` / `DRAFT` — `shared/imaging/imaging.helper.ts:9-30`
- **F7** [P2] 3 separate `findUnique` round-trips for IPD guard checks — `shared/imaging/services/ct.service.ts:374, 408, 416`
- **F8** [P2] `getCTListActivities` refetches whole CT detail to enumerate child ids
- **F9** [P2] Param naming confusion (`opdBillingId` is actually `serviceBillId`)
- **F10** [P3] Hardcoded `AWS_*` env reads at module load (no validated config)

### 15. HD — ⚠️

- **F1** [P0] `createHDRequest` deletes an existing HD request without re-validating ownership/status — `hd-request.service.ts:88-93`
- **F2** [P0] `resolveHDRequestForOPDProxyBill` returns `null` and billing proceeds without an HD request (404 throw commented out) — `hd.service.ts:130-149`
- **F3** [P0] `combineDateWithTime` constructs wall-clock time in server-local zone (DST bug) — `hd-request.repository.ts:212-237`
- **F4** [P1] Server actions have no role/permission gate — `hd.action.ts:12-37`, `hd-request.actions.ts:12-40`
- **F5** [P1] No audit trail for HD vitals edits — `hd-ipd-emr-vital-sign.actions.ts:24-33`
- **F6** [P1] `updateHDProxyBill` allows editing a PAID bill (guard commented out) — `hd.service.ts:198-203`
- **F7** [P1] `getHdAppointments` ignores the "modality" filter (TODO in `hd.repository.ts:467`)
- **F8** [P2] N+1 in referrals join for HD appointment list
- **F9** [P2] Date filter on `hdDate` does not use the timezone
- **F10** [P2] `console.log("Here", services)` left in production — `hd.repository.ts:601`

---

## Suggested PR sequence

Order matters: each PR should leave the tree green. Estimated effort ranges are for an experienced engineer familiar with the codebase.

### Block A — P0 ship-stoppers (do these first; estimated 5–8 days total)

1. **PR-A1: OPD outbox** (3–4 days). Add `model EventOutbox` to `prisma/schema.prisma`; add `CreateOutboxEventStep` to `opd-billing.service.ts:110`; apply canonical DDL from `hms-docs/summary-service/data-model/schema.sql`; add `tenantId` to `OPDBilling`; add `@@index([tenantId, createdAt DESC])`. **Validates Phase 3 of the hms-summary-service end-to-end runtime.**
2. **PR-A2: Authentication sweep (platform)** (2–3 days). Login throttling + constant-time verify; `secure: true` in production; permission cache; cookie clear on expiry; `storeCheckedProcedure`. Single auth PR, ripples to all 15 modules.
3. **PR-A3: Unauthenticated PII leaks** (½ day). ED routes (`auth.required: true` + `permissions`); Membership routes that bypass `verifyApiAuth`; OPD `cancelOPDBillingAction` uncommented `verifyAuth`.
4. **PR-A4: Permission/authorize matrix (first sweep)** (2–3 days). Add `permissions: [...]` to every `enhancedApiHandler` and `authorize(...)` to every `authActionClient`. Requires a permission matrix to be filled in first.
5. **PR-A5: Dead-list-page fix** (½ day). Daycare `getDayCareList` returning `undefined`; paymentStatus filter; error swallowing.
6. **PR-A6: Imaging S3** (½ day). Implement the `inline` if-branch; rewrite presigned-URL signing to require `resourceId` + `resourceType`; convert `uploadCTAttachmentsAction` to `authActionClient` with Zod.
7. **PR-A7: EMR auth + XSS + audit** (1–2 days). `permissions` on every EMR route; DOMPurify on Tiptap input and rendering; `activityLogger` on reads.

### Block B — Concurrency & data integrity (estimated 4–6 days)

8. **PR-B1: Stock dispense atomicity** (1 day). Replace read-then-write with `UPDATE … WHERE qty >= n` (or `SELECT … FOR UPDATE`). Apply to GRN-return + stock-adjustment paths.
9. **PR-B2: Appointment slot booking** (½ day). SERIALIZABLE `$transaction` + partial unique index.
10. **PR-B3: IPD room transfer + discharge** (1–2 days). Add `Room.version` + `updateMany({ where: { id, roomStatus } })`; wrap discharges in `$transaction`.
11. **PR-B4: OT double-booking check** (1 day). Add room/surgeon overlap check in `createIPDOTRequest`; add composite indexes.
12. **PR-B5: Cathlab / Endo / Membership billing transactions** (1 day). Wrap multi-step proxy-bill flows in `$transaction`.
13. **PR-B6: State machines** (1–2 days). Lab critical-value alerts + state guards; OT state machine map; EMR optimistic lock on notes.

### Block C — Code hygiene (estimated 3–4 days)

14. **PR-C1: No more `console.log` in production** (½ day). Sweep + ESLint rule banning `console.*` under `src/app/**` and `src/lib/**`.
15. **PR-C2: API-handler hygiene** (1 day). Body-size cap; Prisma error mapping (`P2002 → 409`, `P2025 → 404`); no-op try/catch removal.
16. **PR-C3: Composite indexes** (1 day). Add the missing `(storeId, itemId, qty)`, `(appointmentDate, doctorId)`, `(wardId, roomNumber)`, `(roomId, operationDate)`, `(tenantId, createdAt)`, etc.
17. **PR-C4: N+1 in list endpoints** (1–2 days). Trim `include` to `select` for list pages; split list vs. detail validators.

### Block D — Process (longer-term)

- Stand up auth integration tests (login races, constant-time error, cookie clear, heartbeat for unknown sid).
- Stand up lab integration tests (critical-value alerts, state-machine guards, audit amendment trail).
- Pre-commit hook + CI check: no `console.log` in `src/**`; no API route ships without `permissions: [...]`.
- Define and ship the permission matrix as a single typed module; centralise role-based logic in one helper.

---

## Notes for the HMS team

- **The OPD outbox is the single most important finding.** Until it's shipped, the hms-summary-service's CFI pipeline cannot be validated end-to-end at runtime. Consider this a release blocker.
- **The auth surface is the second-most-important cluster.** Six P0 findings on the auth perimeter ripple to every other module. A single PR can close them.
- **The 3 cross-cutting patterns (missing permissions, missing $transaction, console.log) account for the majority of the P0/P1 risk.** Each is one mechanical sweep once the design is in place.
- **The permission matrix is the gating item for the auth sweep.** It needs a product owner to enumerate `(action, subject)` pairs before the engineering PR can land. Recommend a 1-hour meeting to fill it in.
- **No `tRPC.auth.getSession` is genuinely public — it's labelled `publicProcedure`** for the auth-flow UI but the implementation is indistinguishable from a `protectedProcedure`. Tighten the procedure type, not just the call sites.
