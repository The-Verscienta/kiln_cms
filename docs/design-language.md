# Kiln CMS — Design Language

*Applies to the admin & authoring UI (`/editor/*`, media, auth). The public
delivery frontend keeps its own minimal chrome.*

Kiln CMS is a focused, editor-first content management system for thoughtful
creators and teams. It prioritizes clarity, speed, and editorial flow over
feature bloat. **Voice**: calm, confident, precise — like a trusted editor.
The design goals: reduce cognitive load for writers/editors, make publishing
feel satisfying and safe, scale from solo to team use, and stay
keyboard-first accessible.

## Why this exists

Kiln already had good bones — a self-owned, DaisyUI-*flavored* token palette in
`assets/css/app.css` (`base-100/200/300`, `primary`, `accent`, semantic
`info/success/warning/error`, light + dark). What was missing was a **coherent
layer on top of those tokens**: a consistent component vocabulary and an app
shell. Without it, pages reached for one-off Tailwind (`rounded border
border-base-content/20 px-3 py-1.5 …`) and the product read like a stock
Phoenix-generated site rather than a content management *application*.

This document is the shared reference for that layer — brand principles,
tokens, the component kit, and the console shell. The goal: Kiln looks like
**Kiln** — familiar to anyone who's used DaisyUI/Directus/Strapi, but its own
thing, and with **no CSS-framework dependency**.

## Principles

1. **Clarity.** Every element has one purpose.
2. **Trust.** Reliable save states, clear permissions, helpful error messages.
3. **Efficiency.** Fast paths for common tasks; minimal clicks to publish.
4. **Editorial focus.** Content is king; chrome stays out of the way.
5. **Own it, DaisyUI-flavored.** Borrow DaisyUI's *naming* (`btn`, `card`,
   `field-*`, `kbd`) so it feels familiar, but define every rule ourselves,
   driven by our tokens. **There is no DaisyUI (or any component-lib)
   dependency — a class outside this hand-written kit renders nothing.**
6. **Tokens are the single source of truth.** Components never hard-code a
   color, radius, or font — they read `var(--color-*)`, `var(--radius-*)`,
   `var(--font-sans)`. Retuning the brand (one `--color-primary` edit) or adding
   a theme flows through everything automatically.
7. **Semantic over ad-hoc.** Prefer a named component (`<.button>`, `.card`,
   `.field-input`) over a bespoke stack of utilities. Utilities are for
   *layout* (flex, grid, spacing), not for re-inventing a control's look.
8. **The shell carries the identity.** A persistent sidebar + workspace top bar
   is the single biggest signal that this is an app. Every authoring screen
   lives inside it.
9. **Both themes, always.** Anything added must look right in light *and* dark;
   because rules use tokens, this is usually free — but check it.
10. **Accessible by construction.** WCAG 2.1 AA+ baseline: full keyboard
    navigation, focus-visible rings, `aria-current` for nav, real labels,
    4.5:1 contrast, semantic HTML preferred. The design language and a11y are
    the same effort.

## Tokens (already in `app.css`)

| Group | Tokens |
| --- | --- |
| Surfaces | `base-100` (page), `base-200` (raised/hover), `base-300` (borders), `base-content` (text) |
| Brand | `primary`, `secondary`, `accent`, `neutral` (+ `*-content`) |
| Status | `info`, `success`, `warning`, `error` (+ `*-content`) |
| Radius | `--radius-sm | md | lg | xl` |
| Type | `--font-sans` (system stack), tightened heading tracking |

Brand palette is the **ember** language (see [Design system](design-system.md)):
the `#FF6200` ember brand on neutral-gray surfaces in light, and a brighter ember
on neutral charcoal in dark. Note ember only reaches ~3:1 against white, so
`--color-primary-content` is a near-black ink — primary buttons/badges carry dark
text on the ember fill (≈6.3:1, WCAG AA), and ember-as-text usages (active nav
link, in-content links) are darkened for AA on light surfaces. Retune by editing
the `@theme` / `[data-theme="dark"]` blocks — do **not** introduce new raw colors
in components.

## Component kit (`@layer components` in `app.css`)

These are plain, token-driven CSS classes so a control looks identical whether
written as a function component or a raw `class="…"` in a template.

- **Buttons** — `.btn` base + `.btn-primary` / `.btn-default` / `.btn-ghost` /
  `.btn-danger`, size `.btn-sm`, `.btn-block`. Prefer the `<.button>` function
  component (`variant=`, `size=`), which emits exactly these classes.
- **Surfaces** — `.card` (the one raised container: base-100, hairline border,
  `--radius-lg`) + `.card-pad` for standard interior padding.
- **Fields** — `.field-input`, `.field-select` (full-width, token border, focus
  ring). The `<.input>` component is the richer, label+error-aware form control;
  these bare classes are for inline filters/toolbars.
- **Tabs** — `.tabs` (segmented-control container) + `.tab`; drive the active
  segment with `aria-selected="true"` (accessible, no extra class). Used for the
  media Library/Trash switch.
- **Tables** — `.table` on a raw `<table>` for consistent header/cell/row
  styling (+ `.table-zebra` for stripes). Cells keep their own alignment / width
  / colour utilities; `.table` owns padding, borders and the header treatment.
  Wrap wide tables in `overflow-x-auto`. Also styles the `<.table>` component.
- **Shell nav** — `.side-link` (+ `aria-current="page"` for the active item),
  `.side-section` (group label).
- **Misc** — `.kbd` (keyboard hint, used by the ⌘K search affordance).

### Do / Don't

```heex
<%!-- DO --%>
<.button variant="primary" size="sm" phx-click="new">New page</.button>
<button class="btn btn-sm btn-default" phx-click="publish">Publish</button>
<ul class="card divide-y divide-base-content/10">…</ul>

<%!-- DON'T — bespoke button, no shared vocabulary --%>
<button class="rounded border border-base-content/20 px-3 py-1.5 text-sm hover:bg-base-200">
  Publish
</button>
```

## Content & tone

- Use "Save draft" and "Publish now", not generic labels like "Submit".
- Errors read in plain language with a next step, not a raw exception.
- Status terminology stays consistent everywhere it appears (draft, in
  review, published, archived — never a synonym mid-flow).
- Copy overall: concise, calm, action-oriented, non-technical where possible.

## UX patterns

- **Entry status system** — Draft → Published → Archived, surfaced with
  `<.badge>`.
- **Save & Publish flow** — autosave plus explicit validation before publish.
- **Editor preview** — live preview with device-width modes.
- **Media, empty, and permission states** — each has a dedicated treatment
  (`<.empty_state>` for the first two; permission states degrade gracefully
  rather than dead-ending).

## Layout

Responsive breakpoints: 640 / 768 / 1024 / 1280px, with a 12-column grid and
the collapsible console sidebar as the base layout. See
[Design system → Responsive](design-system.md#responsive) for the concrete
per-component conventions (nav collapse, header stacking, two-column forms).

## The console shell — `Layouts.console/1`

The authoring app frame (`lib/kiln_cms_web/components/layouts.ex`):

- **Left sidebar** (persistent on `lg+`, slide-in drawer on mobile via a CSS-only
  peer checkbox — works before the LiveView socket connects): brand, two
  role-gated nav groups (**author**: Content, Media, Taxonomy, Calendar,
  Translations, Analytics — **configure**: Content types, Fields, Forms,
  Webhooks, Mail, Trash, Settings), plugin-contributed items, and an account
  footer (avatar, email, sign-out) plus GraphQL / JSON:API links.
- **Top bar** (sticky): page title, a search affordance with a `⌘K` `.kbd`,
  an `:actions` slot for page-level primary buttons, locale switcher, theme
  toggle.
- **Workspace**: `max-w-6xl` content column.

```heex
<Layouts.console flash={@flash} current_user={@current_user}
  page_title={gettext("Content")} active={:content}>
  <:actions>
    <.button variant="primary" size="sm" phx-click="new">New page</.button>
  </:actions>
  …page body…
</Layouts.console>
```

`Layouts.app/1` (the old top-nav shell) still exists during the transition.

## Rollout

1. **Done:** tokens confirmed, component kit added, `console` shell built,
   `<.button>` unified onto `.btn`, and the **Content dashboard** (`/editor`)
   rebuilt on the new shell as the reference implementation.
2. **Done:** all authoring LiveViews migrated from `Layouts.app` →
   `Layouts.console` with the right `active` and one-off controls swapped for the
   kit — analytics, calendar, content editor, fields, forms, mail, media, search
   palette, settings, taxonomy, translations, trash, content types, webhooks.
   Compiles clean under `--warnings-as-errors`; verified in light + dark.
3. **Done:** the **tab** pattern (`.tabs`/`.tab`) and **table** treatment
   (`.table`) graduated into the kit and adopted — media Library/Trash switch on
   tabs; the analytics, webhook-deliveries and translation-coverage tables on
   `.table`. Defining `.table` also revived the previously dead `<.table>` /
   `.table-zebra` references (leftover DaisyUI class names).
   Still deliberately bespoke: **icon-only / subtle destructive** buttons (kept
   as `btn-ghost` + `hover:text-error` rather than a solid `btn-danger`) and the
   translation locale **chips** (a matched link/button pair, not tabs).
4. `Layouts.app/1` is **still used** by the `/` marketing landing
   (`page_html/home.html.heex`) — a public-facing page, not an authoring tool —
   so it is intentionally retained. Retire it only if/when the home page moves to
   `Layouts.public` or its own treatment.

Keep this document in step with the kit: **new shared pattern → document it here
before using it widely.**
