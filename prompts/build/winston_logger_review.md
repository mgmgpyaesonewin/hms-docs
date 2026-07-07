# Review winston migration in hms-summary-service

Run **two reviewers in parallel** on the implementation branch. Each is a
gate. A blocker from either blocks the PR.

## Reviewer 1 — `/ponytail:ponytail-review` (over-engineering)

Goal: confirm the diff is the shortest one that works. Cut anything
speculative.

Findings to look for (each is a one-line: location, what to cut, what
replaces it):

- New abstraction layer with one consumer.
- New config object for a value that never changes.
- Wrapper functions that only forward arguments.
- New dependency when stdlib or already-installed package suffices.
- "Future-proof" hooks with no concrete caller in this PR.
- Shared `@hms/logger` package extraction (out of scope per spec).
- Logger-API re-shape beyond `import` lines (forbidden by spec).

## Reviewer 2 — `/code-reviewer` (correctness + reuse)

Goal: confirm the migration matches `hms-app` and preserves invariants from
`hms-docs/CLAUDE.md`.

Findings to look for:

- **Format mismatch**: any line that does not match the `hms-app` winston line layout (excluding `service`, `time`).
- **Lost fields**: `tenantId`, `requestId`, `service`, `env`, `version`, `mode` missing from default emit.
- **Redaction regression**: `password`, `authorization`, `cookie`, `hmacSignature` not redacted.
- **Worker-vs-api divergence**: one mode logs differently from the other.
- **Pino residue**: `from "pino"`, `pino-pretty`, or `pino-http` strings anywhere in `src/` or `package.json`.
- **Tenant-scope regression**: HMAC middleware (`hmac-auth.ts`) or tenant-guard still constructs logs without `tenantId` where the spec mandates it.
- **Test gaps**: missing coverage for any test in `winston_logger_test_cases.md`.
- **Build / lint / typecheck**: any of the three failing on the branch.

## Inputs

- Approved spec: `hms-docs/prompts/build/winston_logger_addition.md`.
- Implementation diff vs `main` for `hms-summary-service/`.
- For format comparison: `hms-app/` winston config + sample output line.

## Output contract

- Two review reports (one per reviewer). Each ends with `Verdict: APPROVE | BLOCK`.
- PR is mergeable only when both reviewers APPROVE.
- Blockers must name file + line + a one-line fix suggestion.
- Non-blockers (nits) do not block but are listed for follow-up.