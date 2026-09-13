# The overlay contract

What a `projects/<name>/` subproject may rely on, what it may not, and what
happens when something it relies on has to change.

Two other documents already own neighbouring ground, and this one does not
repeat them: [Downstream projects](https://github.com/The-Verscienta/kiln_cms/blob/main/projects/README.md) describes the
*mechanics* — how an overlay attaches, how it is activated and built — and
[`CHANGELOG.md`](../CHANGELOG.md) defines what major, minor and patch *mean*
here. The question neither answers is the one a team has to answer before
pinning a CMS core to their product: **which surfaces does the major-bump
promise actually cover?** That is this document.

The promise in one sentence: a **minor** release must leave your `projects/`
tree compiling, booting, and reading its own data unchanged. If it cannot, the
release is a **major**, and `mix kiln.update` will refuse to move your pin
without `--allow-major`.

## Covered surfaces

A rename, a removal, or a change of meaning in anything below is a breaking
change and forces a major bump. Additions to these surfaces are not breaking.

| Surface | What is promised |
|---|---|
| `KilnCMS.CMS.Content` options | `:type`, `:plural`, `:table`, `:domain`, `:excerpt?`, `:schema_org_type`, `:slug_pattern`, `:alias_pattern`, `:seo_title_pattern`, `:seo_description_pattern` keep their names, defaults and meaning. This is the covered subset, not the full option list: `:dynamic?` is core-internal and `:published?` is accepted but ignored — neither is promised |
| The **two** token vocabularies the `*_pattern` options accept | `KilnCMS.Slug.Pattern` validates `:slug_pattern` and `:alias_pattern`; `KilnCMS.Seo.Pattern` validates the two SEO patterns, and they accept *different* tokens. Both run at build time, so a withdrawn token breaks *your* compile |
| The `__kiln_*__/0` functions the macro injects | The seam between a resource and every core registry. The double underscores read private; they are contract |
| Workflow action names on a content resource | `:read`, `:published`, `:public_by_slug`, `:trashed`, `:create`, `:update`, `:autosave`, `:submit_for_review`, `:return_to_draft`, `:publish`, `:unpublish`, `:archive`, `:unarchive`, `:restore`, `:destroy`. Note `:restore` undoes trashing and `:unarchive` undoes `:archive` — they are not the same inverse |
| The merge-argument convention | `tag_ids` / `add_tag_ids` / `remove_tag_ids`, and `related_<type>_ids` with the same three forms; `remove_*` stays idempotent |
| `Kiln.Plugin` callbacks | All fifteen, their arities and their return shapes, plus the `nav_item` and `admin_route` types |
| `Kiln.Block` and its DSL | The `block`, `field` and `migrate` entities, their options, the declared field-type vocabulary, and the Kiln-to-Ash type mapping |
| The `_type` and `_version` attributes | Injected on every block, and the discriminator a stored block map is resolved by |
| `Kiln.Block.Renderer` | The `:web`, `:json` and `:json_ld` surfaces, and that an implementation returning `nil` for an unhandled surface is correct |
| `Kiln.Block.Info` | Introspection over a block's definition, version, fields and migrations |
| `Kiln.FieldType` | `cast/2` stays required; the optional callbacks stay optional; `parse_float/1` keeps `Float.parse/1`'s return shape and stays total (it is how a `cast/2` parses a number without inheriting `Float.parse/1`'s toolchain-dependent raise) |
| `Kiln.Advisory`, `Kiln.Forms.SpamCheck` | Their `check/1` callbacks, outcome shapes, and registries |
| `Kiln.Plugins`, `Kiln.Version`, `Kiln.Updates`, `Kiln.Tokens` | Their documented functions and return shapes |
| `KilnCMS.Blocks`, `KilnCMS.Blocks.Upcaster`, `KilnCMS.CMS.ContentTypes` | The registry and dispatch functions an overlay calls |
| `KilnCMS.Migrations` | The search-vector helpers every content type's hand-written migration calls |
| `KilnCMS.SchemaExport`, `KilnCMS.Branding` | The exported schema shape, and the theme list a preset is selected from |
| `KilnCMSWeb.PluginRouter` | The three route macros |
| `KilnCMSWeb.AshJsonApiRouter` | That a domain registered in `:content_domains` is exposed on the JSON:API surface with no core edit |
| Config keys | `:ash_domains`, `:content_domains`, `:plugins`, `:audiences`, `:mcp_tools`, and `config/project.exs` as the import point |
| Build conventions | The `PROJECT` Docker build arg, and that an overlay's `priv/repo/migrations` and `priv/resource_snapshots` merge into the core's `priv/` |
| `public-*` CSS hook classes | Named in [public theming](public-theming.md); site stylesheets and presets both hang off them |

Delivery URLs, GraphQL field names and JSON:API routes are derived from `:type`
and `:plural`, so they inherit the promise above — but the HTTP contract has
its own, stricter policy, including a versioned-prefix migration path. See
*Versioning & stability* in the [API guide](api.md); where
the two documents disagree about an HTTP surface, that one wins.

## Not covered

These may change in any release, including a patch. If your overlay reaches
for one, it is reaching past the contract, and an upgrade may break it without
that counting as a major.

- **Everything under `KilnCMSWeb.*`** except `KilnCMSWeb.PluginRouter` and
  `KilnCMSWeb.AshJsonApiRouter` — LiveViews, components, the component kit's
  class names, and the `/editor/...` admin paths themselves.
- **`KilnCMS.*` internals not named above** — changes, calculations, workers,
  firing internals, and anything marked `@doc false`.
- **The console's own `side-*` classes and admin design tokens.** Those are the
  admin skin, and they are re-cut whenever the console is redesigned. Only the
  `public-*` classes on delivery pages are contract.
- **Core Oban queue names**, and the internal write actions a content resource
  carries for its own bookkeeping — the ones outside the workflow set named
  above, which exist to record an embedding, a search reindex, or a published
  version id. One caveat on the queues: the *name space* is shared even though
  individual names are not promised, so a core minor that adds a queue your
  plugin already declares turns `mix kiln.plugins.doctor` red.
- **Search ranking behaviour and its tuning defaults.** New legs and re-tuned
  weights ship in minors; a query's result *order* is not a stable interface,
  even though the functions that run it are.
- **The generated GraphQL schema module itself**, as distinct from the schema it
  produces.
- **Seeds, fixtures, and `projects/example/`.** The example overlay is a
  worked reference that tracks the core; it is not an API. Nor is core test
  support: `test/support/` compiles only in the core's own `:test` env, and
  nothing in it — `KilnCMS.FixturePlugin` included — is a name your overlay
  may hold.

  One in-tree exception, which is **not** a pattern to copy.
  `projects/example/project.exs` restates `KilnCMS.FixturePlugin` in its
  `:test` plugin list. That is not the example depending on a fixture; it is
  the replace semantics of `:plugins`. `config/test.exs` registers the fixture
  plugin, `config/project.exs` is imported last, and an Elixir config list is
  *replaced* rather than merged — so activating the example inside this
  repository without restating it would deregister the plugin the core's own
  suite is written against. The example lives in the core's repo and is
  compiled by the core's `:test` env; your overlay is not, and has its own
  test suite. What does transfer is the mechanic: `:plugins` replaces, exactly
  as `:ash_domains` and `:content_domains` do, so every core entry you want
  kept has to be restated — and re-synced when you bump the pin.

## What a minor may still do to you

Three things a minor is allowed to do that can still cost you work. None of
them breaks compilation, which is why none of them is a major.

**It may add migrations, including to the tables your content types project.**
The `KilnCMS.CMS.Content` macro contributes attributes to *your* resources, so
a core migration that adds a column adds it to every overlay table too — and
your tree carries its own migrations and snapshots, which the core's codegen
cannot see. This has taken production down twice: a `seo_keywords` column
(#452, fixed by #459) and a `path_alias` column (#488, fixed by #504), each
time as `undefined_column` on the first request to a content API. The core's
own `overlay_drift` CI job exists to catch exactly this against the in-tree
example. **Run its equivalent in your repo** — see below.

**It may add a callback to a behaviour.** With `use Kiln.Plugin` you inherit a
default for every callback, so an addition is invisible to you. A module that
hand-rolls `@behaviour Kiln.Plugin` instead gets a missing-callback warning,
which is an error under `--warnings-as-errors`. Use the `use` form; it is the
documented path, and it is what keeps additions non-breaking.

**It may change what a new install defaults to.** Defaults are not data
migrations: an existing deployment keeps its stored settings. Where a default
changes in a way an operator should know about, the release carries an
`### Upgrading` note, and `mix kiln.update` prints it before moving your pin.

## When a covered surface must change

Additive first, always: a new option, a new optional callback, a new function
beside the old one. Where that is impossible:

1. **Keep the old surface working for at least one minor**, with the
   replacement documented beside it and a `### Changed` entry naming both.
2. **Mark it deprecated** where the compiler can carry the marker, so the
   warning reaches you at build time rather than in a changelog you skimmed.
3. **Remove it only in a major**, with an `### Upgrading` section that names
   the mechanical edit — what to rename, to what, and in which files.

A name is never silently repurposed. Reusing an existing option or callback
name for different behaviour is the one change that defeats every check here,
because it compiles.

## Protecting your overlay in CI

Four checks, but they do not all run in the same place — two need more than a
source tree, which is the detail that makes people skip them.

**On every build**, with your `config/project.exs` in place and your overlay's
`priv/` merged, exactly as the image build does it:

```bash
mix ash.codegen --check     # the core's overlay_drift job, run against you
mix kiln.plugins.doctor     # domains registered, no name collisions
```

Without the activation step the first one checks the core alone: it passes
while your tables drift, which is the failure it exists to catch.

**Against a migrated database** — post-deploy, or in a job with Postgres, as
it inspects the live schema rather than your source:

```bash
mix kiln.search.check       # every content type has its search-vector migration
```

**From inside your pinned Kiln checkout**, not your overlay repo — the task
refuses to run anywhere else, and it fetches from the network unless you pass
`--no-fetch`:

```bash
mix kiln.update --check --exit-code
```

Pin to tags rather than a branch. `mix kiln.update --ref main` deliberately
skips both the version comparison and the upgrade notes, so tracking `main`
means opting out of every guarantee on this page.

## Known soft spots

Stated rather than discovered later.

- **The block upcast path has never run in anger.** No block has shipped a
  version above 1, so the automatic upcast the major/minor rule leans on is
  designed and tested but not exercised by a real migration. Worse, a declared
  step that is missing bumps `_version` silently instead of failing. If your
  overlay is the first to version a block, treat that path as new code.
- **Eager backfill is not wired up.** Upcasting happens lazily on read; there
  is no job that rewrites stored blocks, so already-fired artifacts need
  re-firing after a block's shape changes.
- **`to_markdown/1` on a block module is probed informally**, not declared on
  the renderer behaviour. Treat it as unstable until it is.
- **The hand-rolled `@behaviour` path is fragile against additions, on every
  behaviour here.** `Kiln.Plugin` declares no optional callbacks at all, and
  `Kiln.FieldType` marks only its three late additions optional — the rest are
  required-but-defaulted, exactly like `Kiln.Plugin`'s. So a module that
  declares `@behaviour` instead of using the `use` form gets missing-callback
  warnings when a callback is added, which `--warnings-as-errors` turns into a
  failed build. The `use` form is what makes additions safe; prefer it.

## Status of this document

Kiln is pre-1.0. Until 1.0 the *covered* list above may itself gain and lose
entries, and each change ships with a changelog entry saying so. At 1.0 this
page becomes the definition of what a major bump means — and the reason a
major is rare rather than routine.
