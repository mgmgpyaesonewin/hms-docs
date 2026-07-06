Audit Mantine component usage across `hms-app` for correctness and idiomatic usage.

**Background**

- Stack: Next.js 15 (App Router) + TypeScript + Mantine v7 + Tailwind + Prisma/PostgreSQL + tRPC.
- hms-app is the existing Next.js monolith; Mantine v7 is the primary UI component library.
- A Mantine MCP server is available — use it (via the `mcp__mantine__*` tools: `list_items`, `search_docs`, `get_item_doc`, `get_item_props`) to look up the canonical prop API and docs for each component before judging usage.
- A senior-frontend skill is available — invoke `/engineering-skills:senior-frontend` for the review heuristics.

**Scope**

- All Mantine component usage across `hms-app/src/**`.
- Focus on the components that appear most often or carry the highest risk of misuse: `Button`, `TextInput`, `Select`, `MultiSelect`, `Modal`, `Drawer`, `Table`, `Group`, `Stack`, `Grid`, `Paper`, `Card`, `Notification`, `Loader`, `Badge`, `ActionIcon`, `Menu`, `Tabs`, `Accordion`, `Form`/`useForm`.
- Do NOT review every file exhaustively — prioritize directories with the most Mantine surface (`src/app/(dashboard)`, `src/components`, `src/common`).

**What to look for**

For each component, flag (in order of severity):

1. **Bugs / broken APIs** — props that no longer exist in v7, removed/changed event signatures, wrong import paths (`@mantine/core` vs `@mantine/hooks`), missing `MantineProvider`/`withNotifications` setup.
2. **Anti-patterns** — inline styles where Mantine props exist, missing `withinPortal`/`lockScroll` on modals, uncontrolled → uncontrolled switches, `style={{}}` overrides of theme tokens, missing `key` on list items, using `Group`/`Stack` with non-Mantine children inside flex layouts.
3. **Accessibility regressions** — missing labels on form controls (use `Input.Wrapper label` or `aria-label`), missing `closeButtonLabel` on modals/drawers, click handlers on non-interactive elements, color-only state indicators.
4. **Performance** — re-render hotspots from inline objects passed to Mantine props, missing `defaultValue`/`initialValue` discipline, unnecessary `useDisclosure` re-creations.
5. **Theme/style inconsistencies** — hardcoded colors that should reference `theme.colors.*`, missing `size` prop, mixing `variant` choices that don't match the design system.

**Method — fan out to a subagent team, then synthesize**

Use `SendMessage`-first coordination per `CLAUDE.md`. Spawn the team in a SINGLE message, all `run_in_background: true`. The lead (you) is the coordinator; do not poll, do not re-derive findings.

Required agents (spawn in one message):

- **`researcher`** — for each Mantine component in scope, call the Mantine MCP server (`mcp__mantine__list_items`, `search_docs`, `get_item_doc`, `get_item_props`) to capture the canonical v7 prop API, then send the lookup results + file:line samples to `frontend-reviewer`. Do NOT pass judgment — just data.
- **`frontend-reviewer`** — runs `/engineering-skills:senior-frontend`, applies the heuristics in **What to look for**, classifies each finding by severity, and sends the classified list to `architect-reviewer`. Also sends a copy back to the lead for synthesis.
- **`architect-reviewer`** — runs `/engineering-skills:senior-architect`, evaluates the frontend findings for systemic/architectural impact (provider setup, theme tokens, design-system drift, blast radius across modules), and sends a shortlist of structural concerns to the lead.
- **Lead (you)** — receives the frontend findings + the architect's structural shortlist, deduplicates, prioritizes, and writes the report.

Pipeline: `researcher → frontend-reviewer → architect-reviewer → lead`. After spawning all three, send the kickoff to `researcher` and stop. The agents will message back as they complete.

Fallback: if any agent/skill is unavailable, document the gap in **Cross-cutting findings → Methodology gaps** and proceed with the data you have. Do not block.

**Deliverable**

A markdown report saved to `hms-docs/code-reviews/mantine-component-usage-audit.md` (create the file). Structure:

- **Summary** — count of files audited, components reviewed, totals by severity.
- **Per-component findings** — one section per Mantine component, with:
    - File paths + line numbers of problematic usages
    - The current (wrong/anti-pattern) code snippet
    - The correct/idiomatic version
    - Severity: 🔴 bug · 🟠 anti-pattern · 🟡 a11y · 🔵 perf · ⚪ style
- **Cross-cutting findings** — provider/setup issues that affect every component (e.g., missing `MantineProvider`, missing notifications portal, missing color scheme handling).
- **Recommended fixes** — a prioritized list, ordered by severity then by blast radius. Each item: what to change, where, and a one-line rationale.
- **Out of scope** — what was NOT reviewed (so the next pass knows).

**Constraints**

- Do NOT fix any code in this task. Findings + recommendations only. Implementation is a follow-up.
- Cite file paths as `path/to/file.tsx:line` so reviewers can jump straight to the issue.
- Keep snippets short (≤10 lines each). Link to the canonical docs (looked up via MCP) for anything longer.
- If the Mantine MCP server returns no doc for a component, note that explicitly — do not invent the API.
- If the senior-frontend skill is unavailable, fall back to the inline heuristics in **What to look for** above; do not block on it.

**Definition of done**

- `hms-docs/code-reviews/mantine-component-usage-audit.md` exists with all sections above populated.
- Every finding cites a real `file:line` in `hms-app/src/`.
- Every component-API claim is backed by a call to the Mantine MCP server (cite the lookup in the finding or in a footnote).
- No code in `hms-app/src/` has been modified.
