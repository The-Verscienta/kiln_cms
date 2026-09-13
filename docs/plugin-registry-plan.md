# Plugin registry on kilncms.dev — design & phased plan

**Status:** proposal.
**Issue:** [#1447](https://github.com/The-Verscienta/kiln_cms/issues/1447),
under [#333](https://github.com/The-Verscienta/kiln_cms/issues/333).
**Relies on:** the marketplace stance in
[Runtime extensibility](plugin-extensibility.md) (no runtime code loading),
`Kiln.Plugin`/`Kiln.Plugins` (D18, [Plugin system](plugin-system-plan.md)),
dynamic content types (D17, [Dynamic content types](dynamic-content-types-plan.md)),
[Forms](forms.md), the [JSON API](json-api.md) and the `publish_docs.exs`
publisher pattern that already runs against kilncms.dev.

## TL;DR

> **The registry distributes metadata and trust — never code.** A listing is a
> content entry on kilncms.dev (itself a Kiln instance) pointing at a hex
> package or git repository; installing stays "add the dep, add one config
> line, run `mix kiln.plugins.doctor`". Because the registry never serves an
> artifact, hex/git remains the trust root, and a registry compromise cannot
> execute code in anyone's node. Almost everything except the verification
> pipeline is configuration of features Kiln already ships.

## 1. Why a catalog, not a store

[`docs/plugin-extensibility.md`](plugin-extensibility.md) §1 already settled
the load-bearing question: the BEAM has no in-process sandbox, so Kiln does not
hot-load third-party code, and a plugin is compile-time OTP code activated by
`config :kiln_cms, :plugins`. §2b then described the registry as "a governance
artifact… a docs table (or, later, a hosted static index)". This document is
that hosted index, designed out.

The consequence worth stating explicitly, because it shapes every decision
below: **the registry is not in the install path.** It answers "which plugins
exist, who vetted them, and which Kiln versions they work on". `mix deps.get`
answers "give me the bytes", and hex's own checksums and retirement machinery
authenticate them.

That gives a small, honest threat model:

- The worst case of a registry compromise is a **misleading listing** — a
  tampered `package`/`repo_url` pointing a reader at an attacker's package.
  Not remote code execution.
- So the security-critical fields are the **coordinates** (`source`,
  `package`, `repo_url`, `checksum`), not the prose. Changes to them must be
  audited and, once ownership proof exists (§4), re-verified rather than
  trusted.
- A registry outage degrades **discovery only**. Nothing about an existing
  install depends on it. Keep it that way: §11's install task must fail
  closed and never become a build-time dependency.

## 2. Why kilncms.dev is the right host

kilncms.dev is already a Kiln instance, and dogfooding is the point. Every
requirement of a plugin directory except automated verification maps onto a
feature that already exists:

| Registry requirement | What it already is in Kiln |
|---|---|
| Listing model + fields | Dynamic content type + `FieldDefinition` (D17), no code |
| Listing page + index | `/plugins/:slug` delivery; index page by `path_alias` |
| Submission intake | Admin-defined public form + spam scoring ([Forms](forms.md)) |
| Vetting queue | Draft → review → publish, assignees and review recipients |
| Categories / faceting | `Tagging` (polymorphic, any UUID) |
| Search | The hybrid ranking stack (keyword / semantic / tag / alias legs) |
| Machine-readable index | JSON:API reads, incl. `/api/json/type-definitions` |
| README + screenshots | `KilnCMS.Markdown` (#1435) and the media library |
| Change notifications | Webhooks, feeds |
| Publishing from CI | `scripts/publish_docs.exs` + an admin `:read_write` key |

The **index page gotcha** from the docs rollout applies verbatim: a page slug
may not equal a content type's `path_segment` (`SlugAvailable`), so the index
is a page with slug `plugins-directory` carrying `path_alias` `/plugins`,
exactly as the docs index is slug `documentation` aliased to `/docs`.

## 3. Data model: two dynamic types

### 3a. `plugin` — the listing

One entry per plugin, keyed by its machine name (`c:Kiln.Plugin.name/0`).
Fields, using the registered custom-field types (`KilnCMS.CMS.FieldTypes`):

| Field | Type | Notes |
|---|---|---|
| `machine_name` | `:string` | Must equal `name/0`; globally reserved (§4) |
| `summary` | `:string` | `summary/0` |
| `source` | `:select` | `hex` \| `git` |
| `package` | `:string` | Hex package name, when `source = hex` |
| `repo_url` | `:url` | Canonical source repository |
| `homepage` | `:url` | `homepage/0` — hexdocs or README |
| `license` | `:select` | SPDX identifier; required |
| `maintainer` | `:string` | Display name; ownership state is separate |
| `ownership` | `:select` | `unclaimed` \| `claimed` \| `verified` (§4) |
| `tier` | `:select` | `official` \| `reviewed` \| `community` |
| `listing_status` | `:select` | `listed` \| `yanked` \| `removed` |
| `contributes_*` | `:integer`/`:text` | Written by the verifier, never by hand |
| `hex_downloads`, `stars`, `stats_fetched_at` | `:integer`/`:datetime` | Upstream figures (§8) |

Categories are **tags**, not a field — the taxonomy will churn and `Tagging`
already faceting-searches.

The body is the rendered README, imported through `KilnCMS.Markdown`. Imported
bodies must seed `rich_bodies`, or the editor opens empty on the next edit.

The `contributes_*` fields deserve emphasis: the plugin contract is
declarative, so `Kiln.Plugins.manifests/0` yields each plugin's blocks, field
types, advisories, spam checks, nav items, admin/editor/public route counts,
Oban queues, supervision children and domains. Storing that as **structured
data on the listing** is what lets a reader search for "plugins that add a
block" or "plugins that mount public routes" — and lets a cautious operator
see, before installing, that a "star rating widget" wants three public routes
and a supervision child.

### 3b. `plugin_version` — the compatibility and trust record

A second dynamic type, one entry per released version, linked to its listing:

| Field | Type | Notes |
|---|---|---|
| `version` | `:string` | SemVer |
| `released_at` | `:datetime` | From hex / the git tag |
| `kiln_requirement` | `:string` | Version requirement against Kiln |
| `elixir_requirement`, `otp_requirement` | `:string` | Toolchain floor |
| `checksum` | `:string` | Hex checksum, or the resolved git SHA |
| `verification` | `:text` | Verifier output, verbatim (§5) |
| `verified_at`, `verified_against` | `:datetime`/`:string` | Which Kiln version was compiled |
| `yanked`, `yank_reason` | `:boolean`/`:string` | Per version, never per listing |
| `changelog_url` | `:url` | |

**Why a second type rather than fields on the listing:** compatibility and
yanking are properties of a *version*. A single row cannot express "works on
0.8, broken on 0.9, and 1.2.3 is yanked" — and the first time a plugin breaks
on a Kiln release, that is the only question a reader has.

## 4. Submission, ownership and name reservation

**v1 intake is a public form**, built at `/editor/forms`: machine name, source
coordinates, summary, license, contact. Submissions carry the core spam score
and land in the form's own moderation queue with `notify_email` set. The form
deliberately **does not create a listing** — a maintainer reads the submission
and creates the entry, which is what keeps "listed" meaning "a human looked".

**Ownership proof** comes before any self-service editing. Two options:

- **A file in the repo** — `.kiln-plugin.json` at the repository root carrying
  the claimed machine name and a verification token issued to the submitter,
  fetched over `SafeFetch` (never a raw `Req.get/1` against a
  submitter-controlled URL — that is an SSRF sink by construction).
- **Forge OAuth** — simpler for the submitter, but couples the registry to
  GitHub. The file check works for any forge and for a hex-only plugin whose
  repo is elsewhere.

Recommendation: the file check, because it proves control of *the coordinates
the listing points at*, which is the field that actually matters (§1).

**Name reservation is global here, and only here.** `mix kiln.plugins.doctor`
rejects collisions within one install; nothing today stops two authors
publishing plugins both named `ratings`, and a collision is unresolvable after
the fact (one of them cannot be installed alongside the other). The registry
must reject a second claim on a machine name at submission time, and must
treat the reserved core/built-in field-type and block names as taken.

## 5. The verification pipeline

This is the part that does not exist yet, and the reason the registry is worth
building rather than maintaining a table in a README. Per submitted version, a
GitHub Actions workflow shaped like `publish-docs.yml`:

1. **Resolve** the coordinates to an exact ref (hex version, or a git SHA —
   never a moving branch).
2. **Compile** it in a throwaway container, in a bare host app, against each
   supported Kiln version.
3. **Run `mix kiln.plugins.doctor`** with the plugin registered: domain
   registration, block/field-type/queue name collisions, route shape.
4. **Capture `Kiln.Plugins.manifests/0`** for that plugin → the
   `contributes_*` surface.
5. **Publish** the version entry through the JSON:API write path with an admin
   `:read_write` key, the way `publish_docs.exs` publishes guides.

**Compiling untrusted code is executing untrusted code.** `mix compile` runs
module bodies, `@` attributes and macros at compile time; a hostile package
gets arbitrary execution in that container. Therefore:

- The build job is **ephemeral, network-restricted, and holds no registry
  credentials**. It emits a result artifact.
- A **second job** with the `:read_write` key reads that artifact and
  publishes. The key never sits in a job that compiles third-party code.

**Publish the verifier's output verbatim**, next to the badge, and say what was
checked. A green gate means "it compiles and satisfies the plugin contract on
Kiln x.y" — it is not a security audit, and a registry that lets readers infer
otherwise is worse than one with no badge at all.

## 6. Discovery

`/plugins` (aliased index) and `/plugins/:slug`, with tag facets for
categories, sort by recently-updated, and the existing hybrid search over
listings. The JSON:API read endpoints give a machine-readable index for free —
which is what §11's install task, and any future in-admin browser, resolve
against.

## 7. Trust tiers, yanking, security notices

- **Tiers**: `official` (maintained by the Kiln project), `reviewed` (a
  maintainer read the source), `community` (listed and verified to compile,
  not read). Attach the reviewer's notes; a bare star rating communicates
  nothing actionable.
- **Yank** is per version, with a reason, and never deletes the row — a reader
  landing on a yanked version from a search result needs to see *why*.
- **Security notices** are records against a (plugin, version-range) pair.
  Name them "security notice" in-product, not "advisory": `Kiln.Advisory` is
  already the editorial-linting concept, and overloading the word in the same
  product will confuse everyone who reads both.

## 8. Statistics, honestly

Installs cannot be counted: the bytes come from hex or a git host, not from
here. So do not invent a popularity metric. Pull **hex download counts** and
**forge stars** on an Oban schedule, store them with `stats_fetched_at`, and
label them in the UI as upstream figures with their as-of date.

## 9. Policy

A published listing policy, a takedown path, a required SPDX license field, and
a stated rule against name squatting. Paid or licensed plugins are **out of
scope** — commerce is a different project with its own compliance surface, and
nothing in this design forecloses it later.

## 10. Consequences for the kilncms.dev deployment

- The marketing site starts holding **user-submitted content**. That means the
  form spam settings and moderation queue are now operational surfaces, and
  comments on listings should be moderated or off.
- **Demo reset must never touch it.** The registry belongs on the main
  kilncms.dev app; if the golden-snapshot reset (#1425) ever runs on that
  instance, listings are wiped on schedule. The demo sandbox stays a separate
  app.
- **Backups matter more than they did.** Losing the marketing site loses
  regenerable content; losing the registry loses submissions and review
  history.
- Read paths should stay cacheable (and static-exportable), so discovery
  survives a bad deploy.

## 11. Install UX

v1: a generated snippet per listing — the `mix.exs` dep line, the
`config :kiln_cms, :plugins` line, and the `:ash_domains`/`:content_domains`
additions when the plugin ships content types (doctor fails loudly when those
are missing, so the snippet should pre-empt it).

Later: `mix kiln.plugin.install <name>`, resolving through the registry's
JSON:API index and editing `mix.exs` and config. It must print the diff and
require confirmation — silently adding a dependency is the one affordance this
whole design exists to avoid — and it must fail closed when the registry is
unreachable.

## 12. Phases

1. **Listings, by configuration.** The `plugin` type and its fields, the
   submission form, the aliased index page, manual vetting through the normal
   editorial workflow. No new application code.
2. **Versions and verification.** The `plugin_version` type, the two-job
   verification workflow, the published verifier output, install snippets.
3. **Self-service.** Ownership proof, maintainer-editable listings, security
   notices and yanking, upstream statistics.
4. **Deferred, unchanged.** A true third-party runtime-code sandbox (WASM /
   out-of-process) remains [#333](https://github.com/The-Verscienta/kiln_cms/issues/333)'s
   scope and is not a prerequisite for any of the above.

## 13. Explicitly out of scope

Hosting plugin artifacts; runtime loading of plugin code; paid plugins and
licensing; star ratings (moderated comments instead, in a later phase); an
in-admin plugin browser that installs anything.
