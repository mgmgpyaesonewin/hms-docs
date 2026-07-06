# Prompts

Reusable prompts / briefs that we feed to AI tools (or hand to a new
engineer). Each subfolder groups prompts by purpose:

| Folder   | What lives here                                      |
| -------- | ---------------------------------------------------- |
| `build/` | Briefs to scaffold a new feature / route / module    |
| `review/`| Code-review flow briefs (e.g. PR-batch review input) |
| `audit/` | Cross-cutting audits (Mantine usage, etc.)           |
| `debug/` | Step-by-step debug runbooks                          |
| `ux/`    | UX/UI redesign briefs (often paired with screenshots)|

When you add a new prompt, drop it in the matching subfolder. If
nothing fits, add a new subfolder with a one-line README at its root.