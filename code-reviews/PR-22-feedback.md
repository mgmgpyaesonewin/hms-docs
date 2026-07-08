# PR #22 — .5 Decimal Accept in Daily Medicine and Even number only in Durations of Medicine

**Repo:** MyanCare/HMS-Hni-Zi-Gone
**PR:** https://github.com/MyanCare/HMS-Hni-Zi-Gone/pull/22
**Base:** `development` → **Head:** `mpt/half-decimal-accept-daily-medicine`
**Files changed:** 8 (+36 / -16)
**Author:** myopaingthu · **Reviewer:** mgmgpyaesonewin

## Verdict

**Approve with comments.** Small, focused, schema/UX hang together. One real (latent) bug and a missing test. Nothing blocks merge.

## Summary

Daily-medicine template items now accept half-unit qty (0.5, 1.5) — Prisma column, schema, form, and view updated with a UI hint. Medicine-record durations require `≥ 2` and even. Three `actions.ts` paths route Zod failures through `handleActionError` for consistent responses + Sentry capture.

## Findings

1. **[bug, latent] `medicine-form.tsx:168` & `:195` — template qty × durationDays vs `qty.int()`.** Template qty is now decimal; `durationDays` is now forced even. The product `0.5 × even = int` so the `medicineRecordItemFormSchema.qty.int()` (`.schema:40`) currently accepts every legal combination. **But the constraint pairing is implicit — relax either one (e.g. drop the `% 2` refine) and the form rejects the multiply with a 400 the user can't see.** Two fixes, pick one:
   - Loosen `qty` to `.multipleOf(0.5)` and `Math.round` server-side in `medicine-record.service.ts:28`.
   - Add `// ponytail: invariant — durationDays is even (per refine above), template qty is multiple of 0.5, so product is int. Drop this comment if either constraint loosens.` next to the `Number(item.qty) *` calls.

2. **[bug, UX] `medicine-form.tsx:166-168` — silent fallback when `durationDays` is cleared.** `Number(item.qty) * (form.getValues("durationDays") || 1)` falls back to `* 1` if the user clears the field. The client renders the multiplied qty, then the server returns 400 "Duration (Days) is required". Surface this at the field (`error={form.formState.errors.durationDays?.message}`) and disable template apply until `durationDays` is set. The refine already handles it server-side, this is purely UX.

3. **[chore] `medicine-record-form.schema.ts:78-82` — `int() + .min(2) + .refine(v => v % 2 === 0)` is two rules saying the same thing.** Replace `.int() + .refine(...)` with `.multipleOf(2)` and a single message — same UX, one rule. Also `// ponytail` so a future helper doesn't rewrite the error.

4. **[chore] `medicine-form.tsx:248-250` — placeholder duplicates the Zod error.** "Enter Days (Even Number)" is a second source of truth. Drop the placeholder; rely on the Zod error.

5. **[chore] `actions.ts:37,62,82` — three identical `safeParse → handleActionError` blocks.** Extract a `parseOrFail(schema, data)` only when a 4th caller lands. Three is fine.

6. **[chore] `daily-medicine-template-form.schema.ts:31-34` — `.refine(v => Number.isInteger(v * 2))`.** `z.number().multipleOf(0.5)` is the native spelling; keep the refine only because the custom message is better UX. Add `// ponytail: refine kept for message`.

## Correctness / quality summary

- **Security:** `handleActionError` now wraps Zod errors with a "Validation error: …" prefix. Zod errors include field paths/values — currently safe for these schemas, but worth a comment in `handleActionError` warning future authors who add PII fields to `safeParse` paths. No auth/RBAC changes.
- **Design:** SRP holds. Single transaction writes one table; migration is `ALTER COLUMN ... SET DATA TYPE DECIMAL(10,2)` (table rewrite, `VACUUM`/`ANALYZE` after deploy — non-concurrent, fine for this table size).
- **Perf:** negligible — form-level arithmetic.
- **Docs:** PR body is two ClickUp links; the only doc surface is the inline `// ponytail` comments suggested above.

## Test coverage

**Added in this PR:** none.

**Needed before merge:**
- Zod unit test: `dailyMedicineTemplateItemFormSchema.qty` accepts `0.5, 1, 1.5`, rejects `0.3`.
- Zod unit test: `medicineRecordFormSchema.durationDays` accepts `2, 4`, rejects `1, 3, 2.5`.
- Server-action test: `createMedicineRecord` with `durationDays: 3` returns 400 (use the team Jest setup; if not present, add `*.test.ts` next to the schemas — no fixtures needed).
- `handleActionError` test: Zod error → `{ success: false, message: "Validation error: …" }`.

## Over-engineering pass

Clean. No new npm packages, no speculative abstractions. `Alert` block, `Info` icon, and the `Number()` coercion are the only new surface area — all minimum.

## Nits

- `daily-medicine-template-detail.tsx:67` — `Number(item.qty)` is correct for `Prisma.Decimal`. Don't reach for `String()`.
- `medicine-record-form.schema.ts:43-44` — `purchasedPricePerUnit` and `amount` are still `int()`. Currently safe by the same invariant as #1; flag for the next PR if you loosen.
- Don't add the qty-decimal Alert to the medicine-record form — its qty is still int.
