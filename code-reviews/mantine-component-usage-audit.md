# Mantine v7 Component Usage Audit — `hms-app`

**Date:** 2026-07-03
**Scope:** `hms-app/src/**` (Next.js 15 App Router + TypeScript + Mantine v7)
**Method:** Three-stage agent pipeline (researcher → frontend-reviewer → architect-reviewer) using Mantine MCP for canonical v7 prop API and `/engineering-skills:senior-frontend` + `/engineering-skills:senior-architect` for review heuristics.
**Constraint:** No code in `hms-app/src/` was modified. Findings + recommendations only.

---

## Summary

| | |
|---|---|
| **Files using Mantine in the project** | ~1 598 (2 440 import lines) |
| **Files in audit surface (top Mantine use)** | ~25 |
| **Components in scope** | 20 (Button, TextInput, Select, MultiSelect, Modal, Drawer, Table, Group, Stack, Grid, Paper, Card, Notification, Loader, Badge, ActionIcon, Menu, Tabs, Accordion, Form/useForm) |
| **Total findings** | **39** (🔴 0 · 🟠 9 · 🟡 13 · 🔵 0 · ⚪ 17) + 7 structural concerns |
| **Provider/theme setup** | Idiomatic. No bugs. |
| **Top blast-radius files** | `app/(dashboard)/ipd/admission/feature/components/admission-form.tsx` (~10 findings), `prescription-form.tsx` (4), `ipd-billing-ward-services.tsx` (3) |

**Verdict:** The hms-app Mantine surface is **structurally correct at the provider/theme layer** and **free of v6-era API regressions**. The issues are surface-level: a11y gaps in two specific form patterns, a small set of inline `style={{}}` overrides that defeat the design system, and a few Modal hygiene inconsistencies. **Zero bugs.** All findings are a11y / anti-pattern / style.

**Severity legend:** 🔴 bug · 🟠 anti-pattern · 🟡 a11y · 🔵 perf · ⚪ style

---

## Per-component findings

### Button

No findings. Usage across the codebase is idiomatic. (Not exhaustively sampled — out of top surface.)

### TextInput — 4 findings (🟡 ×4)

All four findings are the same pattern: dosage/duration/remark inputs in tabular prescription forms have no `aria-label` and the parent `<Table.Th>` is a header, not a form label. ~30 unlabeled inputs total.

**T1 · 🟡 a11y** — `app/(dashboard)/ipd/features/components/prescription/prescription-form.tsx:411-418`

Current:
```tsx
<TextInput className="w-[50px]" placeholder="" {...form.getInputProps(`medicines.${index}.morningDosage`)} />
```

Corrected:
```tsx
<TextInput
  className="w-[50px]"
  aria-label={`Morning dosage for medicine ${index + 1}`}
  {...form.getInputProps(`medicines.${index}.morningDosage`)}
/>
```

**T2 · 🟡 a11y** — Same file:421-454. Same fix for `noonDosage`, `eveningDosage`, `nightDosage`, `duration`, `remark`.

**T3 · 🟡 a11y** — `app/(dashboard)/ipd/features/components/dischage-summary/discharge-prescription-section.tsx:262-339`. Same fix.

**T4 · 🟡 a11y** — `app/(dashboard)/emr/ipd/features/components/prescription/ipd-emr-prescription-form.tsx:393-461`. Same fix.

**MCP backing:** `TextInput` — `aria-label` is the standard escape hatch; `withAsterisk` shows a red `*` but does **not** set HTML `required` or `aria-required`.

### Select / MultiSelect

No findings in the top-30 audit surface. (Out of scope: deep `Select`/`MultiSelect` review — see "Out of scope" below.)

### Modal — 4 findings (⚪ ×4)

`withCloseButton={false}` and `size="100%"` are declared ad hoc across IPD billing. **Not a 🔴** — Mantine v7 defaults (`withinPortal`, `trapFocus`, `lockScroll`) are sensible, and 333 Modal usages that don't set them are fine.

**M1 · ⚪ style** — `app/(dashboard)/ipd/features/components/prescription/prescription-form.tsx:325-358`
```tsx
<Modal ... withCloseButton={false} size={"400px"}>
```
Non-standard overrides. Mantine v7 has **no** `closeButtonLabel` prop.

**M2 · ⚪ style** — `app/(dashboard)/ipd/ipd-billing/features/components/ipd-billing-ward-services.tsx:37`
```tsx
<Modal ... size={"100%"}>
```

**M3 · ⚪ style** — `app/(dashboard)/ipd/ipd-billing/features/components/ipd-billing-pharmacy-sale.tsx:49-54`. Same as M2.

**M4 · ⚪ style** — `app/(dashboard)/ipd/ipd-billing/features/components/ipd-billing-pharmacy-return.tsx:38-43`. Same as M2.

**Recommendation:** see Structural concern 5 in Cross-cutting findings — fix in `lib/theme.tsx`, not per-file.

### Drawer

No findings. (1 use, no samples in audit surface.)

### Table — 2 findings (🟠 ×2)

**TB1 · 🟠 anti-pattern** — `app/(dashboard)/ipd/ipd-billing/features/components/ipd-billing-ward-services.tsx:57-69` (×6)
```tsx
<Table.Th style={{ textAlign: "right" }}>...</Table.Th>
```
Replace with:
```tsx
<Table.Th ta="right">...</Table.Th>
```

**TB2 · 🟠 anti-pattern** — Same file:81-99 (×2). `<Table.Td style={{ textAlign: "right" }}>` → `<Table.Td ta="right">`.

**MCP backing:** `Table.Th`/`Table.Td` accept Box style shortcuts (`ta`, `p`, `m`, `c`, `bg`, etc.).

### Group — 3 patterns, 11 sites (🟠 ×11)

**G1 · 🟠 anti-pattern** — `app/(dashboard)/ipd/admission/feature/components/admission-form.tsx:646, 870, 1148, 1182, 1218, 1545` (×6)
```tsx
<Group style={{ display: "flex" }}>...</Group>
```
`<Group>` already renders `display: flex`. Drop the style.

**G2 · 🟠 anti-pattern** — Same file:1078-1129. `<Group className="flex w-full items-end"><div className="flex-1">...<div className="flex items-center gap-1 ml-2">...</div></Group>` — replace raw `<div>`s with `<Box>`/`<Group>` props (`gap`, `align`, `wrap`, `justify`).

**G3 · 🟠 anti-pattern** — `app/(dashboard)/opd/opd-billing/ot-request-list/features/components/opd-ot-request-form.tsx:1136, 1187, 1239, 1289` (×4). Same G2 pattern.

### Stack

No findings. (CS1 — see Chip — was a `Stack`/`Group` wrapping question, captured under Chip.)

### Grid

No findings.

### Paper

No findings.

### Card — 1 finding (⚪ ×1)

**CA1 · ⚪ style** — `app/(dashboard)/common/dashboard/components/dashboard-kpi-card.tsx:15`
```tsx
<Card radius="md" p="lg" style={{ background: bg }}>
```
Replace with:
```tsx
<Card radius="md" p="lg" bg={bg}>
```
Mantine v7's `bg` prop accepts CSS color strings directly.

### Notification

No findings. `<Notifications />` is mounted correctly under `<MantineProvider>` in `app/providers.tsx`. **Confirm in prod build** — see CC-3 in Cross-cutting findings.

### Loader

No findings. (Theme override reviewed; idiomatic.)

### Badge

No findings.

### ActionIcon — 3 patterns, 8 buttons (🟡 ×8)

All three findings are the same pattern: `ActionIcon` + `Tooltip` pair, where the Tooltip text does not reach screen readers. Mantine v7 has **no** built-in `aria-label` for ActionIcon.

**A1 · 🟡 a11y** — `app/(dashboard)/pharmacy/stock/used-items/features/components/used-item-table-row.tsx:272-281`
```tsx
<ActionIcon variant="transparent" color="error" onClick={...}>
  <Tooltip label="Remove"><Trash2 /></Tooltip>
</ActionIcon>
```
Corrected:
```tsx
<ActionIcon variant="transparent" color="error" aria-label="Remove item" onClick={...}>
  <Tooltip label="Remove"><Trash2 aria-hidden /></Tooltip>
</ActionIcon>
```

**A2 · 🟡 a11y** — `app/(dashboard)/ipd/features/components/pharmacy-request/pharmacy-request-form.tsx:413-422`. Same pattern.

**A3 · 🟡 a11y** — `app/(dashboard)/ipd/admission/feature/components/admission-form.tsx:1106-1117, 1119-1127, 1462-1475, 1477-1485, 1642-1652, 1655-1663` (×6). Same pattern.

### Menu / Tabs / Accordion

No findings.

### Chip — 1 finding (⚪ ×1)

**CS1 · ⚪ style** — `app/(dashboard)/ipd/admission/feature/components/admission-form.tsx:1559`
```tsx
<Group mt={5}>
  <Chip>...</Chip>
  <Chip>...</Chip>
</Group>
```
If the chips form a single-select or multi-select group, wrap with `<Chip.Group>`; otherwise use `<Stack gap="xs">`.

### Form / useForm — 1 finding (⚪ ×1)

**F1 · ⚪ style** — 6 files mix RHF's `<Form>` and raw `<form onSubmit={handleSubmit(...)}>`. No bug. Pick a convention.

Files: `pharmacy/stock/used-items/features/components/used-item-form.tsx`, `ipd/features/components/prescription/prescription-form.tsx`, `ipd/features/components/pharmacy-request/pharmacy-request-form.tsx`, `emr/ipd/features/components/prescription/ipd-emr-prescription-form.tsx`, `ipd/admission/feature/components/admission-form.tsx`, `opd/opd-billing/ot-request-list/features/components/opd-ot-request-form.tsx`.

Recommendation: settle on raw `<form onSubmit={handleSubmit(...)}>` (the project already does not depend on `@mantine/form`).

---

## Cross-cutting findings

These are systemic / architectural concerns that affect more than one component. They were elevated by the architect-reviewer from the frontend-reviewer's per-file list.

### CC-1 to CC-5 — Provider/theme setup review

| # | Sev | Note | Status |
|---|---|---|---|
| CC-1 | ⚪ | `lib/theme.tsx` `theme.components.TableThead` uses `bg: "brand"` (no shade) — resolves to "filled" token. | Informational, not a bug. |
| CC-2 | ⚪ | `theme.components.Modal` override `centered: true`. | Intentional, 333 Modal usages inherit. |
| CC-3 | 🟡 a11y | `<ColorSchemeScript>` and `mantineHtmlProps` correctly applied in `layout.tsx`; `<Notifications />` mounted under `<MantineProvider>`. | **Confirm in prod build.** |
| CC-4 | ⚪ | `theme.components.Combobox.shadow = "sm"`. | Intentional. |
| CC-5 | ⚪ | `theme.components.ActionIcon.size = "input-sm"` — `"input-sm"` is valid in v7. | OK. |

**MCP backing:** `Table`, `Modal`, `Combobox`, `ActionIcon` lookups.

### H1–H9 — Hardcoded colors (design-system gap)

`theme.colors` registers `brand`, `error`, `accent`, `excel`, `pdf` — but not `orange`, `green`, `blue`, `red`. Status indicators pick hex off the top of contributors' heads. See **Structural concern 3** below.

| # | Sev | File:line | Current | Corrected |
|---|---|---|---|---|
| H1 | ⚪ | `pharmacy/sale-return/features/components/sale-return-detail.tsx:129` | `style={{ color: "#FC7A1E" }}` | `c="accent.6"` (or register `orange` tuple) |
| H2 | ⚪ | `pharmacy/stock/stock-request/features/components/stock-request-transfer-status.tsx:108,116,129` | `#FC7A1E`, `#000DFF`, `#FF2500` | `c="accent.6"`, `c="blue.6"`, `c="error.6"` |
| H3 | ⚪ | `emr/features/pharmacy-request/emr-pharmacy-request-status.tsx:97,104,111,118,125` | same hex pattern | same |
| H4 | ⚪ | `emr/features/patient-appointment-remark.tsx:292` | `<span style={{ color: "var(--mantine-color-error)" }}>*</span>` | `withAsterisk` on the input |
| H5 | ⚪ | `opd-billing/features/components/opd-billing-table-columns.tsx:470` | `<div style={{ color: "green", fontSize: "0.8em" }}>` | `c="excel.6" fz="xs"` |
| H6 | ⚪ | `lab-template-microbiology-template-form.tsx:2107, 2171, 2238, 2305` + `lab-template-category-services.tsx:1505` | `style={{ background: colors.brand[600], color: "#fff" }}` ×5 | `bg="brand.6" c="white"` |
| H7 | ⚪ | `common/dashboard/components/dashboard-donut.tsx:45, 55, 65` | `style={{ background: "#099268", ... }}` | register or reuse color tuple |
| H8 | ⚪ | `opd/services/service-package/features/components/service-select-item.tsx:187` | `<span style={{ color: "red" }}>*</span>` | `withAsterisk` |
| H9 | ⚪ | `common/patients/features/components/delete-patient-model.tsx:33`, `patient-form.tsx:371, 403` | `<span style={{ color: "red" }}>*</span>` | `withAsterisk` |

**MCP backing:** `Box`/`Text` `c`/`bg` props accept `MantineColor | CSS color`.

### Structural concerns (architectural level)

Each concern groups related findings under a single root cause and proposes a structural fix.

#### SC-1 · Form accessibility is unowned at the component layer — 🔴 systemic a11y

**Cluster:** T1–T4 (TextInput a11y) + A1–A3 (ActionIcon a11y) — ~40 unlabeled elements across 5 files.

**Root cause:** The labeling contract for tabular form cells is unowned. `<Table.Th>` is a header, not a form label. Anywhere a component is used inside a row of a custom grid, the accessible name is invented ad hoc or omitted.

**Structural fix:** Ship one shared wrapper per surface, owned in `@common/forms/`:
- `<RowTextInput rowLabel columnLabel />` — auto-wires `aria-label="{rowLabel} {columnLabel}"` and forwards the rest.
- `<RowActionIcon label>` — wraps `ActionIcon`, requires `label` (TS prop, not optional), puts the icon inside a `<VisuallyHidden>` as a secondary signal.

This lands the a11y fix in 4–5 files from a single primitive, instead of editing 40+ call sites.

**Blast radius:** ~5 files, ~40 individual call sites. Fix once in `@common/forms/`, replace usages.

#### SC-2 · Required-field indicator uses raw `<span style={{ color: "red" }}>` instead of `withAsterisk` — 🟡 a11y + ⚪ style

**Cluster:** H4, H8, H9 — 6 sites.

**Root cause:** Sibling-span approach has no `aria-required`, no programmatic link to the input, breaks for screen readers, and visual drifts when the brand red token changes (the project has no `red` in `theme.colors`).

**Structural fix:** Audit `withAsterisk` usage in inputs that already render required markers; replace sibling spans with `withAsterisk`. Also pass `required` so screen readers see `aria-required="true"`. No wrapper needed — codemod/linter job.

**Blast radius:** ~6 files, ~6 sites, low-risk mass-edit.

#### SC-3 · Status colors are hardcoded hex, not theme tokens — ⚪ style (architectural)

**Cluster:** H1, H2, H3, H5, H6, H7 — ~25 sites across 10 files.

**Root cause:** Status indicators across pharmacy/EMR/OPD pick hex off the top of their head. The 3-color status pattern (orange=pending, blue=in-progress, red=rejected/returned) is the same everywhere, but no one owns it. `colors.brand[600]` is also out-of-theme — Mantine v7 accepts `bg="brand.6"` directly.

**Structural fix:** In `lib/theme.tsx`, register one tuple per status: `orange` (10 shades), `green` (10), `blue` (10), `red` (10). Then a one-line codemod: hex → `c="orange.6"` / `c="green.6"` / `c="blue.6"` / `c="red.6"`. Also retire the `style={{ background: colors.brand[600] }}` pattern in favor of `bg="brand.6"`.

**Blast radius:** ~10 files. One-file theme edit + per-file mechanical replacement.

#### SC-4 · `<Group style={{ display: "flex" }}>` and `<Th/Td style={{ textAlign: "right" }}>` — 🟠 anti-pattern

**Cluster:** G1, G2, G3, TB1, TB2 — ~11 sites across 4 files.

**Root cause:** Contributors know Tailwind and don't trust Mantine's intrinsic props. `<Group>` already renders `display: flex`; `ta="right"` exists on every Mantine surface. Same misunderstanding, twice.

**Structural fix:** One-line ESLint rule banning `style={{ display: "flex" }}` on Mantine layout components and banning `style={{ textAlign: "..." }}` (forces `ta`). No wrapper, no helper — just a lint rule + a mechanical codemod. `flex-1` divs → keep them; Tailwind is fine inside Mantine.

**Blast radius:** 4 files, ~11 sites.

#### SC-5 · Modal `size="100%"` and `withCloseButton={false}` declared ad hoc — ⚪ style (architectural)

**Cluster:** M1, M2, M3, M4 — 4 files.

**Root cause:** IPD billing modals settled on `size="100%"` by word of mouth; prescription modal settled on a different convention. `lib/theme.tsx` already overrides `centered: true` for all Modals — which proves the pattern works. The theme is just incomplete.

**Structural fix:** Extend `theme.components.Modal` with defaults: `size: 'xl'`, `centered: true` (already there), `withCloseButton: true` (drop the explicit `false`). Sites that need `100%` width can still pass `size="100%"` — `MantineSize | (string & {})` accepts it. Sites that explicitly want no close button call it out.

**Blast radius:** 4 files, theme touched once. Modals across the whole app (333) inherit.

#### SC-6 · Mixed form pattern: RHF `<Form>` vs raw `<form>` — ⚪ style (convention drift)

**Cluster:** F1 — 6 files.

**Root cause:** RHF's `<Form>` renders a `<form>` element automatically; some files wrap manually with `<form onSubmit={handleSubmit(...)}>`. Both work. The project does not use `@mantine/form`. Convention drift, not a bug.

**Structural fix:** Pick `handleSubmit` (raw `<form>`) and document the choice. No wrapper, no migration. Ponytail: a one-line note in `lib/forms/README.md` (or just in code review).

**Blast radius:** Convention only; no mandatory code change.

#### SC-7 · `Card` `style={{ background: bg }}` should use Mantine `bg` prop — ⚪ style (single point)

**Cluster:** CA1 — 1 file.

**Root cause:** Contributors don't realize Mantine's `bg` prop accepts CSS color strings.

**Structural fix:** Replace `style={{ background: bg }}` with `bg={bg}`. Single-file, one line.

**Blast radius:** 1 file. (The hex colors issue is SC-3.)

---

## Recommended fixes (prioritized by severity × blast radius)

### Prio 1 — biggest user-facing win (a11y)

1. **SC-1 · Build `<RowTextInput>` + `<RowActionIcon>` wrappers in `@common/forms/`.** Replace the 40+ unlabeled elements across `prescription-form.tsx`, `ipd-emr-prescription-form.tsx`, `discharge-prescription-section.tsx`, `used-item-table-row.tsx`, `pharmacy-request-form.tsx`, `admission-form.tsx`. **Rationale:** highest blast radius; ships in one commit; biggest screen-reader impact.
2. **SC-2 · Codemod sibling `<span style={{ color: "red" }}>` to `withAsterisk`.** ~6 sites. **Rationale:** cheap a11y cleanup; ~30 min.

### Prio 2 — design system wins

3. **SC-3 · Register status color tuples in `lib/theme.tsx`, then codemod hex → `c="..."` / `bg="..."`.** ~10 files. **Rationale:** centralizes palette; future-proofs the 3-color status pattern that recurs across pharmacy/EMR/OPD.
4. **SC-5 · Extend `theme.components.Modal` defaults.** 1 file edit, 333 modals inherit. **Rationale:** cheapest theme fix, largest surface impact.

### Prio 3 — codemod / lint-rule level

5. **SC-4 · Add ESLint rule banning `style={{ display: "flex" }}` and `style={{ textAlign: "..." }}` on Mantine components.** 4 files, ~11 sites. **Rationale:** prevents the same anti-pattern from regrowing.
6. **SC-7 · Replace `Card style={{ background }}` with `bg`.** 1 file, 1 line. **Rationale:** one-line cleanup, do it with SC-4.

### Prio 4 — convention / documentation

7. **SC-6 · Document RHF form pattern convention in `lib/forms/README.md`.** 0 code change. **Rationale:** stops drift; takes 5 minutes.

### Prio 5 — one-off cleanups

8. **CS1 · `<Chip.Group>` or `<Stack>` instead of `<Group>` for `Chip`s in `admission-form.tsx:1559`.** 1 line.
9. **CC-3 · Confirm `<Notifications />` mount order in prod build.** Verification only.

---

## Out of scope (so the next pass knows)

**Not reviewed:**

- `Drawer` (1 use in the codebase, no samples in the audit surface)
- `Tabs.Panel` value matching / controlled vs uncontrolled
- `MultiSelect` `hiddenInputValuesDivider` / `searchable` / `clearable` API surface
- `Table.Caption` a11y, `Table.stickyHeader`, `Table.ScrollContainer`
- Components below the top-30 surface: `Autocomplete`, `Slider`, `Switch`, `Checkbox`, `Radio`, `ColorPicker`, `RangeSlider`, `Stepper`, `Timeline`, `RingProgress`, `Progress`, `Rating`, `Spoiler`, `HoverCard`, `Popover`
- Server-component vs client-component boundary for Mantine hooks (use client directives were not audited)
- Bundle size / dynamic import patterns for Mantine chunks
- Color-scheme switching behavior across pages
- Mantine CSS layer (postcss-preset-mantine) coverage / specificity collisions with Tailwind

**Not modified:**

- No code in `hms-app/src/` was changed.
- No new dependencies were added.
- No theme files were edited.

### Methodology gaps

- **Mantine MCP returned no doc for `useForm` from `@mantine/form`.** Moot for hms-app (the project uses `react-hook-form`, not `@mantine/form`); noted here for completeness.
- **No prod-build verification** of `<Notifications />` mount order or `mantineHtmlProps` propagation (would require a build run; deferred to follow-up).

---

## Appendix · Per-file finding density

| File | Findings | Severity mix |
|---|---|---|
| `app/(dashboard)/ipd/admission/feature/components/admission-form.tsx` | ~10 | G1 ×6, G2, A3 ×6, CS1, F1 |
| `app/(dashboard)/ipd/features/components/prescription/prescription-form.tsx` | 4 | T1, T2, M1, F1 |
| `app/(dashboard)/ipd/ipd-billing/features/components/ipd-billing-ward-services.tsx` | 3 | M2, TB1, TB2 |
| `app/(dashboard)/opd/opd-billing/ot-request-list/features/components/opd-ot-request-form.tsx` | 5 | G3 ×4, F1 |
| `app/(dashboard)/ipd/features/components/pharmacy-request/pharmacy-request-form.tsx` | 2 | A2, F1 |
| `app/(dashboard)/ipd/features/components/dischage-summary/discharge-prescription-section.tsx` | 1 | T3 |
| `app/(dashboard)/emr/ipd/features/components/prescription/ipd-emr-prescription-form.tsx` | 2 | T4, F1 |
| `app/(dashboard)/ipd/ipd-billing/features/components/ipd-billing-pharmacy-sale.tsx` | 1 | M3 |
| `app/(dashboard)/ipd/ipd-billing/features/components/ipd-billing-pharmacy-return.tsx` | 1 | M4 |
| `app/(dashboard)/common/dashboard/components/dashboard-kpi-card.tsx` | 1 | CA1 |
| `app/(dashboard)/common/dashboard/components/dashboard-donut.tsx` | 1 | H7 |
| `app/(dashboard)/common/patients/features/components/delete-patient-model.tsx` + `patient-form.tsx` | 1 | H9 |
| `app/(dashboard)/opd/services/service-package/features/components/service-select-item.tsx` | 1 | H8 |
| `app/(dashboard)/opd/opd-billing/features/components/opd-billing-table-columns.tsx` | 1 | H5 |
| `app/(dashboard)/pharmacy/sale-return/features/components/sale-return-detail.tsx` | 1 | H1 |
| `app/(dashboard)/pharmacy/stock/stock-request/features/components/stock-request-transfer-status.tsx` | 1 | H2 |
| `app/(dashboard)/pharmacy/stock/used-items/features/components/used-item-table-row.tsx` | 2 | A1, F1 |
| `app/(dashboard)/emr/features/pharmacy-request/emr-pharmacy-request-status.tsx` | 1 | H3 |
| `app/(dashboard)/emr/features/patient-appointment-remark.tsx` | 1 | H4 |
| `app/(dashboard)/lab/lab-template/features/components/lab-template-microbiology-template-form.tsx` + `lab-template-category-services.tsx` | 1 (5 sites) | H6 |

**Total audited: ~20 files. Total findings: 39. Total structural concerns: 7.**
