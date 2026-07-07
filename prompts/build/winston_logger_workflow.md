# Orchestrate winston migration in hms-summary-service

Invoke the **`/spec-driven-workflow`** skill. This brief is the entry point
— it sequences the four sibling prompts in this folder and gates each stage
on the previous one.

## Goal

Take the user's one-line request ("add winston to hms-summary-service to
match hms-app") and produce a merged branch where `hms-summary-service`
logs via winston in `hms-app`'s format, with full spec, implementation,
tests, and dual-review sign-off.

## Inputs

- User intent: replace pino with winston in `hms-summary-service` so logs
  match `hms-app`.
- Workspace: `/Users/pyaesonewin/Documents/work/hms-system/`.
- Sibling prompts in this folder: `winston_logger_addition.md`,
  `winston_logger_implementation.md`, `winston_logger_test_cases.md`,
  `winston_logger_review.md`.

## Stages (run sequentially; each stage blocks the next)

### Stage 0 — Spec
- Prompt: `winston_logger_addition.md`.
- Skill: `/senior-prompt-engineer` (this same skill from the previous turn).
- Gate: all 8 required sections present, ≤ 20-line code blocks, summary line printed.
- Exit: human approves the spec.

### Stage 1 — Implementation
- Prompt: `winston_logger_implementation.md`.
- Skill: `/senior-backend` (sub-agents `coder-logger` then `coder-call-sites`).
- Gate: `npm run typecheck`, `npm run lint` green; `grep -r "from \"pino\"" src` returns nothing.
- Exit: implementation PR opened.

### Stage 2 — Tests
- Prompt: `winston_logger_test_cases.md`.
- Skill: `/senior-qa`.
- Gate: all five test files pass; coverage ≥ 90% lines / 85% branches on `src/lib/logger.ts`.
- Exit: tests committed to the implementation PR.

### Stage 3 — Dual review (parallel)
- Prompt: `winston_logger_review.md`.
- Skills: `/ponytail:ponytail-review` + `/code-reviewer` (run in parallel).
- Gate: both reviewers print `Verdict: APPROVE`. Either BLOCK requires a fix stage that re-enters at the matching prior stage.
- Exit: PR merged.

## Coordination rules

- One branch per run: `feat/winston-logger-migration`.
- One commit per stage, conventional-commit style (`feat(logging): ...`,
  `test(logging): ...`, `chore(logging): ...`).
- Don't skip stages. If a stage's gate fails, fix in place and re-run that
  gate before moving on.
- If a reviewer BLOCKs on a finding that originated in an earlier stage's
  prompt (e.g. the spec was ambiguous), edit the prompt file, then re-run
  from that stage — do not patch the gap with hidden assumptions in code.

## Out of scope

- `hms-app` log changes.
- Log shipping / retention / alerting.
- Shared `@hms/logger` package extraction.
- Any change to the HMAC contract, tenant-scope extension, or CFI service
  logic — this migration is logging-only.