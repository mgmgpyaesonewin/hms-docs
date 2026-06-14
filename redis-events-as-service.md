# Redis for Events-as-a-Service — Developer Catch-Up

A practical reference for using Redis as the substrate behind an event-driven architecture
in YCare-HMS. Assumes you already know what Pub/Sub, streams, and queues are at a high
level and want the production-grade details.

> **Status:** Learning / catch-up. Not a commitment to ship Redis-backed events in YCare-HMS.
> The codebase currently uses `pg-boss` for background jobs; this doc covers Redis as an
> alternative or complement when we need a real event log, fan-out, and replay.

---

## 1. When Redis Makes Sense for EaaS

| Need | Redis answer |
|------|--------------|
| Sub-millisecond publish | In-memory, single-threaded command loop |
| Multiple consumption styles | Pub/Sub, Streams, Lists, Sorted Sets, Keyspace Notifications |
| Replay / event log | Streams with consumer groups |
| Scheduled / delayed events | Sorted Sets with score = epoch ms |
| Operational simplicity | One binary, well-understood ops, mature client libraries |

**Tradeoffs to be honest about:**

- Redis is **not** a fully durable log like Kafka. A single instance loses data on crash
  unless AOF is on, and even `appendfsync everysec` can drop the last second.
- For multi-tenant SaaS, key namespacing and ACLs are your responsibility.
- Memory pressure is real: streams can grow unbounded without `MAXLEN`.

**Pick Redis EaaS when:** event volume < ~10k msg/s, you need replay + fan-out, the data
is application-scoped (not compliance-critical log), and you can tolerate at-least-once
delivery with idempotent handlers.

**Pick Kafka / NATS JetStream / EventBridge when:** higher volume, multi-region, or
you need stream-replay as a compliance feature.

---

## 2. The Four Primitives

### 2.1 Pub/Sub — fire-and-forget broadcast

```
PUBLISH channel payload
SUBSCRIBE channel
```

- No persistence, no replay, no acknowledgement.
- **Use for:** cache invalidation, presence, "something changed, refresh" hints.
- **Do not use for:** anything a missed consumer must recover.

```ts
// publisher.ts
import Redis from "ioredis";
const pub = new Redis(process.env.REDIS_URL!);

export async function emitInvalidation(key: string) {
  await pub.publish("cache:invalidate", key);
}
```

```ts
// subscriber.ts — must be a long-running process
import Redis from "ioredis";
const sub = new Redis(process.env.REDIS_URL!);
sub.subscribe("cache:invalidate");
sub.on("message", (_chan, key) => {
  localCache.delete(key);
});
```

**YCare-HMS caveat:** Subscribers must live in a long-running process. The
`src/instrumentation.ts` pg-boss worker is fine. A Vercel route handler is not — the
function freezes and the subscription dies between requests.

### 2.2 Streams — the durable event log

The most important Redis EaaS primitive. An append-only log keyed by auto-generated IDs.

```bash
# Write events
XADD patient:events * type admission patientId P-42 ward ICU
XADD patient:events * type prescription patientId P-42 drug ceftriaxone

# Read everything from the start
XREAD COUNT 100 STREAMS patient:events 0

# Consumer group for multi-worker, at-least-once delivery
XGROUP CREATE patient:events billing 0 MKSTREAM
XREADGROUP GROUP billing worker-1 COUNT 10 BLOCK 5000 STREAMS patient:events >

# Acknowledge processed messages
XACK patient:events billing 1718...-0
```

**Why this matters:** Unacked messages stay in the Pending Entries List (PEL). Another
worker can reclaim them with `XPENDING` + `XCLAIM` after a timeout. This is how you get
at-least-once delivery without writing a scheduler.

**Mental model:** `XADD` + `XREADGROUP` + `XACK` = your event log. Streams are to Redis
what compacted topics are to Kafka.

```ts
// src/lib/events/streams.ts
import Redis from "ioredis";

const redis = new Redis(process.env.REDIS_URL!);

type Event = {
  type: string;
  patientId: string;
  payload: Record<string, unknown>;
};

export async function publish(stream: string, event: Event) {
  return redis.xadd(
    stream,
    "*",
    "type", event.type,
    "patientId", event.patientId,
    "payload", JSON.stringify(event.payload),
  );
}

export async function consume(
  stream: string,
  group: string,
  consumer: string,
  handler: (event: Event, id: string) => Promise<void>,
) {
  while (true) {
    const res = await redis.xreadgroup(
      "GROUP", group, consumer,
      "COUNT", 10,
      "BLOCK", 5000,
      "STREAMS", stream, ">",
    );
    if (!res) continue;

    for (const [, entries] of res) {
      for (const [id, fields] of entries) {
        const obj = Object.fromEntries(
          fields.reduce<[string, string][]>((a, _, i, arr) =>
            i % 2 === 0 ? [...a, [arr[i], arr[i + 1]]] : a, []),
        );
        try {
          await handler(
            { ...obj, payload: JSON.parse(obj.payload) } as Event,
            id,
          );
          await redis.xack(stream, group, id);
        } catch (e) {
          // Leave unacked → another consumer (or restart) picks it up
        }
      }
    }
  }
}
```

### 2.3 Lists — simple work queue

```bash
LPUSH  jobs:email "msg-1"
BRPOP jobs:email 5
```

- Reliable-ish: nothing is consumed until `BRPOP` returns, so a crash loses only the
  in-flight item.
- No multi-consumer semantics, no acks, no replay.
- **Use for:** cron-style single-worker dispatch.
- **Don't use for:** anything that needs at-least-once semantics or horizontal scale.
  Use Streams instead.

### 2.4 Sorted Sets — scheduled / delayed events

Score = epoch ms. A worker polls for due items:

```bash
ZADD scheduled 1718000000000 '{"type":"reminder","to":"P-42"}'
ZRANGEBYSCORE scheduled -inf 1718100000000 LIMIT 0 10
ZREM scheduled "<element>"
```

**Important:** `ZRANGEBYSCORE` + `ZREM` must be atomic or two workers can both pick the
same item. Wrap them in a Lua script:

```lua
-- KEYS[1] = scheduled, ARGV[1] = now
local items = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', ARGV[1], 'LIMIT', 0, 10)
for _, item in ipairs(items) do
  redis.call('ZREM', KEYS[1], item)
end
return items
```

**YCare-HMS use cases:** appointment reminders, billing retries, prescription refills.

---

## 3. Pattern → Primitive Mapping

| Pattern | Primitive | Why |
|---|---|---|
| Cache invalidation | Pub/Sub | Lossy is OK, latency matters |
| Cross-service event log | Streams | Replay + at-least-once |
| Task queue with retries | Streams + PEL reclaimer | Visibility into what's stuck |
| Scheduled jobs | Sorted Sets (or BullMQ) | Time-based dispatch |
| Rate-limit / quota | INCR + EXPIRE | Counter pattern, not really events |
| Webhook fan-out | Streams → worker → HTTP | Retry on failure |
| Audit log | Streams + `XADD MAXLEN ~ N` | Bounded, durable, queryable |
| Event sourcing | Streams as source of truth | Replay aggregates from log |

---

## 4. EaaS Architecture (Four Layers)

```
┌──────────────────────────────────────────────────────────┐
│  Producers (tRPC procedures, server actions)             │
│  emit typed events → XADD stream:* * fields...           │
└────────────────────┬─────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────┐
│  Stream + Consumer Group (per topic or per consumer)     │
│  XGROUP CREATE; XADD MAXLEN ~ 100000  (cap memory)      │
└────────────────────┬─────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────┐
│  Workers (one process per group, multiple consumers)     │
│  XREADGROUP → handler → XACK | DLQ on poison message     │
└────────────────────┬─────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────┐
│  Side effects: write to Postgres, send email, webhook    │
│  Idempotency: dedupe by event_id in your DB              │
└──────────────────────────────────────────────────────────┘
```

**For YCare-HMS specifically**, this is how it would slot in:

1. Add `ioredis` to `package.json`.
2. Create `src/lib/redis.ts` (singleton, same pattern as `src/lib/db.ts`).
3. Create `src/lib/events/` with `publish.ts`, `consume.ts`, and a typed `Event` union.
4. In `src/instrumentation.ts`, boot workers that `XREADGROUP` on registered streams
   (next to the existing pg-boss boot).
5. From tRPC procedures (e.g. admission create), call `publish("patient:events", {...})`
   after the DB transaction commits.

This coexists with pg-boss: pg-boss keeps doing job-scheduled work (stocks, billing
reconciliation), Redis Streams handle event log + fan-out + replay.

---

## 5. The Three Production Patterns You Will Write Repeatedly

### 5.1 Idempotent Handler (most important)

Consumers can re-deliver a message (crash before XACK, rebalance, XCLAIM). Handlers
**must be idempotent**.

```ts
async function handler(e: Event) {
  // Atomic "insert if not exists" using the event ID
  const claimed = await db.processedEvent.create({
    data: { id: e.id, processedAt: new Date() },
  }).catch(() => null);

  if (!claimed) return; // already processed
  await doSideEffect(e);
}
```

Use Postgres `INSERT ... ON CONFLICT DO NOTHING` for the dedupe — Redis is fast, but
your durable dedupe record should outlive Redis.

### 5.2 Dead-Letter Handling

After N retries, send to a DLQ stream so a poison message doesn't block the group:

```ts
async function handler(stream: string, group: string, e: Event) {
  const pending = await redis.xpending(stream, group, e.id);
  const attempts = pending?.[0]?.timesDelivered ?? 0;

  try {
    await doSideEffect(e);
  } catch (err) {
    if (attempts >= 5) {
      await redis.xadd("dlq:clinical", "*",
        "original", e.id,
        "error", String(err),
      );
      await redis.xack(stream, group, e.id); // ack so we move on
    }
    throw err; // leave unacked for retry
  }
}
```

### 5.3 Transactional Outbox (the production killer fix)

The classic foot-gun: write to Postgres, then `XADD` to Redis. If the app crashes
between them, the DB commits but the event is lost. Solution: **outbox table drained
by a separate process**.

```ts
// In the producer (inside the same DB transaction)
await prisma.$transaction(async (tx) => {
  await tx.admission.create({ data });
  await tx.outbox.create({
    data: {
      stream: "patient:events",
      payload: { type: "admission.created", patientId, ... },
    },
  });
});

// Drainer — separate process
setInterval(async () => {
  const pending = await prisma.outbox.findMany({
    where: { publishedAt: null },
    take: 50,
  });
  for (const row of pending) {
    await redis.xadd(row.stream, "*", ...Object.entries(row.payload));
    await prisma.outbox.update({
      where: { id: row.id },
      data: { publishedAt: new Date() },
    });
  }
}, 200);
```

Mature EaaS systems (Kafka + Debezium, NATS JetStream) automate this; on Redis you
build it yourself, but it's ~50 lines.

---

## 6. Multi-Tenancy and Namespacing

For a multi-tenant HMS like YCare, key names **must** include the tenant:

```
patient:{tenantId}:events
orders:{tenantId}:events
```

- Prevents one tenant's events leaking into another's consumers.
- Lets you scope rate-limits and stream caps per tenant.
- Pairs with Redis ACLs (`@stream` per user) for defense in depth.

`tenantId` already flows through every `authProcedure` context — pass it into
`publish()` and consume it in `consume()`.

---

## 7. Operations & Failure Modes

| Failure | Behaviour | Mitigation |
|---|---|---|
| Redis OOM | New writes fail (`OOM command not allowed`) | `MAXMEMORY` policy = `noeviction` for streams; `allkeys-lru` only for cache |
| Stream grows unbounded | Memory exhaustion | `XADD MAXLEN ~ 1000000` (approximate trim) |
| Worker crashes mid-handler | Message stays in PEL | `XPENDING` + `XCLAIM` reaper, or auto-claim with min-idle |
| Consumer group falls behind | Backpressure → slow handler | Add consumers horizontally; profile handlers |
| Network partition | Writes can split-brain if not using Sentinel/Cluster | Run Sentinel for HA; Cluster for sharding |
| At-most-once becomes "lost events" | Consumer acks before side effect | Idempotency keys + outbox |

---

## 8. Redis vs. The Alternatives (YCare-HMS context)

| Need | Pick |
|---|---|
| Sub-ms Pub/Sub, no replay | Redis Pub/Sub |
| Durable, replayable, ordered event log | Redis Streams (or Kafka if > 100k msg/s) |
| Multi-tenant SaaS with rich routing | Kafka, NATS JetStream, AWS EventBridge |
| Already on Postgres, low event volume | Postgres `LISTEN`/`NOTIFY` or `pg-boss` (we have this) |
| Schedule + retry + DLQ, Node-native | BullMQ (built on Redis) |

**YCare-HMS rule of thumb:**

- Background jobs, scheduled work, retries → keep using **pg-boss** (already in place).
- Event log + multi-consumer fan-out + replay → **Redis Streams** if < 10k msg/s,
  Kafka above that.
- Cache invalidation, presence → **Redis Pub/Sub**.

---

## 9. Verifiable Success Criteria

Before shipping a Redis EaaS, define three numbers:

- **p99 publish latency:** target < 5 ms (single-region, 1 KB payload).
- **p99 handler latency:** target < 200 ms (most side effects).
- **At-least-once delivery rate:** target ≥ 99.99% (idempotent handlers absorb duplicates).

Measure with:

- `redis-cli --latency` for raw Redis health.
- OpenTelemetry spans on `XADD` and handler end.
- A "lost event" detector: count(published) − count(acked) − count(in PEL) − count(in DLQ)
  should be zero.

---

## 10. Hands-On: Try It Locally

```bash
docker run -p 6379:6379 redis:7-alpine
redis-cli

# Inside redis-cli
XADD test * type hello who world
XLEN test
XRANGE test - +
XREAD COUNT 10 STREAMS test 0
```

Then in a Next.js project:

```bash
npm install ioredis
```

```ts
// src/lib/redis.ts
import Redis from "ioredis";

const globalForRedis = globalThis as unknown as { redis?: Redis };

export const redis =
  globalForRedis.redis ??
  new Redis(process.env.REDIS_URL ?? "redis://localhost:6379");

if (process.env.NODE_ENV !== "production") globalForRedis.redis = redis;
```

Boot a worker in `src/instrumentation.ts`:

```ts
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    const { consume } = await import("./lib/events/consume");
    await consume("test", "dev-group", "w-1", async (e) => {
      console.log("got event:", e);
    });
  }
}
```

---

## 11. Further Reading

- [Redis Streams docs](https://redis.io/docs/latest/develop/data-types/streams/) — short,
  well-written, covers `XADD`, `XREADGROUP`, `XCLAIM`, `XPENDING`.
- [Redis Pub/Sub docs](https://redis.io/docs/latest/develop/pubsub/) — channels vs
  patterns, sharding constraints.
- [BullMQ](https://docs.bullmq.io/) — if your need is "schedule jobs with retries" rather
  than "durable event log", BullMQ is built on Redis and gives you cron + DLQ + UI
  without writing the consumer loop.
- [Debezium outbox pattern](https://debezium.io/documentation/reference/stable/transformations/outbox-event-router.html)
  — same problem, Kafka-flavoured solution, useful comparison.

---

## 12. Open Questions for YCare-HMS

If/when we move to add Redis Streams alongside pg-boss, decisions to make:

1. **Where do producers live?** tRPC procedures only, or also background jobs that
   emit "I finished" events?
2. **Stream cap:** `MAXLEN ~` of 100k? 1M? Per tenant or global?
3. **Idempotency table:** new `ProcessedEvent` model in Prisma, or reuse an existing
   audit table?
4. **Multi-region:** single Redis cluster, or per-region with replication?
5. **What replaces the current direct DB writes between modules?** E.g. OPD writing to
   pharmacy — does that become an event, or stay synchronous for now?

These are not blockers for the catch-up doc, but worth tracking before any
implementation work.
