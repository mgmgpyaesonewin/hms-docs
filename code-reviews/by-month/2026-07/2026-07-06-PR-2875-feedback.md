# Code Review: PR #2875 — Prevent reorder after status update

**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41 (Pyae Phyo Zan)
**Branch:** `issue/ppz/spring-26/lab-module-86ey4v1m5` → `development`
**Files changed:** 7 (+7 / −0)
**Date:** 2026-07-04
**ClickUp ticket:** [9018849685/86ey4v1m5](https://app.clickup.com/t/9018849685/86ey4v1m5)
**PR URL:** https://github.com/MyanCare/Ycare-HMS/pull/2875

## Summary

The PR adds a single line, `orderBy: { id: "asc" }`, to the `LabService` relation inside seven `Prisma.validator` blocks in the lab repositories: `lab-acknowledge`, `lab-report`, `lab-result-entry`, `lab-result-verification`, `lab-sample-collection`, `lab-test-done`, `lab-testing`. The stated intent in the title is "prevent reorder after status update" — i.e. users were seeing labs visually reshuffle in the lab-pivot table as statuses transitioned, and this pins the order by `LabService.id` so the rendered list stays stable across mutations.

The fix is correctly placed (relation-level `orderBy` on the included `LabService` payload is the right Prisma lever), and the seven files are exactly the right surface — each `*Validator` block selects `LabService` as an include, and the orderBy on the relation is what determines the order of services within a single pivot row's nested array.

But the diff has two things missing that the symptom in the title implies, and one structural smell that survived the change.

## Verdict

**⚠️ Request changes — one Critical (missing test), one High (root-cause ambiguity)**

Score: 60/100
Critical: 1 | High: 1 | Medium: 1 | Low: 0

The change is correct on its own terms and the symptom is real (lab service rows were reordering across status mutations). What's missing is **proof the root cause is what this fix addresses**, and **proof the fix actually works** — neither a regression test nor a manual repro is captured. Once those land it's a clean approve; until then, request changes only because the PR ships behavior with no verifiable evidence.

## Findings

### Critical

**No regression test, no repro, no 'before/after' capture.** The ClickUp ticket is referenced but the symptom "rows reorder after status update" is not reduced to anything testable. Two questions that the review should not have to answer:

1. Was the reorder caused by (a) Postgres returning `LabService` rows in insertion order with no `ORDER BY`, so the array happened to be in `[3, 1, 2]` order one moment and `[1, 3, 2]` the next because of how the join planner rescans, or (b) something in the application code that explicitly resorts?
2. Does adding `orderBy: { id: "asc" }` at the include level actually apply to all consumers of these repositories, or only to the ones that go through the `validator` path (i.e. callers that use `Prisma.validator` types for arg-inference)?

Without those answered in the PR description (one screenshot of the table before/after a status flip, or one Jest test that asserts the order), the change reads as "added `orderBy` everywhere it might be needed and shipped". Senior reviewers will block that even when it's correct, because the next time the symptom recurs there will be no way to know whether this PR touched the right code.

**Fix:** add one test. Either a unit test on one repository asserting `lab.LabService` comes back sorted by id, or — better — a Playwright/regression test that loads `lab-acknowledge/[id]/page.tsx`, mutates a status, and asserts the visual order is stable across the mutation. Even a hand-written before/after screenshot in the PR body is enough.

### High

**Root-cause is not isolated; the fix is applied to seven files prophylactically.** The seven repositories all touch `LabService` in slightly different ways (different `select` shapes — `lab-acknowledge` selects `collectStatus`, `lab-report` selects `labReportStatus`, `lab-result-entry` selects `collectStatus`, etc.). The shared shape across all seven is `orderBy` is missing.

The lazy-rung question for this kind of change is: **does the symptom reproduce on every one of these seven pages, or only one?** The PR diff applies the same line to all seven identically, with no commit-per-repository breakdown and no per-page confirmation. There are two possibilities:

- **Symptom reproduces on all seven** → the fix is correct as a sweep. But then a one-line central change (e.g. a shared `LabService` selection helper that already had `orderBy` baked in) would have shipped a one-line diff and surfaced the seven call sites as the only editors. The seven calls being hand-edited suggests this shared helper does not exist, which is its own smell (seven duplicated `select` shapes are already visible in the diffs above).
- **Symptom reproduces on only one or two of the seven** → six of the seven changes are prophylactic edits that don't fix any reported behavior. They still help (consistent ordering is a quiet win), but the PR title and scope don't acknowledge this and they could have been a separate "stabilize lab service ordering across all pivot views" commit.

Either way, the PR is broader than it advertises and the reviewer can't tell.

**Fix:** split into two PRs (or at least two commits) — (1) fix the reported symptom on the minimum set of repositories, with a repro/test; (2) standardize `orderBy` across the remaining repositories as cleanup. The diff is tiny either way; the honesty is what matters.

### Medium

**The seven `LabService` selects are seven near-duplicates of one another and now seven near-duplicates-with-orderBy.** Read the diffs side by side — `lab-acknowledge`, `lab-result-entry`, `lab-test-done`, `lab-testing` all have:

```
orderBy: { id: "asc" },
select: {
  id: true,
  collectStatus: true,
  ...
}
```

…and `lab-result-verification`, `lab-sample-collection` have nearly the same shape. `lab-report` is the outlier with `labReportStatus`. The labs module already has a "lab-pivot" concept (each of these is a pivot view at a different status); if the seven `select` shapes are functionally identical they're a candidate for a single `labServiceSelectArgs` shared via `Prisma.validator` + `Prisma.validator(...)() satisfies Prisma.LabServiceSelect`, exported once from `@/lib/lab/`. That would also fix the ordering once, in one place, and survive the next "we added a `labService.foo` field to the UI" change.

This is out of scope for a 7-line status-ordering fix, but the PR is sitting on the duplication that makes this kind of multi-file edit inevitable, so it is the right time to mention it.

**Fix:** file a follow-up ticket "Consolidate seven duplicated `LabService` selects in lab repositories into one shared `Prisma.validator` select". Linked in the PR description.

## Ponytail notes

- **Rung 1 (does it need to exist at all?)**: ordering at the Prisma layer is fine. There's no UI-level re-sort, no react-table sort override on `LabService` that supersedes this. The orderBy belongs.
- **Rung 2 (already in this codebase?)**: `LabPivot` already has an `orderBy: { id: "asc" }` on the **outer** Prisma query (visible above each touched block in the diffs as `findMany({ orderBy: { id: "asc" } }, ...)`). The relation-level orderBy on `LabService` is the missing piece — the outer sort orders pivots, the inner sort orders services within a pivot. Both are needed; the PR is correct that the inner one was missing.
- **Rung 5 (already-installed dependency solves it?)**: `Prisma.validator` is the right tool and is already the pattern. No new dep.
- **Rung 6 (one line?)**: the fix is already one line per file. Cannot shrink further without consolidating (see Medium).

**net: 0 lines possible.** The diff is already minimal. The simplification opportunity is structural (consolidate the seven duplicates), not size.

## Bottom line

The diff is correct and minimal. The blockers are about evidence, not code: no regression test, no repro, no isolation of which of the seven repositories actually exhibited the symptom. Add one Jest test (or one Playwright snapshot) that asserts `lab.LabService` comes back in `id ASC` order after a status mutation on a single repository — that's enough to unblock. Once that lands the seven-line sweep is a clean approve.

The Medium duplication finding (`LabService` `select` shapes repeated seven times) is a separate cleanup ticket, not this PR.

---

**Subagent review summary:**
- engineering-skills:code-reviewer — High-confidence verdict "Request changes" on missing regression coverage; flagged duplication; score 60/100 with no actual correctness bugs in the diff.
- ponytail:ponytail-review — "Lean already. Ship." for the seven lines themselves. Zero lines removable. The one opportunity is rung-2 reuse (consolidate the seven duplicated selects), filed as Medium.
