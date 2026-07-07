# YCare HMS — Design Artifacts

This repository holds the design documentation for YCare HMS and its
companion services. The authoritative source for *how* the system is
built is the code in the sibling repos (`hms-app/`,
`hms-summary-service/`, `infra/`); this repo captures the *why* —
architecture decisions, schemas, API contracts, operational runbooks.

## Layout

```
hms-docs/
├── README.md                       this file — start here
├── ONBOARDING.md                   workspace onboarding (sibling repos)
│
├── onboarding/                     per-service onboarding packets
│   ├── hms-app.md
│   ├── hms-summary-service.md
│   └── infra.md
│
├── hms-app/                        design home for the HMS monolith
│   ├── README.md
│   ├── api/                        REST + tRPC surface (manifest, paths/, schemas/)
│   ├── onboarding/                 phased Solution Architect checklist
│   └── *.md                        cross-cutting design notes
│
├── summary-service/                design home for the Summary Service microservice
│   └── README.md                   guided reading order
│
├── code-reviews/                   historical PR reviews, by-month/
│   └── README.md
│
├── prompts/                        reusable AI / process prompts
│   ├── README.md
│   ├── build/
│   ├── review/
│   ├── audit/
│   ├── debug/
│   └── ux/
│
├── ops/                            cross-cutting operational artifacts
│   ├── README.md
│   ├── incidents/
│   └── deploy/
│
├── diagrams/                       cross-cutting diagrams
│
└── archive/                        superseded docs (not authoritative)
```

### `hms-app/` — the HMS monolith design

The Next.js hospital management system. This tree holds the API
surface (OpenAPI generation state lives in `api/manifest.yaml`),
the Solution Architect onboarding plan, and standalone design notes
(pricing, cost methods).

### `summary-service/` — the Summary Service design

The newest and most actively maintained design in this repo. The
**Summary Service** is an Express + TypeScript microservice that
auto-creates `Consultation Fees Invoice` rows from HMS OPD billings
(via a Postgres transactional outbox) and serves the admin summary
API.

This folder is comprehensive and has its own
[README](./summary-service/README.md) that explains the folder layout,
reading order, and the v1/v2 split. Read it as the entry point.

In short: 14 ADRs, the canonical DDL + Prisma additions, the OpenAPI
spec, C4 + sequence diagrams, and a complete ops package (systemd
units, observability, security review, cutover plan, runbook,
capacity plan).

### `code-reviews/`, `prompts/`, `ops/`, `diagrams/`

Cross-cutting artifacts. See each folder's README for what's inside
and the naming convention.

### `archive/`

Old or superseded docs (e.g. `redis-events-as-service.md` — replaced
by the transactional-outbox pattern in `summary-service/`). Not
authoritative.

## Doc-vs-code state

The `summary-service/` folder was audited against the live code in
November 2026. The audit closed 9 of 14 findings (3 critical +
6 medium). Five low-priority findings remain as backlog.

For the HMS REST API (`hms-app/api/`), the `manifest.yaml` is the
source of truth and is updated when routes change. If a route in
`hms-app/src/app/api/` diverges from the manifest, the manifest is
right and the code should be brought back into line.

## How to use this repo

- **New to the workspace** → start with [`ONBOARDING.md`](./ONBOARDING.md),
  then the per-service packet that matches your task:
  [`onboarding/hms-app.md`](./onboarding/hms-app.md),
  [`onboarding/hms-summary-service.md`](./onboarding/hms-summary-service.md),
  [`onboarding/infra.md`](./onboarding/infra.md).
- **Reviewing the HMS REST contract** → start with
  [`hms-app/api/manifest.yaml`](./hms-app/api/manifest.yaml).
- **New engineer on the Summary Service** → start with
  [`summary-service/README.md`](./summary-service/README.md) (it has
  a guided reading order).
- **Rationale behind a specific decision** → `adrs/` inside the
  relevant service folder. Each ADR is self-contained.
- **Operational questions** (deploy, recovery, on-prem sizing) →
  `ops/` inside the relevant service folder, or the top-level
  [`ops/`](./ops/) for repo-wide items.
- **Looking for a past PR review** →
  [`code-reviews/by-month/`](./code-reviews/).
- **Feeding a prompt to an AI tool** → [`prompts/`](./prompts/).

## Document conventions

- **`SPEC.md` files are exempt from the workspace 500-line rule — kept
  detailed for AI + human readers.** Per-service `SPEC.md`s (e.g.
  [`hms-app/SPEC.md`](./hms-app/SPEC.md),
  [`summary-service/SPEC.md`](./summary-service/SPEC.md)) are the
  long-form, detailed specs of record; they prioritise completeness over
  brevity. Other markdown in this repo follows the general 500-line
  guidance. If a `SPEC.md` grows past a comfortable read, prefer
  extracting a self-contained topic into `spec/{topic}.md` rather than
  trimming — keep the numbered `§N` index stable.