# ADR 0002: Service decomposition — one codebase, two systemd units

- **Status:** Accepted
- **Section in brief:** 7.2

## Context

The Summary Service has two distinct roles: an HTTP API (serves admin reads and status / adjustment updates) and a long-running inbox worker (polls the outbox, creates CFIs, updates Redis). The two roles have different failure modes, different resource profiles (the API is request/response; the worker is steady-state I/O), and different restart policies.

## Options considered

- **(a) One codebase, two systemd units** — same Node.js process binary, started with `--mode=api` or `--mode=worker`. Two separate services registered with systemd.
- **(b) Two completely separate services** — separate codebases, separate `package.json`, separate deployment artifacts.

## Decision

**(a) One codebase, two systemd units.**

## Rationale

- The two roles share the Prisma client, the Redis client, the schema types, the Zod validators, and the audit-logger code. Duplicating these in two codebases is a maintenance burden.
- systemd makes it easy to run "the same binary in two modes" without code duplication: `ExecStart=/usr/local/bin/ycare-summary --mode=worker` vs `--mode=api`. Each unit has its own restart policy, its own log stream, its own resource limits.
- Failure isolation: an API crash does not affect the worker, and vice versa. systemd restarts each independently.
- Resource limits per role: the API can be capped at 512 MB / 1 vCPU; the worker at 256 MB / 0.5 vCPU. Different limits per unit.

## Consequences

- One `package.json`, one TypeScript build, one Docker image (if we ever go to containers — for now it's a bare-metal systemd deployment).
- Two systemd unit files: `ycare-summary-api.service` and `ycare-summary-worker.service` (see `ops/`).
- One env file shared by both, with mode-specific overrides if needed.
- The `mode` flag is read at startup; the rest of the code branches on it. Each role has a single `main()` entry point.
- Code structure:
  ```
  src/
    api/           ← Express routes, used by --mode=api
    worker/        ← outbox poller, used by --mode=worker
    shared/        ← Prisma client, Redis client, types, Zod schemas
    lib/           ← computePayoutAmount, audit log, etc.
  ```

## Related

- [[0001-trigger-mechanism|ADR 0001]] (Trigger mechanism)
- Section 3.4, 3.5 in the brief
