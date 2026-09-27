# Usability & design aesthetics audit — design

**Date:** 2026-09-27  
**Approved approach:** Security-mirror (A) + light visual spot-checks when feasible  
**Scope:** Console (`/editor/*`, media, account, auth) **+** public delivery (published pages, forms/embed, membership chrome)

## Goal

Produce a dated full-surface usability and design-aesthetics audit of KilnCMS against [`docs/design-language.md`](../../design-language.md) and [`docs/design-system.md`](../../design-system.md), then triage, fix High / clear Medium polish, and file GitHub issues (`usability`, `accessibility`).

## Explicitly out of scope

- Public site visual redesign / new brand for delivery
- Performance (covered by prior audits)
- Security
- Headless API / GraphiQL chrome
- Re-litigating closed July 2026 usability items unless regressioned

## Rubric (severity)

| Sev | Meaning |
|-----|---------|
| **High** | User hard-blocked, destructive ambiguity, broken primary editorial flow, WCAG failure that blocks a task |
| **Medium** | Regular friction, inconsistent kit usage, missing empty/error states, density/hierarchy problems, light/dark breakage |
| **Low** | Polish, minor inconsistency, copy nits |
| **Info** | Matches design language; intentional residual |

## Aesthetic bar

- Ember brand + tokens only (no ad-hoc purple/indigo/cream AI defaults)
- Prefer `.btn` / `.card` / `.field-*` / `<.button>` / `<.input>` / `<.empty_state>` over one-off utility stacks for controls
- Console lives in persistent shell (sidebar + top bar)
- Both light and dark must work
- Delivery: calm chrome, content first, brand consistent with site branding settings — not console skin

## Workstreams

1. Console shell & nav  
2. Content editing flow  
3. Lists, filters, empty states  
4. Settings & form density  
5. Auth & onboarding  
6. Public delivery chrome  
7. Forms embed & membership  
8. A11y & motion  

## Deliverables

1. `docs/audit-2026-09-27-usability.md`  
2. Optional design-language deltas if residuals change  
3. High/clear Medium fixes in-tree  
4. GitHub issues + tracking issue (`audit-2026-09-usability` label)  

## Success

- Every workstream produces findings or explicit “clean” notes with file:line evidence  
- Report filed; issues linked; Highs fixed or accepted with reason  
