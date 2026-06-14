# HMAC Authentication Spec

The Summary Service is internal-only (binds to `127.0.0.1:4000`). The only legitimate caller is the HMS Next.js BFF. The BFF proves its identity on every request via an HMAC-SHA256 signature over a canonical string that includes the HTTP method, path, body, timestamp, service ID, and tenant ID.

This document specifies the exact algorithm. It is the contract between the BFF and the Summary Service.

---

## Headers

Every request (except `GET /healthz`) must include four headers:

| Header | Value | Required |
|---|---|---|
| `X-Service-Id` | `hms-bff` (literal) | yes |
| `X-Timestamp` | Unix seconds (integer, as string) | yes |
| `X-Tenant-Id` | UUID of the calling tenant | yes |
| `X-Signature` | Lowercase hex of HMAC-SHA256 | yes |

For state-changing endpoints, an additional `If-Match` header carries the optimistic-lock version of the CFI (see ADR 0006). The BFF must propagate this from the client UI.

---

## Canonical string

The signature is computed over a canonical string with the following format:

```
METHOD "\n" PATH "\n" SHA256_HEX(BODY) "\n" TIMESTAMP "\n" SERVICE_ID "\n" TENANT_ID
```

Where:

- `METHOD` — uppercase HTTP method, e.g. `GET`, `POST`, `PATCH`.
- `PATH` — the URL path including the query string, e.g. `/consultation-fees-invoices?from=2026-01-01`. **No host, no scheme, no port.** The query string must be in the same order as sent on the wire.
- `SHA256_HEX(BODY)` — lowercase hex of SHA-256 of the raw request body bytes. For requests with no body, hash the empty string (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`).
- `TIMESTAMP` — the value of the `X-Timestamp` header, as a decimal integer string.
- `SERVICE_ID` — the value of the `X-Service-Id` header, currently always `hms-bff`.
- `TENANT_ID` — the value of the `X-Tenant-Id` header, as a UUID string.

The six fields are joined by single LF (`\n`) characters. No trailing newline.

### Example

For:
```
GET /consultation-fees-invoices?from=2026-01-01&to=2026-01-31 HTTP/1.1
X-Service-Id: hms-bff
X-Timestamp: 1735689600
X-Tenant-Id: 7c9e6679-7425-40de-944b-e07fc1f90ae7
X-Signature: <hex>
```

With an empty body, the canonical string is:
```
GET
/consultation-fees-invoices?from=2026-01-01&to=2026-01-31
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
1735689600
hms-bff
7c9e6679-7425-40de-944b-e07fc1f90ae7
```

---

## HMAC computation

```
signature = HEX_LOWER( HMAC_SHA256( shared_secret, canonical_string ) )
```

Where `shared_secret` is the 256-bit (32-byte) key in `/etc/ycare-summary/shared-secret`, read as raw bytes (not hex-decoded).

The signature is encoded as 64 lowercase hex characters.

---

## Validation on the service

For every request, the service performs these steps in order:

1. **Headers present.** Reject `401` with `code: MISSING_AUTH_HEADERS` if any of the four required headers is missing.

2. **Timestamp window.** Reject `401` with `code: STALE_TIMESTAMP` if `|now_seconds - X-Timestamp| > 300` (5 minutes). This bounds replay attacks.

3. **Service ID.** Reject `401` with `code: UNKNOWN_SERVICE` if `X-Service-Id != "hms-bff"`. (Future-proofs against adding more internal callers.)

4. **Tenant ID format.** Reject `401` with `code: INVALID_TENANT_ID` if `X-Tenant-Id` is not a valid UUID.

5. **Signature.** Recompute the HMAC. Compare to `X-Signature` in constant time (`crypto.timingSafeEqual` on equal-length buffers). Reject `401` with `code: BAD_SIGNATURE` on mismatch.

6. **Replay protection.** Maintain an in-memory LRU cache (cap: 10,000 entries) of recently-seen signatures keyed by `(X-Service-Id, X-Tenant-Id, X-Signature)`. If the signature is already in the cache, reject `401` with `code: REPLAY`. The cache entry expires after the 5-minute timestamp window plus a 1-minute grace period (so a request at the edge of the window doesn't race with a fresh replay attempt).

The verified `X-Tenant-Id` is used for **all** data access in the request. Any `tenantId` in the request body or query string is ignored.

---

## Error responses

All auth failures return `401` with a JSON body of the form:

```json
{ "code": "BAD_SIGNATURE", "message": "HMAC signature did not match" }
```

| Code | Meaning |
|---|---|
| `MISSING_AUTH_HEADERS` | One or more required headers are missing. |
| `STALE_TIMESTAMP` | `X-Timestamp` is more than 5 minutes from server time. |
| `UNKNOWN_SERVICE` | `X-Service-Id` is not `hms-bff`. |
| `INVALID_TENANT_ID` | `X-Tenant-Id` is not a valid UUID. |
| `BAD_SIGNATURE` | Recomputed HMAC does not match `X-Signature`. |
| `REPLAY` | The signature was already used in the timestamp window. |

---

## Shared secret

- **Format:** 32 random bytes (256 bits). Generated at install time by the setup script:
  ```bash
  openssl rand -hex 32 > /etc/ycare-summary/shared-secret
  chmod 0440 /etc/ycare-summary/shared-secret
  chown root:ycare-summary /etc/ycare-summary/shared-secret
  ```
- **Storage:** file on disk. The Summary Service and the HMS BFF both read it at startup.
- **Rotation:** see "Secret rotation" below.

---

## Secret rotation

The shared secret must be rotated periodically (recommended: every 90 days). The procedure:

1. **Generate a new secret** on the operator's workstation:
   ```bash
   openssl rand -hex 32 > /etc/ycare-summary/shared-secret.new
   ```

2. **Deploy as a "next" secret.** The service and the BFF support reading two secrets: the current one and the next one. During the rotation window, requests signed with either are accepted.
   - Place the new secret in `/etc/ycare-summary/shared-secret.next` (mode 0440, same owner).
   - The service and the BFF read both files at startup. A request is valid if its signature matches either the current or the next secret.

3. **Cut over.** Restart the service and the BFF. Both will load the new secret as `current` and the old secret as `next`. (Or, more simply, the rotation is atomic: the operator replaces `shared-secret` with the new content, and a 60-second grace period (see below) covers in-flight requests.)
   - **Simpler procedure:** the operator replaces `/etc/ycare-summary/shared-secret` with the new content; both the service and the BFF are restarted within 60 seconds; a 60-second "grace period" in the service accepts signatures made with the old secret (kept in process memory for that window).

4. **Cleanup.** After 60 seconds (or after the next restart), the old secret is gone from memory.

For a planned rotation, the **60-second-grace-period approach** is simpler. For an emergency rotation (suspected compromise), the operator should:
- Replace the secret file immediately
- Restart the service and BFF within 30 seconds
- Accept that in-flight requests in the 30-second window will fail with `BAD_SIGNATURE` and the client UI will retry them with the new secret

---

## Reference implementation (BFF, TypeScript)

```ts
import { createHmac, createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const SHARED_SECRET = readFileSync("/etc/ycare-summary/shared-secret", "utf8").trim();

export function signRequest(opts: {
  method: string;
  path: string;             // includes query string
  body: string | Buffer;   // raw body bytes
  tenantId: string;
  serviceId?: string;       // defaults to "hms-bff"
}): { headers: Record<string, string> } {
  const ts = Math.floor(Date.now() / 1000);
  const serviceId = opts.serviceId ?? "hms-bff";
  const bodyHash = createHash("sha256").update(opts.body ?? "").digest("hex");
  const canonical = [
    opts.method.toUpperCase(),
    opts.path,
    bodyHash,
    ts.toString(),
    serviceId,
    opts.tenantId,
  ].join("\n");
  const sig = createHmac("sha256", SHARED_SECRET).update(canonical).digest("hex");

  return {
    headers: {
      "X-Service-Id": serviceId,
      "X-Timestamp": ts.toString(),
      "X-Tenant-Id": opts.tenantId,
      "X-Signature": sig,
    },
  };
}
```

## Reference implementation (service, TypeScript)

```ts
import { createHmac, timingSafeEqual } from "node:crypto";
import LRU from "lru-cache";

const sharedSecret = readFileSync("/etc/ycare-summary/shared-secret", "utf8").trim();
const replayCache = new LRU<string, true>({ max: 10_000, ttl: 6 * 60 * 1000 }); // 6 minutes

export function verifyRequest(req: Request): { tenantId: string } | { error: string } {
  const serviceId = req.headers.get("X-Service-Id");
  const tsStr = req.headers.get("X-Timestamp");
  const tenantId = req.headers.get("X-Tenant-Id");
  const sigHex = req.headers.get("X-Signature");

  if (!serviceId || !tsStr || !tenantId || !sigHex) {
    return { error: "MISSING_AUTH_HEADERS" };
  }
  if (serviceId !== "hms-bff") return { error: "UNKNOWN_SERVICE" };
  if (!isUuid(tenantId)) return { error: "INVALID_TENANT_ID" };

  const ts = parseInt(tsStr, 10);
  if (!Number.isFinite(ts) || Math.abs(Math.floor(Date.now() / 1000) - ts) > 300) {
    return { error: "STALE_TIMESTAMP" };
  }

  // Compute expected signature
  const bodyHash = createHash("sha256").update(req.rawBody ?? "").digest("hex");
  const canonical = [
    req.method,
    req.path + req.search, // includes query string in wire order
    bodyHash,
    tsStr,
    serviceId,
    tenantId,
  ].join("\n");
  const expected = createHmac("sha256", sharedSecret).update(canonical).digest();

  // Constant-time compare
  const actual = Buffer.from(sigHex, "hex");
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    return { error: "BAD_SIGNATURE" };
  }

  // Replay check
  const replayKey = `${serviceId}:${tenantId}:${sigHex}`;
  if (replayCache.has(replayKey)) return { error: "REPLAY" };
  replayCache.set(replayKey, true);

  return { tenantId };
}
```

---

## Threat model

| Threat | Mitigation |
|---|---|
| Replay of an old request | ±5 minute timestamp window + in-memory LRU replay cache. |
| Cross-tenant forgery (a BFF for tenant A signs a request claiming tenant B) | The `TENANT_ID` is part of the signed canonical string. Changing it invalidates the signature. |
| BFF compromise (attacker has the secret) | Out of scope for v1 — once the secret leaks, all bets are off. Mitigated by short-lived secrets in v2 (RS256 JWT) if the threat is realized. |
| Bypass auth by hitting the service on a different port or interface | The service binds to `127.0.0.1` only (see `c4-deployment.md`). External traffic cannot reach it. |
| HMAC length-extension attacks | Not applicable: HMAC-SHA256 is not vulnerable to length extension. |
| Timing attack on signature compare | Constant-time compare via `crypto.timingSafeEqual`. |
