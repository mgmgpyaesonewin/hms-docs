# PR #2876 — Fix: checkbox incorrect in lab result entry UI

**Repo:** MyanCare/Ycare-HMS · **PR:** https://github.com/MyanCare/Ycare-HMS/pull/2876
**Branch:** `issue/ppz/sprint-26/lab-result-entry-ui-86ey4v5mv` → `development` · **Author:** Pyae41
**Diff:** 1 file · +3 / -1 · **ClickUp:** 9018849685/86ey4v5mv
**Verdict:** Changes requested (1 important)

## Summary

Single-line logical correction in the "select all" checkbox of the lab result entry page. The category-level checkbox is disabled whenever *any* service in the category has a result already entered (`resultEntryStatus === "ENTERED"`), which prevents the user from toggling selection across the rest of an in-progress category. The fix tightens the guard to require both `resultEntryStatus === "ENTERED"` *and* `resultVerificationStatus === "VERIFIED"` — i.e. disable bulk-select only when at least one row is fully past the entry step (entered + verified), not the moment the first row is touched.

The semantic direction is right and matches the workflow (a result that has been verified is effectively locked, while a still-being-entered result can co-exist with unchecked siblings). The variable name `hasTestingedServices` predates this PR but it is now actively misleading (it reads "tested services" but contains "entered and verified" services), and one adjacent dead-code block in the same render lies a couple of screens below.

## Strengths

- Tight one-condition fix. No new state, no new flag, no new memo. The added clause reuses an existing field (`resultVerificationStatus`) that is already on the same `LabResultEntryService` shape (`lab-result-entry.type.ts:3`).
- The semantics line up with the page's manual-row `disabled` predicate downstream (rows with `resultEntryStatus !== "ENTERED"` are still individually selectable; this change brings the "select all" affordance back in line with that).
- No surprise side-effects on permissions, audit, or persist path. The behaviour is purely UI-side.

## Findings

### Important

**I1. `hasTestingedServices` no longer matches what it computes** — `src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:383-385`.

The variable is named for "tested" services but the new predicate (correctly) checks "entered *and* verified". Two consumers on the same page rely on the variable (`disabled={hasMixedStatuses || hasTestingedServices}` at line 412) and any future reader will trip on the wrong name. Rename in this PR — it's a one-character churn and worth doing while the diff is in your hands:

```ts
const hasLockedResults = services.some(
  (service) =>
    service.resultEntryStatus === "ENTERED" &&
    service.resultVerificationStatus === "VERIFIED",
);
```

Verification status enum is `("UNVERIFIED" | "VERIFYING" | "VERIFIED")` per `lab-result-verification.type.ts:7-12`, so the literal is safe and typechecked — no `enum` indirection needed.

### Nit

**N1. `hasMixedStatuses` derived from `resultEntryStatus` only** — same render at line 381-382. Not introduced by this PR, but worth flagging: the new behaviour implies "mixed" should also include `resultVerificationStatus` divergence, otherwise `hasMixedStatuses=false` combined with a mixed verification profile would let the bulk checkbox re-enable on partially-verified categories. If the verification column can legitimately split within a category (it probably can), check both. If it cannot, a one-line comment saying so would save the next reader the question.

**N2. Pre-existing dead block two screens down** — `src/app/(dashboard)/lab/lab-result-entry/[id]/page.tsx:647-661` carries a commented-out 14-line `useMemo` from a prior refactor (mentioned in PR #2863 review, still present). Not part of this PR's diff, but worth sweeping in passing: `git` has the history.

## Simplification lens (ponytail)

The diff is already minimal — one additional clause, one renamed local. Nothing to delete.

- `L383-385`: `hasTestingedServices` name with two-clause predicate: rename only (`shrink:` already-maxed). Net: 0 lines.
- `L381-382`: `hasMixedStatuses` Set-based membership check is correct (Set size > 1 for duplicates), keep as-is.

`net: -1 line possible` (variable rename to drop the misleading "Testinged" — no net line count change, just clarity).

## Recommendations

1. Apply I1 in the same PR. One-line rename, eliminates the next maintainer's confusion when reading the predicate against the variable name.
2. Confirm N1 with the team — does `resultVerificationStatus` need to participate in `hasMixedStatuses` for correctness, or is the current "resultEntryStatus-only" intentional? If intentional, comment it. If not, add to the same diff.
3. Post-merge smoke: with a category in mixed state (one `ENTERED`, one `UNVERIFIED` verification, one `VERIFIED` verification), confirm the bulk checkbox stays disabled and per-row checkboxes remain individual-toggleable.

## Reviewer notes

- ClickUp ticket `9018849685/86ey4v5mv` describes the symptom; matching it against the predicate change is recommended.
- `next.config.ts` ignores ESLint/TS errors at build time. Run `npm run lint && npm run typecheck` locally before approving.
