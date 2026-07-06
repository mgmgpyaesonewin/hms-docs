# PR #2838 — fix: numerix phone number input

**Repo / State / Author / Branch:** `MyanCare/Ycare-HMS` / **OPEN** / `@Xkill119966` / `fix/numerix-phone-number-input` → `development`
**Diff stats:** 8 files / ~10 inputs (17-line `onKeyDown` snippet copy-pasted at each), single commit
**CI:** not captured

**Verdict:** 🔄 Request changes
**Critical+High:** 0 Critical, 1 High, 3 Medium

## Summary

Adds a 17-line `onKeyDown` handler that `preventDefault`s anything outside `[0-9.,+-]` on phone-number input fields across the app. Targets the bug where the mobile alphabetic keyboard lets users enter letters.

The original ticket solves cleanly with **native browser attrs (`inputMode="numeric"` + `type="tel"`)** — zero JS. The added handler is browser-theater that masks the mobile symptom on desktop, breaks IME / modifier shortcuts / paste, and duplicates ~150 LOC across 8 files when one shared wrapper would do.

## Risks

- **Modifier-key shortcuts blocked.** `Ctrl+A` (select all), `Ctrl+C/V/X` (clipboard), `Ctrl+Z` (undo) all pass through keydown — every shortcut silently breaks unless the handler early-returns on `ctrlKey || metaKey || altKey`.
- **IME composition broken.** CJK / Burmese / Thai IME composition fires `keydown` for the composition char; suppress blocks the only path to type non-Latin phones (likely a real use case for an HMS rollout).
- **Paste bypass.** `onKeyDown` does not fire for `Ctrl+V`. With no `onPaste`, users can paste `"09-123abc"` straight in. The Zod schema (almost certainly `digitsOnly()`) then rejects the form silently.
- **Allow-list disagrees with schema.** Allow-list permits `-` and ` `; the Zod schema is almost certainly digits-only. Net result: form rejects chars that visibly were just typed.

## Findings

### 🔴 Critical
None.

### 🟠 High

1. **17-line `onKeyDown` snippet copy-pasted into 10 inputs across 8 files.** One shared `PhoneInput` wrapper removes ~150 lines. Mantine already ships `NumberInput` with `hideControls` + `allowDecimal={false}` — zero custom handler, type-safe. This is the requested reuse. The diff is essentially the same 17 lines copy-pasted into 10 places; the next phone-form ticket will paste it again.

### 🟡 Medium

1. **Keydown blocks modifier shortcuts (`Ctrl+A`, IME compose).** Early-return on `ctrlKey || metaKey || altKey`. Without this the form silently breaks copy / paste / undo for every phone-number field in the app.
2. **Allow-list includes `-` and ` ` but the Zod schema is almost certainly `digitsOnly()`.** Inputs without this fix accept chars the schema rejects. Confirm the schema; drop `-` and ` ` from the allow-list (phone numbers don't contain them).
3. **Paste not scrubbed — `onKeyDown` never fires for `Ctrl+V`.** User can paste `"09-123abc"` straight in. Either:
   - Add `onPaste` that scrubs non-digits, or
   - Lean on `inputMode="numeric"` + `type="tel"` so the mobile keyboard never offers letters — paste is then rare and the schema rejects it loudly.

### 🟢 Root cause vs symptom (Medium, promoted)

Title says "mobile alphabetic keyboard on `<input>`." The phone-correct fix is native: `inputMode="numeric"` + `type="tel"` solves the original ticket without any JS. The 17-line keydown is browser-theater that adds 3 bugs on desktop (modifier keys, IME, paste) and 1 inconsistency (allow-list vs schema).

## Ponytail notes

- **Rung 1 — does this need to exist at all?** Mobile kbd fix is one native attribute; no JS needed.
- **Rung 4 — native platform feature covers it.** `inputMode="numeric"` + `type="tel"` is the W3C-canonical mobile phone input. No custom handler, no copy-paste, no browser-theater.
- **Rung 5 — already-installed dependency solves it.** Mantine `NumberInput` `hideControls` + `allowDecimal={false}` is the installed primitive. Zero custom handler.
- **Rung 2 — already in this codebase?** No existing `PhoneInput` / `NumericInput` helper. `src/components/custom-text-input.tsx` is unrelated (placeholder overlay for member cards).
- **Root cause vs symptom.** The user-visible bug is "letters can be typed on mobile." The native fix is one attribute. The JS handler is a workaround that introduces 3 bugs and 150 LOC.
- **Sibling code.** Every other phone input **not** touched by this PR still accepts letters. Flag once at the root, not per-form.

## Reuse check

- `src/components/custom-text-input.tsx` — unrelated (placeholder overlay for member cards). No phone-input helper exists in the repo.
- **Mantine `NumberInput`** — installed, ships `hideControls` + `allowDecimal={false}` — drop-in for a digit-only field with no spinner.
- `useDebouncedCallback` (if not already used in repo) — new dep for an 8-line effect. Pick one.

## Tests

- **None added.**
- **Minimum useful additions** (Ponytail "one runnable check"):
  1. RTL render of `ClinicForm` + `userEvent.keyDown` `"a"` → expect `preventDefault` was called (proves suppression).
  2. RTL render of `ClinicForm` + `userEvent.keyDown` `"9"` → expect field value is `"9"`.
  3. RTL render of `ClinicForm` + `userEvent.paste("09-123abc")` → expect value is `"09123"` (proves paste guard the PR is missing).
  4. RTL render of `ClinicForm` + `userEvent.keyDown` `{ctrl: true}` + `"a"` → expect `preventDefault` was **not** called (proves modifier-early-return).

## Bottom line

Either:
- **(A) drop the 17-line handler and add `inputMode="numeric"` + `type="tel"`** to the inputs — one attribute, root-cause, no JS, no JS bugs. **Preferred.**
- **(B) keep the handler as a belt-and-braces** measure but: drop the copy-paste to a single shared `PhoneInput`, early-return on modifier keys, scrub paste, drop `-` and ` ` from the allow-list (or align the schema), and add a paste regression test.
