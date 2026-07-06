# Code reviews

Historical code-review notes for the HMS project, bucketed by month.

## Layout

```
code-reviews/
└── by-month/
    ├── YYYY-MM/   one folder per month of reviews
    └── ...
```

Each file is named `YYYY-MM-DD-<slug>.md` where the date prefix is the
review date (or, for files missing one, the git commit date — see below).

## Naming convention

- **PR reviews:** `YYYY-MM-DD-pr-NNNN-slug.md` (e.g.
  `2026-06-24-pr-2744-cathlab-daily-bill-review.md`).
- **Audit / cross-cutting notes:** `YYYY-MM-DD-slug.md` (e.g.
  `2026-07-06-mantine-component-usage-audit.md`).
- **PR-number-only files** (`pr-2749.md` with no descriptive slug) are
  kept as-is under the new prefix; rename them when you next open them.

## Date provenance

Where the original filename already had `YYYY-MM-DD`, that date was used.
Otherwise the date was taken from `git log --format=%cs -1`, and finally
from filesystem mtime. Files with no in-filename date may have a
git/mtime date that doesn't match the original review date; rename
them by hand if you know better.

## Pre-2026-06-16 history

Anything older than `2026-06-16/` was either migrated from the old flat
naming (`pr-NNNN.md`, `pr-NNNN-slug.md`) or from ad-hoc drafts
(`2026-06-16-hms-app-modules.md`). The new layout enforces one
convention going forward.

## Adding new reviews

When you finish a review, drop it in `by-month/<YYYY-MM>/` with the
prefix `YYYY-MM-DD-`. PR reviews: `pr-NNNN-<short-slug>.md`. Other
audit notes: `<short-slug>.md`. Keep it short — the slug is the only
metadata in the filename.