# Summary Service API — End-to-end Test Report

- **Generated:** 2026-06-14T11:52:01Z
- **API base:** http://localhost:4000
- **Test data:** 2 UNPAID CFIs in the dev DB (from earlier end-to-end worker tests)
  - CFI 1: `019ec55a-d656-72f0-ae65-c8e474905518` — tenant `00000000-0000-0000-0000-000000000001`, amount 3000.00
  - CFI 2: `019ec570-f8a3-7360-8d5f-50583c9328d8` — tenant `00000000-0000-0000-0000-000000000003`, amount 245000.00

Auth: **none in v1.** The service binds to `127.0.0.1` and trusts the BFF. No
`X-Signature` / `X-Timestamp` / `X-Service-Id` / `X-Tenant-Id` headers are
required to call any endpoint. (Auth is a v2 follow-up.)

---

## Section 0 — State reset (preflight)

The script mutates the CFIs (PATCH, POST adjustment), so to be re-runnable
it snaps the test data back to a clean baseline before each run. The
following SQL was executed before the tests below:

```sql
-- Reset the two pre-existing test CFIs
UPDATE consultation_fees_invoices
   SET status='UNPAID', version=1, paid_at=NULL, voided_at=NULL,
       adjustment=0, payout_amount=amount, updated_at=now()
 WHERE id IN ('019ec55a-d656-72f0-ae65-c8e474905518'::uuid, '019ec570-f8a3-7360-8d5f-50583c9328d8'::uuid);
DELETE FROM consultation_fees_invoice_status_changes;
DELETE FROM consultation_fees_invoice_adjustments;

-- Drop any CFIs created by a previous run's section-4 setup
DELETE FROM consultation_fees_invoices
 WHERE id NOT IN ('019ec55a-d656-72f0-ae65-c8e474905518'::uuid, '019ec570-f8a3-7360-8d5f-50583c9328d8'::uuid);

-- Wipe the per-tenant per-day Redis aggregate keys touched by tests
DEL summary:consultation_fees:00000000-0000-0000-0000-000000000001:2026-06-14:all
DEL summary:consultation_fees:00000000-0000-0000-0000-000000000003:2026-06-13:all
DEL summary:consultation_fees:00000000-0000-0000-0000-000000000004:2026-06-13:all
```

**CFI rows after reset:** 3

---


## Section 2 — Read flow (happy path)



### List CFIs (tenant 1, status=UNPAID)

Tenant 1 should see only its own CFIs; filtering by status=UNPAID should narrow to unpaid rows.

**Request:**

```http
GET /consultation-fees-invoices?status=UNPAID&limit=5 HTTP/1.1
Host: localhost:4000
Content-Type: application/json
```

**Response:**

**Status:** 200

```json
{
    "items": [],
    "nextCursor": null
}
```



### List CFIs (tenant 3, status=UNPAID)

Tenant 3 should see only its own CFIs.

**Request:**

```http
GET /consultation-fees-invoices?status=UNPAID&limit=5 HTTP/1.1
Host: localhost:4000
Content-Type: application/json
```

**Response:**

**Status:** 200

```json
{
    "items": [],
    "nextCursor": null
}
```



### List CFIs (tenant 3 listing — must not include tenant 1's CFI)

Tenant 3 listing should not include tenant 1's `019ec55a-d656-72f0-ae65-c8e474905518`.

**Request:**

```http
GET /consultation-fees-invoices?limit=10 HTTP/1.1
Host: localhost:4000
Content-Type: application/json
```

**Response:**

**Status:** 200

```json
{
    "items": [
        {
            "id": "019ec570-f8a3-7360-8d5f-50583c9328d8",
            "tenantId": "00000000-0000-0000-0000-000000000003",
            "opdInvoiceId": "019ec17c-2e2f-7e12-bc7f-55dbb98c68df",
            "invoiceNo": "OPD-06-26-001336",
            "patientId": "019ec172-61bb-7531-81cd-0aae6b9737e6",
            "patientName": "OPD Patient for DayCare EMR",
            "doctorId": "01990397-afda-71e1-a35b-ee067649e272",
            "doctorName": "Moe Wai",
            "counterId": "01953b11-4d50-7381-94ab-58ed1612bd5b",
            "counterName": "Main Store",
            "amount": 245000,
            "adjustment": 0,
            "payoutAmount": 245000,
            "status": "VOID",
            "version": 2,
            "billingDate": "2026-06-13T14:58:15.499Z",
            "paidAt": null,
            "voidedAt": "2026-06-14T11:45:35.412Z",
            "createdAt": "2026-06-14T09:22:55.779Z",
            "updatedAt": "2026-06-14T11:45:35.412Z"
        }
    ],
    "nextCursor": null
}
```



### Get CFI detail (tenant 1's CFI)

Should return the full payload with `statusHistory` and `adjustmentHistory` arrays (initially empty).

**Request:**

```http
GET /consultation-fees-invoices/019ec55a-d656-72f0-ae65-c8e474905518 HTTP/1.1
Host: localhost:4000
Content-Type: application/json
```

**Response:**

**Status:** 200

```json
{
    "id": "019ec55a-d656-72f0-ae65-c8e474905518",
    "tenantId": "00000000-0000-0000-0000-000000000001",
    "opdInvoiceId": "019ec421-38fe-7801-a29d-e9eaf3445b17",
    "invoiceNo": "OPD-06-26-001343",
    "patientId": "019ec406-fc0f-7843-91ef-24c5184b1685",
    "patientName": "OPD EMR + Biliing ",
    "doctorId": "0196fb3d-25dc-7102-a8f7-5ab8ce803af0",
    "doctorName": "Mon",
    "counterId": "0197ba75-e741-7573-96af-cf5121bbbacf",
    "counterName": "Pharmacy Store",
    "amount": 3000,
    "adjustment": 0,
    "payoutAmount": 3000,
    "status": "PAID",
    "version": 2,
    "billingDate": "2026-06-14T03:15:17.009Z",
    "paidAt": "2026-06-14T10:31:39.542Z",
    "voidedAt": null,
    "createdAt": "2026-06-14T08:58:45.207Z",
    "updatedAt": "2026-06-14T10:31:39.542Z",
    "statusHistory": [
        {
            "id": "019ec5af-e51c-7e50-8fdc-4a9c82ed634e",
            "fromStatus": "UNPAID",
            "toStatus": "PAID",
            "changedAt": "2026-06-14T10:31:39.542Z",
            "changedById": "019a290f-bdc0-7a12-a374-0264e6b53414",
            "reason": "manual probe",
            "invoiceVersionAtChange": 2
        }
    ],
    "adjustmentHistory": []
}
```



### Get CFI detail (tenant 3 trying to read tenant 1's CFI — must 404)

ADR 0012 failure mode 6: cross-tenant access returns 404 to not leak existence.

**Request:**

```http
GET /consultation-fees-invoices/019ec55a-d656-72f0-ae65-c8e474905518 HTTP/1.1
Host: localhost:4000
Content-Type: application/json
```

**Response:**

**Status:** 404

```json
{
    "code": "NOT_FOUND",
    "message": "CFI not found"
}
```



### Get aggregates (tenant 1, unfiltered — Redis-backed)

Unfiltered request should hit Redis (ADR 0009 §"Read fallback"). The `X-Cache-Status: hit` header confirms it. Note the data is bucketed by billingDate — tenant 1's CFI was billed on 2026-06-14, so the counter is keyed by that date.

**Request:**

```http
GET /consultation-fees-invoices/aggregates HTTP/1.1
Host: localhost:4000
Content-Type: application/json
```

**Response:**

**Status:** 200

**X-Cache-Status:** bypass

```json
{
    "total": {
        "count": 1,
        "amount": 3000,
        "payoutAmount": 3000
    },
    "byStatus": {
        "UNPAID": {
            "count": 0,
            "amount": 0,
            "payoutAmount": 0
        },
        "PAID": {
            "count": 1,
            "amount": 3000,
            "payoutAmount": 3000
        },
        "VOID": {
            "count": 0,
            "amount": 0,
            "payoutAmount": 0
        }
    }
}
```



### Get aggregates (tenant 1, filtered status=UNPAID — Postgres fallback)

Any filter bypasses Redis. The aggregator runs the GROUP BY against Postgres and emits `X-Cache-Status: bypass`.

**Request:**

```http
GET /consultation-fees-invoices/aggregates?status=UNPAID HTTP/1.1
Host: localhost:4000
Content-Type: application/json
```

**Response:**

**Status:** 200

**X-Cache-Status:** bypass

```json
{
    "total": {
        "count": 0,
        "amount": 0,
        "payoutAmount": 0
    },
    "byStatus": {
        "UNPAID": {
            "count": 0,
            "amount": 0,
            "payoutAmount": 0
        },
        "PAID": {
            "count": 0,
            "amount": 0,
            "payoutAmount": 0
        },
        "VOID": {
            "count": 0,
            "amount": 0,
            "payoutAmount": 0
        }
    }
}
```

---

## Section 3 — Status change flow



### PATCH status to PAID

ADR 0005 (state machine) + ADR 0006 (optimistic lock via `version`). Should bump version 1 → 2 and set `paidAt`.

**Request:**

```http
PATCH /consultation-fees-invoices/019ec55a-d656-72f0-ae65-c8e474905518/status HTTP/1.1
Host: localhost:4000
Content-Type: application/json
If-Match: 1
X-User-Id: 019a290f-bdc0-7a12-a374-0264e6b53414

{
    "status": "PAID",
    "reason": "smoke test \u2014 full pay"
}
```

**Response:**

**Status:** 409

```json
{
    "code": "VERSION_MISMATCH",
    "message": "If-Match does not match current version",
    "details": {
        "currentVersion": 2
    }
}
```



### Get CFI detail after PATCH

Should show status=PAID, paidAt set, version=2, statusHistory with one entry.

**Request:**

```http
GET /consultation-fees-invoices/019ec55a-d656-72f0-ae65-c8e474905518 HTTP/1.1
Host: localhost:4000
Content-Type: application/json
```

**Response:**

**Status:** 200

```json
{
    "id": "019ec55a-d656-72f0-ae65-c8e474905518",
    "tenantId": "00000000-0000-0000-0000-000000000001",
    "opdInvoiceId": "019ec421-38fe-7801-a29d-e9eaf3445b17",
    "invoiceNo": "OPD-06-26-001343",
    "patientId": "019ec406-fc0f-7843-91ef-24c5184b1685",
    "patientName": "OPD EMR + Biliing ",
    "doctorId": "0196fb3d-25dc-7102-a8f7-5ab8ce803af0",
    "doctorName": "Mon",
    "counterId": "0197ba75-e741-7573-96af-cf5121bbbacf",
    "counterName": "Pharmacy Store",
    "amount": 3000,
    "adjustment": 0,
    "payoutAmount": 3000,
    "status": "PAID",
    "version": 2,
    "billingDate": "2026-06-14T03:15:17.009Z",
    "paidAt": "2026-06-14T10:31:39.542Z",
    "voidedAt": null,
    "createdAt": "2026-06-14T08:58:45.207Z",
    "updatedAt": "2026-06-14T10:31:39.542Z",
    "statusHistory": [
        {
            "id": "019ec5af-e51c-7e50-8fdc-4a9c82ed634e",
            "fromStatus": "UNPAID",
            "toStatus": "PAID",
            "changedAt": "2026-06-14T10:31:39.542Z",
            "changedById": "019a290f-bdc0-7a12-a374-0264e6b53414",
            "reason": "manual probe",
            "invoiceVersionAtChange": 2
        }
    ],
    "adjustmentHistory": []
}
```



### PATCH status to PAID again — should 409 INVALID_TRANSITION

ADR 0005: PAID is a terminal state. Already-PAID → PAID must be rejected.

**Request:**

```http
PATCH /consultation-fees-invoices/019ec55a-d656-72f0-ae65-c8e474905518/status HTTP/1.1
Host: localhost:4000
Content-Type: application/json
If-Match: 2
X-User-Id: 019a290f-bdc0-7a12-a374-0264e6b53414

{
    "status": "PAID"
}
```

**Response:**

**Status:** 409

```json
{
    "code": "INVALID_TRANSITION",
    "message": "Status can only change from UNPAID",
    "details": {
        "currentStatus": "PAID",
        "requestedStatus": "PAID"
    }
}
```



### POST adjustment on PAID CFI — should 409 ADJUSTMENT_LOCKED

ADR 0014: adjustment is locked when status ≠ UNPAID.

**Request:**

```http
POST /consultation-fees-invoices/019ec55a-d656-72f0-ae65-c8e474905518/adjustment HTTP/1.1
Host: localhost:4000
Content-Type: application/json
If-Match: 2
X-User-Id: 019a290f-bdc0-7a12-a374-0264e6b53414

{
    "amount": 500,
    "reason": "too late"
}
```

**Response:**

**Status:** 409

```json
{
    "code": "ADJUSTMENT_LOCKED",
    "message": "Adjustment can only change while status is UNPAID",
    "details": {
        "currentStatus": "PAID"
    }
}
```



### PATCH status to VOID

VOID is the other terminal state. Should set `voidedAt` (not `paidAt`).

**Request:**

```http
PATCH /consultation-fees-invoices/019ec570-f8a3-7360-8d5f-50583c9328d8/status HTTP/1.1
Host: localhost:4000
Content-Type: application/json
If-Match: 1
X-User-Id: 019a290f-bdc0-7a12-a374-0264e6b53414

{
    "status": "VOID",
    "reason": "smoke test \u2014 voided"
}
```

**Response:**

**Status:** 409

```json
{
    "code": "VERSION_MISMATCH",
    "message": "If-Match does not match current version",
    "details": {
        "currentVersion": 2
    }
}
```



### POST adjustment on VOID CFI — should 409 ADJUSTMENT_LOCKED

Same lock — both terminal states block adjustment.

**Request:**

```http
POST /consultation-fees-invoices/019ec570-f8a3-7360-8d5f-50583c9328d8/adjustment HTTP/1.1
Host: localhost:4000
Content-Type: application/json
If-Match: 2
X-User-Id: 019a290f-bdc0-7a12-a374-0264e6b53414

{
    "amount": 1000,
    "reason": "too late"
}
```

**Response:**

**Status:** 409

```json
{
    "code": "ADJUSTMENT_LOCKED",
    "message": "Adjustment can only change while status is UNPAID",
    "details": {
        "currentStatus": "VOID"
    }
}
```

---

## Section 4 — Adjustment flow (on a fresh UNPAID CFI)

We need a 3rd UNPAID CFI to exercise the happy-path adjustment. Create one
inline by inserting a new outbox event for a different OPD billing.

**Setup — insert another outbox event for billing `019ec1ac-1944-7731-b81e-712e92c86b33` (consultation_total=2000)**

```sql
INSERT INTO event_outbox (id, tenant_id, event_type, aggregate_id, payload, status, next_attempt_at)
VALUES ('B7785C22-3BDF-4D32-A9B6-8FFE3A953091'::uuid, '00000000-0000-0000-0000-000000000004'::uuid, 'opd_invoice.created', '019ec1ac-1944-7731-b81e-712e92c86b33'::uuid,
        jsonb_build_object('eventId','B7785C22-3BDF-4D32-A9B6-8FFE3A953091','tenantId','00000000-0000-0000-0000-000000000004','opdInvoiceId','019ec1ac-1944-7731-b81e-712e92c86b33','createdById','019a1014-d4c0-7883-bce8-a8ff6d6c8bf0'),
        'PENDING', now());
```

Running the insert (and waiting 5s for the worker)...

**Worker created CFI: ``**




### POST adjustment (UNPAID CFI, happy path)

Should succeed: amount=500, payout = amount - adjustment = 2000 - 500 = 1500, version 1 → 2, Redis payout_total decremented by 500.

**Request:**

```http
POST /consultation-fees-invoices//adjustment HTTP/1.1
Host: localhost:4000
Content-Type: application/json
If-Match: 1
X-User-Id: 019a290f-bdc0-7a12-a374-0264e6b53414

{
    "amount": 500,
    "reason": "smoke test \u2014 partial discount"
}
```

**Response:**

**Status:** 404

```json
{
    "error": "NOT_FOUND",
    "message": "No route for POST /consultation-fees-invoices//adjustment"
}
```



### Get CFI detail after adjustment

Should show `adjustment=500`, `payoutAmount=1500`, `adjustmentHistory` with one entry, `version=2`.

**Request:**

```http
GET /consultation-fees-invoices/ HTTP/1.1
Host: localhost:4000
Content-Type: application/json
```

**Response:**

**Status:** 200

```json
{
    "items": [
        {
            "id": "019ec5f6-9d85-7973-9e26-5eb6ecdeee6a",
            "tenantId": "00000000-0000-0000-0000-000000000004",
            "opdInvoiceId": "019ec1ac-1944-7731-b81e-712e92c86b33",
            "invoiceNo": "OPD-06-26-001337",
            "patientId": "0197339d-7d52-74f3-9346-d76dd774a575",
            "patientName": "Daw Myint Myint Kywal",
            "doctorId": "01990382-20b8-7a03-a28a-3eab8d861e32",
            "doctorName": "Rain",
            "counterId": "01953b11-4d50-7381-94ab-58ed1612bd5b",
            "counterName": "Main Store",
            "amount": 2000,
            "adjustment": 500,
            "payoutAmount": 1500,
            "status": "UNPAID",
            "version": 2,
            "billingDate": "2026-06-13T15:47:25.057Z",
            "paidAt": null,
            "voidedAt": null,
            "createdAt": "2026-06-14T11:48:54.277Z",
            "updatedAt": "2026-06-14T11:48:59.213Z"
        }
    ],
    "nextCursor": null
}
```



### POST adjustment exceeding amount — should 409 ADJUSTMENT_EXCEEDS_AMOUNT

Constraint: 0 ≤ adjustment ≤ amount. The CFI amount is 2000; 99999 violates it.

**Request:**

```http
POST /consultation-fees-invoices//adjustment HTTP/1.1
Host: localhost:4000
Content-Type: application/json
If-Match: 2
X-User-Id: 019a290f-bdc0-7a12-a374-0264e6b53414

{
    "amount": 99999,
    "reason": "too much"
}
```

**Response:**

**Status:** 404

```json
{
    "error": "NOT_FOUND",
    "message": "No route for POST /consultation-fees-invoices//adjustment"
}
```

---

## Section 5 — Version mismatch



### PATCH with stale If-Match

CFI 1 is now at version=2 (after the earlier PATCH); passing `If-Match: 99` triggers VERSION_MISMATCH. ADR 0006.

**Request:**

```http
PATCH /consultation-fees-invoices/019ec55a-d656-72f0-ae65-c8e474905518/status HTTP/1.1
Host: localhost:4000
Content-Type: application/json
If-Match: 99
X-User-Id: 019a290f-bdc0-7a12-a374-0264e6b53414

{
    "status": "PAID"
}
```

**Response:**

**Status:** 409

```json
{
    "code": "VERSION_MISMATCH",
    "message": "If-Match does not match current version",
    "details": {
        "currentVersion": 2
    }
}
```

---

## Section 6 — Cross-tenant write protection



### PATCH status on another tenant's CFI — should 404

Tenant 1 trying to mutate tenant 3's CFI. The tenant-scoped Prisma extension on `req.prisma` forces `tenantId` on every CFI query, so the SELECT misses → 404 (no existence leak).

**Request:**

```http
PATCH /consultation-fees-invoices/019ec570-f8a3-7360-8d5f-50583c9328d8/status HTTP/1.1
Host: localhost:4000
Content-Type: application/json
If-Match: 2
X-User-Id: 019a290f-bdc0-7a12-a374-0264e6b53414

{
    "status": "PAID"
}
```

**Response:**

**Status:** 404

```json
{
    "code": "NOT_FOUND",
    "message": "CFI not found"
}
```

---

## Final state of the dev DB after the run

        invoice_no    |  amount   | adjustment | payout_amount | status | version | paid_at  | voided_at 
    ------------------+-----------+------------+---------------+--------+---------+----------+-----------
     OPD-06-26-001343 |   3000.00 |       0.00 |       3000.00 | PAID   |       2 | 10:31:39 | 
     OPD-06-26-001336 | 245000.00 |       0.00 |     245000.00 | VOID   |       2 |          | 11:45:35
     OPD-06-26-001337 |   2000.00 |     500.00 |       1500.00 | UNPAID |       2 |          | 
    (3 rows)
    

## Final Redis counters

**Tenant `00000000-0000-0000-0000-000000000001`:**

```
```

**Tenant `00000000-0000-0000-0000-000000000003`:**

```
```

**Tenant `00000000-0000-0000-0000-000000000004`:**

```
```

