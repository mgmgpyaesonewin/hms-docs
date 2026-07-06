Add a Kubernetes health route to `hms-app` (Next.js 15 App Router + Prisma).

**Background**

- Stack: Next.js 15 App Router, Prisma, custom session auth (Argon2).
- K8s probes are unauthenticated calls from the kubelet. The route must bypass
the session middleware (App Router Route Handlers are public by default).
- Response-shape reference: `hms-summary-service/src/http/routes/health.routes.ts`
(existing `GET /healthz` returning `{status, db, redis}`).

**Build TWO distinct routes — do not collapse into one**

1. `GET /healthz/live` — liveness. Returns 200 if the Node process can respond.
    MUST NOT touch Prisma or any external dependency. Failure here means
    "restart the pod."
2. `GET /healthz/ready` — readiness. Calls `prisma.$queryRaw\`SELECT 1\`` with a
    2s timeout. Returns 200 when DB is reachable, 503 when not. Failure here
    means "remove pod from Service endpoints" — do NOT restart.

**File layout**

- `src/app/healthz/live/route.ts`
- `src/app/healthz/ready/route.ts`
- Do NOT register in tRPC. Do NOT call `authActionClient`.

**Response shape**
Healthy:

```json
{ "status": "ok", "checks": { "db": "up" }, "uptimeSec": 12345 }
Unhealthy (503):
{ "status": "degraded", "checks": { "db": "down" } }
Never include stack traces or Prisma error messages in the body.

Implementation notes
- Use the existing Prisma client (@/lib/prisma or wherever it lives).
- Wrap the DB call in Promise.race with a 2s setTimeout reject so a hung
DB cannot stall the probe past k8s timeoutSeconds.
- uptimeSec from process.uptime().

Suggested k8s probe config
livenessProbe:
httpGet: { path: /healthz/live, port: 3000 }
initialDelaySeconds: 30
periodSeconds: 10
timeoutSeconds: 1
failureThreshold: 3
readinessProbe:
httpGet: { path: /healthz/ready, port: 3000 }
initialDelaySeconds: 5
periodSeconds: 5
timeoutSeconds: 2
failureThreshold: 2

Tests (jest, in __tests__/healthz/)
- live returns 200 even when Prisma is broken.
- ready returns 200 + db:"up" on a healthy Prisma mock.
- ready returns 503 + db:"down" when $queryRaw throws.
- ready returns 503 within ~2.5s when Prisma hangs >2s.

Out of scope
- Redis checks (hms-app doesn't use Redis; that's the summary-service).
- Prometheus/StatsD metrics.
- Auth on these routes (must stay public).

Definition of done
- npm run tsc and npm run lint pass.
- npm test covers the four cases above.
- curl localhost:3000/healthz/live and /ready return the right shape.
