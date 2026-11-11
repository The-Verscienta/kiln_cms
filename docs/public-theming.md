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
| `public-article`, `public-masthead`, `public-title`, `public-meta`, `public-lede`, `public-body` | The document templates (`show*`), the editor's live preview and the shared preview link |
| `public-article`, `public-title` | The in-context editor, which leaves `public-body` off its drag-to-reorder list: a preset that sets it to `display: contents` would take away the box the drag needs |
| `public-title` | The `<h1>` of the blog and event indexes, search, and the locked-page and members-only screens. Not the form's own page (`/forms/<slug>`) or the newsletter pages, whose headings carry no hook |
| `public-byline`, `public-byline-name` | A document's public byline inside `public-meta` (`show*`, #2044): each "By …" / "With …" run, and each person's name or profile link |
| `public-index` | The blog index list |
| `public-search-submit` | The search form's submit button |

The editor's live preview wraps each block in its own element to anchor the
comment pins, so a rule written against `.public-body > .kiln-block` (monograph's
bleeding image and hero) does not reach the blocks there. The shared preview
link has no wrapper and matches the live page.

Custom CSS can target the same hooks. Rename one and you break every preset
and every site stylesheet that uses it.

One page opts out of the preset's reading measure: the stock front page passes
`wide` to `Layouts.public/1`, which stamps `data-public-wide="true"` on
`.public-shell` and pins `--public-measure` to the 72rem that page was drawn at.
It is a fixed marketing design carrying none of the hooks above, so a preset's
measure would only crush it. Every other page takes the preset's own value.

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

## Which language the page text is in

A content page can be served in a language other than the reader's: a reader
on `/fr/…` follows a link to a page that has no French translation and gets
the English one. The page then holds two languages, and Kiln keeps them apart:

* **The chrome is the reader's**: the language in the URL, the path prefix,
  or the site's default language when there is none. It is never the
  visitor's session, because a public page is cached under its URL and handed
  to every later visitor. `<html lang>` and the `Content-Language` header
  declare it. It covers the header and footer menus, the stock **Blog** and
  **Search** links (which keep the `/fr/` prefix), the language switcher,
  the feed advertised in `<head>`, and every word Kiln writes outside the
  article. On the locked-page and members-only screens it covers Kiln's own
  text there (**Protected**, the passphrase form).
* **The article is the document's**: `<article class="public-article">` always
  carries its own `lang`, which differs from `<html lang>` on a fallback page.
  The `x-kiln-locale` header names it. Kiln's text inside the article follows
  it: the byline and its date, a form block's labels and messages, a
  newsletter sign-up's fields, the human-verification widget and an untitled
  embed's title. On a locked page or a members-only teaser, the document's
  title and summary carry its `lang`.
* **The page's description for machines is the document's too**:
  `og:locale`, the canonical URL, the `hreflang` alternates and the JSON-LD
  all name the record that was served, so `/fr/x` answered in English
  canonicalizes to the English URL.

So `/fr/about`, answered by the English page, starts like this:

```html
<html lang="fr">
  …
  <article class="public-article prose max-w-none" lang="en">
```

and is sent with `Content-Language: fr` and `x-kiln-locale: en`.

A theme that styles article text by language (quotation marks, hyphenation,
a typeface for one script) should select the article, not the document:
`.public-article:lang(fr)`, not `html[lang="fr"]`. `:lang()` matches the
nearest `lang` attribute up the tree, so it also matches the chrome by its
own language.

A plugin block that ships its own Gettext backend renders in the request's
language, so on a fallback page its words can differ from the `<article lang>`
around it.

On a multilingual site, form and newsletter sign-up blocks on a content page
post under the article's language prefix (`/en/forms/<slug>`,
`/fr/newsletter/subscribe`). A form's own page and its embed post under the
URL's language, the default's included: `/forms/<slug>` and
`/forms/<slug>/embed` post to `/en/forms/<slug>` when English is the default.
A locked page's passphrase form posts to `/fr/_unlock` under `/fr/`, so the
page after unlocking stays French. A stylesheet or script that selects these
forms by `action` no longer matches; select `.kiln-form` and
`.kiln-newsletter-signup` instead.

The header's brand link keeps the reader's language too: `/` on a page in the
default language, `/fr/home` under `/fr/`. A single segment such as `/fr` is a
page slug, not a language, so the language's home lives at `/<locale>/home`.
That address serves the site's published Home page (slug `home`) in that
language, or the stock front page in it when the site has none
([#2636](https://github.com/The-Verscienta/kiln_cms/issues/2636)).

A regional locale with no catalog of its own uses its language's: a site
that configures `fr-CA` while Kiln ships only `fr` shows French chrome under
`<html lang="fr-CA">`. A message missing from `fr_CA` is looked up in `fr`,
then shown as its English source text, so a regional catalog needs to
translate only the words that differ
([#2637](https://github.com/The-Verscienta/kiln_cms/issues/2637)). Kiln ships
`en`, `fr` and `es`; a locale whose language has none of them (`de`, say)
still shows English chrome until a `priv/gettext/de` catalog is added.

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

### Keep the focus rings on code blocks and tables

Every code block and every table on a public page is a keyboard stop, so a
reader without a mouse can Tab to it and scroll it with the arrow keys:

- a code block is `<pre tabindex="0" role="group" aria-label="Code sample">`
  ([#2164](https://github.com/The-Verscienta/kiln_cms/issues/2164));
- a table sits in
  `<div class="kiln-table-wrap" tabindex="0" role="group" aria-label="Scrollable table">`
  ([#2464](https://github.com/The-Verscienta/kiln_cms/issues/2464)).

A `:web` artifact fired before the upgrade that added these attributes keeps
its old HTML until the document is edited or re-fired; `mix kiln.refire_all`
after deploying brings them all up to date.

The outline each one draws on `:focus-visible` is the only sign of where
focus went. Custom CSS and presets may change its color, but must not remove
it:

```css
/* Don't: a keyboard reader can no longer see which block has focus. */
.public-body pre:focus,
.public-body .kiln-table-wrap:focus { outline: none; }

/* Fine: a different color, still a visible outline. */
pre[tabindex="0"]:focus-visible,
.kiln-table-wrap[tabindex="0"]:focus-visible { outline-color: #0b5394; }
```

Both stock rules are `outline: 2px solid var(--color-primary-ink)`; they
differ in where the outline sits:

- **Code block:** `outline-offset: -2px`, drawn inside the block, so a parent
  with `overflow: hidden` or `overflow-x: clip` (monograph sets the latter)
  cannot trim it. A replacement color needs 3:1 against the block's background
  (`--color-base-200`).
- **Table:** `outline-offset: 2px`, drawn outside the wrapper, because inside
  it would land on the cells' `--color-base-300` borders and the header's
  `--color-base-200` fill. A replacement color needs 3:1 against the page
  background (`--color-base-100`).

Check a replacement in both light and dark mode (WCAG 1.4.11). A broader
reset such as `*:focus { outline: none }` takes these rings away too, along
with every other focus indicator on the page.
