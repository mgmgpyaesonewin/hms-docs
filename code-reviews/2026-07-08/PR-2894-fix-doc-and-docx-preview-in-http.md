# Code Review: PR #2894 — fix: doc and docx preview in http
**Repository:** MyanCare/Ycare-HMS
**Author:** @Xkill119966
**Branch:** `fix/doc-docx-preview-in-http` → `development`
**Files changed:** 8 (+846 / -93)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-08
**ClickUp:** https://app.clickup.com/9018849685/v/l/6-901818951582-1

## Summary
The CT attachment viewer used to delegate `.doc` / `.docx` previews to Microsoft Office Online (`view.officeapps.live.com`), which silently fails when the source file lives behind a private / on-prem S3 URL (the iframe just shows a blank page). This PR replaces that with an in-house pipeline:

1. Client opens the modal; if the file ends in `.doc`, it calls `GET /api/uploads/convert-doc-to-docx?url=…&fileName=…`, which fetches the file from S3, runs `soffice --headless --convert-to docx` on a temp file in `/tmp`, uploads the resulting `.docx` to S3, and returns a 1-hour signed URL.
2. With that URL (or the original `.docx` URL) the client calls `POST /api/uploads/convert-word-to-html` with the URL in the JSON body; the route re-fetches the file and runs `mammoth.convertToHtml` server-side.
3. The modal renders the resulting HTML inline via `dangerouslySetInnerHTML`, and adds Print / Download buttons.

The dropzone in `ct-result-form.tsx` is updated to allow `application/msword` and the hint copy nudges users toward `.docx`.

## Verdict
**Request changes**
Score: 31/100
Critical: 1 | High: 3 | Medium: 4 | Low: 4 | Nit: 2

## Issues

### Critical

1. **XSS via `dangerouslySetInnerHTML` on server-generated Mammoth HTML.** `view-ct-attachment-modal.tsx` renders `wordHtml` (produced by `mammoth.convertToHtml`) directly with `dangerouslySetInnerHTML`. Mammoth strips `<script>` and most event handlers, but the official docs are explicit that **Mammoth's output is not safe to insert into the DOM without further sanitization** — inline styles (`style="background:url(javascript:…)"` historically, plus modern CSS-injection vectors) and `<a href="javascript:…">` from author-supplied Word content will execute in the page origin. Because the file came from an authenticated S3 download behind the user's session, a malicious `.docx` uploaded by anyone with upload rights (or any patient document with a stored hyperlink) is a stored-XSS primitive that runs in the HMS app's origin and can read session cookies / call tRPC mutations. Sanitize with DOMPurify (the standard pattern; e.g. `DOMPurify.sanitize(html, { USE_PROFILES: { html: true } })`) on the server before returning, or render with a sanitizer wrapper on the client. No `DOMPurify` import exists in the repo today, so this would be a new dep — but it is the minimum that closes the hole.

### High

2. **Sibling modals are not fixed — root cause patch only covers CT.** The exact same broken Office-Online pattern lives in `view-echo-attachment-modal.tsx`, `view-x-ray-attachment-modal.tsx`, `view-ecg-attachment-modal.tsx`, `view-ultrasound-attachment-modal.tsx`, and `view-mri-attachment-modal.tsx`. This is a classic "patch the path the ticket named" bug: a report named the CT screen, so the developer rebuilt the CT modal and left five identical modals still broken with the same symptom. The fix belongs in a shared component (a `DocumentPreviewModal` or an `AttachmentPreviewer`) consumed by all six imaging lists, or as a tiny hook (e.g. `useDocPreview({ signedUrl, fileName })`) that returns `{ html, loading, error, download, print }`. The 5 sibling files share the same `isLocalOrPrivateUrl` helper, the same `officeViewerUrl` memo, and the same download-on-mount effect — extracting it is straightforward and the next "x-ray word preview broken" ticket is already on its way.

3. **SSRF surface in `convert-word-to-html` and `convert-doc-to-docx` routes.** Both routes accept an arbitrary `url` (`z.string().url()`) and `fetch(url)` it server-side with no allow-list, no scheme check (only `https://` should be permitted, not `file:`, `gopher:`, or `http://internal`), and no DNS-pinning. `convert-doc-to-docx` writes the fetched body to `/tmp` and shells it out to LibreOffice. An authenticated HMS user (anyone who can attach a result) can therefore probe `http://169.254.169.254/…` (cloud metadata), `http://localhost:5432/…` (Postgres), or `http://10.x.x.x/…` and either exfiltrate via the `success: true` response (for fetchable targets) or use LibreOffice as a parser-amplification oracle. This is a high-impact endpoint — the file fetch needs to be restricted to S3 keys (parse the bucket URL prefix from `s3Service.getBucketUrl()` and reject anything else) and the signed URL pattern itself should be validated (e.g. startsWith check on the `AWS_BUCKET_NAME` URL).

4. **Converted `.docx` blobs are orphaned in S3 with no cleanup.** Every `.doc` preview produces a new S3 object named `${uuidv4()}-${baseName}.docx` under `s3Folders.documents`. Each click on a `.doc` attachment leaks a fresh copy; nothing schedules deletion and nothing tracks the relationship between the original `.doc` and its `.docx`. Within a single hospital doing 50 CTs/day with `.doc` reports, the bucket fills with thousands of duplicated, never-displayed-again `.docx` files. Either (a) cache and reuse one `.docx` per source `.doc` (keyed by SHA-256 of the source bytes), or (b) attach a lifecycle-rule tag and delete after, say, 24 h, or (c) stream the converted buffer directly to Mammoth in the same request without the round-trip to S3. Option (c) is the simplest: one handler, one fetch, one `soffice | mammoth` pipeline, no second bucket write, no signed URL.

### Medium

5. **`application/msword` is added but is already in `MS_WORD_MIME_TYPE`.** The diff expands `ALLOWED_REPORT_MIME_TYPES` to `[MIME_TYPES.pdf, ...MS_WORD_MIME_TYPE, "application/msword"]`. `@mantine/dropzone`'s `MS_WORD_MIME_TYPE` is exported as `("application/msword" | "application/vnd.openxmlformats-officedocument.wordprocessingml.document")[]`, so the third literal is a duplicate. The diff does not change what the dropzone accepts. Either drop the literal (the spread already covers it) or replace the spread with the literal if you want the diff to read explicitly. Functionally a no-op.

6. **Heavyweight toolchain for the symptom.** The fix introduces `mammoth` (+ `bluebird`, `argparse@1.x`, `jszip`, `dingbat-to-unicode`, `lop`, `duck`, `xmlbuilder`, `@xmldom/xmldom`, etc. — see the package-lock delta) **and** requires LibreOffice on the production host. For `.docx` the prior `view.officeapps.live.com` only failed because the source URL was private; if the on-prem constraint is the real issue, the smaller fix is to stream the S3 file to the client through a same-origin `/api/uploads/file-proxy?key=…` route (which already exists in spirit as `pdf-proxy`) and let the existing iframe path take over (Office Online can fetch public URLs). That avoids `mammoth`, avoids LibreOffice, and re-uses `pdf-proxy`'s shape. Worth at least documenting why this heavier route was chosen over the proxy.

7. **`/tmp` is hard-coded and shared.** `documentConverter.service.ts` uses `private tempDir = "/tmp"` and writes `${uuid}.doc` there. Two concurrent conversions could in theory race on cleanup, but more importantly `/tmp` is small (`tmpfs`) on many Linux installs, doesn't exist on Windows (CI runs Windows agents in some Node setups), and is `noexec` on hardened prod images — `soffice` won't run. Use `os.tmpdir()` (cross-platform, respects `TMPDIR`) and check `await fs.mkdtemp(...)` for a per-call dir that you can `rm -rf` in `finally` instead of `unlink`-by-name (avoids the "alternative filename" guesswork branch on lines 84-100).

8. **`console.log` everywhere instead of `winstonLogger`.** The codebase uses `winstonLogger` (`/utils/api-handler.ts`, `/lib/winston.ts`) for structured server logging. The new routes sprinkle 12 `console.log` lines with bracket-prefixed tags (`[DOC Conversion]`) — that's an ad-hoc logging convention the rest of the app doesn't follow. Switch to `winstonLogger.child({ context: "DocumentConverter" })` / `{ context: "DocConversionRoute" }` and use levels (`info` / `debug` / `error`) instead of `console.log`. Drop the per-step logs; the existing `enhancedApiHandler` already logs errors with the stack and route context.

### Low / Nit

9. **`GET` for a state-mutating operation.** `convert-doc-to-docx` is `GET` with `url` and `fileName` as query params. The handler fetches S3, runs LibreOffice, and writes a new object to S3 — none of which is idempotent or cache-safe (the response body embeds a fresh signed URL). GETs are also pre-fetched by browsers and CDN proxies; the resulting `.docx` write could be triggered by an over-eager link prefetcher. Mirror the sibling route and use `POST` with a body schema.

10. **Two `--version` execs back-to-back.** `isLibreOfficeAvailable()` calls `execAsync("${soffice}" --version)` and then the route handler also calls `getLibreOfficeVersion()` — another `--version` exec. Combine: have the availability check return the version string (or null on failure), and skip the second spawn. Save one process exec per request when LibreOffice is missing (which is the very path that needs to be fast).

11. **`getFileExtension` is recomputed on every render of the error state.** Lines 142-148 (the `Alert` branch) call `getFileExtension(viewerState?.fileName || "")` even though the same value was computed in the `useEffect`. Hoist it to a `useMemo` keyed on `viewerState?.fileName` or, simpler, stash it in state alongside `wordHtml`.

12. **`getFileExtension` itself can be one line.** `return `.${fileName.split(".").pop()?.toLowerCase() ?? ""}`;` is 50 chars but the `?` and `?? ""` are guarding against `.docx` with a trailing space — `.split(".").pop()` of `"foo."` returns `""`, which then produces `..`. Easier: `const ext = fileName.toLowerCase().match(/\.[^.]+$/)?.[0] ?? "";`. Trivial.

13. **Nit: file-2 in `package-lock.json` (`sprintf-js` and `path-is-absolute`) lost their `dev: true` flag.** That happens because `mammoth` pulls them in transitively, but `path-is-absolute` isn't actually used in the source. Not a real defect — npm deduplicates the entry — but worth knowing.

14. **Nit: `printWindow.onload = () => printWindow.print()` fires before images / `<style>` are parsed.** The HTML is written via `document.write`, then `document.close()` triggers a load event once parsing is done, but with inline styles only this is usually fine. For `.docx` images embedded as base64 by Mammoth (which Mammoth does NOT do by default — it skips images — so this is currently safe), the print would print an empty page. Worth a comment, not a blocker.

## Recommendation
- **Block the merge until the XSS is closed.** Sanitize Mammoth output (DOMPurify on the server is one line; no DOMPurify dep yet, but `dompurify` is the standard library for this).
- **Stop the SSRF.** Validate the input URL against the S3 bucket URL prefix and reject anything else before `fetch`.
- **Fix the five sibling modals** by extracting the office-preview flow into a shared hook/component, or at minimum add a follow-up issue so the next ticket isn't another one-off.
- **Pick one of (a) cache-and-reuse, (b) lifecycle rule, or (c) inline pipeline** to stop leaking `.docx` blobs into S3.
- Drop the duplicate `"application/msword"` literal (no-op), replace `console.log` with `winstonLogger`, swap `/tmp` for `os.tmpdir()` + per-call `mkdtemp`, and downgrade `convert-doc-to-docx` to `POST`.
- Optional follow-up: consider whether `mammoth` + LibreOffice is the right toolchain vs. a same-origin file proxy that lets the prior Office Online iframe work again — the proxy would remove ~85% of the new code.