# Usability & design aesthetics audit — implementation plan

> **For agentic workers:** Execute workstreams in parallel, synthesize the report, triage, fix High/clear Medium, file issues. Checkbox tracking below.

**Goal:** Full-surface usability + aesthetics audit (console + delivery), same pipeline as the 2026-09-27 security audit.

**Architecture:** Eight parallel read-only workstreams scored against design-language/design-system; dated audit doc; remediation for High/clear Medium; GitHub issues.

**Tech stack:** Phoenix LiveView, HEEx, Tailwind v4 tokens in `assets/css/app.css`, CoreComponents.

## Global constraints

- Scope: console + public delivery only (not headless explorers)
- Do not redesign delivery; judge chrome/clarity/brand consistency
- Prefer kit components over one-off utilities for controls
- No DaisyUI dependency
- Label issues: `usability` and/or `accessibility` + `audit-2026-09-usability`

---

### Task 1: Phase 0 baseline

- [x] Re-read design-language.md, design-system.md, closed July usability audit
- [x] Inventory LiveViews / delivery controllers vs workstreams
- [x] Note known kit (`empty_state`, `button`, shell layouts)

### Task 2–9: Workstreams WS1–WS8

Each returns findings table (sev, file:line, finding) + reconfirmed goods.

- [x] WS1 Console shell & nav — layouts, sidebar, top bar, theme toggle, mobile
- [x] WS2 Content editing — content_editor_live, inspector, canvas hierarchy, save affordances
- [x] WS3 Lists/filters/empty — editor_live, media, trash, taxonomy, tasks, search palette
- [x] WS4 Settings density — settings, configure, branding, team, webhooks, site-*
- [x] WS5 Auth & onboarding — sign-in/register/reset, setup, 2FA UX
- [x] WS6 Public delivery — content_controller templates, layouts delivery, branding
- [x] WS7 Forms embed & membership — form embed, membership_live, thank-you pages
- [x] WS8 A11y & motion — focus rings, labels, live regions, reduced-motion, contrast

### Task 10: Report

- [x] Write `docs/audit-2026-09-27-usability.md`

### Task 11: Triage + fix

- [x] Fix High / small clear Medium polish
- [x] `mix precommit` gates (format/credo/sobelow/authz/…); full `mix test` — UX-touched suites green; 20 unrelated pre-existing failures (`point_combination` atom, env-var anchors, core-agnostic leak)

### Task 12: GitHub issues

- [x] File all findings; tracking issue; verification issues for fixes — [#1669](https://github.com/The-Verscienta/kiln_cms/issues/1669)
