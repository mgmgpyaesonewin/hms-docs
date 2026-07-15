# YCare HMS Vault — Index

A Map of Content for the design vault. Use the Obsidian graph view
(`Ctrl/Cmd+G`) to explore the backlinks from any node below.

> Last curated: 2026-07-10. The vault uses Obsidian wiki links
> (`[[path/to/file|display]]`); bare `[[filename]]` works when the
> filename is unique across the tree.

---

## Start here

- [[README]] — top-level orientation for the design repo.
- [[ONBOARDING]] — workspace-level onboarding (sibling repos + quick start).
- [[INDEX]] — this file.

---

## Summary Service

The newest and most active design. Auto-creates `Consultation Fees
Invoice` rows from HMS OPD billings via a Postgres transactional
outbox. Self-contained in [[summary-service/README|its own README]].

### Brief & spec

- [[summary-service/build-prompt]] — the build brief.
- [[summary-service/summary-service-architecture-prompt]] — the full design brief.
- [[summary-service/SPEC]] — long-form spec.

### ADRs by topic

| Concept | ADRs |
| --- | --- |
| **Trigger / Outbox** | [[summary-service/adrs/0001-trigger-mechanism\|ADR 0001]] |
| **Service decomposition** | [[summary-service/adrs/0002-service-decomposition\|ADR 0002]] |
| **Idempotency** | [[summary-service/adrs/0003-idempotency\|ADR 0003]] |
| **Uniqueness for CFIs** | [[summary-service/adrs/0004-uniqueness-for-cfis\|ADR 0004]] |
| **State machine** | [[summary-service/adrs/0005-state-machine\|ADR 0005]] · [[summary-service/adrs/0006-concurrent-status-updates\|ADR 0006]] |
| **Multi-tenancy** | [[summary-service/adrs/0007-multi-tenancy-enforcement\|ADR 0007]] |
| **HMAC Auth** | ADR 0008 *(see [[summary-service/api/openapi\|OpenAPI]] + [[summary-service/ops/security-review|security review]])* |
| **Redis cache model** | [[summary-service/adrs/0009-redis-cache-model\|ADR 0009]] |
| **Search strategy** | [[summary-service/adrs/0010-search-strategy\|ADR 0010]] |
| **Observability** | [[summary-service/adrs/0011-observability\|ADR 0011]] |
| **Failure modes** | [[summary-service/adrs/0012-failure-modes\|ADR 0012]] |
| **Backup & recovery** | [[summary-service/adrs/0013-backup-and-recovery\|ADR 0013]] |
| **CFI invariants** | [[summary-service/adrs/0014-cfi-invariants\|ADR 0014]] |

### Diagrams

- [[summary-service/diagrams/c4-context|C4 context]] · [[summary-service/diagrams/c4-container|container]] · [[summary-service/diagrams/c4-component|component]] · [[summary-service/diagrams/c4-deployment|deployment]]
- [[summary-service/diagrams/sequences|Sequence diagrams]] — happy path, worker crash + reaper, summary load, status update.

### Data model

- [[summary-service/data-model/schema|schema.sql]] — canonical DDL.
- [[summary-service/data-model/er-diagram|ER diagram]] — Mermaid view.
- [[summary-service/data-model/prisma-additions|prisma-additions.prisma]] — Prisma model subset.

### API

- [[summary-service/api/openapi|openapi.yaml]] — OpenAPI 3.1 spec.
- [[summary-service/api/api-smoke-test|api-smoke-test.md]] — captured end-to-end req/resp.

### Ops

- [[summary-service/ops/runbook|Runbook]] · [[summary-service/ops/observability|Observability]] · [[summary-service/ops/security-review|Security review]]
- [[summary-service/ops/cutover-plan|Cutover plan]] · [[summary-service/ops/capacity-plan|Capacity plan]]
- [[summary-service/ops/ycare-summary-api.service|ycare-summary-api.service]] · [[summary-service/ops/ycare-summary-worker.service|ycare-summary-worker.service]]
- [[summary-service/ops/env.template|env.template]] — environment variable surface.

---

## HMS App (monolith)

Design home for the Next.js hospital management system. See
[[hms-app/README|its own README]] for layout.

### API surface

- [[hms-app/api/manifest|manifest.yaml]] — single source of truth for documented routes.
- [[hms-app/api/openapi-generator-prompt|openapi-generator-prompt.md]] — the generation brief.
- `hms-app/api/paths/` and `hms-app/api/schemas/` — one YAML per module (see [[hms-app/api/manifest|manifest]] for the inventory).

### Onboarding & design notes

- [[hms-app/onboarding/solution-architect-plan|solution-architect-plan.md]] — phased SA onboarding.
- [[hms-app/item-average-cost-design|item-average-cost-design.md]]
- [[hms-app/selling-price-cost-method-impact|selling-price-cost-method-impact.md]]
- [[hms-app/SPEC]] · [[hms-app/TODO]]

### Load testing

- [[hms-app/load-testing/spec|spec]] · [[hms-app/load-testing/workflow|workflow]]

---

## Onboarding packets

Per-service orientation, separate from the design docs:

- [[onboarding/hms-app]] — HMS monorepo orientation.
- [[onboarding/hms-summary-service]] — Summary Service orientation.
- [[onboarding/infra]] — local-dev infra (docker-compose, env wiring).

---

## Prompts

Reusable briefs fed to AI tools. See [[prompts/README|prompts/README]] for the
folder conventions.

- **build/** — scaffold briefs: [[prompts/build/build_route|build_route]] · [[prompts/build/winston_logger_spec|winston_logger_spec]] · [[prompts/build/winston_logger_implementation|implementation]] · [[prompts/build/winston_logger_workflow|workflow]] · [[prompts/build/winston_logger_test_cases|test_cases]] · [[prompts/build/winston_logger_review|review]] · [[prompts/build/winston_logger_addition|addition]]
- **review/** — [[prompts/review/code_review_flow|code_review_flow]]
- **audit/** — [[prompts/audit/mantine-component-usage-audit|mantine-component-usage-audit]]
- **debug/** — [[prompts/debug/hms-app-db-connectivity-debug|hms-app-db-connectivity-debug]]
- **ux/** — [[prompts/ux/ux_improvement/ux_improvement|ux_improvement]] · [[prompts/ux/superadmin_login_conflict|superadmin_login_conflict]]

---

## Ops (cross-cutting)

Repo-wide operational docs. Service-specific runbooks live under each
service's `ops/` folder (see [[INDEX#Summary Service|Summary Service › Ops]]).

- [[ops/README|ops/README]] — folder conventions.
- [[ops/incidents/2026-06-22-prisma-rds-cascade-rca|2026-06-22 Prisma/RDS cascade RCA]].
- [[ops/deploy/uat-steps|uat-steps.md]] — UAT checklist.

---

## Code reviews

Historical PR reviews. Bucketed by month. See
[[code-reviews/README|code-reviews/README]] for naming conventions.

- `code-reviews/by-month/2026-06/` and `code-reviews/by-month/2026-07/` — primary history.
- `code-reviews/2026-07-07/` and later — recent flat folders (legacy).

---

## Diagrams (cross-cutting)

- [[diagrams/category-department-service-doctor|category-department-service-doctor]] — domain model diagram.

---

## Archive

Superseded docs. **Not authoritative** — see [[README|README]] §`archive/`.

- [[archive/redis-events-as-service|redis-events-as-service.md]] — replaced by the transactional-outbox pattern in [[summary-service/README|summary-service]].
- [[archive/departments-services-doctors|departments-services-doctors]] (sql + csv) — early schema dump.

---

## Release notes

- [[release-notes/hms-app-v1.1.35.uat|hms-app v1.1.35 UAT]]

---

## Conventions

- Wikilinks resolve by filename when unique, otherwise by full path.
- Pre-existing relative-path links (`[text](path/file.md)`) still
  resolve in Obsidian — they just don't appear in the graph view. The
  next cleanup pass converts the high-traffic cross-refs to wiki
  syntax; ask if you want that scoped to a folder.
- `SPEC.md` files are exempt from the workspace 500-line rule (see
  [[README|README]] §"Document conventions").