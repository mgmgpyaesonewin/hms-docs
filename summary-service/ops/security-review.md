# Security Review

A STRIDE threat model for the Summary Service on the on-prem deployment. Plus secret handling, file permissions, network isolation, and an attacker-scenario analysis.

---

## STRIDE summary

| Category | Threat | Mitigation |
|---|---|---|
| **Spoofing** | A non-BFF process calls the Summary Service API and pretends to be the BFF. | The service binds to `127.0.0.1` only. Even with shell access, an attacker would need the HMAC secret to forge a request. |
| **Spoofing** | A BFF for tenant A signs a request claiming tenant B. | The `X-Tenant-Id` is part of the HMAC canonical string. Changing it invalidates the signature. |
| **Tampering** | A request body is modified in transit. | The body hash is part of the HMAC canonical string. Tampering invalidates the signature. |
| **Tampering** | A HMAC header is replayed. | The 5-minute timestamp window + in-memory LRU replay cache. |
| **Repudiation** | A user denies making a status change. | Audit tables `consultation_fees_invoice_status_changes` and `consultation_fees_invoice_adjustments` record `changed_by_id` and `changed_at`. Indefinite retention. |
| **Information disclosure** | Cross-tenant data leak. | Defense in depth at 4 layers (ADR 0007). Tenant-scoped Postgres queries (Prisma extension), tenant-prefixed Redis keys, `tenantId` on every log line. |
| **Information disclosure** | Logs leak sensitive data. | `pino` `redact` paths exclude `X-Signature`, `authorization`, and any `hmacSecret` field. No patient name, doctor name, or amount is logged at `info` level. |
| **Information disclosure** | Disk is stolen (theft of the on-prem server). | LUKS full-disk encryption is the hospital's existing posture; the Summary Service does not weaken it. The HMAC secret is on disk; acceptable risk given the physical security. |
| **Denial of service** | Attacker floods the API with requests. | The API binds to `127.0.0.1`; the only caller is the BFF. No external DoS surface. Internal DoS (a buggy BFF) is mitigated by request timeout (10s) and a per-IP rate limit (100 req/s, but only one IP — 127.0.0.1). |
| **Denial of service** | Worker falls behind on event processing. | The stale-claim reaper resets stuck `IN_PROGRESS` rows to `PENDING` after 5 minutes; multiple workers can run in parallel (`FOR UPDATE SKIP LOCKED` ensures no double-processing) — one per host, or one per pod in a future K8s deploy. |
| **Denial of service** | Postgres or Redis is down. | API degrades to bypass mode (Redis down) or 503 (Postgres down). Worker logs and retries. systemd does not page on transient issues. |
| **Elevation of privilege** | An attacker with shell access reads the HMAC secret. | The secret is `0440` owned by `root:ycare-summary`. Only root or the service user can read it. The attacker with shell access as the service user can read the secret, but they could also just call the API directly with the secret — there is no privilege to elevate. |
| **Elevation of privilege** | The service is exploited and code runs as `ycare-summary`. | systemd hardening (`NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, `RestrictAddressFamilies`, `SystemCallArchitectures=native`) limits the blast radius. The service cannot write outside `/var/log/ycare-summary` and `/var/lib/ycare-summary`. |

---

## Attacker scenarios

### Scenario 1: External attacker on the hospital LAN

**Capability:** the attacker has a laptop plugged into the same LAN as the hospital server. They can `nmap` the server and probe open ports.

**What they can reach:**
- Port 3000 (Next.js HMS) — they can log in if they have valid credentials. Out of scope for this review.
- Anything else? **No.** The Summary Service, Postgres, and Redis all bind to `127.0.0.1` only. The only LAN-exposed port is 3000.

**Verdict:** no attack surface on the Summary Service.

### Scenario 2: Attacker with shell access on the host (non-root)

**Capability:** the attacker has SSH access to the hospital server as a non-root user (e.g., a compromised admin account, or a developer with a low-privilege account).

**What they can do:**
- Read `/etc/ycare-summary/env` if it's `0640` and they're in the `ycare-summary` group. Otherwise no.
- Read `/var/log/ycare-summary/*.log`. Logs are scrubbed of secrets; patient names and amounts are at `info` level but not at `debug`. Acceptable disclosure.
- `ps` to see the running processes and their env vars. systemd's `ProtectSystem=strict` means env vars are loaded from a file, not `/proc/<pid>/environ`.
- Cannot read the HMAC secret (different group, mode `0440`).
- Cannot connect to Postgres (peer auth requires the `ycare-summary` user) or Redis (localhost-only, no password, but the attacker is already on the host, so this is moot).

**Verdict:** limited blast radius. Logs and config are the only leakage; both are scrubbed or mode-restricted.

### Scenario 3: Attacker with root shell access

**Capability:** the attacker has root on the hospital server. They can do anything.

**What they can do:**
- Read the HMAC secret.
- Read the Postgres data.
- Read the Redis data.
- Modify the running service binary.
- Replace the systemd unit files.

**Verdict:** game over. The hospital's existing physical security and root-account hygiene is the only defense. This is the standard "if you have root, you can do anything" situation and is not a Summary-Service-specific risk.

### Scenario 4: BFF compromise

**Capability:** an attacker has compromised the HMS Next.js BFF process and can call the Summary Service with valid HMAC signatures.

**What they can do:**
- Read CFIs for the tenants the BFF has access to.
- Change statuses and adjustments.
- Forge any write that the BFF can do.

**What they cannot do:**
- Access a tenant the BFF doesn't have credentials for (the `X-Tenant-Id` is verified).
- Read the HMAC secret (the BFF doesn't store it on disk in the same way — it reads from a file mode `0440` owned by a different group).

**Mitigation:** short-lived secrets, RS256 service JWT, and per-tenant key isolation are v2 features. For v1, the BFF compromise is a high-impact event that requires BFF-level security hardening (out of scope for this review).

### Scenario 5: Outbox compromise (attacker writes to `event_outbox`)

**Capability:** an attacker can write to the `event_outbox` table in Postgres.

**What they can do:**
- Insert fake events. The worker would process them and try to create a CFI. The CFI insert would fail on the `event_id` UNIQUE constraint (the `event_id` from the fake event is unlikely to collide with a real one), and the row would land in `DEAD` after 5 retries.
- Or the fake `event_id` happens to be unique, the CFI insert succeeds, but the consultation fee is computed from the OPD billing line items (which the attacker doesn't control, since the OPD billing is a separate row in `opd_billings`). The CFI is for a real OPD invoice with a real fee.

**Verdict:** limited impact. The worst case is a fake CFI for a real OPD invoice. The CFI shows up in the admin summary; an admin notices a duplicate (the auto-created CFI from the original OPD billing path would have a different `event_id` but conflict on `(tenant_id, opd_invoice_id)` — so the second insert fails at the unique key, not just the `event_id` key).

**Mitigation:** the attacker needs DB write access, which means they have root on the host (scenario 3) or a credential that grants INSERT on `event_outbox` (which the service user has, but no other role). Defense in depth: HMS service user has INSERT-only on `event_outbox`; the Summary Service service user has SELECT + UPDATE on `event_outbox` (no INSERT). This way, an attacker who compromises one side cannot forge events on the other.

---

## Secret handling

| Secret | Storage | Access | Rotation |
|---|---|---|---|
| HMAC shared secret | `/etc/ycare-summary/shared-secret`, mode `0440`, owner `root:ycare-summary` | Read by the service at startup; read by the BFF at startup. Never logged. | Every 90 days. See `api/hmac-auth.md` for the procedure. |
| Postgres password | Part of `DATABASE_URL` in `/etc/ycare-summary/env`, mode `0640`, owner `root:ycare-summary` | Read by the service. Never logged. | Every 180 days, per hospital policy. |
| `ALERT_WEBHOOK_URL` | _Removed in v1 — no automated alerting._ | _n/a_ | _n/a_ |

**All secrets are excluded from logs via the `pino` `redact` paths in `src/lib/logger.ts`.**

---

## File permissions summary

| Path | Mode | Owner | Group | Notes |
|---|---|---|---|---|
| `/opt/ycare-summary/` | 0750 | root | ycare-summary | App install dir, read-only at runtime. |
| `/opt/ycare-summary/dist/` | 0750 | root | ycare-summary | Compiled JS. |
| `/etc/ycare-summary/` | 0750 | root | ycare-summary | Config dir. |
| `/etc/ycare-summary/env` | 0640 | root | ycare-summary | Env vars (DATABASE_URL, etc.). |
| `/etc/ycare-summary/shared-secret` | 0440 | root | ycare-summary | HMAC secret. |
| `/var/log/ycare-summary/` | 0750 | ycare-summary | ycare-summary | Log files. |
| `/var/log/ycare-summary/*.log` | 0640 | ycare-summary | ycare-summary | Per-rotation. |
| `/var/lib/ycare-summary/` | 0750 | ycare-summary | ycare-summary | Runtime state (PID files, etc.). |

---

## Network isolation

The Summary Service, Postgres, and Redis bind to `127.0.0.1` only. The only LAN-exposed port is 3000 (Next.js HMS). The hospital's firewall should also block inbound traffic from outside the hospital LAN.

**On the host:**
```bash
# Verify the Summary Service binds to 127.0.0.1 only
ss -tlnp | grep :4000
# Expected: 127.0.0.1:4000

# Verify Redis binds to 127.0.0.1 only
ss -tlnp | grep :6379
# Expected: 127.0.0.1:6379

# Verify Postgres binds to 127.0.0.1 only
ss -tlnp | grep :5432
# Expected: 127.0.0.1:5432
```

If any of these show `0.0.0.0` or `::`, the configuration is wrong and the system is exposed.

---

## Systemd hardening

Both `ycare-summary-api.service` and `ycare-summary-worker.service` have:

- `NoNewPrivileges=true` — the process cannot gain new privileges.
- `ProtectSystem=strict` — the filesystem is mounted read-only except for `/dev`, `/proc`, `/sys`.
- `ProtectHome=true` — `/home`, `/root`, `/run/user` are inaccessible.
- `PrivateTmp=true` — the process gets its own `/tmp`.
- `PrivateDevices=true` — the process cannot access raw devices.
- `ProtectKernelTunables=true`, `ProtectKernelModules=true`, `ProtectControlGroups=true` — kernel surface is locked down.
- `RestrictSUIDSGID=true` — SUID/SGID bits are ignored.
- `RestrictNamespaces=true` — the process cannot create new namespaces.
- `LockPersonality=true` — the process cannot change its execution domain.
- `RestrictRealtime=true` — no realtime scheduling.
- `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6` — only Unix sockets, IPv4, and IPv6. No weird address families.
- `SystemCallArchitectures=native` — only the native syscall ABI; no 32-bit emulation.
- `MemoryDenyWriteExecute=true` (in the worker, optional) — prevents JIT spraying.

The service can write only to:
- `/var/log/ycare-summary/` (StandardOutput/StandardError)
- `/run/ycare-summary/` (RuntimeDirectory)
- `/var/lib/ycare-summary/` (StateDirectory)

---

## Compliance notes

- **HIPAA-equivalent / local health-data regulations:** the Summary Service handles patient identifiers (patient_id, patient_name) and amounts. The audit tables provide the "who accessed what" trail. Log retention is 90 days for app logs and indefinite for DB audit (matches the hospital's existing posture).
- **PCI-DSS:** the Summary Service does not handle payment card data. The CFI tracks consultation fee amounts, but no card numbers, CVVs, or bank accounts. Out of scope.
- **Right to erasure:** if a patient requests erasure, the `consultation_fees_invoices.patient_name` field would need to be redacted. The audit tables would also need to be updated to remove identifying info. The current design does not provide an erasure flow; this is a v2 feature.

---

## Things to revisit

- **Short-lived service JWTs (RS256).** Currently the HMAC is a long-lived shared secret. A compromise of the secret requires manual rotation. v2 should move to short-lived JWTs (5-minute TTL) with key rotation via JWKS.
- **Rate limiting on the API.** Currently a compromised BFF can hammer the API. A per-API-key rate limit (e.g., 100 req/s) would mitigate.
- **Audit log integrity.** The audit tables can be modified by anyone with DB write access. A hash chain or external append-only log would prevent tampering. v2.
