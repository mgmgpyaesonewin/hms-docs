# ADR 0006: Concurrent status updates — optimistic locking via `version` column

- **Status:** Accepted
- **Section in brief:** 7.5

## Context

Two admins could open the same consultation fees invoice in their browsers and both click "Mark as Paid" simultaneously. The system must not silently let both writes succeed (the second one would be a no-op write of the same status, which is harmless — but if one admin wants to mark Paid and the other wants to mark Void, we have a real conflict that needs explicit resolution).

## Options considered

- **(a) Optimistic locking via `version` column** — every CFI has a `version INT NOT NULL DEFAULT 1`; the status update takes `If-Match: <version>`; service returns `409 Conflict` on version mismatch.
- **(b) Pessimistic locking via `SELECT ... FOR UPDATE`** — the service locks the row inside the transaction.
- **(c) Last-write-wins** — no concurrency control; the latest request wins.

## Decision

**(a) Optimistic locking via `version` column.**

## Rationale

- Conflicts are rare (two admins on the same row at the same time); pessimistic locking is overkill and would hold a DB lock for the duration of a user action.
- The pattern fits the existing HMS REST conventions (the BFF already uses `If-Match` for some endpoints — pattern is familiar).
- The conflict case is rare and easy to handle in the UI: "this row was updated by someone else, please refresh and try again". No data loss; user retries.

## Consequences

- Schema: `version INT NOT NULL DEFAULT 1` on `consultation_fees_invoices`.
- The version is bumped on every UPDATE: `SET version = version + 1, ...` inside the transaction.
- API request: `PATCH /consultation-fees-invoices/{id}/status` with header `If-Match: <version>` (mandatory).
- API response on conflict: `409 Conflict` with body `{ "code": "VERSION_MISMATCH", "currentVersion": <n>, "yourVersion": <n-1> }`.
- The BFF propagates the `If-Match` header from the UI request to the Summary Service.
- The version is also bumped on adjustment updates (per [[0014-cfi-invariants|ADR 0014]]). The same `If-Match` semantics apply.

## Related

- [[0005-state-machine|ADR 0005]] (State machine)
- [[0014-cfi-invariants|ADR 0014]] (CFI invariants — adjustment bumps `version` under the same `If-Match` semantics)
