# PR #2880 — fix: update OT billing and shared proxy bill handling

**Repo:** MyanCare/Ycare-HMS
**PR:** https://github.com/MyanCare/Ycare-HMS/pull/2880
**Author:** DaDDy-chilll (Paing Sett Kyaw)
**Branch:** `psk/26/bug/fix-issues` → `development`
**Changed files:** 21 (+622 / -90)
**State:** OPEN
**ClickUp:** 86ey56gg1, 86exqemt3, 86ey58t4r, 86ey5776c, 86ey4vdfq, 86ey59rut
**Verdict:** Changes requested

## Summary

A six-ticket batch covering OT billing and the shared proxy-bill flow: (1) decimal-typed vital signs (schema + migration + `step="any"` on every numeric input), (2) `OtEmrServiceInfoCard` enriched with an infection-screening sub-card and the OT services tab switched from the (wrong) `makeFetchHDInfectionScreeningQuery` to the new `makeFetchOTInfectionScreeningQuery`, (3) `DailyBillProxyBill` procedure rows now read-only when the procedure has no doctor (in addition to the existing fully-discharged check), (4) the proxy-bill repository's `updateProcedureBill` now uses `upsert` keyed on `proxyBillId` so editing a main-procedure-bearing OT bill preserves the existing `procedureBill` row instead of recreating it from scratch (which was wiping the saved procedure data through the mapping), (5) the appointments-by-doctor report reorders by `total_appointments DESC` server-side and drops the client-side `useMemo` resort, (6) `CustomTextInput`'s on-focus "clear if value exists / restore on blur" behavior is removed in favor of standard Mantine focus.

The OT infection-screening swap alone is a fix for what reads as a copy-paste bug — `makeFetchHDInfectionScreeningQuery` returning HD-shaped data on an OT patient would either be no-op or wrong shape; the new OT query is the right hook. The proxy-bill upsert is the load-bearing behavioral fix — the previous `else { createProcedureBill(...) }` path was recreating the `procedureBill` row on every edit, which is why `useBindForm` was getting nothing back. The other four changes are smaller correctness/UX nudges. The diff is mostly mechanical but has one significant over-engineering smell in the new repository upsert code, plus a test that reaches into the production form source by reading files off disk.

## Strengths

- The OT infection-screening swap (`hd` → `ot` API + new field type) is the right direction; the test (`ot-emr-service-info-card.dom.test.ts`) locks in that the positive-infection label renders red and bold, which is the actually user-visible behavior change.
- The `DailyBillProxyBill` no-doctor-procedure gate is layered on top of the existing `isFullyDischarged` check (`!procedureHasDoctor || isFullyDischarged`), which matches the realm of "this price is not editable" — both reasons converge in the same render branch. The new DOM test (`daily-bill-proxy-bill.dom.test.tsx`) actually exercises the rendering difference (read-only span vs. empty editable input).
- The `updateProcedureBill` upsert keyed on `proxyBillId` is the correct fix. The old `createProcedureBill` fallback was creating a new `procedureBill` row on every OT edit, and `useBindForm`'s `if (proxyBillData?.procedureBill)` guard wouldn't refetch in time — so re-loading the form wiped the procedures. The new test (`proxy-bill-repository-main-procedures.node.test.ts`) covers the upsert path.
- The `useBindForm` change passes the procedure-item `id` through to the form state (`itm.id`). This is small but essential — without `id`, the new `if (watchedProcedure?.id) return` guard in `ProcedureRow` cannot tell a saved item from a freshly-added one, and the saved price/amount would be clobbered by the re-render-effect on every keystroke. The matching `service.id && service.isPriceFromMapping` guards in the two `ServiceRow` components go the same direction.
- `custom-text-input.tsx` simplification: the on-focus "blank-and-restore" wrapper was a magic behavior that broke accessibility (a screen reader tabbing onto the field heard a different value than was on screen) and broke keyboard paste. Removing it is the right call; the new test asserts the input retains its value on focus, which is the regression to guard against.
- Migration `ot_request_vital_sign_decimal_values` is a safe `ALTER TABLE ... SET DATA TYPE DOUBLE PRECISION` over five columns. PG widens `int4 → float8` without an explicit cast and without rewriting the rows.

## Issues

### Important

1. **`updateProcedureBill` upsert payload is duplicated verbatim across `update` and `create`** — `proxy-bill.repository.ts:776-829`. The `procedures.map((pkg) => ({...}))` block (15 lines) appears twice. Lift it to a local `const procedureItems = procedures.map(...)` above the `upsert({...})` call and use it in both `update.procedureBillItem.createMany.data` and `create.procedureBillItem.createMany.data`. A typo or schema field added to one branch but missed on the other would pass code review silently and cause a real runtime divergence between first-edit (insert) and later-edit (update). Net ~15 lines saved and one class of bug closed.

2. **`OtEmrServiceInfoCard` couples rendering to a loadable by inlining `<Loader size={12} />` directly in the label spot** — `ot-emr-service-info-card.tsx:140-148`. The parent already passes `infectionScreeningLoading`, so the component knows when it's loading; but the same component is also reused without a loading flag (the original `data?`-only signature used to be called with just `data`). Two minor consequences:
   - Anyone calling `OtEmrServiceInfoCard` from a non-loading context (an existing call site where `infectionScreening` is derived synchronously from `data`) will now leak a non-loading-but-also-non-meaningful branch where the label just shows `"-"` with no spinner — fine, but worth noting.
   - The "label-or-spinner" ternary logic is now duplicated between `OtEmrServiceInfoCard` (here) and the new `OTInfectionScreeningField` defined inside `ot-emr-services-tab-component.tsx:113-145` (the form-side counterpart). The "show label or show `<Loader>`" branch is essentially the same code in two places — same `hasApprovedRequest && displayLabel` predicate, same red color, same spinner. Factor the prediction (`const label = ...`) into the shared `get-ot-infection-screening.ts` or a tiny `useOTInfectionScreeningLabel` helper, render the JSX in one place, and import it in both callers. The duplication will drift the moment the alert threshold changes (e.g., the team wants yellow for "indeterminate" — one branch gets updated, the other silently stays red-only).

3. **Test that reads form source files off disk is a fragile guarantee** — `ot-vital-sign-decimal-values.node.test.ts:78-117`. Three of the five tests in this file `readFileSync` the production form source (`opd-ot-request-form.tsx`, `ot-request-form.tsx`, `prisma/schema.prisma`) and run a regex against the raw text. This couples the test to the file path and to whatever string shape the JSX happens to compile to after `next build`. Three concrete failure modes:
   - The test reads `process.cwd()`, so it silently breaks if Jest's CWD diverges from the repo root (the test would have to be invoked from the repo root).
   - The regex `<CustomTextInput[\s\S]*?type="number"[\s\S]*?step="any"[\s\S]*?...register("X")` matches by accident any two `<CustomTextInput>` instances in the same file as long as both happen to have `type="number"` and the later one has `register("X")` — there's no positional anchor, only a greedy any-char match. A future refactor that splits a single input across multiple lines or adds a second input between them would make the match noisy rather than failing the test.
   - Source-reading tests do not run the input. They verify "the string `"step="any"` appears next to `register("X")`," not "an input rendered with that string accepts `120.5`." The first test (`createOPDOTRequestSchema.safeParse({...})`) is the actual semantic check; the source-reading tests are scaffolding masquerading as coverage. Replace them with a single RTL render of the two forms and an `await userEvent.type(input, "120.5")` + assert no error, or drop them entirely — the migration column type change is already covered by `prisma migrate deploy` running without error.

4. **`updateProcedureBill` will silently drop the `procedureBill` row when `procedures.length === 0`** — `proxy-bill.repository.ts:779` (`if (!payload.procedureBill || procedures.length === 0) return;`). Before this PR, an empty-procedures edit would have called `createProcedureBill(..., { departmentType: HD })` which would have either created an empty `procedureBill` (probably never expected) or no-op'd. Now it returns `undefined` and **leaves an existing `procedureBill` row untouched in the DB**, even though the form just submitted an empty procedures list. That's an actual data-correctness bug: user clears all main procedures and saves → `procedureBill.procedureBillItem` still contains the old items. Either explicitly delete the existing `procedureBill` (and its items) in this branch, or document the intent ("null means 'no change'") in the function's JSDoc so future readers don't mistake it for a no-op when it isn't.

5. **`useOTServiceBillState` adds a hard-coded `price: 0` to every newly-added service item** — `ot-services.tsx:317`. Combined with the new `if (service.id && service.isPriceFromMapping) return;` effect guard, the new field exists to force `isPriceFromMapping: (service?.price ?? 0) > 0` to evaluate `false` for new items (`isPriceFromMapping` is computed in `proxy-bill.repository.ts` from the mapped item — the explicit `price: 0` in the form state doesn't actually flow into the repository's `isPriceFromMapping` flag, which is set independently at line 528 / 612 from `service.price`). Two flags now govern the same thing: `service.id` (exists if loaded from DB) and `service.isPriceFromMapping` (set by the repo mapping). The `ServiceRow` guard uses both; the `TeamFeeRow` guard uses only `service.id`. This is a leaky contract — fix the contract in one place (either a single `service.isExisting` flag the repo sets, or always use `service.id`) and delete the second one. Right now there are three ways to say "this is a saved item" and the code picks a different two in each row component.

### Nit

6. **`procs` shadowed by `pkg`** — `proxy-bill.repository.ts:783,798`. The outer iteration is `procedures.map((pkg) => ...)`. Conventional JS uses `proc` or the raw `pkg`, but `pkg` here is the variable name for an item whose type is `ProxyBillProcedureType`. A `proc` or `procedure` name would match the sibling `serviceRow` iteration. Trivial; flag only.

7. **`OtEmrServiceInfoCard` no-longer-imported `Dot`** — check whether `ot-emr-service-info-card.tsx` still uses the `Dot` icon. The diff doesn't touch the icon usage but the import is unchanged; if any other refactor pulls it out, an unused-import warning would surface.

8. **`ot-emr-services-tab-component.tsx:113` defines `OTInfectionScreeningField` between two unrelated exports** — the helper sits between `getOtEmrEditPath` (line 105) and `OtEmrServicesTabComponent` (line 152). Convention in this file (and elsewhere in the repo) is helpers above the component that uses them, but `OTInfectionScreeningField` is the *form-side* counterpart of `OtEmrServiceInfoCard`. Either inline it, or move both into a shared `ot-infection-screening.tsx` file alongside the `get-ot-infection-screening.ts` API module.

9. **Test `daily-bill-proxy-bill.dom.test.tsx:27-29` adds a new `jest.mock("../daily-bill-services", () => ({ formatPriceType: ... }))`** — necessary because the component now calls `formatPriceType` somewhere. Worth confirming in the diff that `formatPriceType` is actually invoked in the new rendered path; if it's only invoked in unrelated rows, the mock is defensive noise.

10. **`procedureHasDoctor = Boolean(procedure.doctorId || procedure.doctor)`** — `daily-bill-proxy-bill.tsx:728`. The shape `procedure.doctor` comes from `ProxyBillProcedureType` (which now has both `id` and possibly `doctor`), so this is a reasonable belt-and-braces. But if the upstream type guarantees `doctorId ?? null`, the `procedure.doctor` fallback is dead code. Pick one and drop the other.

11. **`migration.sql` has no `IF EXISTS` / safety clause** — adding `IF NOT EXISTS` or `SET DATA TYPE ... USING ...` is not strictly necessary here (the columns already exist and the cast `int4 → float8` is implicit), but if any future change makes this column nullable with a default, the migration will start to fail with `null values cannot be cast`. Trivial today; flag for the next change.

12. **PR title and body are vague.** `fix: update OT billing and shared proxy bill handling` reads like a release note, not a PR title. Repo convention (per the ClickUp tickets in the description) is `fix(scope): per-clickup`. The body lists 6 ClickUp tickets which is good archaeology but no per-ticket description. A reviewer who hits this PR cold has no way to map each commit to its motivation.

## Recommendations

1. **DRY the upsert payload in `proxy-bill.repository.ts:776-829`** — lift `procedures.map(...)` into a local `const procedureItems`, then reuse in both branches. -15 lines.
2. **Decide the "is this a saved item?" contract.** Use `service.id` everywhere, OR introduce `isExisting` in the repo mapping, OR use `isPriceFromMapping` everywhere. Right now three booleans encode the same fact. -3 lines and one mental model.
3. **Factor the infection-screening label/loader rendering** — small `OTInfectionScreeningDisplay` component imported by both `OtEmrServiceInfoCard` and `OTInfectionScreeningField`. ~30 lines saved across the two callers and one divergence-proofing.
4. **Delete the three source-reading tests in `ot-vital-sign-decimal-values.node.test.ts`** (keep the two `safeParse` tests). Source-reading regex assertions are scaffolding; the migration + Zod schema are the actual contracts and they're already covered. -95 lines.
5. **Make `updateProcedureBill`'s empty-procedures branch explicit** — either delete the existing `procedureBill` or document the "no-op" intent in JSDoc.
6. **Add a one-line description per ClickUp ticket to the PR body** (or accept the current six-line bullets + ClickUp links as the minimum and ship).

## Security / Privacy

- None. The migration widens integer to float and preserves all rows; the OT infection-screening swap uses the existing BFF auth path; the upsert is keyed on the existing `proxyBillId` index; no new auth boundary is crossed.

## Reviewer notes

- This PR fixes one substantive behavioral bug (the OT `procedureBill` recreation on every edit wiping saved procedures) and one substantive UX bug (the OT infection-screening card showing HD-shaped data). Everything else is a small adjacent fix.
- The over-engineering pass would have cut the upsert duplication and dropped the source-reading tests; both are mechanical. Approve once the duplication is de-duped and the source-reading tests are either replaced with a real render test or deleted.
- The `isExisting` flag consolidation (finding #5) is the single highest-value cleanup — three current flags (`id`, `isPriceFromMapping`, `isExisting`) all encode "this row was loaded from DB," and `ServiceRow` uses two of them, `ProcedureRow` uses one, `TeamFeeRow` uses one. A refactor commit that picks one and drops the others is the cleanest follow-up.
- After this PR the OT decimal-step tests exist but the negative test (e.g., `createOPDOTRequestSchema.safeParse({ systolicBloodPressure: "abc" })`) does not. Zod returns `success: false` correctly but no test asserts it. Worth a one-liner addition.
- Adjacent file to look at next time: `src/app/(dashboard)/shared/proxy-bill/features/components/procedure-row.tsx` already had the `if (watchedProcedure?.id) return;` guard but the **sibling** `ServiceRow` (`shared/proxy-bill/features/components/service-row.tsx`) and `ot-services.tsx`'s `ServiceRow` (the other one, inside `ot/features/components`) had to be patched separately. The two components share most of their effect logic; a future refactor that consolidates them into a single component would close both edges of this bug class in one place.

**Net estimate (over-engineering pass):** -45 to -60 lines possible on top of the current +622 / -90 diff, mostly from (a) the upsert payload dedup, (b) the source-reading test deletion, (c) the `isExisting` flag consolidation, (d) the infection-screening display dedup.
