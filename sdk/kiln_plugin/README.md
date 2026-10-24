# kiln_plugin

The compile-time plugin contract for [KilnCMS](https://github.com/The-Verscienta/kiln_cms):
the behaviours and macros a plugin `use`s.

| Module | What a plugin does with it |
| --- | --- |
| `Kiln.Plugin` | The entry module: `use Kiln.Plugin`, override the callbacks you need |
| `Kiln.Block` (+ `Kiln.Block.Renderer`, `Kiln.Block.Info`, …) | A typed content block: `use Kiln.Block` and its `block`/`field`/`migrate` DSL |
| `Kiln.FieldType` (+ `Kiln.Tokens`) | A custom-field value type admins can pick |
| `Kiln.Forms.SpamCheck` (+ `Kiln.Forms.SpamCheck.Context`) | A heuristic run on every public form submission |
| `Kiln.ImageBackend` (`check/0` since 1.2) | An external image service new uploads can go to |
| `Kiln.Advisory` (+ `Finding`, `Context`, `Body`), since 1.1 | An editorial check shown in the content editor's advice panels |
| `Kiln.SafeFetch`, since 1.3 | Fetch a URL from content or settings without an SSRF hole: the address is checked and pinned, redirects re-checked, the body capped |

These modules used to live inside the KilnCMS core, which made it impossible
to compile a plugin as a Mix dependency: Mix compiles a dependency before the
project that uses it, so `use Kiln.Plugin` failed with "module Kiln.Plugin is
not loaded" (kiln_cms#1909). The core now builds against this package, under
the same module names, so a `projects/` overlay sees no difference.

## Installation

To start a new plugin, run `mix kiln.gen.plugin <Name> --dep` in a KilnCMS
checkout. It writes a standalone Mix project to `../<name>`, set up as below.

In the plugin's own `mix.exs`:

```elixir
def deps do
  [
    {:kiln_plugin, "~> 1.3"}
  ]
end
```

For the plugin's own builds and tests (its CI, `mix test` in its repository),
add the one Ash setting a block needs to compile, with the core's value so the
block behaves the same in both places. Ash 3.34 refuses to compile a resource
with a `:string` attribute without it, and every block is an embedded Ash
resource:

```elixir
# the plugin's config/config.exs
import Config
config :ash, default_string_length_count: :codepoints
```

A dependency's config never reaches the project that uses it, so this changes
nothing inside a KilnCMS build: there, the core's own config applies.

Require the lowest minor whose additions you use. A KilnCMS build always
compiles against the copy of this package it bundles (its `mix.exs` takes it
as a `path:` dependency with `override: true`), and Mix does not check a
dependency's requirement against an overridden package, so the core checks it
instead: `mix kiln.plugins.doctor` fails when an installed plugin requires a
`kiln_plugin` version the core doesn't bundle.

Then, in the site, the plugin goes in the overlay's dependency list and one
config line activates it. `config/project_deps.exs` sits beside
`config/project.exs` and, like it, is git-ignored in the core and committed
in the overlay. The core's own `mix.exs` and `mix.lock` never change: Mix
locks the overlay's dependencies into `config/project.lock` (kiln_cms#1967).

```elixir
# config/project_deps.exs
[{:kiln_ratings, "~> 1.0"}]

# config/project.exs
config :kiln_cms, :plugins, [KilnRatings.Plugin]
```

## What works from a dependency, and what doesn't

A dependency compiles before the core and sees only its own dependencies.
Anything a plugin builds on that lives in the core, rather than here, still
has to be a `projects/<name>/` overlay, which is compiled *inside* the core.

| Contribution | As a dependency |
| --- | --- |
| Blocks (`blocks/0`) | Yes |
| Field types (`field_types/0`) | Yes, except a colocated client hook (`input_hook/1`): Phoenix writes a dependency's colocated hooks under its own app name, which the core's `app.js` does not import |
| Spam checks (`spam_checks/0`) | Yes |
| Image backends (`image_backends/0`) | Yes. The connection check, `check/0`, from 1.2 (`{:kiln_plugin, "~> 1.2"}`) |
| Nav items, supervision children, Oban queues | Yes |
| Admin, editor and public routes | Only for a LiveView that depends on `phoenix_live_view` directly; one that does `use KilnCMSWeb, :live_view` or renders `Layouts.app` needs the core, so it stays an overlay |
| Content types (`use KilnCMS.CMS.Content`), Ash domains (`domains/0`) | No: they need the core's repo, domains and policies. Overlay only |
| Advisory checks (`advisories/0`, `Kiln.Advisory`) | Yes, from 1.1 (`{:kiln_plugin, "~> 1.1"}`). The core walks the blocks and fills `%Kiln.Advisory.Body{}`; a check only reads it |
| Outbound HTTP to a URL the plugin didn't write (`Kiln.SafeFetch`) | Yes, from 1.3 (`{:kiln_plugin, "~> 1.3"}`). The core does the fetch; with no core loaded (a plugin's own test suite) every call is an error unless `config :kiln_plugin, :safe_fetch` names a stand-in |

## Versioning

See [CHANGELOG.md](CHANGELOG.md). The contract is covered by the KilnCMS 1.x
stability promise (`docs/overlay-contract.md` in the core), so this package is
1.x too: minors add, and a major comes only with a KilnCMS major.

## Releasing

Publishing runs from `.github/workflows/release-clients.yml` in the core
repository, triggered only by a tag named `kiln_plugin-vX.Y.Z`. The workflow
checks the tag equals `@version` in `mix.exs`, runs the same gate as CI's
`plugin_sdk` job, builds the package with `mix hex.build`, and, after approval
in the `hex` environment, attests the tarball, proves a rebuild is
byte-identical, and runs `mix hex.publish --yes`.

1. Bump `@version` in `mix.exs`, add a `CHANGELOG.md` entry, and merge.
2. Tag the merge commit `kiln_plugin-vX.Y.Z` and push the tag.
3. Approve the run in the `hex` environment.

The `hex` environment's deployment-tag rule allows both `kiln_client-v*` and
`kiln_plugin-v*`; a tag matching neither never reaches the publish step. The
`HEX_API_KEY` there must be allowed to publish `kiln_plugin`.
