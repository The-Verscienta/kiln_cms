# Public theming

How a site changes what its **public pages** look like without an overlay
(#1318). Three layers, from safest to sharpest:

1. **Theme preset** — Branding → *Public site* → Theme.
2. **Menu slots** — Branding → *Public site* → Header/Footer menu.
3. **Custom CSS** — Code injection → *Custom CSS*.

The delivery chrome (`KilnCMSWeb.Layouts.public/1`) wraps every public page in
a `.public-shell` element stamped with `data-public-theme`, and the presets are
CSS compiled into `app.css` — selecting one never puts an admin-typed byte into
a stylesheet. That boundary is deliberate and documented on
`KilnCMS.CMS.Validations.BrandTokens`: an org admin is not the platform
operator, so anything CSS-shaped they type is untrusted. When a site needs more
than a preset, the arbitrary-CSS escape hatch lives on **code injection**
(`KilnCMS.CMS.SiteCodeInjection.custom_css`), which already carries the right
properties for untrusted authored code: org-admin-only writes, a paper-trail on
every change, and delivery-only rendering — an org admin's CSS can restyle
their site, never the editor console.

## Theme presets

`KilnCMS.Branding.themes/0` is the closed list; each preset only moves CSS
tokens (`--public-measure`, the heading/body font variables) consumed by the
public shell:

| Preset | Look |
|---|---|
| `standard` | The stock look: UI font, 48rem reading column. What an unconfigured site renders. |
| `editorial` | System serif for body and headings, slightly narrower column. |
| `studio` | Wide (64rem) column, heavy tight-tracked display headings. |
| `monograph` | Architectural-monograph look. Condensed uppercase display type in a wide (80rem) frame, hard edges, and running text in a right-hand reading column on wide screens. Top-level images and galleries bleed to the viewport edges. A page that opens on an image gets it as a full-height hero, with the title set over it. The post index becomes a numbered list. |

Presets compose with the solved brand colour and with dark mode — they don't
touch `--color-*` tokens at all, so a branded editorial site in dark mode needs
no extra work. `monograph` takes its accents (pull-quote rule, hover colour)
from the brand colour. Adding a preset is a code change on purpose: an atom in
`KilnCMS.Branding.themes/0`, a token block in `assets/css/app.css`, and a label
in `KilnCMSWeb.BrandingLive` and `KilnCMSWeb.SetupLive`.

### Structural presets

A token can't bleed an image or lay a title over it, so `monograph` also has
structural rules. They are scoped to `[data-public-theme="monograph"]` and
target hook classes that the public layout and the delivery templates carry
for this purpose. The hooks have no styles of their own:

| Hook | On |
|---|---|
| `public-header`, `public-site-name`, `public-main`, `public-footer-nav`, `public-attribution` | The public chrome (`Layouts.public/1`) |
| `public-article`, `public-masthead`, `public-title`, `public-meta`, `public-lede`, `public-body` | The document templates (`show*`) |
| `public-title` | Every other public page's `<h1>` (blog, events, search, lock, teaser) |
| `public-index` | The blog index list |

Custom CSS can target the same hooks. Rename one and you break every preset
and every site stylesheet that uses it.

Full-bleed images need an honest `sizes`, or the browser fetches a candidate
for the 768px column and upscales it. `KilnCMSWeb.ContentHTML.image_sizes/1`
passes `100vw` to top-level image blocks under `monograph`. Images inside a
`columns` block keep the column default.

The condensed faces are system fonts: `font-src` names no webfont host and
none is bundled. A machine without any of them falls back to a heavy
uppercase sans.

## Menu slots

Branding stores menu **keys**, not ids — a menu is one key with a row per
locale, and the layout resolves the request-locale variant the way every other
delivery surface does (`KilnCMS.CMS.Menus`).

* **Header** — top-level items only (a header has no room for a tree), and
  they *replace* the stock Blog/Search links. Items without a URL are dropped
  here. A key that resolves to no menu — deleted, renamed, or missing the
  request locale — falls back to the stock links rather than stripping the
  site of navigation.
* **Footer** — the full tree, rendered as sections: top-level items are the
  headings (linked when they have a URL), children the link list beneath;
  deeper nesting flattens into its section. Renders above the attribution
  line, and only when configured.

Trees are served from a per-org cache (`KilnCMS.CMS.Menus.public_tree/3`) so
the delivery hot path stays cheap; any menu or item write bumps the org's
menus generation (`KilnCMS.CMS.Changes.BustPublicMenus`), so edits are visible
on the next request. The cached tree is resolved for the **anonymous**
audience only — it is shared across visitors, so it must never carry a link
only a signed-in audience may see.

## Custom CSS

A plain-CSS field on the code-injection screen, served inside a
`<style data-custom-css>` element at the end of `<head>` on delivery pages
only. Two rules, both enforced:

* **No markup.** `</style` is refused at save
  (`Validations.CustomCssStaysCss`) and dropped when the row is
  resolved (`KilnCMS.CodeInjection`) — the field must not be able to close
  the element it is emitted into and continue as HTML, or its label lies.
  Everything else is passed through: this field's trust model is code
  injection's, not branding's.
* **Delivery only.** The assign the layout renders exists only in the
  `:delivery` pipeline — the same structural guarantee the head/footer HTML
  has, so custom CSS never restyles the console.

`style-src` already allows inline styles, so no CSP work accompanies the
field. The 64 KB bound and the paper trail come with the resource.
