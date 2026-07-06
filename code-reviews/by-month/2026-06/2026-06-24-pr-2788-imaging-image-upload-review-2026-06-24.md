# Code Review: PR #2788 — feat: add image upload in image templates

**Repository:** MyanCare/Ycare-HMS
**Author:** @Xkill119966
**Branch:** `feat/imaging-template-image-upload` → `development`
**Files changed:** 5 (+75 / -0)
**Reviewer:** code-reviewer skill (automated, independent re-review)
**Date:** 2026-06-24
**ClickUp ticket:** https://app.clickup.com/t/86ey07294

## Summary

The PR claims to "add image upload in image templates." The actual diff is the smallest plausible client-side change: it wires an existing `uploadImagingTemplateImageAction` server action into five imaging template forms (ECG, ECHO, MRI, Ultrasound, X-Ray). Each form gains a `handleImageUpload` callback that wraps a `File` in `FormData`, calls the server action, and returns the server's `result.displayUrl`. The diff also adds `placeholder="Write template..."` to all five editors. No server-side code, no schema changes, no migrations, no S3 changes are included.

The work is largely **thin wiring of code that already exists** in the shared imaging module. The PR does exactly one thing per form, and does it consistently. The most important question is therefore not what's in the diff but what's missing from it: the `uploadImagingTemplateImageAction` and the `RichTextEditor`'s `onImageUpload` contract are the load-bearing pieces, and **neither is shown in the diff**. Several security and reliability concerns (MIME allowlist, size cap, S3 key path, presigned-URL TTL, error shape, race-on-save, cleanup on failure) cannot be verified from this PR alone — they live in code that was already merged in a prior PR. The reviewer is being asked to approve five identical copies of a client adapter without seeing the underlying server action or the editor's upload callback.

I cannot read `src/app/(dashboard)/shared/imaging/imaging-template.actions.ts` (where `uploadImagingTemplateImageAction` is defined) or the `RichTextEditor` component definition from this environment, so several findings below are conditional on assumptions about that code. I have called those out explicitly under "Unverified" — they are the only path to changing this verdict from "Request changes" to "Approve with suggestions."

## Verdict
**Request changes**
Score: 48/100
Critical: 1 | High: 4 | Medium: 5 | Low: 4 | Nit: 5

## Strengths

- `src/app/(dashboard)/imaging/ecg/templates/features/components/ecg-template-form.tsx:104-114` (and the four mirrored sites) — the `handleImageUpload` adapter is small, single-purpose, and has a clean error path: it throws on `!response.success` rather than swallowing the error, which lets the editor surface the failure to the user.
- `ecg-template-form.tsx:13-15` — the import block re-uses the existing action module (`@/app/(dashboard)/shared/imaging/imaging-template.actions`) and slots `uploadImagingTemplateImageAction` alphabetically between `create…` and `update…`. No new server action is introduced in this PR — that is the right place for it to live.
- `ecg-template-form.tsx:141-142` — adding `placeholder` and `onImageUpload` together means the editor's empty-state copy is now useful (`"Write template..."`), which is a real UX win that the form previously lacked.
- The five changes are byte-for-byte identical, which means a single server-action bug fix will land for all modalities — no skew.
- The `FormData` payload is correctly built: the field is named `file`, matching what a typical `safeActionClient` Zod schema for `file: z.instanceof(File)` would expect.

## Issues

### Critical

- **All 5 files — no PHI / patient-context guard on upload path**
  The five imaging-template forms are reachable from clinical workflows that do not carry a patient ID, but the upload destination (presumably S3) almost certainly does. We can't verify the S3 key path, bucket policy, or whether the upload is bound to the currently logged-in tenant/store from this diff alone. If `uploadImagingTemplateImageAction` keys uploads by `userId + timestamp` with no `tenantId` (which the HMS uses per the project CLAUDE.md), a template image uploaded by a doctor in one store could be readable by another store, or could leak across tenants. The PR also does not assert what `displayUrl` returns — a presigned S3 URL with a long TTL would defeat the tenant-scoping strategy. **Action:** author must paste the `uploadImagingTemplateImageAction` body and the editor's `onImageUpload` invocation into the PR description or as a follow-up commit, and reviewers must confirm the action enforces `tenantId` and that the returned URL is a short-lived presigned URL (or a server-proxied route that re-checks auth). This is the single most important thing to verify before merge.

### High

- **All 5 files — no client-side file validation**
  `handleImageUpload` accepts any `File` and forwards it. There is no MIME check (`file.type !== 'image/png' | 'image/jpeg' | 'image/webp' | 'image/gif'`), no extension check, and no size check before the `FormData` POST. The reviewer's rules for file-upload features specifically call out MIME allowlist, size limits, and extension allowlist. The server action may re-validate, but the PR ships zero client-side guards. A user dropping a 200 MB raw video, an `.exe` renamed to `.png`, or a `data:` URL paste will trigger a network round-trip and an unhelpful error toast — and any time the server's allowlist is wrong, the client provides no second line of defense. Add a 5 MB cap and an `image/*` MIME allowlist client-side; the server must still re-check.

- **All 5 files — `onImageUpload` is not `await`-safe in the editor contract**
  The callback returns `Promise<string>`. The function is named `handleImageUpload` and assigned to `onImageUpload={handleImageUpload}` — i.e. the prop receives the function reference, not the result. If the editor's `onImageUpload` is supposed to be `(file) => Promise<string>` and the editor `await`s the returned promise to embed the URL, fine. But if the editor is typed as `(file: File) => void` and is *meant* to be invoked synchronously with a pre-uploaded URL, the contract is wrong and the editor will likely receive `undefined`. We cannot confirm this without the editor's type signature. Either way, the PR's TypeScript gives us no safety net — there is no explicit return type on `handleImageUpload`. Add `: Promise<string>` to the function signature and add a comment stating the editor's `onImageUpload` contract.

- **All 5 files — no `try`/`catch` and no `finally` around the action call**
  If `uploadImagingTemplateImageAction` throws (network error, server 500, Zod parse failure, `safeActionClient` rejection), the function throws and the editor's promise rejects — but the form has no local error handling, no loading state, and no way to tell the user "image upload failed, your template body is still being edited but the image didn't make it." The user may save the template, get a success toast, and then discover hours later that the embedded image is broken because the S3 upload was never retried. Wrap the call in `try { … } catch (err) { toast.error(…); throw }` so the editor surfaces the failure inline rather than failing silently.

- **All 5 files — leaked S3 object on form abandonment**
  When a user uploads an image, gets a `displayUrl`, embeds it in the editor, then **navigates away without saving the form**, the S3 object is orphaned. There is no cleanup pass, no `beforeunload` warning that says "you have unsaved image uploads," and no scheduled GC of unreferenced template uploads. For a hospital system, orphaned PII-bearing images in S3 are a real audit problem. The fix is usually a server-side sweep keyed on `templateId IS NULL` plus a soft-delete TTL, or a client-side warning. The PR introduces zero such guard. This is a long-standing design issue with the upload action — but the PR is what brings the surface area live across all five modalities, so the burden of addressing it is now on this PR.

### Medium

- **`ecg-template-form.tsx:114` (and 4 mirrors) — return type is implicit**
  `handleImageUpload` does not declare a return type. TypeScript will infer `(file: File) => Promise<string>`, but if the action's `result` shape changes (e.g. `displayUrl` is renamed to `url`, or the result is wrapped in `{ data: { displayUrl } }`), the failure will be a runtime `TypeError: Cannot read property 'displayUrl' of undefined` rather than a compile error. Add an explicit `Promise<string>` return type and define a Zod schema for the action's result on the client side (or import the inferred type from the action).

- **All 5 files — error message is leaked to the UI**
  `throw new Error(response.error || "Failed to upload image")` — `response.error` is whatever the server action returned, which on `safeActionClient` is the raw Zod issue list or a server stack-trace excerpt. The RichTextEditor presumably renders this as the image-failed-to-load tooltip. The server should map all errors to a small, user-safe string set ("File too large", "Unsupported file type", "Upload failed — please try again") and the client should not pass `response.error` through. Right now a Zod issue list will be shown verbatim to the clinician.

- **All 5 files — no file size or extension surfaced to the user before upload**
  Even setting aside the security concern, the UX is poor: the user picks a 50 MB file from their file picker, the editor's spinner runs for 30 seconds, then a cryptic error appears. Add a pre-flight check (`if (file.size > 5 * 1024 * 1024) { toast.error("Image must be under 5 MB"); return; }`) at the top of `handleImageUpload`.

- **All 5 files — DRY violation: the 12-line block is duplicated 5 times**
  `handleImageUpload` is identical in all five form files. This is a maintenance hazard: when the error-message mapping or return-type contract changes, all five must be updated in lockstep, and the diff in this PR shows the team has historically missed such lockstep (the `placeholder` was added in all 5 in this PR, but on review of git blame one often finds that a previous PR added it in 3 of 5). Hoist `handleImageUpload` into a shared hook — `useImagingTemplateImageUpload()` — under `src/app/(dashboard)/shared/imaging/hooks/` and call it from all five forms. This also makes the upload contract testable in isolation.

- **`ecg-template-form.tsx:113` — `displayUrl` is treated as directly embeddable**
  The function returns `response.result.displayUrl` straight to the editor. If `displayUrl` is a raw S3 URL (`https://ycare-hms.s3.amazonaws.com/...`), the editor embeds it in the HTML body, and the body is later rendered to other users — the other user's browser requests the S3 object with no HMS auth. If the bucket is private and `displayUrl` is a presigned URL, fine. If it isn't, this is a data-exfiltration path. Confirm the action returns a presigned URL with TTL ≤ 15 min, and that the S3 bucket denies unauthenticated GETs.

### Low

- **`ecg-template-form.tsx:105` — `FormData` field name is not typed**
  `formData.append("file", file)` — the literal `"file"` should be a const (`const FILE_FIELD = "file" as const;`) and the server-side Zod schema should reference the same constant. Right now the only thing binding the client to the server is the string `"file"`, and a typo on either side will produce a 422 that takes 20 minutes to debug.

- **All 5 files — no test added**
  The PR introduces 75 lines of client code across 5 files and adds zero tests. The action was likely tested in its original PR, but the client adapter (the part the diff actually changes) is not. A 30-line Vitest/RTL test that asserts `handleImageUpload` returns `displayUrl` on success, throws on `response.success === false`, and throws on `!response.result` would catch the three regressions most likely to land.

- **All 5 files — `placeholder` is added but `aria-label` and `i18n` are not**
  `placeholder="Write template..."` is hard-coded English. If the HMS ships in any language other than English (the project uses `next-intl` per typical YCare patterns — confirm with the team), this is a regression vs. the prior un-placeholdered state. If the editor supports a `placeholder` prop typed as `string | TranslationKey`, fine; otherwise this is a follow-up.

- **`ecg-template-form.tsx:113` (and 4 mirrors) — early-return guard is buggy**
  `if (!response.success || !response.result) { throw new Error(...) }` — if `response.success === true` but `response.result` is `undefined` (a shape the server might return on a no-content success), the guard is bypassed and the next line throws a `TypeError` with no useful message. Add a `response.result &&` check or invert the guard.

### Nit

- **All 5 files — `handleImageUpload` could be `useCallback`-wrapped**
  The function is recreated on every render, which will cause the editor's upload prop to re-evaluate identity on every keystroke. With a debounced editor this is usually harmless, but if the editor is memoized, this will defeat the memo. Wrap in `useCallback(…, [])`.

- **All 5 files — function name shadows the prop**
  `handleImageUpload` (the local function) and `onImageUpload` (the prop) both end with the same word. Renaming the local to `uploadAndGetUrl` would make the call site read better: `onImageUpload={uploadAndGetUrl}`.

- **All 5 files — `placeholder` is a UX change bundled with an upload change**
  This PR's title is "feat: add image upload in image templates." The `placeholder` addition is unrelated and should have been a separate commit, or called out in the PR description. Mixing concerns makes rollback harder if the placeholder turns out to break an existing test that asserted on the editor's empty state.

- **All 5 files — no JSDoc on the new function**
  A one-line `/** Uploads an image and returns the displayUrl for embedding in the editor. Throws on failure. */` would document the contract for the next reader.

- **`ecg-template-form.tsx:101` (and 4 mirrors) — placement of `handleImageUpload`**
  The function is defined after `handleSubmit`. Convention in the existing file (and in React generally) is to define handlers before the `return`. Move it above `return` but after the state hooks — currently it sits in an odd middle position.

## Unverified (cannot be confirmed from this diff alone)

The following are conditional on the body of `uploadImagingTemplateImageAction` and the contract of the `RichTextEditor`'s `onImageUpload` prop. The PR is **not approvable** until these are confirmed by the author in a PR comment or follow-up commit:

1. The server action enforces a MIME allowlist and a size cap server-side (re-validation per the reviewer's rules).
2. The S3 key path is tenant-scoped (per project CLAUDE.md, `tenantId` is mandatory on every persisted row; S3 keys should be too).
3. The returned `displayUrl` is a short-lived presigned URL (TTL ≤ 15 min) and the bucket denies unauthenticated GETs.
4. The `RichTextEditor`'s `onImageUpload` prop is typed `(file: File) => Promise<string>` and `await`s the return value.
5. The action cleans up S3 objects on the editor's `onImageUpload` rejection / timeout / form-abandonment path, or there is a sweep job.
6. The action returns a small, sanitized error message rather than a raw Zod issue list.

If any of 1-6 is "no," the Critical issue above is upgraded to "Block" and the PR must be returned for revision.

## Recommendations

- **Author:** paste the body of `uploadImagingTemplateImageAction` and the `RichTextEditor`'s `onImageUpload` type signature into the PR description. The diff alone is insufficient for a security-sensitive feature review.
- **Author:** hoist `handleImageUpload` into `src/app/(dashboard)/shared/imaging/hooks/useImagingTemplateImageUpload.ts` and call it from all 5 forms.
- **Author:** add an explicit `Promise<string>` return type, a `try`/`catch` with a user-facing toast, and a client-side size+MIME guard.
- **Author:** split the `placeholder` change into a separate commit (or PR).
- **Reviewer (next pass):** if the author confirms points 1-6 above, downgrade the Critical to "Resolved" and re-score.
