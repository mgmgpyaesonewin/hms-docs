# PR #2853 Review: Fix - fix deposit UI issue and some improvement

**Repo:** MyanCare/Ycare-HMS
**PR URL:** https://github.com/MyanCare/Ycare-HMS/pull/2853
**Author:** Pyae41 (Pyae Phyo Zan)
**State:** OPEN
**Verdict:** changes-requested

## Summary
Single-file UI fix to the IPD deposit form: extracts the cancel-button reset into a `handleCancel` helper (also clears `selectedDepositType` and `showCanSubmitError`), broadens responsive layout (flex/wrap/min-width), and guards `dbTotalPaidAmount`/`remainingAmount` against running when there is no `admissionId`. The reset and layout changes are good, but the `DepositSummary` guards duplicate state already enforced at the query layer, there is a leftover `console.log`, a stale commented-out `<TextInput>` block sits in the live render path, and one deposit-amount input was missed in the width-class sweep.

## Findings

### Blocking
(none)

### Important
1. **deposit-form.tsx:707-709** — `useEffect(() => { console.log("Calculated total:", newPaymentsTotal); }, [newPaymentsTotal]);` is a debug log with no runtime value; the variable it logs is already consumed two lines later. Remove it.

2. **deposit-form.tsx:711-713, 731-735** — The new `!admissionId ||` guard duplicates state already enforced upstream: both `useQuery` calls (lines 677, 682) use `enabled: !!admissionId`, so when `admissionId` is falsy `totalDeposits`/`latestDeposit` are guaranteed `undefined` and the existing `?? 0` already handles it. Express the readiness once as `const summaryReady = !!admissionId && !isLoading;` and reuse it for `dbTotalPaidAmount`, `remainingAmount`, and any future summary value — ad-hoc ternaries per value will drift the next time a third field is added.

3. **deposit-form.tsx:206-225** — A 20-line commented-out `<TextInput>` block (min-deposit validation) sits directly above the live deposit-amount `<Controller>`. Delete it or move it to a TODO with a ticket link. Dead code in a render path is what someone decodes at 3am.

4. **deposit-form.tsx:268** — The diff updates `PaymentMethodSelect`'s `className` to `flex-1 min-w-[220px]` but the live deposit-amount `<TextInput>` immediately below it still has `className={index === 0 ? "w-1/3" : "w-1/2"}`. If the intent was a uniform row width, this is the one that was missed.

### Nit
1. **deposit-form.tsx:166-185** — `handleCancel` duplicates the default-form-values shape. The literal `payments: [{ paymentMethodId: "", depositAmount: "" }]` is now in `handleCancel` and the `append(...)` call. Extract an `EMPTY_DEPOSIT_VALUES` constant.

2. **deposit-form.tsx:276, 287** — Two `ActionIcon`s still use inline `style={{ marginTop: "28px" }}`. The diff converts the `+` button to `mt-7`; do the same to the trash button for consistency. `mt-7` is `1.75rem` (28px on 16px base) — value preserved.

3. **deposit-form.tsx:639-640** — `patient?.patientGroup` was simplified to `patient.patientGroup` (correct — the surrounding ternary proves `patient` is defined), but the adjacent line 639 still uses `patient?.patientGroup`. Match.

4. **deposit-form.tsx:169, 194, 315** — The codebase mixes `gap={"lg"}` and `gap="lg"`. The diff uses the plain form on touched sites; surrounding untouched lines keep the noisy form. Drive-by cleanup is optional.

### Question
1. **deposit-form.tsx:166-185** — `handleCancel` resets `isPreDeposit: tab === "pre-deposit"`. Is `isPreDeposit` a registered form field? If not, this is dead config in the reset object — please confirm.

2. **deposit-form.tsx:739** — `DepositSummary` early-returns with `if (!admissionId || !patientId) { return ... }`. If that early return always runs first when `admissionId` is missing, the new `!admissionId ||` guard in the consts is redundant. Please confirm which render path executes for an existing deposit on the pre-deposit tab.

3. **deposit-form.tsx:274-294** — Wrapping the row in `flex-wrap` plus each child in `flex-1 min-w-[220px]` means on a narrow screen the add/trash `ActionIcon`s (no width class) will share a row with the inputs. Will the icons stretch and break the "+" affordance? If yes, add `flex-none` to the icons.

## Recommendation
The `handleCancel` extraction, the responsive sweep, and the `!admissionId` correctness fix are all the right shape. Before merge: drop the `console.log` on line 708, delete or ticket the commented-out `<TextInput>` block, and collapse the two ternaries into a single `summaryReady` boolean so the next contributor does not have to remember the rule in three places. Decide whether the `mt-7` migration and the `flex-1 min-w-[220px]` width should include the trash `ActionIcon` and the deposit-amount `TextInput` for consistency, or whether the existing classes are deliberate. Once those are addressed, this is approvable.
