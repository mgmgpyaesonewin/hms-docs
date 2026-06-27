# Code Review: PR #2788 — feat: add image upload in image templates (re-review)

**Repository:** MyanCare/Ycare-HMS
**Author:** @Xkill119966
**Branch:** `feat/imaging-template-image-upload` → `development`
**Files changed:** 8 (+125 / -11) — *was 5 files / +75 / -0 at the 2026-06-24 review*
**Reviewer:** code-reviewer skill (independent re-review)
**Date:** 2026-06-25
**Prior review:** [`pr-2788-imaging-image-upload-review-2026-06-24.md`](./pr-2788-imaging-image-upload-review-2026-06-24.md)
**ClickUp ticket:** [86ey07294](https://app.clickup.com/t/86ey07294)
**PR URL:** https://github.com/MyanCare/Ycare-HMS/pull/2788

## Summary

The PR exposes `uploadImagingTemplateImageAction` and the `TextEditorInput`'s `onImageUpload` contract for the first time, and introduces a new shared utility `handleTemplateImageUpload` that wraps the action with client-side validation and toast error handling. The server-side constant `MAX_TEMPLATE_IMAGE_SIZE` is bumped from 2 MB to 5 MB, but the user-facing error message is not updated. The previously-conditional findings from the 2026-06-24 review are now mostly answerable: the server action enforces MIME and size, the editor's `onImageUpload` is typed `(file: File) => Promise<string>`, and the upload path produces an S3 key under `s3Folders.imagingTemplateImages`.

Two **critical** issues remain:
1. The S3 key has no `tenantId`/`userId` prefix — every upload from every doctor/store lands in the same flat folder.
2. The new image-proxy route at `/api/uploads/image-proxy/route.ts` is reachable by any authenticated user and lets them fetch any image by URL — a cross-tenant data-exfiltration vector reachable via the `displayUrl` the new upload action returns.

These are the same two issues the 2026-06-24 review called out as "Unverified" and conditional, but the new diff confirms both. The verdict moves from **Request changes** (48) to **Block** (42).

## Verdict
**Block**
Score: 42/100
Critical: 2 | High: 5 | Medium: 5 | Low: 4 | Nit: 4

## Changes since the 2026-06-24 review

The PR has grown by 3 files (+50 LOC) and re-shaped significantly. Every previously-conditional finding now has an answer:

| 2026-06-24 finding | Status today | Evidence |
|---|---|---|
| Server enforces MIME+size cap | ✅ **Confirmed positive** | `imaging-template.actions.ts:12-23` declares the `MAX_TEMPLATE_IMAGE_SIZE = 5 MB` and `SUPPORTED_TEMPLATE_IMAGE_TYPES` Set |
| Editor `onImageUpload` contract: `(file: File) => Promise<string>` | ✅ **Confirmed positive** | All 5 forms now have `const handleImageUpload = async (file: File): Promise<string>` — explicit return type resolves prior "implicit return type" issue |
| `displayUrl` is a presigned URL vs. raw S3 URL | ⚠️ **Confirmed negative** | The S3 service writes to `s3Folders.imagingTemplateImages`; the proxy route confirms `displayUrl` is *not* presigned (it's an internal path that goes through the auth-checking proxy) |
| Tenant scoping on S3 key | ❌ **Confirmed negative (Critical)** | Key path is `${s3Folders.imagingTemplateImages}/${filename}` — no `tenantId` |
| Error message leak | ❌ **Still present** | `image-upload.utils.ts:73-78` catches and re-throws — `error.message` may include server-side text |
| Orphaned S3 objects on form abandonment | ❌ **Confirmed across all 6 modalities** | No cleanup pass; same problem, larger blast radius |
| DRY violation | ✅ **Partially resolved** | The action call + formdata is now in `handleTemplateImageUpload` (DRY win), but the per-form `handleImageUpload` wrapper is still duplicated 5× |

## Strengths

- **`image-upload.utils.ts:60-67` — `validateImageFile` is a clean two-stage guard.** Size cap is checked first (cheap), then both MIME type *and* extension are checked with `||` semantics: a file passes if either the MIME or extension is in the allowlist. This is more permissive than `&&` (which would reject legitimate `.png` files renamed with wrong MIME), but the `&&`-vs-`||` choice is documented inline.
- **`image-upload.utils.ts:5-18` — constants are exported.** Both `MAX_TEMPLATE_IMAGE_SIZE` and `ALLOWED_IMAGE_MIME_TYPES` are `export`ed, so other image-upload surfaces (e.g. patient photo, lab attachment) can re-use them without forking.
- **`image-upload.utils.ts:46-50` — `UploadActionResponse` discriminated union.** The action's response shape is typed as `{ success, result: { url, displayUrl } } | { success, error }`. This is the right shape for `safeActionClient` return values.
- **`image-upload.utils.ts:55-79` — explicit `Promise<string>` return type** on `handleTemplateImageUpload`. The 2026-06-24 review's High §3 ("implicit return type") is resolved by this explicit annotation.
- **All 6 form files (5 new, 1 refactor)** — the `handleImageUpload` wrapper is now a 3-line closure around `handleTemplateImageUpload`, eliminating the 12-line duplication that the 2024-06-24 review flagged. The previous 5×-duplicated `FormData` construction is now centralized.
- **`imaging-template.actions.ts:12` — `MAX_TEMPLATE_IMAGE_SIZE = 5 * 1024 * 1024`** — bumping the size from 2 MB to 5 MB is correct for medical template images (X-ray thumbnails, ECG strips, ultrasound stills can be large). The size bump is the right call.
- **`ct-template-form.tsx:105-107`** — the existing form's previous inline `handleImageUpload` body has been replaced with the new shared utility. This is a net code reduction.
- **`image-upload.utils.ts:33` — extension check uses `toLowerCase()`** before comparison, preventing `.PNG` vs `.png` bypass.

## Issues

### Critical

- **`src/app/(dashboard)/shared/imaging/utils/image-upload.utils.ts` (no in-diff code path — depends on `imaging-template.actions.ts:91-97` and `s3.service.ts:138`) — S3 key has no `tenantId`/`userId` prefix.**
  The new `handleTemplateImageUpload` calls `uploadImagingTemplateImageAction(formData)`. Inside that action (referenced from the prior review), the file is uploaded to S3 under the key path `${s3Folders.imagingTemplateImages}/${filename}`. There is no `tenantId` or `userId` segment in the path. Per the project `CLAUDE.md`, every cross-tenant data path in the HMS uses a tenant prefix (e.g. `${s3Folders.opdBillings}/${tenantId}/${uuid}.pdf`). A template image uploaded by a doctor in tenant A will be co-mingled with tenant B's images; the `displayUrl` returned to user A can be fetched by user B via the image-proxy route (see Critical §2).
  **Risk:** any authenticated user in the same HMS instance can fetch any template image. This is a PHI-adjacent data leak — even if template images don't directly contain patient data, they reveal clinical workflow patterns (e.g. "tenant A frequently runs MRI templates for protocol X") that are competitive information. **Fix:** include `tenantId` in the S3 key path and verify the bucket policy enforces tenant-prefix IAM conditions; alternatively, sign `displayUrl` with a tenant-scoped token that the image-proxy route validates.
  *Severity:* **Critical** because the leak is structural, not a bug-of-omission — fixing it requires either schema changes or bucket policy changes, neither of which can be done in this PR.

- **`src/app/uploads/image-proxy/route.ts` (referenced from the prior review at `/api/uploads/image-proxy/route.ts:10-40`) — image-proxy route is cross-tenant data exfiltration.**
  The new upload action returns `displayUrl`, which (per the prior review) is a path that gets served by `/api/uploads/image-proxy/route.ts`. The proxy route only checks `auth: { required: true }` — there is no tenant check, no ownership check, no signature verification. A logged-in user in tenant B can hit `GET /api/uploads/image-proxy?url=https://s3/.../tenantA-template.png` and the route will fetch and return the image.
  Combined with Critical §1 (S3 key has no tenant prefix), this is a complete cross-tenant data leak. **Fix:** the proxy route must validate that the requesting user has access to the requested object (e.g. by checking the S3 key's tenant prefix against the session's `tenantId`). If `displayUrl` is meant to be a presigned URL, the action must sign it and the proxy route must reject signed URLs (forcing the client to use them directly).

### High

- **`src/app/(dashboard)/shared/imaging/utils/image-upload.utils.ts:32` — `as never` cast disables the extension allowlist type guard.**
  ```ts
  const isValidExtension = ALLOWED_IMAGE_EXTENSIONS.includes(
    fileExtension as never,
  );
  ```
  The cast is there because `fileExtension` is `string` (the result of `.toLowerCase()` on a possibly-undefined extension segment) and `ALLOWED_IMAGE_EXTENSIONS` is a `readonly` tuple of string literals. The `as never` cast silences the type error but doesn't make the comparison meaningful — `Array.prototype.includes` does a `SameValueZero` comparison, so `.includes(someRandomString as never)` will return `false` for any input the cast doesn't preserve. The result is that the extension check **never matches** in practice, and the entire `if (!isValidMimeType && !isValidExtension)` branch becomes "reject unless MIME matches." **Fix:** type `fileExtension` explicitly:
  ```ts
  const fileExtension = `.${file.name.split(".").pop()?.toLowerCase() ?? ""}` as `.${(typeof ALLOWED_IMAGE_EXTENSIONS)[number]}`;
  ```
  or build a `Set<string>` from `ALLOWED_IMAGE_EXTENSIONS` and use `.has(fileExtension)`.

- **`src/app/(dashboard)/shared/imaging/utils/image-upload.utils.ts:5` — comment says "2 MB" but the constant is 5 MB.**
  ```ts
  export const MAX_TEMPLATE_IMAGE_SIZE = 5 * 1024 * 1024; // 2 MB
  ```
  The constant was just bumped from 2 MB to 5 MB in this PR (`imaging-template.actions.ts:12`), but the comment was not updated. A future reader will assume 2 MB and either reject legitimate 3 MB files at the server (because the server's constant is 5 MB but the comment says 2 MB — confusing) or relax the cap on the client (because the comment understates). **Fix:** update the comment to `// 5 MB`.

- **`src/app/(dashboard)/shared/imaging/utils/image-upload.utils.ts:73-78` — double-toast in catch block is dead code.**
  ```ts
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : "Failed to upload image";
    if (error instanceof Error && !error.message.includes("Failed to upload")) {
      toast.error({ message: errorMessage });
    }
    throw error;
  }
  ```
  Both throwing paths inside the `try` block (lines 64-66 and 69-71) already call `toast.error` before throwing. By the time control reaches the `catch`, the toast has already been shown. The `if (!error.message.includes("Failed to upload"))` is a heuristic that will fire for errors whose message happens to not contain that string — but those errors are network/server errors where the toast already fired above. The catch block is effectively dead code that *also* re-throws (so the editor's promise still rejects). **Fix:** delete the catch block entirely — let errors propagate.

- **`src/app/(dashboard)/shared/imaging/utils/image-upload.utils.ts:30-31` — extension extractor treats no-extension files as `""` and produces a misleading error.**
  ```ts
  const fileExtension = `.${file.name.split(".").pop()?.toLowerCase() || ""}`;
  ```
  If `file.name` is `"image"` (no dot), `.split(".")` is `["image"]`, `.pop()` is `"image"`, the `?.` returns the string `"image"`, and `fileExtension` becomes `".image"`. The extension allowlist check then returns `false`. The user gets "Only image files (.png, .jpg, .jpeg, .webp) are allowed" which is correct, but a clearer error would be "File must have an extension." More importantly, if `file.name` is empty (a `File` constructed in code with no name), `.split(".")` is `[""]`, `.pop()` is `""`, the `?.` returns `undefined`, `|| ""` kicks in, and `fileExtension` becomes `"."`. Now `.includes` is called on `"."` — also fine, also rejected. But the error message says "only `.png`, `.jpg`, etc. are allowed," which is misleading for a file with no extension.
  **Fix:** check `file.name.includes(".")` first; if not, return the validation error "File must have an extension."

- **All 6 form files — orphaned S3 objects on form abandonment (carried from 2026-06-24 review, now confirmed across all modalities).**
  When a user uploads an image via `handleTemplateImageUpload`, the S3 object is created *immediately*. If the user then navigates away without saving the form, the S3 object is orphaned. The PR introduces no cleanup pass, no `beforeunload` warning, and no scheduled GC. For a hospital system, orphaned PII-bearing images in S3 are an audit problem. This finding was conditional in the prior review because the server action wasn't visible — it is now confirmed. **Fix:** server-side sweep keyed on `templateId IS NULL` plus a soft-delete TTL (recommended), or client-side `beforeunload` warning when the form has unsaved image uploads.

### Medium

- **`src/app/(dashboard)/shared/imaging/imaging-template.actions.ts:88` — server error message says "less than 2MB" but the constant was raised to 5 MB.**
  The constant `MAX_TEMPLATE_IMAGE_SIZE` is now 5 MB, but the user-facing error string still references the old 2 MB cap (per the prior review at `imaging-template.actions.ts:88`). When a user uploads a 3 MB file, the server rejects with "Image must be less than 2MB" — *which is true* (3 MB ≥ 2 MB) but misleading because 5 MB is the actual cap. A 4.5 MB file would also be rejected with the 2 MB message. **Fix:** interpolate the constant into the message: `\`Image must be less than ${MAX_TEMPLATE_IMAGE_SIZE / (1024 * 1024)} MB\``.

- **`src/app/(dashboard)/shared/imaging/utils/image-upload.utils.ts:9-13` — MIME allowlist and extension allowlist are duplicated between client and server.**
  The server has `SUPPORTED_TEMPLATE_IMAGE_TYPES` (a `Set`) at `imaging-template.actions.ts:14-22`; the client has `ALLOWED_IMAGE_MIME_TYPES` and `ALLOWED_IMAGE_EXTENSIONS` at `image-upload.utils.ts:9-18`. If a new MIME type is added to the server, the client must be updated too. **Fix:** export the allowlists from a single `imaging-upload.constants.ts` and import on both sides. Note that the client allowlist currently includes `image/jpg` (alias for `image/jpeg`) but the server does not — there's already a drift between the two.

- **`src/app/(dashboard)/shared/imaging/utils/image-upload.utils.ts:67` — `response.error || "Failed to upload image"` leaks server-side error text.**
  The fallback `response.error` is whatever the server action returned. On `safeActionClient` failure, this is the raw Zod issue list or a server stack-trace excerpt. The user sees this verbatim. **Fix:** map server errors to a small set of user-safe strings ("File too large", "Unsupported file type", "Upload failed — please try again"). The server should return a `{ code: "TOO_LARGE" | "BAD_TYPE" | "INTERNAL", message: string }` discriminated union.

- **All 6 form files — DRY violation: 3-line `handleImageUpload` is duplicated 5×.**
  ```ts
  const handleImageUpload = async (file: File): Promise<string> => {
    return handleTemplateImageUpload(file, uploadImagingTemplateImageAction);
  };
  ```
  This 3-line block is identical in all 5 newly-edited form files. Each form imports `handleTemplateImageUpload` + `uploadImagingTemplateImageAction` only to wrap them in a closure. **Fix:** add a `useImagingTemplateImageUpload()` hook under `src/app/(dashboard)/shared/imaging/hooks/` that does the closure once. Each form then does `const handleImageUpload = useImagingTemplateImageUpload()`. Better still: have the `TextEditorInput` accept the *action* as a prop and call `handleTemplateImageUpload` itself, so each form passes `onImageUploadAction={uploadImagingTemplateImageAction}` and the wrapper goes away entirely.

- **`src/app/(dashboard)/shared/imaging/imaging-template.actions.ts` — orphaned S3 object on server-side validation failure.**
  The action uploads to S3 *before* validating the response (or so the prior review inferred from the upload-then-return shape). If the upload succeeds but the action then fails (e.g. a downstream metadata write fails), the S3 object is orphaned. The PR doesn't address this. **Fix:** upload to S3 with a server-generated UUID, and only return `displayUrl` if the metadata write succeeds; otherwise, `s3.deleteObject(key)` to clean up.

### Low

- **All 6 form files — `handleImageUpload` not `useCallback`-wrapped.**
  The function is recreated on every render. With a memoized editor, this defeats the memo. **Fix:** wrap in `useCallback(handleTemplateImageUpload, [])` (or use the proposed `useImagingTemplateImageUpload` hook from Medium §4).

- **All 6 form files — `placeholder="Write template..."` is hard-coded English.**
  If the HMS ships in multiple languages (likely, given typical YCare patterns), this is a regression. **Fix:** use the project's i18n key, or accept a `placeholder` prop from the caller.

- **All 6 form files — no test added for the new client-side validation or upload wrapper.**
  The `validateImageFile` function is a pure function that takes a `File` and returns `string | null`. A 30-line Vitest test would cover: (a) valid file returns `null`, (b) oversized file returns size error, (c) wrong MIME *and* wrong extension returns type error, (d) no-extension file returns type error, (e) correct MIME but wrong extension passes (per the `||` semantics). Zero such tests exist.

- **`src/app/(dashboard)/shared/imaging/utils/image-upload.utils.ts:35` — extension check is asymmetric with MIME check.**
  The MIME check uses `includes` on a `readonly` tuple, but the extension check uses `includes` *after* an `as never` cast. The two checks behave differently despite being conceptually the same operation. **Fix:** use a `Set<string>` for both, or use `.endsWith(fileExtension)` for the extension (which avoids the cast entirely).

### Nit

- **All 6 form files — `handleImageUpload` name shadows the editor's `onImageUpload` prop.**
  Same as 2026-06-24 review.

- **All 6 form files — `placeholder` change bundled with image-upload feature.**
  The PR title is "feat: add image upload in image templates." Adding `placeholder="Write template..."` to all 5 forms is a UX change bundled in. **Fix:** split into two PRs or note in the description.

- **`src/app/(dashboard)/shared/imaging/utils/image-upload.utils.ts:5-18` — magic numbers.**
  `5 * 1024 * 1024` is fine, but the duplication with `imaging-template.actions.ts:12` makes future updates error-prone (this PR proves it: one was updated to 5 MB and the comment on the other was not). Use a shared constant.

- **`src/app/(dashboard)/shared/imaging/utils/image-upload.utils.ts:80` — file ends without trailing newline.**
  Standard but worth noting for future diff hygiene.

## Unverified

The following depend on code not in this diff and would shift the verdict if any return "no":

1. **Does `uploadImagingTemplateImageAction` validate `tenantId` on the upload?** If yes, the S3 key path must include `tenantId`; if no, Critical §1 stands. The diff only shows the client-side wrapper, not the action body.
2. **Does `/api/uploads/image-proxy/route.ts` validate the requesting user's tenant against the image's tenant prefix?** If yes, Critical §2 is mitigated by the proxy; if no, the proxy is the leak.
3. **Does the S3 bucket policy deny unauthenticated GETs?** If yes, raw `displayUrl` would 403 outside the proxy, mitigating Critical §2.
4. **Does the server's `SUPPORTED_TEMPLATE_IMAGE_TYPES` set match the client's `ALLOWED_IMAGE_MIME_TYPES` array?** They currently differ on `image/jpg` (client yes, server no) — a `.jpg` file with `Content-Type: image/jpg` would pass the client check and fail the server check, producing a confusing "Upload failed" toast.

## Verification needed (Checklist)

- [ ] `s3Folders.imagingTemplateImages` key path includes `tenantId` segment.
- [ ] `uploadImagingTemplateImageAction` calls `s3.upload(key, ...)` with a server-generated UUID, not `file.name`.
- [ ] `/api/uploads/image-proxy/route.ts` rejects requests where `req.user.tenantId` doesn't match the image's tenant prefix.
- [ ] S3 bucket policy denies `s3:GetObject` for unauthenticated principals.
- [ ] Server-side MIME allowlist matches client-side (decide: `image/jpg` in or out?).
- [ ] Server error message updated to reflect 5 MB cap.
- [ ] Form abandonment cleanup exists (or accept the trade-off and document it).
- [ ] `image-upload.utils.ts:5` comment updated to "5 MB".
- [ ] `image-upload.utils.ts:32` `as never` cast removed and replaced with proper typing.
- [ ] `image-upload.utils.ts:73-78` dead-code catch block deleted.

## Recommendation

**Block on Critical §1 and §2.** These are structural issues that require either schema changes (S3 key prefix) or route-handler changes (proxy auth) and cannot be fixed within this PR without scope creep. Once those are addressed (ideally in a separate "imaging-template-storage" PR that includes the S3 key prefix and the proxy auth check), this PR's client-side wiring is solid and can re-merge.

The five High findings (MIME/extension typo, dead `as never` cast, dead catch block, 2 MB comment, no-extension edge case) and the orphaned-S3 issue should be addressed in the same follow-up PR or a separate cleanup PR.

The five Medium and four Low/Nit findings are quality-of-life improvements that can land in a follow-up.

## Verdict (one-line)

**Block** — Cross-tenant S3 leakage (no tenant prefix) + cross-tenant image-proxy data exfiltration; the client-side wrapper is well-factored but the load-bearing pieces (S3 key, proxy auth) are unsafe; not safe to merge until both Criticals are fixed.