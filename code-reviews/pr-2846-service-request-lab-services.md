# PR #2846 — Fix - get all lab test services when module type LAB in service request

**Repo / State / Author / Branch / Diff / CI**
- Repo: `MyanCare/Ycare-HHMS` → `MyanCare/Ycare-HMS`
- State: **OPEN**
- Author: `Pyae41` (Pyae Phyo Zan)
- Branch: `issue/ppz/sprint-26/service-request-lab-module-86ey01z3k` → `development`
- Diff: +10 / -6, 1 file (`src/app/(dashboard)/shared/opd/repositories/service.repository.ts`)
- CI: Build pass, ESLint pass, TS pass, **SonarCloud FAIL** (1m11s)

**Verdict:** ⚠️
**Critical+High:** 0 Critical, 2 High, 2 Medium, 2 Low

## Summary

`ServiceRepository.findServices` filters `module` via `category.ServiceCategoryModuleMapping.module`. For `module="LAB"` this returns zero services because lab tests are tagged by a sibling `LabTest` row (1:1 on `serviceId`), not by category-module mapping. PR adds an `if (query.module === "LAB")` branch that uses `where.LabTest = { isNot: null }` — the **same condition already used by the `serviceType=LAB_TEST` branch 30 lines below**. Trigger: `emr-standard-service-request-form.tsx:208` sends `module=watchModule` to `/api/services`.

## Risks

- **Inconsistent source of truth for "is this a lab test?"** — two paths, same rule.
- **Pre-existing**: `query.categoryId` sets `where.categoryId` (line 108); `query.module` overwrites with `where.category` (line 112/144). Combining them silently drops `categoryId`. Inherited by both branches of the new `if`.
- **No tests for `findServices`** (verified — `find service.repository*.test*` returns nothing). SonarCloud fail is plausibly "no coverage for new code path".
- **`query.module === "LAB"` is case-sensitive**; the sibling branch calls `.toUpperCase()`. A `"lab"` request hits the mapping branch and returns zero.

## Findings

### 🔴 Critical
None.

### 🟠 High

1. **Sibling module types may share the same defect.** `CT`/`ULTRASOUND`/`ECHO`/`ECG`/`X_RAY`/`MRI`/`ENDO`/`HD`/`CATHLAB`/`OT` all use the same `ServiceCategoryModuleMapping` join. If any category for those modules lacks a mapping row, picking that module in the service-request form returns the same empty list. **Fix the class once** in `findServices` (or a shared helper) — not a series of one-off `if (module === "X")` branches.
2. **Duplicated filter logic.** `where.LabTest = { isNot: null }` lives at line 144 (`serviceType` branch). Now also at line 112 (module branch). Two callers, one rule. Extract a const and reuse. Ponytail rung 2: **already in this codebase, 30 lines below**.

### 🟡 Medium

1. **`query.module === "LAB"` is case-sensitive** — inconsistent with the sibling branch which calls `.toUpperCase()`. Normalise once.
2. **`where.category` overwrites `where.categoryId`.** Pre-existing but preserved by both branches. Merge into one object literal or short-circuit.

### 🔵 Low

1. Use `ServiceCategoryModule.LAB` not `"LAB"` (verified used in `patient-emr.service.ts:871`).
2. `SpecialLabTest` exists (`prisma/schema.prisma:5715`); not affected today but flag for the design doc if "lab test" ever needs to include SpecialLabTests.

## Ponytail notes

- **Rung 1**: yes, fix is needed.
- **Rung 2**: yes — already at line 144, reuse it.
- **Rung 6**: fix is one line; PR is +10/-6 for a one-line guard.
- **Root cause**: grep every caller of `findServices`. 6+ callers; only EMR service-request form ships `module=LAB` today. Tomorrow, any caller re-introduces.
- **No unrequested abstractions added** (good) — but missing the abstraction it leaves behind.

## Reuse check

- **LabTest existence predicate**: already in this file (`service.repository.ts:144`).
- **`ServiceCategoryModule` enum**: already imported (line 2). Use the enum value, not string.
- **`getLabServices(serviceIds[])`** (line 382): same conceptual axis (`LabTest` row exists) but different shape.
- **`getImagingServices(serviceIds[])`** (line 411): hardcodes `ImagingModules` list via `ServiceCategoryModuleMapping` — confirms imaging IS tagged by mapping. LAB is the odd one out; fix direction is correct, execution incomplete.

## Tests

- **None added.**
- **Required minimum**:
  1. `module=LAB` returns services with `LabTest` rows, ignores mapping.
  2. `module=CT` still joins mapping.
  3. `module="lab"` lowercase normalised to `LAB`.
- **Pattern**: `hms-app/src/app/(dashboard)/shared/ipd/services/__tests__/room-checkout.service.node.test.ts` (Prisma + real DB).
- **SonarCloud fail likely resolves once tests exist.**

## Action items

1. Add tests (likely flips SonarCloud green).
2. Extract `LabTest` predicate constant; reuse from both branches.
3. Use `ServiceCategoryModule.LAB` not `"LAB"`.
4. Normalise `query.module` via `.toUpperCase()` once.
5. (Follow-up) Audit sibling module types for the same bug class.
6. (Follow-up) Fix `categoryId + module` overwrite interaction.

## Bottom line

Correct fix direction, incomplete execution. One-line guard, duplicated from 30 lines below. Ship after tests + case-normalisation; file follow-ups for sibling-module audit and `categoryId`/`module` overwrite.
