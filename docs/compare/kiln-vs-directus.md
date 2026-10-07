# Kiln vs Directus

<!-- seo-description: Kiln CMS compared with Directus: the v12 licence change,
databases, permissions, collaborative editing, workflows and pricing, with
sources and a check date on every claim. -->

> **Facts checked 2026-10-06.** Review owner: the Kiln maintainers. The
> sources are listed [at the end](#sources). See
> [how these pages stay honest](how-kiln-compares.md#how-these-pages-stay-honest).

Directus is a data platform first. Point it at an SQL database and it turns the
tables into an admin app and an API. Kiln is a content system first. It owns its
schema and adds publishing, delivery and editorial workflow on top. Since
Directus 12 the two also differ on licence, which matters more than any single
feature.

## At a glance

| | Directus (12.x) | Kiln (1.0) |
|---|---|---|
| Licence | MSCL-1.0-GPL since v12. Each version becomes GPL-3.0 four years after release; "Competing Use" is prohibited ([licence][directus-license], [v12.0.0][directus-12]) | MIT ([licence][kiln-license]) |
| Free to use | Under $5M annual revenue **and** fewer than 50 employees, with a registered key (Open Innovation Grant); otherwise the free Core tier, capped at 3 seats, 25 collections and 5 Flows ([licensing][directus-licensing], [pricing][directus-pricing]) | Free for everyone, with no caps |
| Without a licence key | From v12, SSO and custom permission rules are switched off. After a 30-day grace period on upgrade, GraphQL, WebSockets and MCP are disabled and non-admin login is blocked ([v12 breaking changes][directus-v12-breaking]) | Not applicable |
| Stack | Node.js. PostgreSQL, MySQL, Oracle, SQL Server, SQLite or CockroachDB ([databases][directus-db]) | Elixir and PostgreSQL 17 with pgvector ([deploy](../deploy.md)) |
| Latest major | 12.0.0, released 2026-06-10 ([releases][directus-releases]) | 1.0.0, released 2026-10-02 ([changelog][kiln-changelog]) |
| Modeling | Database-first: introspects existing SQL tables, or you model in its Data Studio ([overview][directus-overview]) | Kiln owns its schema; types in code or in the admin UI ([extending content](../extending-content.md)) |
| APIs | REST, GraphQL, WebSockets and MCP ([overview][directus-overview]) | JSON:API and GraphQL (with subscriptions), both read and write, plus MCP ([API overview](../api.md)) |
| Permissions | Roles and policies, field-level permissions, item-level filter rules ([access control][directus-access]) | Roles, custom roles, per-type and per-field grants ([RBAC](../granular-rbac.md)). There are no arbitrary per-item filter rules |
| Real-time co-editing | Yes, since 11.15: presence and field locking ([collaborative editing][directus-collab]) | Presence and field locks; simultaneous typing is off in production ([details](../multiplayer-preview.md)) |
| Scheduled publishing | Not native; built with a Flows cron trigger ([recipe][directus-schedule]) | Built in, plus content releases ([releases](../content-releases.md)) |
| Managed hosting | Team plan $499/month billed annually; Cloud add-on $99/month for Core and Grant users ([pricing][directus-pricing]) | None. Self-host, or use a one-click platform ([deploy platforms](../deploy-platforms.md)) |

## Choose Directus if…

- **You already have a database** and want an admin app and API over it
  without migrating. Kiln cannot do that; it owns its schema.
- **You need Oracle, SQL Server, MySQL or CockroachDB.**
- **You want fine-grained permission filters** per item, written as rules in
  the UI.
- **Live co-editing matters today.** Directus ships presence and field locking
  over WebSockets.
- **Your organisation qualifies for the free grant,** or the paid tiers fit
  your budget.

## Choose Kiln if…

- **You want an open-source licence with no conditions.** Kiln is MIT. No
  revenue threshold, no seat cap, no key to register, and no features that
  switch off without one.
- **You are publishing, not just storing data.** Drafts, review, scheduled
  releases, versioned and pre-rendered delivery, a public website, SEO,
  newsletters and memberships are built in ([content lifecycles](../content-lifecycles.md),
  [resilient delivery](../resilient-delivery.md), [SEO](../seo.md)).
- **You want PostgreSQL as the only dependency,** with search and email
  included ([deploy](../deploy.md)).

## Moving from Directus

There is no Directus importer yet. Kiln's portable JSON format and its write
API are the way in. See [content portability](../content-portability.md) and
[the JSON:API guide](../json-api.md).

## Sources

All checked 2026-10-06.

- [Directus licence][directus-license]
- [v12.0.0 release notes][directus-12]
- [Licensing overview][directus-licensing]
- [Directus pricing][directus-pricing]
- [Version 12 breaking changes][directus-v12-breaking]
- [Database configuration][directus-db]
- [Directus releases][directus-releases]
- [Getting started overview][directus-overview]
- [Access control][directus-access]
- [Collaborative editing][directus-collab]
- [Scheduling content with Flows][directus-schedule]

[directus-license]: https://github.com/directus/directus/blob/main/license
[directus-12]: https://github.com/directus/directus/releases/tag/v12.0.0
[directus-licensing]: https://directus.com/docs/licensing/overview
[directus-pricing]: https://directus.com/pricing
[directus-v12-breaking]: https://directus.com/docs/releases/breaking-changes/version-12
[directus-db]: https://directus.com/docs/configuration/database
[directus-releases]: https://github.com/directus/directus/releases
[directus-overview]: https://directus.com/docs/getting-started/overview
[directus-access]: https://directus.com/docs/guides/auth/access-control
[directus-collab]: https://directus.com/docs/guides/content/collaborative-editing
[directus-schedule]: https://directus.com/docs/tutorials/workflows/schedule-future-content-with-directus-automate
[kiln-license]: https://github.com/The-Verscienta/kiln_cms/blob/main/LICENSE
[kiln-changelog]: https://github.com/The-Verscienta/kiln_cms/blob/main/CHANGELOG.md
