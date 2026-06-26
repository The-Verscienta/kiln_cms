# KilnCMS design system

A small, self-owned Tailwind design system for the admin/editor UI — **no
DaisyUI**. Two pieces: semantic **color tokens** (in `assets/css/app.css`) and
shared **HEEx component patterns** (in `lib/kiln_cms_web/components/`).

**Visual identity — "kiln" (warm clay).** A fired-clay terracotta brand
(`primary`) on warm bisque surfaces, with an ember `accent`, tuned to evoke the
product name. Light and dark are both first-class. Type is a refined system
stack (no web-font dependency); radii are slightly softened
(`--radius-*`).

## Color tokens

Defined once via Tailwind v4 `@theme` and consumed as ordinary color utilities
(`bg-base-100`, `text-base-content`, `border-error/30`, `text-primary-content`,
…) with the usual opacity modifiers. Light is the default; `[data-theme="dark"]`
swaps the values. Retune the brand by editing `--color-primary` (and friends) —
every utility follows automatically.

| Role | Tokens | Use for |
|---|---|---|
| Surfaces | `base-100` / `base-200` / `base-300` | page background, cards, raised panels, hover fills |
| Text-on-surface | `base-content` | body text (with `/60`, `/40` for muted) |
| Brand | `primary` · `secondary` · `accent` · `neutral` (+ `*-content`) | primary actions, accents |
| Status | `info` · `success` · `warning` · `error` (+ `*-content`) | flashes, badges, conflict/validation states |

The page surface and default text color follow the active theme via a base-layer
rule (`body { background: base-100; color: base-content }` + `color-scheme`).
Theme selection happens before first paint in `root.html.heex` (it resolves
`system` → a concrete `light`/`dark` `data-theme`), and the toggle lives in
`Layouts.theme_toggle/1`.

## Component patterns

`KilnCMSWeb.CoreComponents` holds the shared building blocks — all token-based:

- `button/1` — `variant="primary"` (solid clay), `"danger"` (outlined error), or
  default (bordered), all with a focus ring.
- `input/1` — text/select/textarea/checkbox, token-styled with a clay focus ring,
  label + inline errors; checkboxes use a native `accent-primary` style.
- `badge/1` — status pill: `variant` of `neutral`/`primary`/`success`/`warning`/
  `error`/`info`.
- `empty_state/1` — centered icon + title + body + optional action slot.
- `flash/1` — toast notice, `info`/`error` tinted via status tokens.
- `header/1`, `table/1`, `list/1`, `icon/1` (heroicons).

Common ad-hoc patterns used across LiveViews (compose with utilities + tokens):

- **Card / panel:** `rounded border border-base-content/10 bg-base-100 p-4`
- **Muted text:** `text-sm text-base-content/60`
- **Status badge:** `rounded-full px-2 py-0.5 text-xs` + a status tint
  (e.g. `bg-success/15 text-success`)
- **Destructive action:** `text-error` / `border-error/40 hover:bg-error/10`

## Conventions

- Prefer the tokens over raw palette colors (`bg-base-200`, not `bg-gray-100`) so
  light/dark and rebrands stay automatic.
- Keep one-off component CSS out of templates; extend `CoreComponents` or use the
  patterns above.
- `dark:` variants are available (`@custom-variant dark`) for the rare case a
  token swap isn't enough.
- Status pills go through `<.badge>`; primary surfaces/empty views through
  `<.empty_state>` — don't re-roll them inline.

## Responsive

The admin/editor UI works on phones and tablets. Conventions (`sm` = 640px):

- **Nav** collapses to a hamburger disclosure (`<details>`) below `sm`; the theme
  toggle stays visible. Inline links return at `sm+`.
- **Page headers** (title + actions) stack with `flex flex-col gap-3 sm:flex-row
  sm:items-center sm:justify-between`; action groups use `flex-wrap`.
- **List rows** keep the title + badge on the first line and let the action
  buttons wrap to a second line on mobile (`w-full sm:w-auto justify-end`).
- **Two-column layouts** (editor form/preview, taxonomy) are `lg:grid-cols-2`
  and single-column below; paired fields are `sm:grid-cols-2`.
