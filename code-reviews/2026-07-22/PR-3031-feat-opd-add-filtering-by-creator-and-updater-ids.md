# Code Review: PR #3031 — feat(opd): add filtering by creator and updater IDs
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/29/enhance-opd-filter` → `development`
**Files changed:** 3 (+11 / -1)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22
**ClickUp:** https://app.clickup.com/t/9018849685/86eyar25z

## Summary
Adds two optional query filters (`createdById`, `updatedById`) to the OPD billing list endpoint. The schema gains two `z.string().optional()` fields, and the repository applies them as plain Prisma `where` clauses using the same `if (query.x) where.x = query.x` pattern already used throughout the file. The OPD submodule pointer is also bumped. The change is the minimum expression of the feature — no helpers, no abstractions, no new dependencies.

## Verdict
**Approve with suggestions**
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
Ship. Two small follow-ups are optional and not blockers:

1. **No tests.** The existing `getOPDBillingsSchema` likely has unit coverage; consider adding two cases (`createdById`, `updatedById`) to lock the parsing in. The repository `where` builder is a glue layer — the schema test is where most regressions would surface.
2. **OpenAPI / tRPC doc propagation.** If the OPD list endpoint surfaces Zod-derived types to clients, the consumer type should regenerate automatically; verify `npm run prisma:generate` / codegen produces `createdById`/`updatedById` in the client input shape.

Neither is required for merge.
