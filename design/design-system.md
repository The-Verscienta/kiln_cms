# Kiln CMS Design System

## Brand Overview
Kiln CMS is a focused, editor-first content management system for thoughtful creators and teams. It prioritizes clarity, speed, and editorial flow over feature bloat.

**Voice**: Calm, confident, precise. Like a trusted editor.

**Design Goals**:
- Reduce cognitive load for writers/editors.
- Make publishing feel satisfying and safe.
- Scale beautifully from solo to team use.
- Strong accessibility and keyboard-first experience.

## Design Principles
1. **Clarity** — Every element has one purpose.
2. **Trust** — Reliable save states, clear permissions, helpful error messages.
3. **Efficiency** — Fast paths for common tasks; minimal clicks to publish.
4. **Accessibility** — WCAG 2.1 AA+ baseline.
5. **Editorial Focus** — Content is king; chrome stays out of the way.

## Foundations & Tokens

**Color Tokens**  
- Brand: #FF6200 (ember)  
- Neutrals: #FFFFFF (surface), #F8F9FA (muted), #212529 (text-strong)  
- Semantic: color.brand, color.surface, color.text-strong, color.success, etc.

**Typography**  
- Display: 2.5rem  
- Body: 1rem / 1.6 line-height  
- Small: 0.875rem  
Font stack: system UI + mono fallback.

**Spacing** (4px base)  
space.4 = 16px, space.6 = 24px, etc.

**Radii**: md = 8px

## Components
- **Button**: Primary (brand), Secondary, Ghost, Destructive. States: default, hover, active, disabled, loading.
- **Inputs/Textarea/Select**: default, focus, error, disabled.
- **Table, Badge** (Draft/Published/etc.), **Modal, Toast, Tabs, Sidebar Nav**.

## Patterns
- Entry status system (Draft → Published → Archived)
- Save & Publish flow (autosave + validation)
- Editor preview (live + device modes)
- Media handling, Empty states, Permission states.

## Content Rules
- Use "Save draft" and "Publish now".
- Errors in plain language with next steps.
- Consistent status terminology.

## Accessibility
- Full keyboard navigation.
- 4.5:1 contrast.
- Visible focus rings.
- Semantic HTML preferred.

## Layout
- Responsive breakpoints: 640px, 768px, 1024px, 1280px.
- 12-column grid with collapsible sidebar.

## Tone & Voice
Concise, calm, action-oriented, non-technical where possible.

## Implementation Notes
The tokens above are the design spec; the live implementation lives in
[`assets/css/app.css`](../assets/css/app.css) as OKLCH custom properties (`@theme`
for light, `[data-theme="dark"]` for dark), consumed by the token-driven component
kit documented in [`docs/design-language.md`](../docs/design-language.md).

- **Brand** — `--color-primary: oklch(69% 0.21 44)` resolves to exactly `#FF6200`.
- **Surfaces** — `base-100` `#FFFFFF`, `base-200` `#F8F9FA`, `base-300` `~#E9ECEF`,
  `base-content` `#212529`.
- **Contrast (AA)** — pure `#FF6200` only reaches ~3:1 on white, so
  `--color-primary-content` is a near-black ink: primary buttons/badges use **dark
  text on the ember fill** (≈6.3:1). Ember-as-text (active nav link, in-content
  links) is darkened for AA on light surfaces. Dark mode uses a brighter ember
  (`#ff874a`) with the same dark ink. All semantic pairs verified ≥4.5:1 in both themes.
- **Radii** — anchored at `md = 0.5rem` (8px); scale `sm 0.375 / md 0.5 / lg 0.75 / xl 1rem`.

Retune the whole system from one place: edit `--color-primary` (and friends) and
every button, card, field, table, badge and nav follows automatically.

---

Full layered structure: Foundations → Tokens → Components → Patterns → Templates.
