# Verscienta Health content modules

Stretch issue #64. Verscienta Health is a TCM (Traditional Chinese Medicine)
content use case for KilnCMS. Rather than bespoke schemas, the health content
types are generated with `mix kiln.gen.content`, so each one inherits the full
CMS spine — block editor, publishing workflow, version history, search, SEO,
taxonomy, and the shared policy model — with no extra wiring.

## Generated types

Two example types ship as a starting point (both with an excerpt for listings
and a published index):

```bash
mix kiln.gen.content Herb --excerpt --published
mix kiln.gen.content Condition --excerpt --published --plural conditions
```

- **`Herb`** (`KilnCMS.CMS.Herb`) — a TCM herb / materia-medica monograph
  (properties, channels, actions, cautions captured in the block body). Served
  at `/herbs/<slug>`.
- **`Condition`** (`KilnCMS.CMS.Condition`) — a patient-facing condition /
  educational resource. Served at `/conditions/<slug>`.

Extend the set the same way for the rest of a TCM catalogue, e.g.:

```bash
mix kiln.gen.content Formula --excerpt --published          # herbal formulas
mix kiln.gen.content Acupoint --published --plural acupoints # acupuncture points
mix kiln.gen.content Modality --published --plural modalities
```

Each generated type is immediately taggable and linkable to any other type via
the polymorphic `Tagging` / `ContentLink` layer — so an `Herb` can link to the
`Formula`s and `Condition`s it appears in with no join tables. After generating,
run `mix ash.codegen add_<plural> && mix ash.migrate`.

## Policy model

Health content reuses the standard CMS authorization model unchanged — there is
no separate health policy surface to maintain. The authoritative reference is
[`docs/policy-matrix.md`](policy-matrix.md); the health-specific summary:

| Actor | Herb / Condition (and any health type) |
|-------|----------------------------------------|
| **Anonymous (public)** | Read **published** records only, via the public delivery routes / headless APIs. The `state == :published` filter is the security boundary — drafts and in-review monographs are never reachable. |
| **Viewer** | Same as anonymous for content; no authoring. |
| **Editor** | Create/update health content, submit for review, manage drafts; cannot publish or return-to-draft. |
| **Admin** | Full lifecycle including publish, return-to-draft, archive, and destroy. |

Because health types are built on `KilnCMS.CMS.Content`, they get the same
`draft → in_review → published → archived` state machine, paper-trail history,
and field-level behaviour as `Page`/`Post`. The workflow-notification
preferences (#46) and accessibility work (#47) apply equally.

### Data-handling note (important)

These modules model **public educational health content** — herb monographs,
condition explainers, treatment information. They are **not** a system of record
for patient data: no PHI (personal health information) is stored in or
authorized through these resources. Anything published is world-readable by
design. Keep any future patient-specific or clinical-record features in a
separate, access-controlled domain with its own policies and audit trail — do
not extend these public content types to hold PHI.

## Disclaimers & SEO

Health content should carry appropriate medical disclaimers (rendered in the
block body or the public layout) and accurate JSON-LD. The existing SEO
structured-data pipeline applies to every content type; consider a
health-specific schema.org type (e.g. `MedicalWebPage`) as a follow-up if richer
health markup is needed.
