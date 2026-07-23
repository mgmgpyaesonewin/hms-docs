# Code Review: PR #3017 — feat(ui): update branding from YCare to Y-Connect
**Repository:** MyanCare/Ycare-HMS
**Author:** @DaDDy-chilll
**Branch:** `psk/29/logo-change` → `development`
**Files changed:** 23 (+28 / -28)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-22

## Summary
This PR replaces the primary YCare logo assets with Y-Connect assets, updates logo references and accessibility text across login, header, letterhead, and receipt components, changes the browser metadata title to “Y-Connect HMS,” and adjusts the expanded header logo sizing and spacing.

## Verdict
**Request changes**
Score: 92/100
Critical: 0 | High: 1 | Medium: 1 | Low: 0 | Nit: 0

## Issues

### Critical
None

### High
- `public/images/yconnect_logo_vertical.png`, `public/images/yconnect_logo_vertical_black.png`, and `public/images/yconnect_logo_horizontal.png`: all three newly added files contain the same binary image (the diff reports identical content/index for each). The code uses the horizontal asset in the expanded header and the vertical asset on login, so those screens can receive the wrong orientation/lockup and the black variant is not actually distinct. Add the intended, separately exported Y-Connect image files and verify their dimensions/content before merging.

### Medium
- `src/components/header.tsx:11-14`: the expanded header changes the rendered logo from `130x130` to `70x70` while also adding `mt-1 ms-2`; because the new horizontal asset is apparently the same square binary as the vertical asset, the header can render a visually incorrect/squeezed logo and alter the sidebar alignment. Verify the asset's intrinsic aspect ratio and check both open/closed sidebar states at the target viewport before release.

### Low / Nit
None

## Recommendation
Replace the duplicated logo binaries with the correct horizontal, vertical, and black variants, then visually verify login, expanded/collapsed navigation, and printed receipts. Confirm that the updated dimensions preserve the intended layout and run the relevant build/typecheck checks.
