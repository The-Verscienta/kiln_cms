# Getting started

KilnCMS is a CMS that is headless *and* traditional: the same content is served
through JSON:API, GraphQL, MCP and a RAG endpoint, and rendered directly by the
app. It runs on Phoenix · Ash · LiveView · Tailwind · Elixir, with
the **Ash Framework** at its core — resources, not schemas, are the source of
truth for storage, actions, authorization and the publishing state machine.

A KilnCMS install is meant to be *overlaid*, not forked: the reusable core lives
in `lib/`, and a downstream site adds its own content types under `projects/`.

This page is the landing page for `mix docs` and the orientation path for a new
contributor. It points at the right guide rather than restating it.

## 1. Run it locally

Prerequisites: Elixir 1.19.3+ / OTP 27+, Docker (for Postgres), Node.js.

`.tool-versions` pins the exact Elixir/OTP that CI and the release image build
on — `asdf install` (or `mise install`) reproduces it. Developing on something
newer is fine and expected; `mix kiln.toolchain.check` compares the *declared*
versions to each other, never to the one you are running.

```bash
docker compose up -d postgres   # the only required service
mix setup                       # deps.get + ash.setup + assets.setup + npm install
mix phx.server
```

`mix setup` seeds a demo admin and editor. The full setup — optional infra
profiles for cache, search and object storage, plus the environment quirks that
bite people (PATH, spaced/iCloud paths, the `igniter` dependency) — is in
[Overview](../README.md) and [Contributing](../CONTRIBUTING.md).

Once it boots, the surfaces worth opening:

| URL | What it is |
|-----|-----------|
| `/` | the delivered site |
| `/editor` | the authoring UI — this is the product |
| `/admin` | AshAdmin raw CRUD (dev only) |
| `/gql` · `/gql/playground` | GraphQL endpoint and playground |
| `/api/json/swaggerui` | JSON:API browser over the OpenAPI spec |
| `/mcp` | the MCP endpoint for LLM authoring |

## 2. Read the architecture

- **`lib/kiln_cms/`** — the domain, split by concern: `cms/` (content, blocks,
  taxonomy), `accounts/`, `media/`, `search/`, `firing/` (publishing to served
  artifacts), `analytics/`, `mail/`, and so on. Each has a matching Ash domain
  module beside it (`cms.ex`, `accounts.ex`, …).
- **`lib/kiln_cms_web/`** — endpoint, router, LiveViews (`*Live`), controllers
  and the component kit.
- **`lib/kiln/`** — the extension points a downstream project or plugin builds
  against: `Kiln.Plugin`, `Kiln.Block`, `Kiln.FieldType`, `Kiln.Advisory`.
- **`projects/`** — downstream overlays. `projects/acupuncture/` is the worked
  example.
- **`lib/mix/tasks/`** — the operator surface (`mix kiln.*`).

Read the resource modules before changing behaviour — `lib/kiln_cms/cms/content.ex`
is the centre of gravity. Its policies, state machine and paper-trail history are
declarative, so the module *is* the specification.

## 3. Find the right guide

| You want to… | Read |
|--------------|------|
| Use the editor | [Editor shortcuts](editor-shortcuts.md), [Editorial advisories](advisories.md) |
| Model new content | [Extending the content model](extending-content.md) |
| Understand who can do what | [Authorization policy matrix](policy-matrix.md), [Granular RBAC](granular-rbac.md) |
| Consume the content headlessly | [Headless consumer guide](headless-consumer-guide.md) — it routes you to [JSON:API](json-api.md), [GraphQL](headless-graphql-api.md), [MCP](mcp.md) or [RAG](rag.md) |
| Wire up an external front end | [Visual-editing bridge](visual-editing-bridge.md), [Static export](static-export.md) |
| Style the admin UI | [Design system](design-system.md) |
| Write a plugin | [Runtime extensibility](plugin-extensibility.md) |
| Configure an install | [Environment variables](environment-variables.md) |
| Operate it in production | [Backups](backups.md), [Observability](observability.md), [Performance](performance.md), [Resilient delivery](resilient-delivery.md) |
| Cut a release | [Releasing Kiln](releasing.md) |
| Assess its security posture | [Threat model](threat-model.md), [Data flows & retention](data-flows.md) |

Everything else is in the sidebar, grouped the same way. Two groups are archives
rather than guidance: **Design notes & decision records** holds the plans behind
shipped features, and **Audits & release checklists** holds point-in-time
material that was true on its date and is kept for the record.

## 4. Make a change

1. Branch off `main`.
2. Model in Ash. If you change a resource's attributes or actions, regenerate
   migrations and snapshots — never hand-write them:

   ```bash
   mix ash.codegen <short_name>
   ```

   Commit the generated `priv/repo/migrations/*` and `priv/resource_snapshots/*`
   with your code; CI fails on drift via `mix ash.codegen --check`.
3. Every action gets a domain code interface, and every resource gets policies.
   Policy changes need policy tests — see the existing `*_policies_test.exs`.
4. Run the gate:

   ```bash
   mix format
   mix precommit
   ```

   If you touched a file containing `gettext(...)`, also run
   `mix gettext.extract --merge && git diff --exit-code -- priv/gettext` — that
   gate is CI-only and drifting line references alone will fail it.

[Contributing](../CONTRIBUTING.md) has the full workflow, the reasoning behind
each rule, and the commit and PR conventions.

## 5. Build these docs

```bash
mix docs
open doc/index.html
```

The output covers every module in `lib/` plus every guide under `docs/`. CI
builds it too, so a renamed guide or a dead cross-reference fails a check
instead of rotting.
