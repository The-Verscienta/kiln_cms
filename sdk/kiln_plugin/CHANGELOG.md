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

## 1.0.0

### Added

- **First release (kiln_cms#1909).** The compile-time plugin contract moved
  out of the KilnCMS core into this package, under the same module names:
  `Kiln.Plugin`, `Kiln.Block` and `Kiln.Block.*`, `Kiln.FieldType`,
  `Kiln.Tokens`, `Kiln.Forms.SpamCheck` (with its `Context`),
  `Kiln.ImageBackend`, and `Kiln.Advisory` with its `Finding`, `Context` and
  `Body` structs. Nothing about them changed; what changed is that a
  plugin can now depend on them without depending on the core, so it can
  ship as a Hex, git or `path:` dependency. The first KilnCMS release after
  1.3.0 is the first core that builds against it. One part of
  `Kiln.Advisory.Body` did not come along: the block walk (`compute`,
  `from_typed`, `from_indexed`) matches the core's block types, so it stays
  in the core as `Kiln.Advisory.Walk`. `Body` keeps the three as deprecated
  delegates, which work only inside a KilnCMS build. A check never called
  them; it only reads the body the core hands it.
