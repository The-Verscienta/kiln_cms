# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

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
