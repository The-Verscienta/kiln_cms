# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="system-requirements"></a>

- **`docs/system-requirements.md` lists what a machine needs to run the
  release image, build it, and develop on Kiln.** One page for the question
  that was spread across the README, `getting-started.md`, `deploy.md`, the
  platform guides and the Dockerfile: CPU, RAM and disk for running (512 MB
  minimum, 1 GB recommended) and for building (2 GB marginal, 4 GB
  comfortable), Postgres 17 with the `vector` extension as the one required
  service, the native libraries the runner image carries (libvips, qpdf,
  `postgresql-client-17`) and the optional one it does not (ffmpeg), the
  optional services behind compose profiles, and the developer toolchain
  pinned by `.tool-versions`. Linked from the getting-started prerequisites
  and registered under Operations & deployment. Three deployment presets
  under `deploy/presets/` (`minimal`, `publishing`, `everything`) turn the
  runtime features on or off as a set, each a layer on `.env.prod`.

<a id="mix-kiln-import-ghost"></a>

- **`mix kiln.import.ghost` imports a Ghost JSON export: posts, pages, tags,
  images, SEO fields and bylines, members-only posts kept gated, and a
  redirect from every old URL.** `KilnCMS.Portability.Ghost` reads the export
  into the same source-neutral shape as the WordPress parser, so it shares
  that importer's dry run, re-run rules, media sideloading, author mapping and
  report. `--site-url` replaces Ghost's `__GHOST_URL__` placeholder, and the
  task refuses to start without it when the export contains one. Posts
  restricted to members, paid members or tiers import into the `member`
  audience, or as drafts if no gated audience is configured. Scheduled and
  email-only posts import as drafts, and the task lists each one. The shared
  HTML converter now keeps every image in a figure holding several, so a Ghost
  gallery card no longer imports as its first image only.
  ([#1876](https://github.com/The-Verscienta/kiln_cms/issues/1876))

<a id="importers-from-a-release"></a>

- **The importers run from a release: `bin/kiln_cms rpc
  'KilnCMS.Release.import_wordpress(path, dry_run: true)'`, and likewise
  `import_ghost/2` and `import_content/2`.** A Docker or Coolify deploy has no
  Mix, so a migration used to need a source checkout with the production
  environment loaded. The functions take the tasks' flags as keyword options,
  refuse an unknown one (so a misspelt `dry_run:` cannot import for real), and
  print the same report into the `rpc` terminal. They refuse under `eval`,
  which has no job queue, media fetching or caches. The mix tasks and the
  release now run the same code, `KilnCMS.Portability.Commands`, and
  `KilnCMS.Portability.CLI` no longer calls Mix; the tasks' output and errors
  are unchanged. See
  [content portability](../content-portability.md#from-a-release).

<a id="kiln-vs-pages-and-migration-guides"></a>

- **Public "Kiln vs" pages for WordPress, Ghost, Strapi, Payload and Directus,
  plus WordPress and Ghost migration guides, every competitor claim dated
  and sourced.** They live in `docs/compare/` and publish to kilncms.dev with
  the other guides. Each comparison table links a source in every row (a test
  enforces it), states the date its facts were checked, and names a review
  owner. The docs publisher now sends a guide's
  `<!-- seo-description: … -->` comment as the entry's `seo_description`.
  ([#1876](https://github.com/The-Verscienta/kiln_cms/issues/1876))

<a id="newsletter-signup-block"></a>

- **A *Newsletter sign-up* block puts an email sign-up on any page; it adds
  people to the newsletter list with double opt-in.** Until now the only way
  onto a page was a theme edit: the rich-text sanitizer strips a raw `<form>`,
  and the *Form* block's submissions go to the forms inbox, not the subscriber
  list. The block has an optional heading and intro, a button label (default
  "Subscribe") and a switch to also ask for a name. It posts to the existing
  `POST /newsletter/subscribe`, so sign-up behaves exactly as before: the
  shared honeypot, one "check your inbox" page for every outcome, and nothing
  sent until the reader confirms. The fired `:web` artifact is the real form,
  and the `:json` surface carries `action` and `honeypot_field` for a headless
  frontend. See [the newsletter guide](../newsletter.md#a-sign-up-on-a-page).
  ([#1870](https://github.com/The-Verscienta/kiln_cms/issues/1870))

## Changed

<a id="custom-fields-under-the-blocks"></a>

- **Custom fields sit in the editor's main column, under the blocks, instead
  of behind the inspector's Settings tab.** The inspector opens on Preview, so
  a type's own fields (a recipe's chef, an event's venue) were invisible until
  a writer thought to open Settings, where they were mixed in with URL, SEO and
  scheduling. They are now a *Custom fields* panel below the block canvas, the
  way WordPress puts meta boxes under the post body. The panel flags its own
  validation errors, so the Settings tab's alert dot no longer counts them.
  The panel stays visible in the Markdown view. Inputs, names and the save
  path are unchanged. See `KilnCMSWeb.ContentEditor.CustomFieldsPanel`.

<a id="newsletter-pages-in-site-chrome"></a>

- **The newsletter's sign-up and unsubscribe pages render in the site's own
  layout instead of as bare unstyled pages.** "Almost there", "Check that
  address", "Something went wrong" and both unsubscribe pages were
  hand-built HTML with inline styles, so a reader who signed up from a styled
  page landed somewhere that looked like a different site. They now use
  `Layouts.public` and the confirmation page's card, like the confirmation
  page already did. Routes, status codes, wording and the unsubscribe
  one-click are unchanged.
  ([#1870](https://github.com/The-Verscienta/kiln_cms/issues/1870))

## Security

<a id="ash-3-34-6-aggregate-policies"></a>

- **Ash 3.34.6: an MCP read tool's `count`/`exists`/`aggregate` result no
  longer skips related resources' read policies in its filter.**
  EEF-CVE-2026-101028 (MEDIUM): `Ash.count`, `Ash.exists` and
  `Ash.aggregate` applied only the root resource's read policy, so a filter
  crossing a relationship could test conditions against related rows the
  caller can't read. Kiln's MCP read tools keep AshAi's default parameters,
  which let an API-key holder choose those result types and send a filter.
  `Ash.read` and page counts were not affected.
