# hms-app — design artifacts

Design documentation for the **hms-app** Next.js monolith (the hospital
management system itself).

## Layout

```
hms-app/
├── README.md                          this file
├── api/                               REST + tRPC surface
│   ├── manifest.yaml                  OpenAPI generation inventory + per-module status
│   ├── paths/                         one YAML per module
│   ├── schemas/                       one YAML per module
│   └── openapi-generator-prompt.md    the generation brief
├── onboarding/
│   └── solution-architect-plan.md     phased SA onboarding checklist
├── item-average-cost-design.md        pricing/cost design note
└── selling-price-cost-method-impact.md
```

## Where to start

- New to the API surface → [`api/manifest.yaml`](./api/manifest.yaml).
  Each module entry lists the routes, files, and what's been
  documented vs. what's still pending.
- Generating the OpenAPI spec → follow
  [`api/openapi-generator-prompt.md`](./api/openapi-generator-prompt.md).
- New Solution Architect → start with
  [`onboarding/solution-architect-plan.md`](./onboarding/solution-architect-plan.md).

## Status of the API docs

`api/manifest.yaml` is the single source of truth for what's been
documented. Modules with `status: documented` are complete;
`status: pending` ones still need a pass. The big `notes:` blocks
on each module capture audit findings (security, RBAC, perf) — those
should eventually move out into per-module `findings/` files; for now
they live inline in the manifest.

## Cross-references

- Live code: `../hms-app/` in the parent workspace (sibling repo).
- This design tree is **not** the source of truth for any code-level
  decision; if the two disagree, the code is right and this tree
  should be updated.