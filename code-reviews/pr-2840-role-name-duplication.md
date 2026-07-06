# PR #2840 — fix: role name create and update duplication

**Repo / State / Author / Branch / Diff / CI**
- Repo: `MyanCare/Ycare-HMS` · State: **OPEN** · Author: `Xkill119966`
- Branch: `fix/role-name-duplication` → `development`
- Diff: +107 / −16 across 2 files (1 commit `0172f178`)
- CI: not captured

**Verdict:** ⚠️ Request changes
**Critical+High:** 0 Critical, 2 High

## Summary

1. `base-role-form-schema.ts` — `name` field: `min(1)` then `.transform(trim)` then `.pipe(...)` with `min(2)` + format refinements (one of them dead).
2. `role-form.tsx` — adds a `useQuery` debounced search against `get-roles.api` (`page=1, limit=10, search=debouncedName`); if any role in the result page matches the typed name exactly (case-insensitive), shows an inline error and disables submit.

## Risks

- **Server already rejects duplicates** (`role-service.ts:createRole:18-21` and `updateRole:51-56`). The DB has `name String @unique` (`prisma/schema.prisma`). The client-side check is therefore advisory, not load-bearing. The button-disable UX promises a guarantee the server can't deliver — a role inserted by another tab/operator between debounce and submit passes the guard then fails server-side.
- **Repo file pushed past 500 lines** (`role-form.tsx` ~508 lines) — violates `CLAUDE.md` rule.

## Findings

### Critical
None.

### High

1. **Server already enforces + DB already has `@unique` — symptom-level fix (ponytail: root cause, not symptom).** The unique constraint plus the explicit pre-checks in `RoleService.createRole/updateRole` already return `AppError("Role already exists", 400|409)`. The `onError` toast in `add-role-form.tsx:12-14` and `edit-role-form.tsx:15-17` already surfaces the server message. The added client check is a parallel source of truth for the same invariant. Friendlier-UX options, in order of laziness:
   - Add a `code: 'DUPLICATE_ROLE_NAME'` to the existing `AppError` and emit a styled toast. ~5 lines, no schema rewrite, no client guard.
   - Extend `role-repository.findByName` to be transactional (`SELECT … FOR UPDATE`) and call from `role-service` once — form already toasts on `onError`.
2. **`role-form.tsx` exceeds the 500-line cap.** Per `CLAUDE.md`. The check belongs next to `findByName` in `role-repository` plus a single endpoint, not 70 more lines in the form's already-bulky render tree.

### Medium

1. **`base-role-form-schema.ts:14-32` — `.transform(trim).pipe(...)` introduces dead code.** `refine((val) => val.length > 0, ...)` between `.transform(trim)` and `pipe(z.string().min(2))` is unreachable: after trim, `min(2)` has already failed on length 0. Replace the whole `.transform().pipe()` chain with `z.string().trim().min(2,...).max(30,...).refine(...)`. `z.string().trim()` is documented Zod 3.x+.
2. **`role-form.tsx:111-129` — full paginated search for an existence check.** `makeFetchRolesQuery({page:1, limit:10, offset:0, search: debouncedName})` hits `RoleRepository.findAndCountRoles` (findMany with permissions join + count). One row is needed. Minimum-lazy: `GET /api/roles/check-name?name=...` returning `{exists: boolean}` (or tRPC `checkRoleNameAvailable`). One SQL, no payload, no count.
3. **`role-form.tsx:50-51` — four independent state pieces for "duplicate?"** `nameValidationError`, `isCheckingName`, `shouldCheckName`, `debouncedName` can drift (e.g. `isCheckingName` left `true` if deps shift before the query resolves). Single `status: 'idle' | 'checking' | 'duplicate' | 'ok'` reduces ordering bugs.

### Low

1. **`role-form.tsx:5-6` — `useDebouncedCallback` from `@mantine/hooks`.** If not already used in the repo, this is a new dep for an 8-line `setTimeout/clearTimeout` effect. Pick one, drop the other. Mark with `ponytail:` if staying with the effect.
2. **`role-form.tsx:131-142` — debounce re-fires on trailing whitespace keystrokes.** Gate on `watchName.trim() !== prev.trim()`.

## Ponytail notes

- **Rung 5 — already-installed dependency solves it.** `role-repository.findByName` already does `findFirst` with `mode: "insensitive"`. Expose a thin existence endpoint, reuse the same case-insensitive comparison, drop the bespoke client check.
- **Rung 4 — native platform feature covers it.** Postgres `EXISTS (…)` or a migration `CREATE UNIQUE INDEX roles_name_lower_idx ON roles (LOWER(name))` enforces case-insensitive uniqueness at the DB and would obviate both the existing `RoleService` pre-checks and this PR's client check. One DDL line, root-cause.
- **Rung 2 — already in this codebase.** `RoleService.createRole` already throws `AppError("Role already exists", 409)`; the existing `onError` toast already surfaces it. The likely real complaint is "toast text is plain" — fix that one shape.
- **Reuse check**: no existing `unique-by-name` helper in `src/utils` or `src/lib`. `role-repository.findByName` and `categories-repository` are the only refs (category used to be unique, intentionally dropped per `migrations/20241221170746_remove_unique_name_in_category`). So a *new* shared helper would itself be an unrequested abstraction — don't add one, just reuse `findByName`.

## Tests

None added. `src/app/(dashboard)/common/user-management/roles/features/__tests__/` doesn't exist; no Jest file. Minimum: one Zod test for `"  "` rejection, or one component test for the duplicate-name UI flag. Both ~20 lines.

## Bottom line

Either (A) drop the client check entirely and improve the toast on the existing `AppError`, or (B) replace both server pre-checks with one Postgres case-insensitive unique index — one DDL, no schema, no client code, definitive uniqueness for both create and update.
