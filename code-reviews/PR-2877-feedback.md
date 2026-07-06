# PR #2877 — fix stock request print

**Repo:** MyanCare/Ycare-HMS
**PR:** https://github.com/MyanCare/Ycare-HMS/pull/2877
**Author:** April-Naing
**Changed files:** 1 (`src/app/(dashboard)/pharmacy/stock/stock-request/features/components/stock-request-print-document.tsx`, +9 / -5)
**ClickUp:** https://app.clickup.com/t/9018849685/86ey390ww
**Branch:** `fix/april/sprint-26/stock-request` → `development`
**Verdict:** Changes requested (small)

## Summary

Two-cell column layout fix on the stock-request print document table. The "Requested" and "Received" columns are switched from `px-1 py-1.5 w-40` (left-aligned, uniform padding, 160px wide) to `text-right`, asymmetric padding (`pl-1 pr-8` / `pr-10`), narrower width (`w-32`, 128px), and the inner `Received` box drops its explicit border + fixed-height/min-width/max-width chrome in favor of the `<td>`'s own padding. Net effect: numbers right-align, the borderless "received" cell no longer overflows on printers, columns are 32px narrower.

Fix direction is right and the layout changes are minimal. Three things to tighten:

## Issues

### Important

1. **Column widths were reduced (`w-40` → `w-32`) without a width budget** — `stock-request-print-document.tsx:161-164` (header row). The two changed `<th>`s used to be 160px each and are now 128px each. The other columns (`Item`, `Batch`, `Expiry`) keep their original widths (`w-28` etc.). Print-layout total width should still fit an A4 portrait, but the PR does not show an actual print preview of the affected rows — and a future column addition would push the table over its container without warning. Cheap win: add `table-layout: fixed` (Tailwind: `table-fixed`) on the `<table>` and a `print:` style pass if A4 layout is sensitive. If a screenshot of the printed PDF was attached to the ClickUp ticket, link it from the PR body; reviewers cannot verify the print result from the diff alone.

2. **`Received` cell loses its visible bounding box** — `stock-request-print-document.tsx:196-199` (the new `<div>` inside the Received `<td>`). The previous `<div className="inline-block border border-gray-800 px-1 h-[12px] min-w-[60px] max-w-[70px]">` was the only thing that *visually* marked the editable input slot on paper. After the change the `<div>` has no styling at all, so the "Received" cell on the printed page renders an empty number with no border to indicate "fill this in." If the border was deliberately removed because the print preview looked better without it, that's fine — but it now reads as "this row is missing data" rather than "intentionally blank field." Either:
   - keep a `print:`-scoped border (so the live preview drops the border but the printed PDF keeps it), or
   - document the decision in the PR body.

### Nit

3. **Trailing whitespace in `text-right "`** — `stock-request-print-document.tsx:199`. New line is `<td className="pl-1 pr-10 py-1.5 w-32 text-right ">` with a stray space before the closing quote. Cosmetic, ESLint usually catches it; trim it.

4. **Inconsistent padding math** — `stock-request-print-document.tsx:161, 164, 196, 199`. Header `<th>` uses `pl-1 pr-8` / `pr-10`; the matching `<td>`s use the same. Why two different right paddings (`pr-8` vs `pr-10`) on adjacent columns? If the goal is 8px / 10px optical alignment because "Requested" has the parenthesised qualifier, fine — but it's a magic number. Pick the smallest pair that aligns and leave a one-line comment if it's intentional, or normalise both to the same value.

5. **PR title is vague** — `fix stock request print`. Repo convention is `fix(scope): what`; `fix(pharmacy/stock-request): align right-justified quantity columns in print layout` would survive `git log`.

## Recommendations

- Attach (or link in the PR body) a print preview screenshot of one row with mixed widths so reviewers can confirm the layout reads correctly on A4.
- Decide and commit to one of the two options on the Received-cell box: `print:`-scoped border if the input slot is meant to be filled in by hand, or explicit acceptance in the PR body that the empty cell is intentional.
- Trim the trailing space on the `text-right` class string.
- Normalise the right-pad values across the two columns or leave a one-line comment justifying `pr-8` vs `pr-10`.

## Reviewer notes

- `next.config.ts` ignores ESLint/TS errors at build time. Run `npm run lint && npm run typecheck` locally before approving — the trailing whitespace should be caught.
- The `reduce(...)` inside the Received cell (unchanged in this diff) returns a number but React renders it directly; with the removed `border` + `px-1` wrapper that number now sits flush against the cell's `pr-10` right padding. Worth eyeballing once.
- Smallest-possible follow-up: this PR is a fair basis for shipping the fix. The two column-widths and the bounding-box questions are both one-line follow-ups in a separate screenshot-on-PR change, no need to gate this on them if the author confirms by reply.

net: ~0 lines possible. Lean already; only correctness/clarity nits remain.
