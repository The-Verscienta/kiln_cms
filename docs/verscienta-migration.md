# Verscienta → KilnCMS migration

A one-off importer that moves the [Verscienta](https://verscienta.com) herbal
database from its legacy **Directus 11 / MariaDB** backend into KilnCMS.

The two systems model content very differently, so this is an ETL, not a copy:
Directus exposes ~6 flat collections of typed columns plus junction tables;
KilnCMS models each record as a typed block tree with data-driven custom fields,
namespaced tags, polymorphic content links and media items. The mapping below is
declared as data in `KilnCMS.Verscienta.Mapping` and applied by
`KilnCMS.Verscienta.Importer`.

## What moves where

| Directus | KilnCMS |
| --- | --- |
| `herbs`, `formulas`, `conditions`, `practitioners`, `clinics`, `modalities` | content types of the same name (`mix kiln.gen.content`) |
| `title` / `name`, `slug`, `status` | `title`, `slug`, publish/archive state |
| rich-text/HTML fields (e.g. `botanical_description`, `therapeutic_uses`, `description`, `bio`, `benefits`) | body **blocks** — each section becomes a `heading` + `rich_text` block; HTML lands in `RichText.legacy_html` (sanitised on cast) |
| scalar & select fields (`scientific_name`, `severity`, `total_weight`, …) | `custom_fields` (auto-created `FieldDefinition`s, type inferred per field) |
| JSON array/object fields (`synonyms`, `tcm_meridians`, `symptoms`, `hours`, …) | `custom_fields`, JSON-encoded as `:text` — **lossless** |
| rich O2M children (`herb_clinical_studies`, `herb_dosages`, `herb_case_studies`, …) | captured automatically as JSON-encoded `custom_fields` on the parent herb |
| `herb_tags`, `tcm_categories` (M2M) | `Tag`s, namespaced `herb-tag-*` / `tcm-*` so the vocabularies never collide |
| M2M relations (`conditions_treated`, `related_species`, `formulas_conditions`, `clinics_practitioners`, …) | `ContentLink`s with a relation `kind` (`:treats`, `:related_species`, `:substitute`, `:offers`, `:staff`, `:related`, …) |
| O2M children that carry data (`formula_ingredients`, `formula_modifications`) | `ContentLink`s; the child's own fields (quantity, unit, role, …) go on the link `metadata` |
| file references — `image` M2O, `herb_images`/`clinic_images` O2M | `MediaItem`s built from the Directus file object, preferring the Cloudflare-offload URL. The first image becomes the content's `featured_image`; the rest become `image` blocks |

**Nothing is silently dropped.** Any Directus field not handled structurally is
captured in `custom_fields` (JSON-encoded if non-scalar). Compare the importer's
report counts against the Directus row counts to confirm a complete run.

## Running it

Prerequisites: the six content types exist (already committed — generated with
`mix kiln.gen.content`) and their migration has been applied (`mix ash.migrate`).

### Against the live Directus API

The importer pulls every collection over the Directus REST API using a **static
read token**. Create a read-only token in Directus, then:

```bash
DIRECTUS_URL=https://api.verscienta.com \
DIRECTUS_TOKEN=xxxxxxxx \
mix kiln.import.verscienta
```

or pass them as flags: `--url https://api.verscienta.com --token xxxxxxxx`.

Add `--dry-run` to fetch + transform and print counts without writing anything:

```bash
mix kiln.import.verscienta --url … --token … --dry-run
```

The importer is **idempotent** — content is matched by `slug`, tags/media by
their natural key, and link edges by `[source, target, kind]` — so a re-run tops
up rather than duplicates. It runs in two passes (all content first, then links)
so cross-document references (including self-references between herbs) resolve.

### Offline / fixtures

A small fixture set under `priv/verscienta_fixtures/` mirrors the Directus
`fields=*.*` response shape and exercises the whole pipeline with no network:

```bash
mix kiln.import.verscienta --source priv/verscienta_fixtures
```

The test suite (`test/kiln_cms/verscienta/`) runs the full ETL against these
fixtures, plus pure transform tests and a `Req.Test`-stubbed client test.

## Notes & integration seams

- **Relation expansion.** The client requests `fields=*.*`, which expands
  relations one level. The transform reads each relation as an array of related
  items and takes their `id` (a bare id also works). If a given Directus M2M
  alias returns *junction* rows rather than the related items, deepen that
  collection's `fields` selector so the target item (and its `id`) is present —
  this is the one place worth validating against the live API on a first run.
- **Actor.** Writes run as the admin resolved from `ADMIN_EMAIL` (default
  `admin@kiln.test`); seed one first, or pass `actor:` to `Importer.run/2`.
- **Out of scope (extend in `Mapping`).** The TCM "science" collections
  (`tcm_ingredients`, `tcm_target_interactions`, `tcm_clinical_evidence`) and
  hierarchical tag parents aren't mapped yet; add configs/links as needed.
