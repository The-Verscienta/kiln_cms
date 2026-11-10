# Changelog — kiln_plugin

Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html),
read for a plugin contract:

- **major** — a callback, DSL option or return shape a plugin relies on was
  renamed, removed or changed meaning. Only ever alongside a KilnCMS major.
- **minor** — something was added (a callback with a default, a DSL option, a
  helper). A plugin that uses the addition should require at least that
  minor (`{:kiln_plugin, "~> 1.1"}`).
- **patch** — fixes only.

Releases are tagged `kiln_plugin-vX.Y.Z` in the
[KilnCMS repository](https://github.com/The-Verscienta/kiln_cms).

## 1.4.0

### Added

- **`c:Kiln.Plugin.plug_routes/0` (kiln_cms#2272).** Controller-style routes
  (`{:post, "/hooks/ping", MyController, :create}`) and `forward`s to a Plug
  (`{:forward, "/feeds", MyRouter, []}`), mounted before the content-delivery
  catch-alls in a scope with no session or CSRF check. Defaults to `[]`; a
  plugin that does not override it is unchanged. A plugin using it should
  require `{:kiln_plugin, "~> 1.4"}`.

- **`c:Kiln.FieldType.graphql_kind/1`, an optional callback naming how the
  GraphQL API types a field's value (kiln_cms#2290).** Return `:string`,
  `:int`, `:float`, `:boolean`, `:date`, `:datetime` or `:json` for the value
  `cast/2` stores. The core serves it through the matching typed reader
  (`customInt(name:)`, …) and `fields(names:)`. It has no default and is not
  required: a type without it, or compiled against an older `kiln_plugin`, is
  served as `:json`, and so is any other return. A plugin that implements it
  should require `{:kiln_plugin, "~> 1.4"}`; publish this version to Hex before
  a plugin does. Additive: no callback or return shape changed.

- **`c:Kiln.FieldType.widgets/1` and `Kiln.FieldType.widget/2`, a choice of
  editor input per field (kiln_cms#2284).** A type lists the inputs an admin
  may pick between, default first (`[:number, {:stars, "Stars"}]`); the pick
  is stored on the field definition as a string, and `widget/2` reads it back
  inside `input_attrs/1`, `input_parts/1` or `input_hook/1`. Storage and
  delivery do not change. It has no default and is not required: a type
  without it offers no choice. A plugin that implements it should require
  `{:kiln_plugin, "~> 1.4"}`. Additive: no callback or return shape changed.

- **`Kiln.Security.Check` and `c:Kiln.Plugin.security_checks/0`
  (kiln_cms#2252).** A plugin can add a line to the console's Security
  posture page: `id/0`, `title/0`, `scope/0` (`:site` or `:deployment`) and
  `run/1`, which gets a `Kiln.Security.Check.Context` (site, build
  environment, clock, reader's locale; no actor) and answers a
  `Kiln.Security.Check.Result` built with `pass/2`, `warn/2`, `fail/2`,
  `unknown/2` or `n_a/2`. The core runs each check in its own process under a
  deadline (`timeout/0`, default 1000 ms); one that crashes, overruns or
  answers anything else shows as "could not run", never as a pass. Ids
  starting `core.` are reserved. `Kiln.Security.Check.conformance/1` checks a
  module without running it. `c:Kiln.Plugin.security_checks/0` defaults to
  `[]`. A plugin using it should require `{:kiln_plugin, "~> 1.4"}`.

- **A security check's `facts` and `summary` are published to monitoring,
  and `Kiln.Security.Check.Result` repairs invalid UTF-8 (kiln_cms#2521).**
  The core now serves the posture report as JSON at
  `GET /api/security/posture`, to the site's administrators (`:site` checks)
  or platform administrators (`:deployment` checks) who hold an API key.
  Each check's `id`, `title`, `summary`, `fix_path`, `docs_url` and `facts`
  are in it; `details` and `description` are not. So `facts` must never
  carry a secret, a token or a person's address: put names in `details`.
  - `Kiln.Security.Check.Result.sanitize/1` replaces each invalid UTF-8
    sequence with U+FFFD in the summary, every detail, every fact key and
    every string fact value, before it trims them, so a result always
    encodes as JSON.
  - `Kiln.Security.Check.Result.fix_path/1` and
    `Kiln.Security.Check.Result.docs_url/1` return `nil` for a value that is
    not valid UTF-8: a link is dropped, not repaired.
  - `Kiln.Security.Check.describe/1` is unchanged and still accepts a
    non-UTF-8 title or description; the core replaces the bad bytes when it
    lists the check, and lists a plugin whose `name/0` is not valid UTF-8
    under its module name.

- **`Kiln.Challenge.Provider` and `c:Kiln.Plugin.challenge_providers/0`
  (kiln_cms#2249).** A plugin can ship a human-verification provider that
  the operator picks with `CHALLENGE_PROVIDER`, beside the built-in
  Turnstile and reCAPTCHA v2. `c:Kiln.Plugin.challenge_providers/0` defaults
  to `[]`. `Kiln.Challenge.Provider.conformance/1` checks a provider the way
  the core does before using it: an unregistered or non-conforming provider
  leaves verification off rather than failing open. The core enforces the
  hostname and action a provider reports. A plugin using it should require
  `{:kiln_plugin, "~> 1.4"}`.

## 1.3.1

### Changed

- **`Kiln.Block.JsonSchema`'s `portable_text_block` definition declares the
  standard Portable Text keys (kiln_cms#2126).** `style`, `listItem`, `level`,
  `children` (spans with `text` and `marks`) and `markDefs` (with `href`),
  all optional, the definition still open, so a model generated from the
  schema keeps a block's text. Additive: a value that validated before still
  validates, and no callback or DSL option changed.

## 1.3.0

### Added

- **`Kiln.SafeFetch` (kiln_cms#2047).** A plugin that fetches a URL chosen
  by content or configuration — a feed poller, a link unfurler — can do it
  through the SDK: `get/2`, `head/2`, `post/3` and `request/3`, with the
  core's `KilnCMS.SafeFetch` doing the fetch inside a KilnCMS build. The
  address is checked and pinned against DNS rebinding, redirects are only
  followed on request and re-checked per hop, and the body is capped.
  Options outside the documented set are dropped. With no core loaded every
  call is an error unless `config :kiln_plugin, :safe_fetch` names a
  stand-in for the plugin's own tests. A plugin that uses it should require
  `{:kiln_plugin, "~> 1.3"}` and a KilnCMS core that implements it (the
  first release after 1.5.1).

## 1.2.0

### Added

- **`c:Kiln.ImageBackend.check/0` (kiln_cms#1955).** A backend can say whether
  its service answers with the settings it has, and what it found there, for
  System → Image backend. Optional: `use Kiln.ImageBackend` defaults it to
  `:unsupported`. A backend that implements it should require
  `{:kiln_plugin, "~> 1.2"}`.

## 1.1.0

### Added

- **Advisory checks (kiln_cms#1909).** `Kiln.Advisory` moved out of the
  KilnCMS core into this package with its `Finding`, `Context` and `Body`
  structs, under the same names, so a plugin that ships a check matching
  `%Kiln.Advisory.Context{}` can be a dependency. Such a plugin should
  require `{:kiln_plugin, "~> 1.1"}`. One part of `Kiln.Advisory.Body` did
  not come along: the block walk (`compute`, `from_typed`, `from_indexed`)
  matches the core's block types, so it stays in the core as
  `Kiln.Advisory.Walk`. `Body` keeps the three as deprecated delegates,
  which work only inside a KilnCMS build. A check never called them; it
  only reads the body the core hands it.

## 1.0.0

### Added

- **First release (kiln_cms#1909).** The compile-time plugin contract moved
  out of the KilnCMS core into this package, under the same module names:
  `Kiln.Plugin`, `Kiln.Block` and `Kiln.Block.*`, `Kiln.FieldType`,
  `Kiln.Tokens`, `Kiln.Forms.SpamCheck` (with its `Context`) and
  `Kiln.ImageBackend`. Nothing about them changed; what changed is that a
  plugin can now depend on them without depending on the core, so it can
  ship as a Hex, git or `path:` dependency. The first KilnCMS release after
  1.3.0 is the first core that builds against it.
