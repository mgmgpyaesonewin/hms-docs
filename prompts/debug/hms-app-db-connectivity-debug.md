# NON-NEGOTIABLE RULES

1. **Triage first, investigate second.** Before opening any file, extract
   the structured signal from the log (see §SIGNAL EXTRACTION). Most of
   the noise in a raw error log is duplicate stack frames — the
   interesting bit is usually one or two lines.
2. **Distinguish the three failure classes** before forming a hypothesis:
   - **ECONNREFUSED** — nothing listening on the port. Wrong host/port,
     firewall silently dropping, or RDS stopped.
   - **ECONNRESET** — TCP connection was open then RST'd. SG/NACL drop
     after handshake, RDS failover, server-side close, or stale pooled
     connection.
   - **P1001 (`Can't reach database server`)** — Prisma's umbrella error.
     Underneath it is almost always one of the above two, plus DNS or
     route failures.
   - **Auth failures** look different (P1000 / `password authentication
     failed`). They are out of scope for this prompt.
3. **Hypothesis ordering matters.** Network-path failures (SG / NACL /
   route table / RDS state) account for ~90% of these incidents. Code
   bugs in Prisma/pg-boss are rare and should be considered last.
4. **Read-only by default.** Do not edit code, infra, or RDS settings
   without explicit approval from the caller. Output is a diagnosis +
   proposed fix.
5. **No live prod probing without a stated change window.** All network
   and AWS checks should be read-only (`describe-*`, `get-*`).

---

# INPUT CONTRACT — what the caller must provide

Before starting, confirm you have:

| Input | Example | Why it matters |
| --- | --- | --- |
| Raw error log | (paste or path) | Source of truth for the signal |
| Environment | `dev` / `staging` / `prod` / `local` | Determines which checks are valid |
| HMS app runtime | `ecs-fargate` / `ec2` / `docker-compose` / `lambda` | Determines network path |
| HMS app region | `ap-south-1` | Must match RDS region |
| RDS endpoint | `ycare-dev.ciaklsje1ynv.ap-south-1.rds.amazonaws.com:5432` | Distinguishes endpoint-level vs network-level failures |
| When it started | ISO timestamp or "since deploy X" | Narrows cause to deploy, AWS event, or config drift |
| HMS app reachability | "HMS app is up but DB calls fail" / "HMS app is fully down" / "intermittent" | Distinguishes partial vs total outage |
| Recent changes | last deploy, last infra change, last IAM/SG edit | Most incidents correlate with a recent change |

If any of these are missing, ask. Do not guess the environment.

---

# SIGNAL EXTRACTION

Before forming hypotheses, parse the raw log into a one-line summary.
Template:

```
Failed operation: <prisma.X.create() | pg-boss init | ...>
Prisma code:      <P1001 | P1000 | P1017 | ...>     (or "n/a — pg-boss")
Underlying code:  <ECONNRESET | ECONNREFUSED | ETIMEDOUT | ENOTFOUND | ...>
Target endpoint:  <host:port>
First seen:       <ISO timestamp>
Last seen:        <ISO timestamp>
Frequency:        <once | sporadic | continuous>
Caller stack:     <file:line — short>
Container path:   <yes/no — e.g. /app/node_modules/...>
Prisma version:   <e.g. 6.0.1>
pg-boss version:  <if present>
```

For the example log this prompt was built around, the extraction is:

```
Failed operation: prisma.logs.create() (and pg-boss initPgBossLogger)
Prisma code:      P1001
Underlying code:  ECONNRESET (4× in 6s, then again 90s later)
Target endpoint:  ycare-dev.ciaklsje1ynv.ap-south-1.rds.amazonaws.com:5432
First seen:       2026-06-22T04:41:05.034Z
Last seen:        2026-06-22T04:42:42.686Z
Frequency:        continuous
Caller stack:     prisma.logs.create (logger is trying to write its own failure)
Container path:   yes — /app/node_modules/@prisma/client/runtime/library.js
Prisma version:   6.0.1
pg-boss version:  (not stated — confirm from hms-app/package.json)
```

The two facts that immediately narrow the search:

1. **`/app/node_modules/...`** → running inside a Docker container, not
   on the host. Rules out "is Postgres running locally?" type checks.
2. **`prisma.logs.create()` failing while the logger is *trying to log*
   its own failure** → classic symptom of a Prisma client whose
   underlying pool has zero live connections. Don't read it as "the
   logs table is broken" — read it as "we cannot reach the DB at all."

---

# HYPOTHESIS TREE (priority order)

Investigate in this order. Stop as soon as one is confirmed.

## H1 — Network path blocked (most common, ~50% of incidents)
- Security group on RDS does not allow port 5432 from the container's
  CIDR (or its security group, if SG-to-SG reference).
- NACL on either side denies ephemeral return traffic (NACLs are
  stateless — easy to break).
- Route table: container subnet has no route to the RDS subnet
  (private subnet without NAT/IGW, or VPC peering broken).
- RDS is in a VPC the HMS app cannot reach.

## H2 — RDS instance state (next ~25%)
- Instance is `stopped`, `stopping`, `rebooting`, or `incompatible-parameters`.
- Instance is mid-failover (Multi-AZ). During failover, existing
  connections get RST'd → ECONNRESET spike that resolves within ~60s.
- Maintenance window applied a reboot or parameter change.
- Storage full → RDS rejecting new connections.

## H3 — Endpoint / DNS (next ~10%)
- RDS endpoint was rotated (rare, but happens after a restore-from-snapshot).
- Container DNS resolution broken (coreDNS down, `/etc/resolv.conf`
  misconfigured in the image).
- Private hosted zone missing in the container's VPC.

## H4 — Auth / credentials (~10%)
- Password rotated in Secrets Manager / Parameter Store but the
  running container still holds the old value.
- IAM token expired (if using `?awsiamplugin=1` in DATABASE_URL).
- These usually surface as `P1000`, not `P1001`, but check anyway.

## H5 — App-side config drift (~5%)
- `DATABASE_URL` in the deployed container's env differs from `.env.example`.
- Recent Prisma upgrade introduced a connection-string incompatibility
  (Prisma 6.x added stricter `sslmode` defaults).
- `pg-boss` schema missing from the DB (would surface as a Prisma
  *operation* error, not ECONNRESET — but worth a glance).

## H6 — Library bug (rare, <1%)
- Known regressions in `prisma@6.0.1` or `pg-boss@<ver>`. Only consider
  after H1–H5 are ruled out.

---

# INVESTIGATION PLAYBOOK

Run the phases in order. Each phase is read-only.

## Phase 1 — Confirm scope (≤ 2 min)

1. Is the HMS app generally up, or fully down?
   - `curl -fsS https://<env-host>/api/health` or the equivalent
     health route. A 200 with a DB-dependent response means "app up,
     DB blocked." A 5xx on a non-DB route means something else is
     broken.
2. Is the failure intermittent or total?
   - One ECONNRESET in 10 minutes = transient (probably failover).
   - 100% failure rate for >2 minutes = systemic.
3. Did anything change in the last 24h?
   - Last deploy, last SG edit, last RDS parameter change, AWS
     Health Dashboard event.

## Phase 2 — RDS instance state (≤ 2 min)

Read-only AWS checks. Replace `<rds-id>` with the identifier from the
endpoint's prefix (`ycare-dev` → likely DB identifier `ycare-dev`).

```bash
aws rds describe-db-instances \
  --db-instance-identifier <rds-id> \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone,SubnetGroup:DBSubnetGroup.DBSubnetGroupName,ParameterGroup:DBParameterGroups[0].DBParameterGroupName,Endpoint:Endpoint}'

aws rds describe-events \
  --source-type db-instance --source-identifier <rds-id> \
  --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%S) \
  --query 'Events[].{Date:Date,Msg:Message}'
```

Expected state for a healthy instance: `available`, Multi-AZ yes,
endpoint matches the URL in the log.

## Phase 3 — Network reachability from inside the container (≤ 5 min)

If you have shell/exec access to a running HMS app container:

```bash
# DNS resolves?
nslookup ycare-dev.ciaklsje1ynv.ap-south-1.rds.amazonaws.com
# or
dig +short ycare-dev.ciaklsje1ynv.ap-south-1.rds.amazonaws.com

# TCP reachable? (Ctrl-C after a few seconds; success prints "Connected")
nc -vz ycare-dev.ciaklsje1ynv.ap-south-1.rds.amazonaws.com 5432

# SSL handshake works? (this is what Prisma actually does)
openssl s_client -connect ycare-dev.ciaklsje1ynv.ap-south-1.rds.amazonaws.com:5432 -starttls postgres </dev/null 2>&1 | head -20
```

If you don't have container exec, run the same from a debug pod in
the same VPC/subnet (e.g. `amazon/aws-cli` in a Fargate task with the
same SG as HMS app).

## Phase 4 — Security groups (≤ 5 min)

```bash
# Find the RDS instance's SG
aws rds describe-db-instances --db-instance-identifier <rds-id> \
  --query 'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId' --output text

# Inspect ingress rules — looking for a rule allowing 5432 from the HMS SG
aws ec2 describe-security-groups --group-ids <rds-sg-id> \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`5432`].{Proto:IpProtocol,From:FromPort,To:ToPort,SGs:UserIdGroupPairs,IPs:IpRanges}'

# What's the HMS app's SG?
# (from the ECS service / EC2 instance / docker-compose file)
```

Common findings:
- SG allows `0.0.0.0/0` — fine but worth tightening.
- SG allows a specific CIDR that no longer matches the container
  subnet (after a subnet resize or a refactor to a new VPC).
- SG-to-SG reference points at the wrong SG (typo after a rename).
- SG has the right inbound rule but the **outbound** rule on the
  container side is missing.

## Phase 5 — NACLs and route tables (only if H1 unconfirmed)

Only relevant if Phases 2–4 didn't pinpoint the issue.

```bash
# Find the subnet the HMS container runs in
# Find the NACL attached to that subnet and to the RDS subnet
# Check for explicit DENY rules
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=<hms-subnet-id>" \
  --query 'NetworkAcls[0].Entries[?RuleAction==`deny`]'
```

## Phase 6 — App-side checks (last)

Only after network and RDS state are confirmed healthy.

1. Compare `DATABASE_URL` in the running container env vs the expected
   value in `.env.example` / parameter store. Truncated values are a
   common cause.
2. Look at the most recent commits that touched:
   - `hms-app/prisma/schema.prisma`
   - `hms-app/src/lib/pg-boss*` (or wherever pg-boss is initialized)
   - `hms-app/Dockerfile` (base image, ENV defaults)
   - `infra/` (compose files, Terraform, CDK)
3. Check if `pg-boss` schema exists in the DB:
   ```sql
   SELECT schema_name FROM information_schema.schemata
    WHERE schema_name = 'pgboss';
   ```
4. Confirm Prisma version:
   ```bash
   grep '"@prisma/client"' hms-app/package.json
   grep '"prisma"'        hms-app/package.json
   ```

---

# OUTPUT FORMAT

Respond in this exact shape. No prose before section 1.

```
## 1. Root Cause
<one sentence, naming the specific failure mode and where it lives>

## 2. Evidence
- <bullet> — <what you found and where> (file path, log line, AWS output, command)
- ...

## 3. Hypotheses Ruled Out
- <H#> — <one-line reason> (e.g. "H4 auth: error code is P1001, not P1000")

## 4. Proposed Fix
<minimal, reversible change. Include exact command(s) or file edit(s).
  State the blast radius and the rollback step.>

## 5. Verification Plan
- <command or check that proves the fix worked>
- <command or check that proves no regression>

## 6. Follow-ups (optional)
- <preventive measure, e.g. "add a /healthz route that pings RDS and page on P1001">

## 7. Confidence
<low | medium | high> — <one line explaining what would raise confidence>
```

---

# CONSTRAINTS

- **Read-only by default.** Do not run `aws rds modify-db-instance`,
  `aws ec2 revoke-security-group-ingress`, or `kubectl rollout restart`
  without explicit approval.
- **Do not paste the full `DATABASE_URL` into chat.** Mask the password.
- **Do not assume dev == prod.** Re-confirm which environment before
  running any check.
- **Do not open a fix PR** based on this prompt. Diagnosis only.
- **Respect on-prem prod access.** If the production host is on-prem
  (not AWS), `aws rds` and `aws ec2` calls are wrong — use the
  on-prem equivalents and document them in §2.

---

# EXIT CONDITIONS

End the response when one of these is true:

1. **Root cause confirmed.** Present §1–§5 above and stop. Wait for
   approval before applying any fix.
2. **Root cause is in shared infra (RDS, VPC, SG, NACL).** Hand off to
   the platform / infra team with the full §2 evidence packet.
3. **Inconclusive after Phases 1–4.** List the next two hypotheses
   you would investigate and the specific data needed to confirm or
   rule each out (e.g. "need exec into a container in subnet X to run
   `nc -vz`").

Do not start Phase 5+ without explicit caller approval — NACL and
route-table spelunking can mislead if you're looking at the wrong
VPC.

---

# QUICK-REFERENCE: PHASE → CHECK

| Phase | Asks                                  | If you can't do it  |
| ----- | ------------------------------------- | ------------------- |
| 1     | Is HMS app up? Continuous or bursty?  | Curl the health route; check CloudWatch / ECS metrics |
| 2     | Is the RDS instance `available`?      | Skip if production is on-prem — use the runbook |
| 3     | Can the container reach the endpoint? | Run from a debug pod in the same subnet/SG |
| 4     | Does the SG allow 5432 from the app?  | Read the Terraform / CDK / compose file the SG was declared in |
| 5     | NACL / route table                    | Requires VPC flow logs or `describe-network-acls` access |
| 6     | App config / schema / library version | `git log` + `package.json` + a read-only DB session |
