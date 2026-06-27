# Code Review: PR #2793 — Fix/daycare clinical doucments permission

**Repository:** MyanCare/Ycare-HMS
**Author:** @Xkill119966
**Branch:** `fix/daycare-clinical-doucments-permission` → `development`
**Files changed:** 6 (+6 / -6)
**Reviewer:** code-reviewer skill (automated, independent re-review)
**Date:** 2026-06-24
**ClickUp ticket:** none in PR body

## Summary

The PR fixes two distinct permission-subject typos/bugs that were causing `PermissionGuard` to deny access to daycare clinical documents and to the four IPD service-request edit pages (CathLab, Endo, HD, OT). All six edits are one-line `subject=` swaps inside `<PermissionGuard>` JSX props; no logic, no tests, no server-side code, and no tRPC routers change. The opd submodule pointer is bumped by one commit (no contents in this PR's diff).

The first fix (`daycare-emr-tabs-component.tsx:258`) changes `subject="DayCare::Clinical Documents"` to `subject="Daycare::Clinical Documents"`, matching the canonical `"Daycare"` module name declared in `permission-ui-config.ts:695`. Because `utils.ts:35-39` only generates a `${module}::${subName}` subject key when `subModuleGlobalCounts.get(subName) > 1`, and `"Clinical Documents"` already appears under the `"OPD Management"` module (line 274), the registry builds the prefixed subject as `"Daycare::Clinical Documents"`. Any UI guard using `DayCare::...` therefore fails to match and falls through to `UnauthorizedPage`. The fix is correct and aligns the daycare tab with the seven other daycare tabs in the same file (all of which already use the `"Daycare::…"` form, lines 142/157/172/187/202/219, plus the four sibling pages in `features/clinical-document/` and `add/clinical-documents/`).

The second fix changes the four IPD service-request edit pages from per-modality subjects (`CathLab Requests`, `Endo Requests`, `OT List`) to the single consolidated `"IPD Management::Service Request"`. This matches the canonical sibling subjects used elsewhere under `src/app/(dashboard)/ipd/.../service-request/` (12 sites identified via grep) and the registry entry at `permission-ui-config.ts:303`. The change is correct in spelling, but it has two consequences the PR does not call out: (1) it merges CathLab/Endo/HD/OT edit rights into one permission bit, which broadens access for any role that had only one of the four, and (2) the HD page's old `subject="Endo Requests"` looks like an accidental copy-paste from the Endo page — the PR fixes it but does not note that this was a pre-existing typo bug, not a deliberate subject choice.

For a permission/authorization change this PR is small and surgical, and the spelling corrections are demonstrably correct against the registry. The main quality concerns are: (a) the broadness change for the IPD service-request subjects is undocumented and unanalyzed; (b) there are no tests covering the permission boundary, which is the standard expectation for auth-sensitive changes; (c) the opd submodule bump ships an unverified diff against `development`; (d) the PR body is empty (no description, no ClickUp link).

## Verdict

**Approve with suggestions**

Score: 72/100
Critical: 0 | High: 2 | Medium: 4 | Low: 2 | Nit: 2

## Strengths

- **`src/app/(dashboard)/emr/daycare/features/daycare-emr-tabs-component.tsx:258` — Typo fix is correct and matches the canonical module name.** The dynamic subject parser at `@common/user-management/roles/features/utils.ts:35-39` constructs `${mod.module}::${subName}` only when the submodule name is duplicated across modules. Since `"Clinical Documents"` already exists under `"OPD Management"` (`permission-ui-config.ts:274`), the daycare lookup requires `"Daycare::Clinical Documents"`. The registry declares `module: "Daycare"` (line 695), so the old `"DayCare::…"` subject never resolved and the tab was always blocked.
- **Daycare fix aligns the broken tab with the seven other daycare tabs in the same file.** Every other `<PermissionGuard>` in `daycare-emr-tabs-component.tsx` already uses `"Daycare::…"` (lines 142, 157, 172, 187, 202, 219), and the four sibling files in `features/clinical-document/` and `add/clinical-documents/` all use the same spelling. This is the lone outlier. Fixing it removes a UX regression where the Clinical Documents tab was effectively dead.
- **`src/app/(dashboard)/ipd/ipd-list/[buildingId]/[roomLogId]/[patientId]/service-request/cathlab/[id]/edit/page.tsx:27`, `endo/.../edit/page.tsx:27`, `hd/.../edit/page.tsx:27`, `ot/.../edit/page.tsx:28` — Consolidation to `"IPD Management::Service Request"` is consistent with 12 sibling sites.** A grep for `IPD Management::Service Request` shows the same subject is used at `ipd/features/components/service-request/ipd-emr-service-request-item.tsx:82,99`, `ipd-list/.../service-request/add/page.tsx:25`, `ipd-list/.../service-request/add/page-back-up.tsx:36`, `ipd-list/.../service-request/general/[id]/edit/page.tsx:37`, `ipd/ward/.../service-request/add/page.tsx:26`, `ipd/ward/.../service-request/general/[id]/edit/page.tsx:38`, `ipd/features/components/ipd-patient-detail-page.tsx:144`, `ipd/features/components/service-request/add-service-request-button.tsx:29`, and `ipd/features/components/service-request/service-request-item.tsx:87,104`. The PR brings four outlier edit pages into line.
- **HD page fix corrects a pre-existing copy-paste bug.** `src/app/(dashboard)/ipd/ipd-list/[buildingId]/[roomLogId]/[patientId]/service-request/hd/[id]/edit/page.tsx:27` previously used `subject="Endo Requests"` for an HD (Hemodialysis) request page — almost certainly a paste from `endo/.../edit/page.tsx`. The PR fixes it as a side effect of the broader consolidation, which is the right outcome even if the author didn't notice.
- **Subject is constructed client-side via `checkPermission(user, action, subject)` (`@/components/with-permission.tsx:166`); the lookup is purely a string equality check.** No type errors possible because `Subject` is `export type Subject = string` (`utils.ts:49`) and the prop is typed `Subject | (string & {})`. The change can't regress type safety.
- **PR diff is +6 / -6 across 6 files — extremely reviewable.** Each change is a single string swap with no logic change. Safe to ship from a code-shape perspective.

## Issues

### Critical

None. The diff is too small and the change too well-bounded to introduce a critical regression. **However, see High #1 and High #2 below for security-adjacent concerns.**

### High

- **`src/app/(dashboard)/ipd/ipd-list/[buildingId]/[roomLogId]/[patientId]/service-request/{cathlab,endo,hd,ot}/[id]/edit/page.tsx` — Consolidating four subjects into `"IPD Management::Service Request"` silently broadens access for any role that holds only one of the four old subjects**
  Before this PR, editing a CathLab request required the `CathLab Requests` permission, editing an OT request required the `OT List` permission, and so on. After this PR, all four require only `IPD Management::Service Request` — a single permission bit. The registry entry at `permission-ui-config.ts:282-330` exposes `IPD Management::Service Request` with the `crudPrintStatusExport` permission set and `excludeActions: ["delete", "print", "export"]` (line 304). The old subjects were granular: `CathLab Requests` and `Endo Requests` each had their own `excludeActions: ["delete"]` (lines 254 and 252) and `OT Requests` had `excludeActions: []` (line 253). **Any role that was granted `OT Requests` but not `IPD Management::Service Request` will now also gain CathLab/Endo/HD edit rights after this merge.** Whether this is the intended consolidation or an unintended side effect is unclear from the PR (no description). If the intent is to merge them, that is a meaningful auth-model change and should be called out in the PR body and approved by a domain owner. If the intent is to fix the typo only, the four edit pages should each use their own canonical subject (`IPD Management::CathLab Requests`, etc.) or the registry should be updated to expose per-modality sub-subjects. Recommended fix: clarify the intent, then either (a) revert to per-modality subjects after fixing the registry to expose them, or (b) keep the consolidation and document the access-model change explicitly in the PR description + a ClickUp ticket.
  Evidence: `permission-ui-config.ts:248-278` (OPD Management module has per-modality submodules `HD Requests`, `ENDO Requests`, `OT Requests`, `CathLab Requests`); `:281-330` (IPD Management module has a single `Service Request` submodule used for all four modalities via this PR).

- **No test for any of the five permission boundaries being touched, and the test gap is structural**
  This is a permission/authorization change. The codebase already has tests for boundary conditions (`hms-summary-service/src/db/__tests__/tenant-scope.test.ts` is the canonical example in this monorepo). On the hms-app side, the `with-permission.tsx` module and the dynamic subject parser in `utils.ts` have no unit tests in the diff. After this PR, the following invariants are load-bearing and untested:
  1. `Daycare::Clinical Documents` is generated by the registry and is granted to roles that have the daycare `Clinical Documents` submodule action (previously: silently broken; now: working).
  2. `IPD Management::Service Request` covers CathLab/Endo/HD/OT edit rights (previously: per-modality; now: consolidated).
  3. The dynamic subject parser correctly prefixes when a submodule name appears under multiple modules (`utils.ts:35-39`) — this is the bug class that produced the original `DayCare::` typo.
  Recommended fix: add at minimum one unit test per file that the subject string matches what `subjectConfigs[subject].module` returns from the registry. Even a single 30-line test file `src/app/(dashboard)/common/user-management/roles/features/__tests__/subject-resolution.test.ts` covering the five subjects in this PR would catch regressions in either direction.
  Evidence: PR contains zero test files in its 6-file diff; `utils.ts:48-50` defines `subjects` and `Subject` but no test references them; `permission-ui-config.ts` is the source of truth and has no test coverage either.

### Medium

- **`src/app/(dashboard)/ipd/ipd-list/[buildingId]/[roomLogId]/[patientId]/service-request/hd/[id]/edit/page.tsx:27` — The pre-existing `subject="Endo Requests"` on the HD edit page was almost certainly a copy-paste from `endo/[id]/edit/page.tsx`; the PR fixes it but doesn't acknowledge it**
  The HD (Hemodialysis) request edit page guarded itself with the `Endo Requests` permission — meaning any user with edit rights for endoscopy could also edit HD requests, and any user with edit rights for HD but not endoscopy could not edit HD requests (they got `UnauthorizedPage`). The PR's swap to `"IPD Management::Service Request"` masks this pre-existing bug by collapsing both into one subject. If a future PR un-collapses the IPD service-request subjects per High #1, the HD-vs-Endo bug will resurface. Two suggestions: (a) note the HD-vs-Endo pre-existing bug in the PR description so reviewers and a future bisect can attribute it correctly, and (b) verify against the production roles table that no role was relying on the broken asymmetry (i.e. a role that *should* have HD edit rights but was silently denied because of the Endo guard).
  Evidence: `service-request/hd/[id]/edit/page.tsx:27` (pre-PR `subject="Endo Requests"`); `service-request/endo/[id]/edit/page.tsx:27` (the source the page was copied from).

- **`src/app/(dashboard)/opd` — Submodule pointer bumped (09714186f → 364060b51) with no diff in this PR**
  The diff shows `Subproject commit 09714186f121c70c677dfcf744026ff0ef2dd6ce → 364060b51d0753c4ab05bf0bdc6630095b427edd` and zero file-level changes in this commit's diff for the submodule contents. Submodule bumps routinely carry permission-related changes that affect the same auth surface area. The PR should either: (a) include the submodule diff (and explain why the parent repo's daycare/IPD permission fixes required a submodule bump), or (b) split the submodule bump into a separate PR. As-is, a reviewer cannot verify what code in `opd/` was added/removed and whether it interacts with the permission-subject changes.
  Evidence: PR file list shows `src/app/(dashboard)/opd` with +1/-1; the diff section for that file is the submodule pointer swap only.

- **PR body is empty — no description, no rationale, no ClickUp link, no list of which roles were broken or which users were affected**
  Compare to PR #2780 which had both a title, a body, and a ClickUp ticket link in the file (per the team's review template). An empty PR body for a permission change is a quality-bar miss because:
  1. The IPD service-request consolidation (High #1) is a non-trivial access-model change with no rationale.
  2. The HD-vs-Endo pre-existing bug (Medium #1) is silently fixed with no note.
  3. The author `@Xkill119966` does not explain which role(s) tested the fix or which permission matrix was consulted.
  4. The opd submodule bump (Medium #2) is unexplained.
  Recommended fix: add a PR description that covers (1)–(4) above. Even three sentences — "Fixes typo on daycare Clinical Documents tab. Consolidates four IPD service-request edit subjects to a single IPD Management::Service Request for consistency with sibling pages. Side-effect: corrects a pre-existing Endo Requests subject on the HD edit page." — would unblock the review.
  Evidence: `gh pr view 2793 --json body` returns `""`.

- **SonarQube Cloud analysis failed (`❌ The last analysis has failed`) — security-sensitive PR is being merged without a successful static analysis pass**
  The only PR comment is from `sonarqubecloud` reporting a failed analysis. For a permission/authorization change this is a process gap: SonarQube's `javascript:S1523` (hardcoded credentials) and `javascript:S4833` (broken access control) rules would be exactly the checks a reviewer wants for this kind of change. The failure is also unexplained — was it an infrastructure outage, or did the analysis actually flag something? Either way, the analysis should be re-run before merge.
  Evidence: `gh pr view 2793 --comments` returns a single comment from `sonarqubecloud` with status `none` and text "❌ The last analysis has failed."

### Low

- **The other four tabs under `service-request/` (CathLab/Endo/HD/OT request *list* and *add* pages) still use per-modality subjects (`CathLab Requests`, `Endo Requests`, `OT List`) — High #1's consolidation is incomplete**
  A grep across `src/app/(dashboard)/ipd/features/components/service-request/` shows the *list* / *detail* / *add* paths still use `CathLab Requests` / `Endo Requests` / `OT List` (e.g. `cathlab/cathlab-request-item.tsx:82,96,110`; `endo/endo-request-item.tsx:95,109,124,138`; `ot/ot-request-item.tsx:85,99`). After this PR, an `IPD Management::Service Request` permission grants edit rights on the edit pages but **does not** grant view/add rights on the list pages (because those pages still require `CathLab Requests`, `Endo Requests`, `OT List`). This creates a confusing permission model where the same logical action (viewing/editing a CathLab request) requires two different permission bits depending on whether the user is on the list page or the edit page. Either fully consolidate (also update the list/add pages) or do not consolidate at all (revert the edit pages to per-modality subjects after fixing the registry).
  Evidence: `src/app/(dashboard)/ipd/features/components/service-request/cathlab/cathlab-request-item.tsx:82,96,110` (CathLab Requests); `:endo/endo-request-item.tsx:95,109,124,138` (Endo Requests); `:ot/ot-request-item.tsx:85,99` (OT List). None of these are touched by this PR.

- **No link between the two fixes in the PR — daycare typo fix and IPD service-request consolidation are unrelated concerns**
  These are two separate fixes to two separate modules' permission subjects. Bundling them in one PR makes bisection harder if either regresses. The daycare fix is one line in one file (a true typo fix) and could ship in 5 minutes; the IPD consolidation touches four files and has the High #1 access-model implication. Splitting into two PRs would also let the daycare fix unblock users immediately while the IPD consolidation gets more eyes.
  Evidence: PR title is "Fix/daycare clinical doucments permission" (singular, daycare-specific) but the diff includes five IPD service-request files.

### Nit

- **Branch name has a typo: `fix/daycare-clinical-doucments-permission`** (matches the PR title typo). The typo is also in the PR title: `doucments` should be `documents`. Once merged, the typo propagates into git history (the branch reflog, merge commits, etc.). Recommend: rename the branch via `git branch -m fix/daycare-clinical-documents-permission` before merging, or at minimum acknowledge in the PR body. The team's quality bar for branch names is loose enough that this isn't blocking, but it costs nothing to fix.
  Evidence: `gh pr view 2793 --json headRefName,title`.

- **`fallback={<UnauthorizedPage />}` on `daycare-emr-tabs-component.tsx:260` and the four IPD edit pages is consistent, but `UnauthorizedPage` is imported as a default export from `@/app/unauthorized` — verify the page exists and is the correct component on each route**
  All five modified pages import `UnauthorizedPage` from `@/app/unauthorized`. If `@/app/unauthorized.tsx` doesn't exist (or only `page.tsx` does), the import will resolve but may behave differently than expected (e.g. a 404 instead of a 401-style "no permission" page). Out of scope for this PR but worth a sanity check given the auth-sensitive nature.
  Evidence: `cathlab/[id]/edit/page.tsx:5` (`import UnauthorizedPage from "@/app/unauthorized";`); same import on the other four IPD pages and the daycare tabs file.

## Scope creep / file placement

The PR bundles three concerns:

1. **Daycare Clinical Documents typo fix** — `daycare-emr-tabs-component.tsx:258` only. Correct, surgical, and matches the seven sibling tabs in the same file.
2. **IPD service-request subject consolidation** — four files in `ipd-list/[buildingId]/[roomLogId]/[patientId]/service-request/{cathlab,endo,hd,ot}/[id]/edit/`. Has the High #1 access-model implication.
3. **Opd submodule bump** — one commit pointer advance with no diff in this PR's content.

The daycare fix and the IPD consolidation are unrelated to each other and to the opd submodule bump. Recommend splitting into three PRs:

- **PR A** (this one, smallest): `daycare-emr-tabs-component.tsx:258` only. Ships immediately to unblock users who can't see the Clinical Documents tab.
- **PR B**: the four IPD service-request edit pages. Should include a ClickUp ticket, a description of the access-model change (or a revert to per-modality subjects), and a test for the permission boundary.
- **PR C**: the opd submodule bump. Either drop if unnecessary, or include the submodule's own diff in the PR description.

## Type safety & schema issues

- The `Subject` type is `export type Subject = string` (`utils.ts:49`), so the `<PermissionGuard subject="…">` prop accepts any string at compile time. The typo was a runtime bug, not a type bug. No type-safety improvement is available without changing `Subject` to a string-literal union (which would be a separate, large refactor — out of scope).
- `with-permission.tsx:120` accepts `subject: Subject | (string & {})`, which lets arbitrary strings through with a type assertion escape hatch. This is what allowed the `DayCare::…` typo to compile. A stricter type would catch this earlier but is out of scope.

## Transaction & data integrity

No DB writes in this PR. The five `PermissionGuard` changes only affect whether the wrapped component is rendered; the underlying server actions / tRPC procedures are unchanged. **However, this is also the gap**: the PR does not verify that the corresponding server actions and tRPC routers enforce the same permission subject. If the server-side check uses the same subject string, a typo there would be silently fixed by this PR's UI fix without the server-side check being re-verified. Recommend confirming that:

1. The CathLab/Endo/HD/OT update server actions check the same permission the edit page checks (UI guard + server check should match).
2. The daycare clinical documents server-side handler (likely a tRPC procedure) checks the same subject.

These are out-of-scope for this PR but represent the defense-in-depth gap that an auth-sensitive PR should at least mention.

## Performance

No perf impact. `PermissionGuard` does a synchronous string-lookup against the in-memory `subjectConfigs` map (`with-permission.tsx:166` → `utils.ts:166` `checkPermission`). Five string-equality checks per page render is negligible.

## Accessibility & UX

- Removing the `<UnauthorizedPage />` fallback for the daycare Clinical Documents tab restores access for users who should see it — net positive for affected users.
- The IPD service-request edit pages currently show `UnauthorizedPage` for any role missing the four old per-modality subjects. After this PR, those roles will instead see the edit form (if they have `IPD Management::Service Request`) — which is the desired behavior *if* the consolidation is intentional. If not, the regression is that a role previously denied on all four edit pages will now pass through on all four — depending on the role, this is either correct or a security regression.
- No focus management, ARIA, or keyboard-nav changes.

## Error handling

N/A — no error paths in this PR.

## Style & consistency

- The single-line diff style is consistent across all five edited files. Good.
- Subject-string spelling (`Daycare::`, `IPD Management::Service Request`) now matches every other site identified by grep. Good.
- The PR title typo (`doucments`) and branch name typo (`doucments`) are the only style misses. Nit-level.

## Questions for the author

1. The PR body is empty and there's no ClickUp link. What is the user-reported bug — is it (a) "daycare Clinical Documents tab shows UnauthorizedPage", (b) "IPD service-request edit pages show UnauthorizedPage", or (c) both? Different users may report different symptoms but be hitting the same root cause (registry subject mismatch), or different root causes (typo + consolidation).
2. Was the IPD service-request subject consolidation (`CathLab Requests` → `IPD Management::Service Request`) intentional, or was it driven by the fact that the existing `CathLab Requests` subject wasn't actually exposed under `IPD Management` in `permission-ui-config.ts`? If the latter, a more surgical fix is to add per-modality submodules under `IPD Management` (e.g. `IPD Management::CathLab Requests`) rather than collapse to the generic `Service Request`.
3. The HD page previously used `subject="Endo Requests"` (clearly a copy-paste bug). Was this caught during testing, or was it a side effect of the broader consolidation? If it was unintentional, the IPD consolidation hides the bug rather than fixing it.
4. Which roles were tested? The daycare typo fix changes behavior for any role with `Daycare::Clinical Documents`. The IPD consolidation changes behavior for any role with one of the four per-modality subjects *or* the generic `IPD Management::Service Request`.
5. Why is the opd submodule pointer bumped in this PR? What changed in opd/ that this PR depends on?
6. Is there a test plan (manual or automated) for the permission boundary? The team uses `<UnauthorizedPage />` fallbacks everywhere; a smoke test that asserts "user with role X sees the Clinical Documents tab and user with role Y does not" would be a useful regression guard.

## Cross-references

- **`/Users/pyaesonewin/.claude/CLAUDE.md` §Rules** — "Keep files under 500 lines" is not relevant (no file grew beyond 500 lines). "Validate input at system boundaries" is relevant: the `Subject` string is the boundary; it's typed as `string`, which is permissive.
- **`hms-app/CLAUDE.md`** — The tRPC / `authorizeProcedure(action, subject)` / `authActionClient` patterns are the canonical server-side enforcement layer. This PR is UI-only; **the diff does not verify that the server side enforces the same subject strings**. Recommend a follow-up grep: `grep -rn "authorizeProcedure" src/server/api/routers/ipd | grep -i "service-request\|cathlab\|endo\|hd\|ot"` and the daycare analog.
- **`@common/user-management/roles/features/utils.ts:35-39`** — The dynamic subject-parser logic is the root cause of both the original typo (camelCase `DayCare` doesn't match the registry's `Daycare`) and the IPD consolidation's coverage question. Any future subject-spelling fix should land here as a test case first.
- **PR #2780** — The team has a recent precedent for a thorough PR review (the file in this directory). Compare this PR's score (72) to PR #2780's score (48). Both are "Request changes / Approve with suggestions" tier but PR #2793 is materially smaller and safer.
- **`/Users/pyaesonewin/Documents/work/hms-system/hms-docs/code-reviews/pr-2780-lab-template-review-2026-06-24.md`** — The review template this file follows.

## Verification needed

Things that cannot be verified from the diff alone:

1. **Does the daycare Clinical Documents tab actually render for users with the `Daycare::Clinical Documents` permission?** Manual test: log in as a role that has daycare `Clinical Documents` View permission, open a daycare EMR, click the Clinical Documents tab. Expected: tab content renders; previously: `UnauthorizedPage`. Should reproduce immediately.
2. **Does the IPD service-request edit page render for the correct roles?** For each of {CathLab, Endo, HD, OT}, log in as a role that has only `IPD Management::Service Request` Edit permission, attempt to edit a request. Expected: form renders. Also test the inverse: a role with only `CathLab Requests` Edit should *not* render the form (per High #1's regression concern).
3. **Is there a server-side check matching the UI subject?** Grep `src/server/api/routers/ipd` and `src/server/api/routers/emr/daycare` for `authorizeProcedure` calls referencing the same subject strings. If the server checks a different subject, the UI fix doesn't actually grant access — it just hides the `UnauthorizedPage` while the underlying mutation still 403s. **This is the most important verification.**
4. **What changed in the opd submodule?** Run `cd src/app/(dashboard)/opd && git diff 09714186f..364060b51` and confirm there is no permission-related change in opd/ that this PR should have called out.
5. **Did the SonarQube analysis fail because of an infra outage or because of a new finding?** Re-run the analysis; if a finding is produced, address it before merge.

## Checklist results

- [x] `any` type annotations — None added.
- [x] `@ts-ignore` / `@ts-expect-error` / `eslint-disable` — None added.
- [x] TODO / FIXME — None added.
- [x] Hardcoded secrets — None.
- [x] SQL/Prisma injection — N/A (no DB queries).
- [ ] Long files (>500 lines) — N/A (no file grew).
- [ ] God components — N/A (no new components).
- [x] Missing `key` props — N/A.
- [ ] Unsafe type assertions — `with-permission.tsx:120` accepts `Subject | (string & {})`; out of scope for this PR but the type escape hatch is what allowed the typo.
- [x] Async error swallowing — N/A.
- [x] Missing `await` inside transactions — N/A.
- [x] Tenant-scope — N/A.
- [ ] Permission checks — **Partially addressed**: UI guards corrected, but no server-side check is re-verified. **High #1 + High #2.**
- [x] Missing Zod validation at boundary — N/A.
- [ ] Tests for the auth boundary — **None added. High #2.**
- [ ] Opd submodule diff — **Not included in PR. Medium #2.**
- [ ] PR description — **Empty. Medium #3.**
- [ ] SonarQube pass — **Failed. Medium #4.**

## Recommendation

**Approve with suggestions.** The daycare typo fix is a clear win and ships a real UX regression fix. The IPD service-request consolidation is the right *direction* (consolidation matches the registry's structure) but has an undocumented access-model implication (High #1) that the team should acknowledge before merge — either as a ClickUp ticket, a one-line PR description, or a follow-up test. The two gaps that most warrant a follow-up: (1) verify the server-side enforcement layer uses the same subject strings (a `grep authorizeProcedure` smoke check), and (2) add at least one test for the dynamic subject parser in `utils.ts:35-39` to catch future spelling regressions.

If the team prefers to land this fast, **the daycare fix alone is merge-ready today**; the four IPD edit-page changes can ship together once the consolidation rationale is documented. The opd submodule bump should be split out unless there's a concrete reason it has to ride along.

**Score rationale:** +30 for the correct typo fix and the consistency with seven sibling tabs (Strong evidence the fix is right). +25 for the IPD consolidation being mostly right and matching 12 sibling sites. +15 for surgical, minimal diff. -15 for the High #1 undocumented access-model change. -10 for the High #2 missing tests. -8 for the Medium issues (empty PR body, opd submodule, HD typo, SonarQube). -5 for the Low/Nit issues. Net: 72/100.
