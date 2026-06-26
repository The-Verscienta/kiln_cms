# Getting started

Onboarding path for new contributors to KilnCMS — a headless + traditional CMS
on the STAPLE stack (Phoenix · Tailwind · LiveView · Elixir) with the **Ash
Framework** at its core. This is the landing page for `mix docs`; it points you
at the right guide for whatever you're doing.

## 1. Run it locally

Prerequisites: Elixir 1.18+ / OTP 27+, Docker (for Postgres).

```bash
docker compose up -d postgres   # only required service
mix setup                       # deps.get + ash.setup + assets.setup
mix phx.server
```

Then visit <http://localhost:4000> (app), `/admin` (AshAdmin CRUD tool),
`/editor` (the authoring UI), `/gql/playground`, and `/api/json/swaggerui`. Full
details and the optional infra profiles (cache/search/storage) are in the
[README](../README.md).

## 2. Learn the architecture

- **[README](../README.md)** — stack, content model, and the resolved
  architectural decisions (D1–D8).
- `KilnCMS_Project_Plan.md` — the full vision and phase plan.
- **Domain code** lives in `lib/kiln_cms/` (Ash resources, grouped by domain:
  `cms/`, `accounts/`, `analytics/`, …). Web/LiveView code is in
  `lib/kiln_cms_web/`.
- Ash is the backbone: content is modeled as Ash resources with policies, a
  publishing state machine, and paper-trail history. Read the resource modules
  (e.g. `lib/kiln_cms/cms/content.ex`) before changing behaviour.

## 3. Find the right guide

| You want to… | Read |
|--------------|------|
| Understand who-can-do-what | [Authorization policy matrix](policy-matrix.md) |
| Style the UI | [Design system](design-system.md) |
| Use the editor | [Editor shortcuts](editor-shortcuts.md) |
| Consume the APIs | [API overview](api.md), [GraphQL](headless-graphql-api.md), [JSON:API](json-api.md) |
| Work on search | [Search roadmap](search-roadmap.md), [Semantic search plan](semantic-search-plan.md) |
| Deploy | [Coolify deployment](deployment-coolify.md), [Releases & migrations](releases-and-migrations.md), [Domain & SSL](domain-and-ssl.md) |
| Operate in prod | [Observability](observability.md), [Backups](backups.md), [CDN](cdn.md), [Threat model](threat-model.md) |

## 4. Make a change

1. Create a branch.
2. Add or modify Ash resources / LiveViews. If you change a resource's schema or
   actions, regenerate migrations + snapshots:
   ```bash
   mix ash.codegen <short_name>
   ```
   Commit the generated `priv/repo/migrations/*` and
   `priv/resource_snapshots/*` together with your code — CI fails on drift
   (`mix ash.codegen --check`).
3. Write tests next to the code (`test/` mirrors `lib/`). Ash policy changes
   need policy tests; see existing `*_policies_test.exs`.
4. Before pushing, run the full gate:
   ```bash
   mix format
   mix precommit   # compile (warnings as errors), credo, sobelow,
                   # deps.audit, and the test suite
   ```
   `precommit` checks formatting strictly and does **not** auto-fix — run
   `mix format` first.
5. Open a PR. CI runs the same checks plus Dialyzer, migration-drift, and the
   Playwright E2E suite. See [CONTRIBUTING](../CONTRIBUTING.md).

## 5. Generate the docs

```bash
mix docs           # builds the full API reference + these guides into doc/
open doc/index.html
```

This page is the docs landing page; every guide above is grouped in the sidebar.
