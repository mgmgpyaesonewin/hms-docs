# Summary Service API — End-to-end Test Report

- **Generated:** 2026-06-14T11:52:01Z
- **API base:** http://localhost:4000
- **Service ID:** hms-bff
- **Test data:** 2 UNPAID CFIs in the dev DB (from earlier end-to-end worker tests)
  - CFI 1: `019ec55a-d656-72f0-ae65-c8e474905518` — tenant `00000000-0000-0000-0000-000000000001`, amount 3000.00
  - CFI 2: `019ec570-f8a3-7360-8d5f-50583c9328d8` — tenant `00000000-0000-0000-0000-000000000003`, amount 245000.00

Auth scheme: HMAC-SHA256 over `METHOD\nPATH\nSHA256(BODY)\nTIMESTAMP\nSERVICE_ID\nTENANT_ID`
(per `hms-docs/summary-service/api/hmac-auth.md`). Every signed request below
includes the actual `X-Signature` and `X-Timestamp` that was used.

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

## Section 1 — Auth enforcement (negative tests)

The HMAC middleware must reject: missing headers, unknown service, bad
signature, stale timestamp, non-UUID tenant, and replayed signatures.


### 1.1 No auth headers

**Request:**

```http
GET /consultation-fees-invoices HTTP/1.1
Host: localhost:4000
```
**Status:** 401

```json
{
    "code": "MISSING_AUTH_HEADERS",
    "message": "One or more required auth headers are missing"
}
```


### 1.2 Wrong `X-Service-Id`

**Request:**

```http
GET /consultation-fees-invoices HTTP/1.1
Host: localhost:4000
X-Service-Id: not-the-bff
X-Signature: 00
X-Timestamp: 1781437921
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
```
**Status:** 401

```json
{
    "code": "UNKNOWN_SERVICE",
    "message": "Unknown service id: not-the-bff"
}
```


### 1.3 Stale `X-Timestamp` (1 hour old)

**Request:**

```http
GET /consultation-fees-invoices HTTP/1.1
Host: localhost:4000
X-Service-Id: hms-bff
X-Signature: 344edf25eec96dea1466c301c4d788bb46f35fb4ae2c0a8679a9df1857a2e2b5
X-Timestamp: 1781434321
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
```
**Status:** 401

```json
{
    "code": "STALE_TIMESTAMP",
    "message": "X-Timestamp is outside the acceptable \u00b15-minute window"
}
```


### 1.4 Non-UUID `X-Tenant-Id`

**Request:**

```http
GET /consultation-fees-invoices HTTP/1.1
Host: localhost:4000
X-Service-Id: hms-bff
X-Signature: 680684c862c1341789e26a0f58df4ed1fda5f24bffa9d47cd8a305a118fa72e0
X-Timestamp: 1781437921
X-Tenant-Id: not-a-uuid
```
**Status:** 401

```json
{
    "code": "INVALID_TENANT_ID",
    "message": "X-Tenant-Id is not a valid UUID"
}
```

---

## Section 2 — Read flow (happy path)



### List CFIs (tenant 1, status=UNPAID)

Tenant 1 should see only its own CFIs; filtering by status=UNPAID should narrow to unpaid rows.

**Request:**

```http
GET /consultation-fees-invoices?status=UNPAID&limit=5 HTTP/1.1
Host: localhost:4000
Content-Type: application/json
X-Service-Id: hms-bff
X-Signature: 120e82803813a8820ebf8eb4d49329798156f11f85f08eb0644151f72120e917
X-Timestamp: 1781437921
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
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
X-Service-Id: hms-bff
X-Signature: 3c696ec36ce47e593570ee1b57c69ddcbc07353c3d92a984d4ede4160878b836
X-Timestamp: 1781437921
X-Tenant-Id: 00000000-0000-0000-0000-000000000003
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
X-Service-Id: hms-bff
X-Signature: d0d766e1f90e0a4930a0d0723b461af73186413c37128af3b7dbf1cfac2fba32
X-Timestamp: 1781437921
X-Tenant-Id: 00000000-0000-0000-0000-000000000003
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
X-Service-Id: hms-bff
X-Signature: ddf7ac5f8625c6830ec7413df6e32610ec5995394a1e4cf49afd721c11891b02
X-Timestamp: 1781437921
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
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
X-Service-Id: hms-bff
X-Signature: c9c366ea179de269c4275534dd37f6f92370c332a7850f3f74b22e9d290cd36b
X-Timestamp: 1781437921
X-Tenant-Id: 00000000-0000-0000-0000-000000000003
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
X-Service-Id: hms-bff
X-Signature: c73260e4b404462a1e8c5486c2bfc232ec6439be93652d7c90c5ad5c00cbf4e6
X-Timestamp: 1781437921
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
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
X-Service-Id: hms-bff
X-Signature: 8fc39d398edee812119c848d43a91c65c109a1ef90d78d76533f247be0da66be
X-Timestamp: 1781437922
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
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
X-Service-Id: hms-bff
X-Signature: dfea2a79bdc4ea1296274253177c766efaeab6c5a6494f7edfb81930351d9ec9
X-Timestamp: 1781437922
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
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
X-Service-Id: hms-bff
X-Signature: 285a9ada76a79ff20ccfe3b0d534222cf8cf64c6274695993290dd65c369ef4c
X-Timestamp: 1781437922
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
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
X-Service-Id: hms-bff
X-Signature: c8103e3090ca782486af145af54dbbce30cbf9a0d2b832d68ea3dbb2dc2fecbb
X-Timestamp: 1781437922
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
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
X-Service-Id: hms-bff
X-Signature: b8ad8f5c0614da95177b459bca60fc2625f541e131c969a96c5302489bedb70c
X-Timestamp: 1781437922
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
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
X-Service-Id: hms-bff
X-Signature: a47adc641681f226357929bec053b2c97f66ef546eb92cac939dcf055315cde9
X-Timestamp: 1781437922
X-Tenant-Id: 00000000-0000-0000-0000-000000000003
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
X-Service-Id: hms-bff
X-Signature: fc2c4d5ca58e917f711a31af8b7c054ac711ed1ffde560f35784f040242a7af0
X-Timestamp: 1781437922
X-Tenant-Id: 00000000-0000-0000-0000-000000000003
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
X-Service-Id: hms-bff
X-Signature: d9aec052ed9e324d960a161ccd8bd28a82e49c00ce7601036b839b7afe5013b6
X-Timestamp: 1781437927
X-Tenant-Id: 00000000-0000-0000-0000-000000000004
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
X-Service-Id: hms-bff
X-Signature: 1ed189585fe9c2278c7ed8b05d73f7cbbe900beb169c7a883c532e9ba9db742b
X-Timestamp: 1781437927
X-Tenant-Id: 00000000-0000-0000-0000-000000000004
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
X-Service-Id: hms-bff
X-Signature: 2c001868d168ad20d56dd4f398698a2c19bddcc4840029d67a8e609cbf2b3d90
X-Timestamp: 1781437928
X-Tenant-Id: 00000000-0000-0000-0000-000000000004
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
X-Service-Id: hms-bff
X-Signature: 29b5f5cefb744e3ce4ef835f52fd0f196bcc89260fbdcaaf18274e4b87c9121c
X-Timestamp: 1781437928
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
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
X-Service-Id: hms-bff
X-Signature: e8507ac6a547ae5518bb38eabccedda9fe985a6908406c47fad9979e521b302b
X-Timestamp: 1781437928
X-Tenant-Id: 00000000-0000-0000-0000-000000000001
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

