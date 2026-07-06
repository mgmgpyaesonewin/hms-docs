# hms-app Cathlab — Code Review Findings (2026-06-17)

**Scope.** Four findings in the cathlab service line-items update flow and its consumer UI: copy-paste between two service methods, a dead schema file, an action wired to the wrong schema, and an optimistic-state commit that runs before server confirmation.

---

## 1. ~200 lines of copy-paste in `cathlab.service.ts`

`updateCathLabProcedureItems` (`cathlab.service.ts:1195-1502`) is a structural clone of `updateCathLabServiceItems` (`cathlab.service.ts:901-1192`). The only real differences are:

- `tx.cathLabServiceItem` → `tx.cathLabProcedureItem`
- `Prisma.CathLabServiceItemUpdateInput` → `Prisma.CathLabProcedureItemUpdateInput`
- One extra business guard: `if (!hasDoctor || !isZeroPrice) continue;`
- Audit-message suffix `"service items"` → `"procedure items"`

The deposit calculation, change-tracking arrays, changeType string-building, audit creation — all identical. Future fixes (e.g., new discount modes, rounding, deposit logic) will silently diverge.

**Fix:** extract a generic helper like:

```ts
private async updateCathLabLineItems<TDelegate>(
  delegate: TDelegate,
  payload: UpdateCathLabServiceItemSchema,
  userId: string,
  options: { requireDoctorAndZeroPrice?: boolean; auditLabel: string },
)
```

---

## 2. Dead schema file

`update-cathlab-procedure-item.schema.ts` is created in this PR but never imported. The new action reuses `updateCathLabServiceItemSchema` (`cathlab.action.ts:50`). Either:

- Delete the new file, or
- Have `updateCathLabProcedureItemsAction` use `UpdateCathLabProcedureItemSchema` (currently the schema files disagree — service uses `z.string().uuid()`, procedure uses plain `z.string()`).

---

## 3. Action wired to the wrong schema

```ts
// cathlab.action.ts:50
export const updateCathLabProcedureItemsAction = authActionClient
  .schema(updateCathLabServiceItemSchema)
```

The action is for procedures but validates against the service schema. The export name suggests one thing, the validation says another.

---

## 4. Optimistic state commits before server confirmation

In `handleSaveAllChanges` (`daily-bill-cathlab.tsx`, diff lines 200-238), when `changedServices.length > 0`:

```ts
updateServiceItem({...});
setOriginalServices(editableServices);  // ← runs synchronously, before server responds
```

If the server action later throws (validation, deposit error, race with another editor), `onError` only shows a toast — but `originalServices === editableServices` has already been committed. The local baseline no longer reflects server state.

**Fix:** move the `setOriginalServices` call into the `useAction` `onSuccess` only (it already does this — the in-handler call is redundant and harmful).

Same bug applies to `setOriginalProcedures`.