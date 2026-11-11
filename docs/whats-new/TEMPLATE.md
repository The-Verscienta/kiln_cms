# What's new in Kiln X.Y

<!--
  Copy this file to docs/whats-new/vX.Y.md for every minor or major release
  (a patch release that only fixes things needs none), then fill it in and
  delete every comment. docs/releasing.md → "Documenting a release" says when
  and how; `/release-docs` drafts it.

  Rules:
  - Write only what is true of the release. Check every name, default, label,
    env var and response shape against the code at the release commit, not
    against a plan or a pull request description.
  - Every code example is one that works: run it, or copy its shape from a
    test. Mark placeholders as `<like-this>`.
  - Link to the guide for each feature rather than repeating it. This page
    tells readers what changed and where to read more. The guide is where the
    full reference lives.
  - Leave out a section with nothing in it, rather than writing "None".
  - Never paste a long form from docs/changelog/. Those explain why a change
    was made. This page shows how to use it.
-->

Kiln X.Y was released on YYYY-MM-DD. Below: what it adds, what works
differently, what to do before you upgrade, and what is still broken. Every
change, one line each, is in the [X.Y.0 changelog](../changelog/vX.Y.0.md).

## At a glance

<!-- Three to six bullets, the ones a reader would tell a colleague about.
     One sentence each, plain words, with the audience in front:
     "Editors can …", "Operators can …", "API clients get …". -->

- **Editors** can …
- **Developers** get …
- **Operators** can …

## Before you upgrade

<!-- A short summary of what the release asks of whoever upgrades, in order.
     The steps themselves are in CHANGELOG.md's Upgrade notes and Breaking
     sections, which `mix kiln.update` prints. Link to them; don't restate
     them in different words. Say how long migrations take on a large site,
     whether the upgrade can be rolled back, and from which versions it was
     rehearsed. -->

1. Run `mix ash.migrate`. It adds … (about N seconds on a site with 100,000
   entries). Rolling back is safe.
2. …

`mix kiln.update` prints these steps, and the release's known issues, before
it moves your pin.

## New features

<!-- One subsection per headline feature. Smaller additions go in a list
     under "Also new" at the end of this section. -->

### <Feature name>

<!-- What it is and who it is for, in two or three sentences. Then how to
     use it: the UI path (exact labels and the role needed) or the call. Then
     one complete example. Then a link to the guide. -->

What it does and who it is for.

**In the editor:** *Settings → <Section> → <Button>* (admins only). …

**Through the API:**

```bash
curl -s https://<your-site>/api/content/<type>/<slug> \
  -H "Authorization: Bearer <api-key>"
```

```json
{
  "data": {
    "slug": "<slug>",
    "new_field": "…"
  }
}
```

Read more: [<Guide title>](../<guide>.md#<section>).

### Also new

- … ([#NNNN](https://github.com/The-Verscienta/kiln_cms/pull/NNNN))

## Changes

<!-- Behavior that works differently now, but that nobody has to act on.
     Show the difference: "Before … Now …", or a before/after example. -->

- **<What changed>.** Before, … Now, … ([guide](../<guide>.md))

## Breaking changes

<!-- One subsection per item under CHANGELOG.md's Breaking section. Each:
     who is affected, how to tell whether you are, and how to migrate, with
     the code before and after. -->

### <Short description of what broke>

**Who is affected:** sites that …. To check, run ….

**Before:**

```elixir
# overlay code that compiled against X.(Y-1)
```

**After:**

```elixir
# the same code for X.Y
```

## Deprecations

<!-- What still works but will be removed, the release that removes it, and
     what to use instead. -->

- `<old>` is deprecated. Use `<new>` instead. It will be removed in X.(Y+1).

## Known issues

<!-- The same list as CHANGELOG.md's `### Known issues` for this release.
     Each one: the symptom as a user would see it, who is affected, the
     workaround, and the tracking issue. When a patch release fixes one,
     mark it here as fixed rather than deleting it:
     "**Fixed in X.Y.1.**" -->

- **<Symptom, as a user would describe it>.** Affects …. Until it is fixed,
  …. Tracked in [#NNNN](https://github.com/The-Verscienta/kiln_cms/issues/NNNN).

## Documentation updated in this release

<!-- The guides that are new or changed, so a reader who knows the old ones
     can see what to read again. -->

- New: [<Guide>](../<guide>.md)
- Updated: [<Guide>](../<guide>.md) — <what changed in it>
