# Kiln vs Payload

<!-- seo-description: Kiln CMS compared with Payload: code-first modeling,
Next.js, databases, access control, workflows and hosting, with sources and a
check date on every claim. -->

> **Facts checked 2026-10-06.** Review owner: the Kiln maintainers. The
> sources are listed [at the end](#sources). See
> [how these pages stay honest](how-kiln-compares.md#how-these-pages-stay-honest).

Payload and Kiln are the closest pair on this list in philosophy. Both are
code-first and MIT-licensed, and both derive their APIs from content types you
declare. The big difference is where they live. Payload installs into a
Next.js app, in TypeScript. Kiln is its own Elixir application that serves the
site and the API together.

## At a glance

| | Payload (3.x) | Kiln (1.0) |
|---|---|---|
| Licence | MIT ([licence][payload-license]) | MIT ([licence][kiln-license]) |
| Ownership | Joined Figma, announced 2025-06-17. Payload says it remains open source and self-hosting is unchanged ([announcement][payload-figma]) | Independent open-source project ([repository][kiln-repo]) |
| Stack | TypeScript on Node.js 20.9+, Next.js-native since 3.0. MongoDB, PostgreSQL or SQLite ([databases][payload-db]) | Elixir and PostgreSQL 17 with pgvector ([deploy](../deploy.md)) |
| Latest major | 3.0.0, released 2024-11-19; 4.0 is in canary ([releases][payload-releases]) | 1.0.0, released 2026-10-02 ([changelog][kiln-changelog]) |
| Modeling | Code: collections and fields in the TypeScript config ([access control][payload-access]) | Code (`use KilnCMS.CMS.Content`), or the admin UI on a running site ([extending content](../extending-content.md)) |
| APIs | REST, GraphQL and a Local API; API keys per auth collection ([API keys][payload-keys]) | JSON:API and GraphQL, both read and write, plus MCP; scoped API keys ([API overview](../api.md)) |
| Access control | Functions you write, at collection, field and row level; no roles UI ([access control][payload-access]) | Declarative policies, plus custom roles and per-field grants in the admin UI ([RBAC](../granular-rbac.md)) |
| Drafts, versions, scheduling | Built in ([drafts][payload-drafts]) | Built in ([content lifecycles](../content-lifecycles.md)) |
| Approval workflows | Enterprise ([enterprise][payload-enterprise]) | Built in: draft, in review, published ([content lifecycles](../content-lifecycles.md)) |
| Localization | Built in, per field ([localization][payload-l10n]) | Built in, one record per locale ([localization](../localization-workflows.md)) |
| Live preview | Built in, iframe-based ([live preview][payload-preview]) | Built in for Kiln's own site; a bridge for external front ends ([bridge](../visual-editing-bridge.md)) |
| Managed hosting | Payload Cloud takes new projects from Enterprise teams only ([new project][payload-new]) | None. Self-host, or use a one-click platform ([deploy platforms](../deploy-platforms.md)) |

## Choose Payload if…

- **Your product is a Next.js app,** and you want the CMS inside it, in the
  same language and the same deploy.
- **You want MongoDB,** or SQLite at the edge.
- **You want access rules as plain functions** in the codebase you already
  have, rather than a policy layer.
- **Your team knows TypeScript,** and nobody knows Elixir.

## Choose Kiln if…

- **You want editors to change the model too.** Kiln's types can be declared in
  code *or* added on a live site, and both kinds get the same APIs
  ([extending content](../extending-content.md)).
- **You want roles and permissions administered, not programmed.** Custom
  roles, per-type scopes and per-field grants are managed in the UI, enforced
  by the same policies for the editor and every API ([RBAC](../granular-rbac.md)).
- **You want approval workflow in the free product.**
- **You want more than a CMS in one deployment.** Search, newsletters, its own
  mail server, paid memberships, webhooks and real-time updates ship inside
  Kiln ([newsletter](../newsletter.md), [memberships](../memberships.md),
  [webhooks](../webhooks.md)).
- **You do not want your content service tied to a front-end framework's
  release cycle.**

## Moving from Payload

There is no Payload importer yet. Kiln's portable JSON format and its write API
are the way in. See [content portability](../content-portability.md) and
[the JSON:API guide](../json-api.md).

## Sources

All checked 2026-10-06.

- [Payload licence][payload-license]
- [Payload is joining Figma][payload-figma]
- [Database adapters][payload-db]
- [Payload releases][payload-releases]
- [Access control][payload-access]
- [API keys][payload-keys]
- [Drafts][payload-drafts]
- [Enterprise features][payload-enterprise]
- [Localization][payload-l10n]
- [Live preview][payload-preview]
- [Payload Cloud: new project][payload-new]

[payload-license]: https://github.com/payloadcms/payload/blob/main/LICENSE.md
[payload-figma]: https://payloadcms.com/blog/payload-is-joining-figma
[payload-db]: https://payloadcms.com/docs/database/overview
[payload-releases]: https://github.com/payloadcms/payload/releases
[payload-access]: https://payloadcms.com/docs/access-control/overview
[payload-keys]: https://payloadcms.com/docs/authentication/api-keys
[payload-drafts]: https://payloadcms.com/docs/versions/drafts
[payload-enterprise]: https://payloadcms.com/enterprise
[payload-l10n]: https://payloadcms.com/docs/configuration/localization
[payload-preview]: https://payloadcms.com/docs/live-preview/overview
[payload-new]: https://payloadcms.com/new
[kiln-license]: https://github.com/The-Verscienta/kiln_cms/blob/main/LICENSE
[kiln-repo]: https://github.com/The-Verscienta/kiln_cms
[kiln-changelog]: https://github.com/The-Verscienta/kiln_cms/blob/main/CHANGELOG.md
