# Superadmin Login Conflict — Agent Team Brief

## Context
- App: `hms-app` (Next.js 15 App Router, Mantine v7, tRPC, Prisma, Zod)
- Surface: `hms-app/src/app/auth/login`
- Symptom: logging in as `superadmin` at `http://localhost:3000/auth/login` returns
  > "This account is already in use on another device. To continue, please contact the admin for support."
- Working dir for investigation: `hms-app/`

## Task
Determine WHY `superadmin` was rejected and report a concrete next step to unblock the user.

## Steps
1. Read `hms-app/.env` for `DATABASE_URL`. Connect with the Prisma client at
   `hms-app/prisma/schema.prisma`. Do **not** run migrations.
2. Grep `hms-app/src` for the literal error string
   `"already in use on another device"` and identify the function that raises
   it. Capture `file:line` and the exact condition checked.
3. From the DB, fetch the `superadmin` user row and every active session
   tied to that user id. The session table name is **not** assumed — find it
   by reading `hms-app/prisma/schema.prisma` (likely `user_sessions` /
   `sessions` / similar).
4. Cross-reference: was the guard tripped by a real concurrent session, or
   by a stale row that should have been reaped?
5. Report findings in the Output format below.

## Output (Markdown, in this order)
- **DB findings** — user id, session count, session ids + `created_at` + `last_seen_at`
- **Code path** — `file:line` of the guard and the exact condition checked
- **Root cause** — one paragraph, no hedging
- **Recommended fix** — either (a) the SQL to clear the stale session safely, or (b) the code change if it is a logic bug

## Constraints
- Read-only on `hms-app/` source and the DB. No migrations. No `prisma db push`.
- Do not modify `hms-summary-service` or any `hms-docs/` files other than
  adding notes inside this brief.
- If a step is blocked (e.g. table not found, error string not in src), say so
  explicitly — do not fabricate rows, file paths, or session ids.

## Team & Pipeline

Run in order; each phase must produce the listed deliverable before handing off:

1. **senior-backend** — execute Steps 1–4 above. Deliverable: raw DB output
   (user row + sessions) and the `file:line` of the guard, with the exact
   condition code quoted.
2. **senior-architect** — review the code path and the DB state. Decide
   whether this is (a) a real concurrent session, (b) a stale row, or
   (c) a logic bug in the guard. Deliverable: classified root cause.
3. **senior-backend** — produce the Recommended fix as a SQL snippet
   (read-only cleanup) or a minimal code patch, whichever applies.
4. **senior-qa** — if a code patch is produced, write/run a test that
   reproduces the conflict (two sessions for the same user) and asserts the
   guard's behavior. Deliverable: green test run + 1-line summary.

If any agent blocks for >1 turn waiting on info from the user, post a
question to the lead instead of guessing.

## Out of scope
- No DB migrations.
- No changes to `hms-summary-service` or the outbox.
- No changes to the login UX, error message copy, or auth flow shape.
- No new dependencies without explicit approval.

## Done = root cause classified + concrete fix (SQL or patch) ready to apply.
