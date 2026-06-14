# ADR 0007: Multi-tenancy enforcement — defense in depth, four layers

- **Status:** Accepted
- **Section in brief:** 7.6

## Context

The HMS is multi-tenant by design. The on-prem install is single-tenant in practice, but every query, every Redis key, every log line must be scoped by `tenant_id` so the codebase can be deployed to multi-tenant environments in the future without a security retrofit.

## Options considered

- **(a) Defense in depth at four layers** — API edge, query layer, Redis key namespace, log fields.
- **(b) Row-level security (Postgres RLS)** — the database enforces `tenant_id` filtering on every query.
- **(c) Single-tenant mode for v1** — skip multi-tenancy since the on-prem install is one tenant.

## Decision

**(a) Defense in depth at four layers.**

## Rationale

- RLS (option b) is robust but adds significant operational complexity (per-connection role switching, policy management) and is hard to test. For a service with a small query surface (~20 queries), app-level enforcement is simpler and equally secure.
- Skipping multi-tenancy (option c) is the easiest path but creates a security retrofit the day the hospital wants to share the codebase with another hospital or move to a cloud multi-tenant deployment. The cost of preserving `tenant_id` discipline is low; the cost of retrofitting it is high.
- Four layers: edge, query, Redis, logs. Each catches a different class of bug.

## Consequences

- **Layer 1 — API edge:** the BFF passes `X-Tenant-Id: <tenantId>` as an HMAC-signed header (see ADR 0008). The Summary Service reads the tenant from the verified JWT/JWS-claim (not from the request body), validates it's present, and uses it for the entire request.
- **Layer 2 — Query layer:** a Prisma client extension injects `where: { tenantId: <verifiedTenantId> }` into every query. A test suite asserts that no query can omit the filter — every test runs against a two-tenant fixture and verifies that a query scoped to tenant A cannot return tenant B's rows.
- **Layer 3 — Redis key namespace:** all keys are prefixed `summary:consultation_fees:{tenantId}:...`. The service refuses to read or write a key whose prefix doesn't match the verified tenant.
- **Layer 4 — Logs:** every log line carries `tenantId` as a required field. Pino binding ensures the field is set; missing-field is a startup config error.

## Threat model coverage

- A user crafts a request with a different `tenantId` in the body: rejected at layer 1 (the body's `tenantId` is ignored; the verified header is the only source of truth).
- A bug in the query layer omits the filter: caught by the test suite.
- A bug in the Redis layer reads a key with a different prefix: rejected at layer 3.
- An attacker with shell access on the host: the host is on a private network, no external access; even with shell access, the keys are not guessable across tenants. Layer 4 (logs) ensures any cross-tenant attempt shows up in audit logs.

## Related

- ADR 0008 (Service-to-service auth)
- ADR 0009 (Redis cache model)
- ADR 0011 (Observability)
