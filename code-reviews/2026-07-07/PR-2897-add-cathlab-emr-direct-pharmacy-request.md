# Code Review: PR #2897 — Add cathlab emr direct pharmacy request
**Repository:** MyanCare/Ycare-HMS
**Author:** @Pyae41
**Branch:** `feat/ppz/sprint-27/cathlab-emr-pharmacy-request` → `development`
**Files changed:** 3 (+49 / -12)
**Reviewer:** code-reviewer skill (automated)
**Date:** 2026-07-07
**ClickUp:** https://app.clickup.com/t/9018849685/86ey5746x

## Summary
Adds the ability to create a **direct (non-prescription) pharmacy request** from the CathLab IPD EMR Pharmacy Request tab. Mirrors the existing OT implementation: a "Request Pharmacy" button now appears on the tab, and clicking it sets `?page=edit&requestType=direct` so the existing `IpdEmrPharmacyRequestForm` opens in direct mode. The cathlab-specific action server-side forces `moduleType="CATH_LAB"` regardless of payload to prevent client tampering.

## Verdict
**Request changes**
Score: 84/100
Critical: 0 | High: 1 | Medium: 1 | Low: 2 | Nit: 0

## Issues

### Critical
None

### High
- **`moduleType="OT"` passed to the pharmacy requests table on the cathlab page** — `cathlab-ipd-emr-pharmacy-request-tab-component.tsx` passes `moduleType="OT"` to `IpdEmrPharmacyRequestsTable`. The OT template correctly uses `"OT"`; this cathlab copy should be `"CATH_LAB"`. Knock-on effects:
  - `usePharmacyRequestsColumns` calls `dynamicPharmacyRequestSubject("OT")` → permission subject becomes `"Operation Theatre::Pharmacy Request"` instead of `"CathLab::Pharmacy Request"`. CathLab users with `CathLab::Pharmacy Request` permission will fail the `Change Status` permission check on the cathlab page; OT users will be granted access they should not have.
  - `getIpdEmrBaseRoute("OT")` returns `/ot/emr-creation-ot/...`, so any column links from the cathlab table will route to OT routes.
  - The form (edit branch) correctly receives `moduleType="CATH_LAB"`, so the asymmetry is not a typo by intent — it is a copy-paste leftover from the OT template. Fix: change the prop on the table to `moduleType="CATH_LAB"`.

### Medium
- **`requestType` URL default forces "direct" even when a prescription exists** — The new code computes `requestType` from `searchParams.get("requestType")` and defaults to `"direct"` whenever the URL param is absent or anything other than `"prescription"`. The downstream `resolveEmrPharmacyRequestType` already falls back to `"prescription"` if `hasPrescription` is true, but that fallback only triggers when `requestType` is `undefined` — the cathlab component now always passes a defined value, so the fallback is a no-op. The cathlab parent still passes the `prescription` prop, so any future flow that deep-links to the edit page with a prescription but no `requestType` query param will silently open in direct mode. Today this works because the cathlab flow is intentionally direct-only, but flagging as a latent footgun. Recommend passing `requestType="prescription"` (or removing the URL default and letting `resolveEmrPharmacyRequestType` decide) once a prescription-driven edit link is added.

### Low / Nit
- **PR title is lower-case and lacks a Conventional Commits prefix.** Suggested: `feat(cathlab-emr): add direct pharmacy request`. Cosmetic, but the rest of the sprint PRs use Title Case + a clearer subject.
- **`Plus` icon import + `leftSection` is inconsistent with the OT template** (OT's button has no `leftSection`, no `lucide-react` import). Not a bug; if the design team wants consistency either both should show an icon or neither. Pick one.

## Recommendation
1. **Required:** Change `moduleType="OT"` to `moduleType="CATH_LAB"` on the `IpdEmrPharmacyRequestsTable` call inside `cathlab-ipd-emr-pharmacy-request-tab-component.tsx`. Without this, the cathlab tab shows OT permission subjects and OT base-route links — both user-visible and likely to fail permission audits.
2. **Suggested:** Tighten the `requestType` default or stamp `?requestType=prescription` explicitly when deep-linking with a prescription. Today it happens to work because the form's internal fallback decides, but the URL-driven default makes that fallback a no-op.
3. Optional: align the button styling with OT (drop `leftSection` + `Plus` for parity) or update OT to match — design call.