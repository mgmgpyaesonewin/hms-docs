# Code Review: PR #3025 — Prisma Migration Error
**Repository:** MyanCare/Ycare-HMS
**Author:** @myopaingthu
**Branch:** `fix/migration-hot-fix-report` → `development`
**Files changed:** 1 (+7 / -1)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22

## Summary
Hotfix for a Prisma migration error. Two schema-level corrections in `prisma/schema.prisma`:

1. **`EventOutbox`** — removes the `@@index([nextAttemptAt], map: "idx_outbox_pending")` declaration and replaces it with a comment. The actual `idx_outbox_pending` index was created in migration `20260617091918_add_summary_service_tables` as a *partial* index (`CREATE INDEX ... ON "event_outbox"("next_attempt_at") WHERE "status" = 'PENDING'`). Prisma cannot express partial indexes, so leaving the `@@index` in place made `migrate dev` diff re-emit a regular `CREATE INDEX` on a name that already exists, failing to apply. Removing the declaration lets Prisma ignore the partial index it cannot see.
2. **`ItemAverageCostHistory`** — adds `@@index([stockId])` and `@@map("item_average_cost_histories")`. The `@@map` is required because the table name in the DB is plural (`item_average_cost_histories`) but the Prisma model name is singular, so without the override Prisma would generate DDL referencing `item_average_cost_history` (the wrong table). The `@@index([stockId])` mirrors an index already present in migration `20260630031124_add_item_average_cost_table_and_history_table`.

Both fixes were verified against the migration history.

## Verdict
**Approve**
Score: 100/100
Critical: 0 | High: 0 | Medium: 0 | Low: 0 | Nit: 0

## Issues

### Critical
None

### High
None

### Medium
None

### Low / Nit
None

## Recommendation
Ship it. Both changes are correct, minimal, and well-justified against the migration history. The comment block on `EventOutbox` is exactly the kind of "future-self" note needed to stop someone re-adding the `@@index` and re-breaking migrations. Optional polish: the PR title "Prisma Migration Error" is vague; future fixes of this kind would benefit from a one-line body explaining which migration they were resolving (e.g. "fix: align schema with partial index from 20260617091918 and plural table name in 20260630031124"). Not blocking.
