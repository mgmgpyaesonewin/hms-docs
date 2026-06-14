# ADR 0008: Service-to-service auth — HMAC-SHA256 with file-based shared secret

- **Status:** Accepted
- **Section in brief:** 7.7

## Context

The Summary Service binds to `127.0.0.1` only. The only legitimate caller is the HMS Next.js BFF. The BFF must prove its identity to the Summary Service on every request, and the Summary Service must reject requests that are stale, replayed, or unsigned.

## Options considered

- **(a) HMAC-SHA256 with file-based shared secret** — the BFF signs `(method, path, body, timestamp)` with a key in `/etc/ycare-summary/shared-secret`; the service validates signature, timestamp window, and replay window.
- **(b) mTLS via service mesh** — the BFF and the service present certificates; the network enforces trust.
- **(c) RS256 service JWT** — the BFF signs a short-lived JWT with claims; the service validates the JWT signature with a public key.
- **(d) No auth (localhost-only)** — the service binds to localhost and trusts the BFF implicitly.

## Decision

**(a) HMAC-SHA256 with file-based shared secret.**

## Rationale

- The service binds to `127.0.0.1`. Network-level isolation is the primary defense. The HMAC is defense in depth, not the only defense.
- mTLS (option b) requires a service mesh (Istio/Cilium), which the on-prem deployment doesn't run. Overkill for v1.
- JWT (option c) is appropriate for cross-machine or cross-network service auth. For localhost-only, HMAC is simpler and provides equivalent security.
- "No auth" (option d) is risky: a future refactor that exposes the service on a different interface (e.g., to a sidecar) immediately opens it up. HMAC is cheap insurance.

## Consequences

- The shared secret is a 256-bit random key, generated at install time by the setup script, written to `/etc/ycare-summary/shared-secret` (mode 0400, owner `root:ycare-summary`).
- The HMS BFF reads the same secret at startup.
- The BFF adds four headers to every request:
  - `X-Service-Id: hms-bff`
  - `X-Timestamp: <unix-seconds>`
  - `X-Signature: <hex-encoded HMAC-SHA256 of (METHOD || "\n" || path || "\n" || sha256(body) || "\n" || timestamp || "\n" || serviceId)>`
  - `X-Tenant-Id: <tenantId>` (signed as part of the body for tenant-binding — see ADR 0007)
- The Summary Service:
  1. Reads the shared secret from `/etc/ycare-summary/shared-secret` at startup, caches it in memory.
  2. On every request, recomputes the HMAC and compares with `X-Signature` in constant time. Reject `401` on mismatch.
  3. Validates `X-Timestamp` is within ±5 minutes of `Date.now() / 1000`. Reject `401` on staleness.
  4. Maintains an in-memory LRU cache of seen signatures within the timestamp window to reject replays. (Cap: 10,000 entries; oldest evicted on overflow. A persistent replay store is not needed for v1 — the 5-minute window + LRU is enough.)
- Secret rotation: see `api/hmac-auth.md` for the procedure. In summary, a new secret is deployed, the service is restarted with the new secret, the BFF is restarted with the new secret. The old secret is kept valid for a 60-second grace period for in-flight requests.

## Related

- ADR 0007 (Multi-tenancy enforcement)
- `api/hmac-auth.md` for the exact spec
