# PR #2843 — Fix: show friendly error when deleting doctor with history

**Repo / State / Author / Branch / Diff / CI**
- Repo: `MyanCare/Ycare-HMS` · State: **OPEN** · Author: `Pyae41` (Pyae Phyo Zan)
- Branch: `issue/ppz/sprint-26/doctor-delete-message-86ey2uc11` → `development`
- Single commit `59a78d4c` · 1 file changed · +66 / -2
- ClickUp: https://app.clickup.com/t/9018849685/86ey2uc11
- CI: not captured (PR OPEN, no checks listed)

**Verdict:** ⚠️ Approve with two small fixes
**Critical+High:** 0 Critical, 1 High, 2 Medium, 3 Low

## Summary

`DoctorsRepository.deleteById` previously relied on `prisma.user.delete` throwing an FK violation to detect that the doctor had related history, and translated that into a bare `400 "Doctor is in use and cannot be deleted"`. That message leaked the generic FK path and only fired after Postgres raised — opaque to the user.

This PR replaces the FK-catch with a pre-check: load the doctor with `_count` over **47 relation fields**, sum via `Object.values(...).some(c => c > 0)`, and throw an `AppError("This doctor has previous history. You can't delete right now.", 400)` before issuing the delete. The branch keeps the FK fallback as a backstop — the right belt-and-braces shape.

## Risks

- **N+1 surface.** Prisma compiles 47 `_count` sub-selects into a single SQL with 47 correlated subqueries. On a doctor with a long history (the case this PR is built for) the `_count` may scan large index pages. Not introduced here — the pre-check is cheaper than the original (a failed `DELETE` cascade + rollback) — but flag as a known cost.
- **Race.** Between the `_count` SELECT and the `user.delete` another transaction can insert a referencing row. The retained FK-catch arm preserves correctness for that window; the friendly path stays best-effort. Good.
- **Multi-tenancy / soft-delete.** Skim `prisma/schema.prisma` `model Doctor` — if the project soft-deletes doctors elsewhere this guard may need to exclude `deletedAt` rows from `_count`. Out of scope of the diff.
- **No tests.** The repository has zero unit coverage in this directory.

## Findings

### 🔴 Critical
None.

### 🟠 High

**H1 — Status code 400 vs sibling convention 409.** Every peer pre-check in this codebase uses `409 Conflict` for "has previous history":

- `service.repository.ts:305` — 409
- `service-category-repository.ts:124` — 409
- `service.repository.ts:346` — 409 (cascading-delete variant)
- `procedure.repository.ts`, `ward-repository.ts`, `floor-repository.ts`, `lab-test.service.ts`, `foc-item.service.ts`, `lab-group.service.ts`, `lab-collection-method.service.ts`, `lab-status.service.ts`, `lab-sample.service.ts`, `test-script.service.ts`, `deposit-type-repository.ts`, `vital-signs.repository.ts`, `room-list-reposity.ts`, `service-sub-category-repository.ts`, `service-package.repository.ts`, `special-lab-test.service.ts`, `emr-vital-sign.repository.ts` — all 409.

PR emits **400**. The FK fallback arm in the same function also emits 400 (no regression there). Make the new pre-check arm `409` for consistency — clients that already key off `409 HAS_HISTORY` from sibling endpoints will see two different codes for the same condition. One-line change.

### 🟡 Medium

**M1 — `Object.values().some(c => c > 0)` is correct but fragile to schema drift.** When somebody adds a new relation to `model Doctor` in Prisma, the array still iterates the old set and the new relation is silently ignored — silent regression of the very bug this PR fixes. Two cheap mitigations, pick one:

- **(preferred, Ponytail rung 2 — reuse):** define `const DOCTOR_RELATIONS = ["appointments", "bookingLists", ..., "readingLabResultItems"] as const;` array, use it both in `select._count.select` and the `.some` test. One source of truth, TypeScript forces the field to exist on the Prisma type. Roughly the same byte count as the inline literal, but reviewer-readable.
- (alternative) comment `// ponytail: keep in sync with model Doctor relations` — fragile, skip.

**M2 — `_count` arms miss `user`-side relations.** `User` (the row that actually gets deleted, `this.prisma.user.delete`) has its own relations (sessions, etc.). The 47 fields are all `Doctor.*`. If `User` has any FK pointing **at it** from a row that references the doctor via `userId`, those won't be counted. The FK-catch backstop catches it — but if the goal is "friendly, not generic," surface that. Skim `model User` to confirm the omitted relations are either empty or non-blocking; if any are real (e.g. login sessions, audit), extend the `_count` list. Quick check, low effort.

### 🔵 Low

**L1 — Wording nuance.** Sibling pattern uses two phrasings interchangeably: *"You cannot delete right now"* (no apostrophe, full stop) and *"You can't delete right now!"* (apostrophe + exclamation). PR picks `"You can't delete right now."` (apostrophe, no bang) — fine and grammatical. **No i18n concern** because none of the ~25 sibling messages are localized either; flag once at the codebase level, not per-PR.

**L2 — `try`/`catch` no longer needed around the `findUnique` + `_count` block alone.** The catch's other branch was the FK translation (now redundant for the pre-check path) and `logger.error(error); throw error;` (default behavior anyway). With the new shape the `try` is still useful because of the retained `prisma.user.delete` + FK fallback. Keep as-is.

**L3 — `_count` then `user.delete` is two round-trips, not one.** Fine; `O(1)` extra latency on a low-frequency admin action. Don't wrap in a transaction. Ponytail: leave it.

## Ponytail notes

- **Ladder rung 1 — does this need to exist?** Yes, the FK-only message is the symptom. Pre-check is the right shape.
- **Ladder rung 2 — already in codebase?** **Yes**, the `_count`-then-throw-AppError pattern lives in `service.repository.ts:312-347` (`deleteServiceWithDependencies`). This PR is a faithful copy-paste variant. Good — that's the requested reuse.
- **Ladder rung 6 — can it be one line?** No, 47 relation fields won't fit; the typed-array variant in M1 is the right "shortest working diff."
- **No new abstractions introduced.** No helper, no factory, no shared `hasHistory()` utility. Correct — a 47-field list is a one-off, generalizing across entities would be premature.
- **No new dependency.** Correct.

## Reuse check (existing friendly-error helper?)

- `src/utils/errors.ts` — only defines `AppError`. No "friendly FK" helper.
- `src/utils/error-handling.ts` — only `repositoryErrorHandle`, unrelated.
- `src/utils/prisma-errors.ts` — exports `isForeignKeyConstraintViolationError` (used here).
- `src/lib/safe-action.ts` — server-action wrapper; transforms `AppError.message` to client. The new throw propagates through it untouched.
- `src/lib/flatten-error-messages.ts` — likely used in client form error display.

**No shared "entity has history" helper exists.** ~25 sites inline the message. That is itself tech debt, but Ponytail says do not gold-plate. Don't extract here; raise a separate refactor ticket if anyone cares. Inline copy-paste matches the established pattern.

## Tests

- **None added.** No `doctors.repository.test.ts` in the directory.
- **Minimum useful additions** (Ponytail "one runnable check"):
  1. `deleteById` happy path — doctor with no relations -> `user.delete` succeeds.
  2. `deleteById` history path — seed one row in any of the 47 relations (e.g. one `appointment`) -> throws `AppError("This doctor has previous history. You can't delete right now.", 409)` (after H1 fix).
  3. `deleteById` 404 — non-existent id -> `AppError("Doctor not found", 404)`.

Skipping 1 + 2 is acceptable for this PR (matches the file's no-test convention) but call it out in the merge description.

---

**Merge after:** H1 (status code -> 409) and M1 (typed-array constants) applied. M2 is a sanity skim. Tests optional but recommended.
