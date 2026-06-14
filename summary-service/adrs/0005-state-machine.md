# ADR 0005: State machine — UNPAID → PAID, UNPAID → VOID, immutable thereafter

- **Status:** Accepted
- **Section in brief:** 7.4

## Context

A `consultation_fees_invoice` has a `status` column with three possible values: `UNPAID`, `PAID`, `VOID`. The transitions and the rules around them drive the UI, the audit log, the Redis aggregates, and the API.

## Options considered

- **(a) DB CHECK constraint + app-level transition guard** — `status IN ('UNPAID', 'PAID', 'VOID')` at the schema level; the API service explicitly checks the current status before allowing a transition.
- **(b) DB trigger** — a Postgres trigger enforces the allowed transitions on UPDATE.
- **(c) Pure app-level enforcement** — no DB constraints beyond the type.

## Decision

**(a) DB CHECK constraint + app-level transition guard.**

## Rationale

- The CHECK constraint catches obvious garbage (e.g., a typo like `status = 'UNPAID '` with a trailing space, or a new enum value added without a migration).
- The app-level guard enforces the *transition* (not just the value): "you can only go from UNPAID to PAID, not from PAID to UNPAID". The DB doesn't have a clean way to express "current value must be X" in a CHECK constraint; a trigger would work but is overkill for a simple state machine.
- App-level guard is testable in unit tests and is the same code path that writes the audit log.

## Consequences

- Schema: `status TEXT NOT NULL CHECK (status IN ('UNPAID', 'PAID', 'VOID'))`.
- API code: every status-changing endpoint reads the current row, validates the transition (`if (currentStatus === 'UNPAID' && newStatus === 'PAID') { ... } else if (currentStatus === 'UNPAID' && newStatus === 'VOID') { ... } else { throw new TransitionError(...) }`).
- The transition table is hard-coded in code, with a corresponding test that asserts the full state matrix (3 states × 3 states = 9 cells; 2 are allowed, 7 are rejected).
- The audit row in `consultation_fees_invoice_status_changes` captures the transition with `from_status` and `to_status`; this is the audit trail of "who changed what when".

## Related

- ADR 0011 (Observability — audit log is here)
- Section 3.2 in the brief
