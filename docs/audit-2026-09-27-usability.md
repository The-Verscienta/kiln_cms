# Full-surface usability & aesthetics audit — 2026-09-27

A console + public delivery pass against [`design-language.md`](design-language.md)
and [`design-system.md`](design-system.md), mirroring the 2026-09-27 security
audit pipeline (eight workstreams → dated report → triage → High/clear Medium
fixes → GitHub issues).

**Scope:** `/editor/*`, media, account, auth/setup, published delivery, forms
embed, membership. Out of scope: headless explorers, performance, security,
delivery visual redesign, re-litigating closed July 2026 usability items unless
regressed.

**Headline:** Foundations (ember tokens, console shell, Content/Media list
patterns, delivery `Layouts.public`) are strong. Friction clusters on **editor
chrome hierarchy**, **kit drift on secondary lists/settings/auth**, **form
submit recovery**, and a handful of **a11y** gaps (form labels, auth skip
target, public search focus, `text-primary` as link colour).

Prior design audits: closed July 2026 usability epic (see project plan) and
[`audit-2026-07-performance-usability.md`](audit-2026-07-performance-usability.md).

## Phase 0 — Baseline

| Check | Result |
|-------|--------|
| Design-language / design-system re-read | Console shell, kit (`.btn`/`.card`/`.field-*`/`empty_state`), delivery chrome rules confirmed |
| July 2026 closed items | Media tile buttons, Content/Media filter empties, etc. remain good; not re-opened |
| Surface inventory | LiveViews under `lib/kiln_cms_web/live/` + delivery templates under `content_html/` / `form_html` / error HTML mapped to WS1–WS8 |

## Findings

| # | Sev | Status | GitHub | Location | Finding |
|---|-----|--------|--------|----------|---------|
| 1 | High | **Fixed** — verify | [#1670](https://github.com/The-Verscienta/kiln_cms/issues/1670) | Eight `site_*` / `backup` / `code_injection` LiveViews | Assigned `:page_title` but never passed into `Layouts.console` → empty sticky top-bar title |
| 2 | High | **Fixed** — verify | [#1671](https://github.com/The-Verscienta/kiln_cms/issues/1671) | `content_editor_live` Visual + chrome Save/Publish | Visual was `btn-primary` competing with Save; copy off design-language. Visual → default; Save → “Save draft”; Publish → “Publish now” |
| 3 | High | **Fixed** — verify | [#1672](https://github.com/The-Verscienta/kiln_cms/issues/1672) | `calendar_live` month/week | Empty filtered month looked like a blank grid; now shows the list empty card |
| 4 | High | **Fixed** — verify | [#1672](https://github.com/The-Verscienta/kiln_cms/issues/1672) | `task_live` scope chips | Empty copy identical for All vs block/document scope |
| 5 | High | **Fixed** — verify | [#1676](https://github.com/The-Verscienta/kiln_cms/issues/1676) | `two_factor_controller` `/sign-in/verify` | Standalone dark HTML island (no `Layouts.auth`, no light theme). Now a `TwoFactorHTML` template in `Layouts.auth`: labelled one-time-code field, `lang` from the locale, both themes, recovery-code disclosure, no script |
| 6 | High | **Fixed** — verify | [#1675](https://github.com/The-Verscienta/kiln_cms/issues/1675) | `settings_live` TOTP | After recovery-code login, no UI to re-enrol authenticator (`recovery_login?` unused). Surfaced “Set up a new authenticator” |
| 7 | High | **Fixed** — verify | [#1674](https://github.com/The-Verscienta/kiln_cms/issues/1674) | `content_html/search.html.heex` | Search stripped focus outline with no ring → kit `.field-input` / `.btn` |
| 8 | High | **Fixed** — verify | [#1673](https://github.com/The-Verscienta/kiln_cms/issues/1673) | `form_controller` thank-you/error | Unstyled system-font page; embed errors had no recovery. Now `app.css` + success/error headings + embed “Try again” |
| 9 | High | **Fixed** — verify | [#1674](https://github.com/The-Verscienta/kiln_cms/issues/1674) | `account_live` / `membership_live` | Missing `current_user` on `Layouts.public` → no Account/Sign out in header |
| 10 | High | **Fixed** — verify | [#1673](https://github.com/The-Verscienta/kiln_cms/issues/1673) | `block_components` `public_form_field` | Labels not associated (`for`/`id`); required `*` SR-hidden only. Associated + kit field classes + submit `.btn` |
| 11 | High | Open / backlog | [#1677](https://github.com/The-Verscienta/kiln_cms/issues/1677) | Widespread `text-primary` on interactive text | Ember ~3:1 on white; kit provides `text-primary-ink`. Needs sweep (overview, chips, delivery links) |
| 12 | Medium | **Fixed** | — | `layouts` search kbd | Hardcoded ⌘K; now platform-aware via `data-kiln-search-kbd` |
| 13 | Medium | **Fixed** | — | `core_components` `<.header>` | Non-responsive flex crush; now stacks on narrow + `text-xl tracking-tight` |
| 14 | Medium | **Fixed** | — | `editor_live` filter miss | No Clear filters; added (true-empty keeps header New — in-panel CTA would duplicate) |
| 15 | Medium | **Fixed** | — | `setup_live` colour placeholder | Indigo `#1d4ed8` → ember `#FF6200` |
| 16 | Medium | **Fixed** | — | `account_live` empty membership | CTA outside `empty_state` `:action` |
| 17 | Medium | **Fixed** | — | `app.css` `.tab` / reduced-motion | Missing `:focus-visible`; expanded `prefers-reduced-motion` for kit transitions/pulses |
| 18 | Medium | Open | [#1678](https://github.com/The-Verscienta/kiln_cms/issues/1678) | Lists empties (trash, taxonomy, inbox, search…) | Still inline `<p>` vs `<.empty_state>` |
| 19 | Medium | **Fixed** | [#1679](https://github.com/The-Verscienta/kiln_cms/issues/1679) | Content editor density | Header action strip, inspector tabs vs `.tabs`, hover-only block chrome, device preview gap |
| 20 | Medium | Open | [#1680](https://github.com/The-Verscienta/kiln_cms/issues/1680) | Settings density | Your settings / Mail long scroll without TOC; Form Builder kit drift; “← All content” crumbs on Team/Webhooks/Mail |
| 21 | Medium | **Fixed** — verify | [#1681](https://github.com/The-Verscienta/kiln_cms/issues/1681) | AuthOverrides / passkey CTA / setup brand | Bespoke utilities; JS-injected passkey; setup unbranded. Kit `.btn`/`.field-*`/`.auth-*` classes; passkey server-rendered hidden + `PasskeySignIn` hook; `Layouts.auth_brand/1` on setup |
| 22 | Medium | Open | [#1682](https://github.com/The-Verscienta/kiln_cms/issues/1682) | Delivery chrome | Preview ≠ live `public-*` hooks; header `aria-label`; locale-aware error links; mobile header wrap |
| 23 | Medium | Open | [#1683](https://github.com/The-Verscienta/kiln_cms/issues/1683) | Form validation UX | Still replaces form with message page (recovery improved); per-field errors + re-render preferred |
| 24 | Low | Open | — | Brand row not linked; icon-rail hides mark; h1 scale drift; TipTap EN strings; etc. | See workstream notes |

**Tracking:** [#1669](https://github.com/The-Verscienta/kiln_cms/issues/1669) (`audit-2026-09-usability`).

## Triage (Phase 3)

| Finding | Decision |
|---------|----------|
| #1–#4, #6–#10, #12–#17 | **Fix now** (shipped below) |
| #5 `/sign-in/verify` restyle onto `Layouts.auth` | **Fixed** in [#1676](https://github.com/The-Verscienta/kiln_cms/issues/1676) — controller→template cutover; no script, CSP unchanged |
| #11 `text-primary` → `text-primary-ink` sweep | **Backlog** — broad; start overview + chips |
| #18–#23 Medium clusters | **Backlog** issue-track |
| Low | Issue-track selectively |

## Remediation shipped this pass

1. Pass `page_title={@page_title}` on eight console LiveViews  
2. Editor chrome: demote Visual; “Save draft” / “Publish now”  
3. Calendar month/week empty card; task scope-aware empty copy  
4. Public search focus kit; account/membership `current_user`  
5. Auth `<main id="main">`; public form label association + kit fields  
6. Form thank-you/error styled + embed Try again  
7. TOTP re-enrol after recovery login  
8. Platform search kbd; responsive `<.header>`; Content clear filters + empty CTA  
9. Setup ember colour placeholder; account empty `:action`  
10. `.tab:focus-visible` + broader reduced-motion  

## Reconfirmed goods (summary)

- Ember tokens + light/dark; console sidebar kit + Essentials/Everything; pre-paint theme/nav restore  
- Content & Media filter/empty/pagination model  
- Editor trust plumbing (conflict banner, UnsavedGuard, autosave language, sticky action bar)  
- Delivery `Layouts.public`, branding, theme presets, skip link on non-auth shells  
- One public form renderer shared with builder preview  

## Workstream index

| WS | Focus | Agent |
|----|-------|-------|
| 1 | Console shell & nav | completed |
| 2 | Content editing | completed |
| 3 | Lists / filters / empty | completed |
| 4 | Settings density | completed |
| 5 | Auth & onboarding | completed |
| 6 | Public delivery | completed |
| 7 | Forms embed & membership | completed |
| 8 | A11y & motion | completed |
