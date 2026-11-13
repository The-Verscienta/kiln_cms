# 0060. An artifact change bumps `format_version` only when every existing document needs it

- **Status** — accepted (2026-11-13), recording the rule behind the bumps and
  non-bumps that shipped from 0.5.0 to 1.9.0.
- **References** — [#2580](https://github.com/The-Verscienta/kiln_cms/issues/2580),
  which asked for this record;
  [#2258](https://github.com/The-Verscienta/kiln_cms/issues/2258) and
  [#2582](https://github.com/The-Verscienta/kiln_cms/pull/2582) (`social`, v4);
  [#2256](https://github.com/The-Verscienta/kiln_cms/issues/2256) (`robots`),
  [#2103](https://github.com/The-Verscienta/kiln_cms/issues/2103)
  (`custom_fields_portable`), `deliver_plain` (`custom_fields_plain`) and
  [#1327](https://github.com/The-Verscienta/kiln_cms/issues/1327)
  (`inherited_fields`), all added without a bump;
  [#2164](https://github.com/The-Verscienta/kiln_cms/issues/2164) and
  [#2464](https://github.com/The-Verscienta/kiln_cms/issues/2464) (new `:web`
  markup, re-fired with `mix kiln.refire_all`);
  [#615](https://github.com/The-Verscienta/kiln_cms/issues/615) (the lazy
  re-fire that made a bump do something);
  [#2463](https://github.com/The-Verscienta/kiln_cms/issues/2463) and
  [#2583](https://github.com/The-Verscienta/kiln_cms/pull/2583) (the artifact
  `ETag` became a digest of the body);
  [#2579](https://github.com/The-Verscienta/kiln_cms/issues/2579) (the SwiftUI
  example that drifted past v4). It refines decision A2 (D9 in
  `KilnCMS_Project_Plan.md`: every artifact is stamped with an integer
  `format_version`). The sibling rule for the field sync file is
  [ADR 0047](0047-the-field-sync-file-stays-version-1-and-a-new-attribute-does-not-bump-it.md);
  site-level values are
  [ADR 0061](0061-site-level-values-stay-out-of-per-document-artifacts.md).
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#twitter-card-upgrade) (v4),
  [1.9.0](../changelog/v1.9.0.md#robots-flags-upgrade) (`robots`, no bump),
  [0.5.0](../changelog/v0.5.0.md#artifacts-fired-before-a-surface-shape-change-are-now-migrated-instead-of)
  (lazy re-fire).

## The problem

Every fired artifact is stamped with `KilnCMS.Firing.Engine.format_version/0`
(`@format_version`, now 4). Since #615 the stamp is read:
`Engine.migrate_if_stale/4` runs on each artifact read that misses the firing
cache (`Firing.Delivery`, `Firing.Sync`, the provenance controller and the
engine's own read), and enqueues a `FireWorker` job for a row older than the
build. Bumping the number therefore re-fires, lazily, every published document
that anyone reads.

The `json` surface has gained keys since v3 without a bump: `robots` (#2256),
`custom_fields_portable` (#2103), `custom_fields_plain` (`deliver_plain`) and
`inherited_fields` (#1327). `social` (#2258) bumped to v4. The `:web` markup
changed twice (#2164, #2464) with no bump either. The reasons lived in the
engine's comments and in pull request text, and nothing told the author of the
next artifact change which way to go.

## Decision

**Bump `@format_version` when the change belongs on every document fired
before the deploy. Don't bump when both of these hold:**

1. **Every artifact fired before the deploy is already correct without the
   change.** Nothing the old build could store would set the key, so its
   absence says the same thing the new build would.
2. **Whatever turns the change on re-fires the documents it affects.**

The keys added so far, against that rule:

- **`robots`** (`put_robots/2`) is absent unless `noindex` or `nofollow` is
  set. Both columns arrived with #2256, defaulting to false, so no older
  document has either set, and absent means both false. Setting one is an edit,
  and an edit of a published document fires it
  (`Changes.FireArtifacts, only_when: :published`). The type's
  `noindex_default` applies only to new documents. No bump.
- **`custom_fields_plain` and `custom_fields_portable`** (`put_plain_fields/2`,
  `put_portable_fields/2`) are absent on a type that flags no field
  `deliver_plain` / `deliver_portable`, and no field could carry the flag
  before its release. Flipping either flag re-fires the type's published
  documents (`Changes.BustTypeRegistry`). No bump.
- **`inherited_fields`** (`annotate/3`) is absent unless a `:fallback` field
  inherited a value, and no field could be `:fallback` before #1327.
  Publishing a locale variant of a type with a `:shared` or `:fallback` field
  re-fires its published siblings (`I18n.SharedFieldsWorker`), and saving the fallback
  chain at `/editor/locales` re-fires every published translation of a type
  that declares a `:fallback` field (`I18n.RefireInheritingWorker`). Changing a
  field's `localization` to `:fallback` re-fires nothing, so a variant that
  already left that field empty gains its inherited value at its next fire,
  not at once. That gap is about the setting, not the deploy; a bump would not
  close it. No bump.
- **`social`** (`put_social/2`) is on every document: `title` is always
  present. Every artifact fired before the deploy lacks it, and no editorial
  action re-fires an untouched document. A bump is the only thing that makes
  those converge without an operator. **v4.**

Two cases the version cannot handle:

- **New markup in an existing key** (#2164's code blocks, #2464's tables).
  The old artifacts are valid, only older; they shipped without a bump, with an
  upgrade note to run `mix kiln.refire_all`. Bump instead when serving the old
  markup is wrong, not merely dated.
- **A new surface.** There is no row for it, so a read is a plain not-found
  and `Engine.stale?/1` never runs (`migrate_if_stale/4`'s "What this does not
  cover"). `mix kiln.refire_all` is required whatever the version says.

## The cost of a bump

Each of these is real, and each is a reason not to bump for a key that rule
1 and 2 already cover:

- **The lazy re-fire is silent.** `migrate_if_stale/4` enqueues a job with
  neither `"refire" => true` nor `"announce" => "delivery"`, so `FireWorker`
  announces nothing: no webhook, no change-feed entry, no `KilnCMS.Cache` bust,
  no CDN purge.
- **Only `If-None-Match` revalidators converge.** The artifact `ETag` is a
  digest of the body served (#2463, #2583), so it moves when the body does. A
  cache that revalidates with `If-Modified-Since` alone keeps the old body
  until it expires, because `Last-Modified` is the last edit, which a re-fire
  does not move.
- **An `/api/sync` mirror never hears of it.** A re-fire is not an edit, so the
  delta feed does not send the document again. The mirror needs a fresh
  `?initial=true` sync after the corpus has been re-fired.
- **Convergence is eventual, and partial.** The stale body is served on the
  read that triggers the job and cached for up to an hour. A document nobody
  reads is never re-fired. Under a cold cache, each stale read pays one job
  insert (and its uniqueness check) until the re-fire lands, because
  `FireWorker`'s `unique` window dedups jobs, not inserts.
- **A rolling deploy writes both versions.** A job picked up by a node still on
  the old release writes the old version; a new node reading it re-fires it
  again.
- **A rollback serves the newer rows as stored.** The older build sees a row
  from the future (`from_future?/1`), logs it at most once a minute
  (`warn_future_artifact/3`) and does not downgrade it; `mix kiln.refire_all`
  on that build rewrites them.
- **Every generated contract moves.** `GET /api/schema` reports the version as
  `x-kiln.artifact_format_version`, the OpenAPI export uses it as
  `info.version`, and the TypeScript, Swift and Kotlin emitters write it into
  their file header. Every schema-export golden changes, and so does the
  SwiftUI example's `Kiln.swift`.

`mix kiln.refire_all` (on a release, `KilnCMS.Firing.Sweep.run()`) is the
fast path for a large corpus, with or without a bump. `--notify` sends each
document as `<type>.updated` with `"reason": "refire"`
([Re-render published content after an upgrade](../releasing.md#re-render-published-content-after-an-upgrade)).

## Checklist for the next artifact change

1. Would an artifact fired before the deploy be wrong, or only older, without
   the change? Wrong for every document: bump. Wrong for none: go on.
2. Does whatever turns the change on (a document edit, a field flag, a site
   setting) re-fire the documents it affects? If not, make it re-fire them
   (`Changes.BustTypeRegistry` and `Firing.Sweep.sweep_type/2` are the usual
   ways), or bump.
3. Is it a new surface? Then `mix kiln.refire_all` is required; say so in the
   upgrade note.
4. Does `KilnCMS.SchemaExport` declare the key? A key the export leaves out is
   absent from every generated client.
5. Regenerate the schema-export goldens (`RegenerateGoldensTest`) and the
   SwiftUI example's models (`examples/swiftui-reader/bin/regenerate`);
   `DriftTest` and `SwiftUIReaderDriftTest` fail until you do.
6. On a bump, add a line to `@format_version`'s history comment and to
   `Engine.format_version/0`'s `@doc`, and write an upgrade note that names the
   consumers a re-fire does not reach (the list above).

## Rejected

- **Bump on every new key.** Each bump buys a whole-corpus re-fire with the
  costs above, for keys whose absence on an old artifact already means the
  right thing.
- **Never bump; rely on `mix kiln.refire_all`.** That was the state before
  #615: the version was decorative, and every document published before a
  shape change served the old shape until an operator remembered the sweep.
  A key every document needs should converge without one.
- **Backfill in a migration.** Firing needs the application (renderers,
  branding, the field registry); a migration has only SQL. The lazy re-fire is
  that backfill, run by the application.

## Consequences

- Most artifact changes ship without a bump and with an upgrade note that
  says whether `mix kiln.refire_all` is worth running.
- A consumer reads a key added without a bump as optional, and reads
  `format_version` when it needs to know which shape it holds
  ([headless consumer guide](../headless-consumer-guide.md)).
