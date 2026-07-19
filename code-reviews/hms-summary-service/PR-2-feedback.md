# PR #2 Feedback — `refactor: fix for PR review`

| Field | Value |
| --- | --- |
| Repo | MyanCare/YCare-HMS-Summary-Service |
| PR | https://github.com/MyanCare/YCare-HMS-Summary-Service/pull/2 |
| Title | refactor: fix for PR review |
| Author | myopaingthu |
| Base | `development` |
| Head | `mpt/tele-consult-fees-report` |
| Status | Open |
| Files | 3 (+62 / -1) |
| ClickUp | https://app.clickup.com/t/9018849685/86exqc3nt |

## TL;DR

**Request changes — important issues only, no blockers.**

The PR correctly fixes the previous review by moving audit logging into the same Postgres transaction as the status change (atomicity is the actual invariant here, not novelty). The shape is right; the typing is sloppy, the test story is missing, and `CollectStatus.CANCELLED` is dropped without a story. Ship after the Important items below are addressed; the rest is hygiene.

## What the PR does

1. Adds a hand-maintained subset `ActivityLog` model to `prisma/schema.prisma` so the summary service can write audit rows directly into the HMS-owned `activity_logs` table.
2. Inside the `payReports` and `revertReports` transactions in `cf-report.service.ts` and `tc-report.service.ts`, inserts an `ActivityLog` row alongside the status change. Audit row commits atomically with the status change — replaces the "separate best-effort write from the HMS BFF" path.
3. Removes `CANCELLED` from the `CollectStatus` enum.

---

## Blocking

None.

---

## Important

### 1. `userId` typing drops the constraint the comment asserts
**File:** `prisma/schema.prisma` (ActivityLog model)
**What:** The comment says `userId` is a real FK to `users(id)`, enforced at the DB level. The field is typed `String @db.Uuid` and marked non-null, so Prisma will happily accept any UUID-shaped string and let a violating row reach the DB and fail there — or worse, be silently accepted if a future migration relaxes or drops the constraint. Either:

- Type it as `userId String @map("user_id") @db.Uuid` and rely on the FK (accept the FK error path), or
- Add a runtime existence check (`SELECT 1 FROM users WHERE id = $1` inside the same transaction) before insert — cheap, atomic, and converts the FK violation from a 500 into an explicit error.

The comment sells one invariant; the code ships another. Pick one.

### 2. `prisma/schema.prisma` is being hand-edited with no migration story
**File:** `prisma/schema.prisma`
**What:** Per the repo CLAUDE.md, the summary service "does NOT run migrations against the shared DB — the HMS team runs the DDL from `hms-docs/summary-service/data-model/schema.sql`." This PR adds the `ActivityLog` model and removes `CANCELLED` from `CollectStatus` without:

- Linking a DDL change in `hms-docs/summary-service/data-model/` (or wherever `activity_logs` lives in this repo).
- A migration coordination note (which DB environment got the new column / dropped enum value first, and in what order).

If the summary service is deployed before the HMS DDL ships, runtime inserts throw "column does not exist" and the two `payReports` / `revertReports` txns fail atomically (good — but invisible in dev). If the HMS DDL ships first without notifying the summary service, every existing `CollectStatus = CANCELLED` row becomes orphaned enum-wise. Add a coordination note in the PR description.

### 3. Status writes no longer idempotent on retry — needs a test or a doc note
**Files:** `src/services/cf-report.service.ts:309-329`, `src/services/tc-report.service.ts:311-331`
**What:** Before this PR, retrying a failed `payReports` batch would re-update status (the update is a no-op on row state, so safe). With the new `tx.activityLog.create({...})`, every retry inserts a new audit row.

If `payReports` fails halfway, callers now see:
- Some `UNPAID → PAID` transitions committed, but the response promise rejected.
- A retry sees those rows already paid (status guard rejects), so the txn aborts before reaching the audit insert — good.
- A retry from a caller that doesn't check rows (e.g. an HTTP path that re-posts the same body) is the danger. Audit rows proliferate.

**Fix:** add the unique constraint the rest of the summary service uses (`@@unique([entity, entityId, action])` would be the natural fit — `description` is computed, so not a uniqueness candidate). Without it, audit logs can duplicate, which defeats their purpose for a finance audit trail.

### 4. No tests
**Files:** the four edit hunks
**What:** Audit logging is a finance audit trail. The repo already has a tenant-scope Jest test for the CFI service. Add at minimum:

- `payReports` happy path → exactly one `activity_logs` row, with the expected `entity`/`action`/`userId`.
- `revertReports` happy path → exactly one row, with `additionalData.remark` when `input.remark` is set, and omitted (not empty object) when it's not.
- Failure path → status update fails; audit row is not present.

### 5. `CollectStatus.CANCELLED` removal has no accompanying change
**File:** `prisma/schema.prisma:1119`
**What:** Postgres enum removals are not zero-touch — every row storing `'CANCELLED'` becomes invalid the moment the new enum value list is committed. If a future query selects `*`, those rows return with a value Prisma can't map and the worker crashes. Either:

- Drop the rows in the same migration, or
- Add `ALTER TABLE ... ALTER COLUMN status TYPE text USING status::text`, drop the enum, then re-add without `CANCELLED`. Slower, but data-safe.

If `CANCELLED` is genuinely unused in this repo's tables, say so in the PR description and link the supporting query. As shipped, it's a silent landmine.

---

## Nit

### N1. Description strings are leaky display text, not stable identifiers
**File:** both report services
**What:** `description: "Paid Consultation Fees"` and `description: "Reverted to Unpaid Tele Consultant Fees"` are user-facing sentences committed to the audit table. The audit table is queried by `entity`/`action`, not by description, so this string is purely cosmetic. If the HMS UI renders it, a translation/localization pass will require a schema migration. Compromise: use a stable enum-like prefix the UI can map (`Pay consultation fee` / `Revert consultation fee`), or store an enum + a separate UI label table. Not blocking.

### N2. `description` is non-null but `action`, `entity`, `entityId` are nullable
**File:** `prisma/schema.prisma`
**What:** Inconsistent. The summary service's inserts populate all four fields — so they should all be non-null. Nullable `action`/`entity` will accept any junk from a future contributor. Either tighten the schema or document why only `description` is required.

### N3. Inline `additionalData: input.remark ? { remark: input.remark } : undefined` is noisy
**Files:** `cf-report.service.ts:405`, `tc-report.service.ts:407`
**What:** `prisma` accepts `additionalData: undefined` and Prisma treats it as "do not write this column", so the ternary is unneeded. `additionalData: input.remark ? { remark: input.remark } : undefined` and `additionalData: input.remark ? { remark: input.remark } : Prisma.skip` are both fine. The current form works; it's just one more symbol than necessary.

### N4. Comment block in `prisma/schema.prisma` is longer than the model
**File:** `prisma/schema.prisma`
**What:** 6-line preamble for a 12-line model. The "HMS-owned" note is worth keeping; the "instead of a separate best-effort write from the HMS BFF" half belongs on the service call sites, not in the schema. Trim to one line.

---

## Ponytail / over-engineering pass

| File:Line | Tag | What to cut | Replacement |
| --- | --- | --- | --- |
| `prisma/schema.prisma:743-750` | `shrink` | 6-line preamble for a 12-line model | One-line note: `// activity_logs is HMS-owned; this service only writes it.` |
| `prisma/schema.prisma` (ActivityLog block) | `delete` | Inline `// Real FK to HMS's users(id)...` comment | Move reasoning to the `userId` field comment, not a separate block |
| `cf-report.service.ts:405`, `tc-report.service.ts:407` | `shrink` | `input.remark ? { remark: input.remark } : undefined` | `additionalData: input.remark ? { remark: input.remark } : undefined` → drop the ternary, Prisma treats `undefined` as "skip column"; or always write `{ remark: input.remark ?? null }` |
| (service files) | `yagni` | Storing the user-facing sentence in `description` while `action`/`entity` already encode the event | `description` is redundant information carried in a non-translatable field; YAGNI until the UI renders it |
| (no finding) | — | No new deps, no new abstractions, no helpers | — |

**Net:** roughly -6 lines possible (comment trim + ternary deletion), once the Important items are addressed. Otherwise this is close to the minimum shape the audit trail requires. Lean.

---

## Test coverage gap

Three tests minimum, all in `tests/services/{cf,tc}-report.service.test.ts` (or wherever the repo keeps service tests):

1. `payReports` happy path → exactly one matching `activityLog` row, fields as expected.
2. `revertReports` happy path with `remark` → `additionalData.remark === input.remark`; without `remark` → `additionalData` is null/unset.
3. Force a status-update failure mid-batch → no `activityLog` row for any CFI in the batch (txn atomicity).

Bonus: a regression test that re-runs `payReports` twice on the same input IDs and asserts no duplicate `activityLog` row — only doable after the unique constraint from Important #3 lands.

---

## Final recommendation

**Request changes.** The atomicity decision is correct and the right one to make. Five Important items to close before merge:

1. Decide what `userId` typing actually enforces (Important #1).
2. Link the DDL coordination for both the new model and the dropped enum value (Important #2, #5).
3. Add the unique constraint on audit rows, or document the no-retry assumption (Important #3).
4. Land at least the three tests above (Important #4).
5. Resolve the `CANCELLED` data-question (Important #5).

Nits can ship as follow-ups.
