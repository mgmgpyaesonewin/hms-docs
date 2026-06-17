# YCare HMS — Design Artifacts

This repository holds the design documentation for YCare HMS (the
Next.js hospital management system) and its companion services. The
authoritative source for how the system is built is the code in the
sibling repos (`hms-app/`, `hms-summary-service/`, `infra/`); this repo
captures the *why* — Architecture Decision Records, the canonical
schemas, the API contracts, the operational runbooks.

## Layout

```
hms-docs/
├── api/                REST API surface for the HMS (the Next.js monolith)
├── etc/                Miscellaneous design notes / TODOs
└── summary-service/    Detailed design for the Summary Service microservice
```

### `api/` — HMS REST API surface

The external HTTP API exposed by `hms-app`. Generated from a manifest,
not from the live Next.js routes — kept here so the contract is
reviewable independently of code.

- `manifest.yaml` — the full OpenAPI-style manifest of every route
  the HMS exposes (paths, methods, request/response shapes)
- `paths/`, `schemas/` — split-out path and schema files (referenced
  from the manifest)
- `openapi-generator-prompt.md` — the brief for generating the
  client SDK / type definitions from the manifest

This folder is read-only reference. The code that *implements* the
API lives in `hms-app/src/app/api/`.

### `etc/` — Miscellaneous

Loose notes that don't belong in the structured design folders.

- `TODO.md` — open questions and known gaps

### `summary-service/` — the Summary Service design (the most detailed folder)

The newest and most actively maintained design in this repo. The
**Summary Service** is an Express + TypeScript microservice that
auto-creates `Consultation Fees Invoice` rows from HMS OPD billings
(via a Postgres transactional outbox) and serves the admin summary
API.

This folder is comprehensive and has its own [README](./summary-service/README.md)
that explains the folder layout, reading order, and the v1/v2 split.
Read it as the entry point.

In short: 14 ADRs, the canonical DDL + Prisma additions, the OpenAPI
spec, C4 + sequence diagrams, and a complete ops package (systemd units,
observability, security review, cutover plan, runbook, capacity plan).

The most-recent code lives in the `hms-summary-service/` repo in the
parent workspace; the `api/api-smoke-test.md` file in that folder
captures a live end-to-end run of the API for review.

## Doc-vs-code state

The `summary-service/` folder was audited against the live code in
November 2026. The audit closed 9 of 14 findings (3 critical + 6
medium). Five low-priority findings remain as backlog and are listed
in the audit-fix commit message.

For the HMS REST API (`api/`), the manifest is the source of truth
and is updated when routes change. If a route in `hms-app/src/app/api/`
diverges from the manifest, the manifest is right and the code
should be brought back into line.

## How to use this repo

- New engineer joining the Summary Service → start with
  [`summary-service/README.md`](./summary-service/README.md) (it has a
  guided reading order).
- Reviewing the HMS REST contract → start with
  [`api/manifest.yaml`](./api/manifest.yaml).
- Looking for the rationale behind a specific decision → `adrs/`
  inside the relevant service folder. Each ADR is self-contained
  (Context, Options, Decision, Rationale, Consequences, Related).
- Operational questions (how to deploy, how to recover, how the
  on-prem hospital host is sized) → `ops/` inside the relevant
  service folder.
