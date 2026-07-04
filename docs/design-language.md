# Kiln CMS — Design Language

*Status: proposal / first slice. Applies to the admin & authoring UI (`/editor/*`,
media, auth). The public delivery frontend keeps its own minimal chrome.*

## Why this exists

Kiln already had good bones — a self-owned, DaisyUI-*flavored* token palette in
`assets/css/app.css` (`base-100/200/300`, `primary`, `accent`, semantic
`info/success/warning/error`, light + dark). What was missing was a **coherent
layer on top of those tokens**: a consistent component vocabulary and an app
shell. Without it, pages reached for one-off Tailwind (`rounded border
border-base-content/20 px-3 py-1.5 …`) and the product read like a stock
Phoenix-generated site rather than a content management *application*.

This document is the shared reference for that layer. The goal: Kiln looks like
**Kiln** — familiar to anyone who's used DaisyUI/Directus/Strapi, but its own
thing, and with **no CSS-framework dependency**.

## Principles

1. **Own it, DaisyUI-flavored.** Borrow DaisyUI's *naming* (`btn`, `card`,
   `field-*`, `kbd`) so it feels familiar, but define every rule ourselves,
   driven by our tokens. No DaisyUI (or any component-lib) dependency.
2. **Tokens are the single source of truth.** Components never hard-code a
   color, radius, or font — they read `var(--color-*)`, `var(--radius-*)`,
   `var(--font-sans)`. Retuning the brand (one `--color-primary` edit) or adding
   a theme flows through everything automatically.
3. **Semantic over ad-hoc.** Prefer a named component (`<.button>`, `.card`,
   `.field-input`) over a bespoke stack of utilities. Utilities are for
   *layout* (flex, grid, spacing), not for re-inventing a control's look.
4. **The shell carries the identity.** A persistent sidebar + workspace top bar
   is the single biggest signal that this is an app. Every authoring screen
   lives inside it.
5. **Both themes, always.** Anything added must look right in light *and* dark;
   because rules use tokens, this is usually free — but check it.
6. **Accessible by construction.** Focus-visible rings, `aria-current` for nav,
   real labels, keyboard-reachable controls. The design language and a11y are
   the same effort.

## Tokens (already in `app.css`)

| Group | Tokens |
| --- | --- |
| Surfaces | `base-100` (page), `base-200` (raised/hover), `base-300` (borders), `base-content` (text) |
| Brand | `primary`, `secondary`, `accent`, `neutral` (+ `*-content`) |
| Status | `info`, `success`, `warning`, `error` (+ `*-content`) |
| Radius | `--radius-sm | md | lg | xl` |
| Type | `--font-sans` (system stack), tightened heading tracking |

Brand palette is a warm "fired-clay on bisque" in light, deeper charcoal +
brighter clay in dark. Retune by editing the `@theme` / `[data-theme="dark"]`
blocks — do **not** introduce new raw colors in components.

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
3. **Remaining:** a few intentional patterns were left on bespoke markup by
   design and could graduate into the kit if we want them shared — a **tab**
   component (media Library/Trash toggle, translations locale chips), a **table**
   treatment (analytics, webhooks deliveries), and **icon-only / subtle
   destructive** buttons (kept as `btn-ghost` + `hover:text-error` rather than a
   solid `btn-danger`). Extend the kit here first, then adopt.
4. `Layouts.app/1` is **still used** by the `/` marketing landing
   (`page_html/home.html.heex`) — a public-facing page, not an authoring tool —
   so it is intentionally retained. Retire it only if/when the home page moves to
   `Layouts.public` or its own treatment.

Keep this document in step with the kit: **new shared pattern → document it here
before using it widely.**
