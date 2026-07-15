# Changelog

All notable changes to **hms-app** (YCARE HMS monolith) are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project does not yet adhere to [Semantic Versioning](https://semver.org/).

> **Related:** [[INDEX]] · [[hms-app/README]] · [[hms-app/SPEC]] · [[code-reviews/README|Code reviews]]
> Tags: #release-notes #hms-app

## Summary (for non-technical readers)

This update (v1.1.35.uat) is a substantial one for the HMS, headlined by the introduction of the **CathLab module** — a long-awaited addition for cardiac catheterization procedures that lets the team manage CathLab requests, EMR direct pharmacy requests, and CathLab pharmacy sales all in one place, replacing the previous workaround of stitching these together across screens.

On the OPD side, **pharmacy refund and billing have been refined**: the tax field on OPD refunds now follows the global default setting so receipts are consistent, and pharmacy discount labels on OPD bills show the right wording based on context. Day-to-day IPD work is smoother too — **pre-deposits are now visible in patient deposit history**, the **discharge final bill** has a cleaner workflow, and staff no longer need to fill in building/room fields when ordering IPD services.

**Lab and Imaging get a print-UI refresh** for better readability of result entry and reports, and **EMR emergency services can now be deleted cleanly** (previously a pain point). There are also fixes to patient registration (phone numbers now persist correctly when editing), pharmacy sale return edge cases, OT procedure search, ward ordering, and a bundle of small but annoying bugs that the UAT team flagged and we folded in. Under the hood, several shared validation paths were refactored to reduce duplication, which means fewer surprises in future updates.

Overall: **a meaningful step forward for CathLab users, cleaner OPD/IPD billing, and a long list of small fixes that make daily workflows less frustrating.**

## [Unreleased]

_Changes accumulated on `development` after the v1.1.35.uat cut._

---

## [v1.1.35.uat] — 2026-07-08

**Branch:** `origin/uat` @ `74b421657` (bump commit `5192c0fa9`)
**Diff range:** `3fda005c9^..5192c0fa9` (58 commits)
**Cut by:** knzth <khun.noonzayar@gmail.com>

### Added

#### CathLab module (sprint 26)
- **PR #2869** CathLab base module (`cathlab-86ey3pg5q`)
- **PR #2899** CathLab module continued (`86ey2rjb6`)
- **PR #2897** CathLab EMR direct pharmacy request (`cathlab-emr-pharmacy-request`)
- **PR #2912** CathLab module finalisation (`86ey2rjb6`)
- `29fdff75f` — Add CathLab EMR direct pharmacy request

#### OPD sprint 27
- **PR #2913** OPD sprint-27 (knzth) — adds OPD appointment list to sidebar config/permissions
- **PR #2917** OPD sprint-27 (knzth) — _UAT-only path_

#### Lab / Imaging print UI
- **PR #2904** Lab print UI (`86ey4c3qp`)
- **PR #2901** Imaging print UI (`86ey4c4dj`)
- `03b0bef59` — Update Lab Print UI
- `efe634723` — Change UI Imaging Printouts

#### Lab result entry & infrastructure
- `84b746503`, `88e032a65` — Infinite scroll scaffolding in lab result entry

#### Patient registration
- `78230784b` — Check additional appointment logic in patient-type changes

### Changed

- **OPD refund:** tax field now driven by global default setting (`1b4c07514`, ticket `86ey5vwr0`)
- **OPD pharmacy:** conditional discount label based on related context (`bb1fa2214`, ticket `86ey6hvmt`)
- **IPD final bill:** deposit close/reopen queries inlined; cancellation order corrected (`597ed40c6`); close-deposit logic updated on final-bill creation/discharge (`0580eb6f9`); pre-deposits now visible in patient deposit history (`c3d098356`)
- **Daily bill:** ward services & procedure component editable until final bill is created (`760e4b116`)
- **OPD submodule head:** rebased to development (`e3765b963`)

### Fixed

#### CathLab
- Correct CathLab pharmacy invoice-number generation (`2732a33d7`)
- Wrong module classification (`70668f3a0`)

#### OPD / Pharmacy
- `f8d929b6f` & `3f1ce0b8c` — Team-fee UI: recalculate team-fee price as 0 (reopen fix)

#### IPD / Admission
- **PR #2886** fix-pre-deposit (`psk/27`)
- **PR #2889** order-by-ward (`psk/27`) — standard ordering
- **PR #2878** Discharge final bill (april, sprint 26)
- **PR #2896** `fix/building-and-room-optional-ipd` — building & room optional in IPD service request (`155f6a66b`) — _UAT-only path_
- `41602df42` — Standardise ward list order by `createdAt` in Request Room

#### Procedure / OT
- **PR #2887** fix-procedure search (`psk/27`)
- `9937099ad` — OT: clear procedure search after adding item

#### EMR
- **PR #2895** `fix/emr-emergency-services-delete` — EMR emergency service deletion (`c7718b20e`) — _UAT-only path_
- `c603e078b` — doc/docx preview in http — _UAT-only path_
- **PR #2894** `fix/doc-docx-preview-in-http` — UAT-side merge

#### Patient / Undercare
- **PR #2903** patient-registration-appt-check (april, sprint 27)
- **PR #2911** `fix/undercare-doctor-report-issues` (`3c85d7d1d`, `7bff39644` ticket `86ey77ahr`) — _UAT-only path_

#### Pharmacy
- **PR #2885** team-fee-visibility (`86ey2ykbd`)
- `339bec3c3` — Update pharmacy sale in CathLab

#### General
- `09c9dbdaa` — Fix build fail + guard `useSearchSelect` infinite hook
- `59b3657ed` — Fix TS error — _UAT-only path_
- `bcf8af400` — PR #2886 fix-pre-deposit (psk/27)
- `c3d098356` — IPD pre-deposits shown in patient deposit history

### Refactored

- `640672371` — Extract shared validation logic for patient-type changes (patients module)
- `597ed40c6` — Inline deposit close/reopen queries in IPD final bill; correct cancellation order
- `5d1a66828` — CathLab code refactor

### Security

_None this cycle._

### Submodule bumps (benign)

- `3408d6682`, `76a814826`, `8cf5dc87b` — submodule pointer advances (no app-code impact)

---

## [v1.1.34.uat] — 2026-07-07

_Bump commit `3fda005c9`. Prior UAT cut — not detailed here._

## [Earlier versions]

See `git log origin/uat` for the full v1.1.x history (v1.1.32.uat, v1.1.33.uat, … v1.1.7).

---

### Notes for the release captain

- **Conventional-Commit compliance:** 0/58 — generated manually from PR titles. Wire `commit_linter.py --strict` into PR pipeline before next cut.
- **UAT-only paths:** items marked _UAT-only path_ were merged via `knzth/uat` and do not appear on `development`. They include `155f6a66b`, `c7718b20e`, `c603e078b`, `3c85d7d1d`, `59b3657ed`, `7bff39644`, `0e2b113d9`. Worth confirming these are folded back into `development` to keep the branches aligned.
- **PR #2879** appears in earlier notes as a CEct-refund PR; not present in the v1.1.35.uat range (must have been included in v1.1.34.uat already).