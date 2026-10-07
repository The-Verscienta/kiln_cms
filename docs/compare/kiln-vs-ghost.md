# Kiln vs Ghost

<!-- seo-description: Kiln CMS compared with Ghost: newsletters, paid
memberships, content modeling, APIs, multilingual and hosting, with sources and
a check date on every claim. -->

> **Facts checked 2026-10-06.** Review owner: the Kiln maintainers. The
> sources are listed [at the end](#sources). See
> [how these pages stay honest](how-kiln-compares.md#how-these-pages-stay-honest).

Ghost is the closest thing to Kiln among publishing platforms. Both are open
source, both send their own newsletters, and both sell paid memberships through
Stripe. The difference is scope. Ghost is deliberately a blog and newsletter,
and very good at it. Kiln is a general CMS with a headless API, which also does
newsletters and memberships.

## At a glance

| | Ghost (6.x) | Kiln (1.0) |
|---|---|---|
| Licence | MIT ([licence][ghost-license]) | MIT ([licence][kiln-license]) |
| Stack | Node.js. MySQL 8.0 or 8.4 is the supported production database, on Ubuntu with NGINX ([install][ghost-install]); SQLite can be configured ([config][ghost-config]) | Elixir and PostgreSQL 17 with pgvector ([deploy](../deploy.md)) |
| Latest major | 6.0, released 2025-08-04 ([release][ghost-6]) | 1.0.0, released 2026-10-02 ([changelog][kiln-changelog]) |
| Content model | Posts and pages, plus tags and authors. No custom content types or custom post fields ([schema][ghost-schema]) | Any number of content types, with typed fields, in code or the admin UI ([extending content](../extending-content.md)) |
| APIs | Content API (REST, read-only) and Admin API (REST, read/write); no GraphQL ([Content API][ghost-content-api], [Admin API][ghost-admin-api]) | JSON:API and GraphQL, both read and write, plus MCP ([API overview](../api.md)) |
| Newsletters | Built in. Self-hosted bulk email needs Mailgun ([config][ghost-config]) | Built in, sent by Kiln's own DKIM-signing mail server, or through an SMTP relay ([newsletter](../newsletter.md), [direct delivery](../direct-email-delivery.md)) |
| Paid memberships | Built in, through Stripe. Ghost(Pro) takes no transaction fee ([pricing][ghost-pricing]) | Built in, through Stripe; no Kiln fee ([memberships](../memberships.md)) |
| Multilingual | Not built in for content; Ghost suggests one install per language ([FAQ][ghost-i18n]) | Built in: one record per locale, fallback chains, hreflang ([localization](../localization-workflows.md)) |
| Roles | Fixed staff roles: Contributor, Author, Editor, Administrator, Owner ([staff][ghost-staff]) | Admin/editor/viewer plus custom roles with per-type and per-field grants ([RBAC](../granular-rbac.md)) |
| Real-time co-editing | No. A conflicting save is refused; a presence-indicator PR was closed unmerged ([PR][ghost-presence]) | Presence and field locks; simultaneous typing is off in production ([details](../multiplayer-preview.md)) |
| Managed hosting | Ghost(Pro) from $18/month billed yearly. Paid subscriptions start on the $29 Publisher plan ([pricing][ghost-pricing]) | None. Self-host, or use a one-click platform ([deploy platforms](../deploy-platforms.md)) |

## Choose Ghost if…

- **You are a publication, and that is all you need.** Ghost's member
  management, newsletter editor and paywall have had years of polish for
  exactly that job. Kiln's are newer.
- **You want it hosted for you,** with no fees on subscriptions. Ghost(Pro)
  does both, and Kiln offers no hosting.
- **You want a large theme marketplace** built for publishing.

## Choose Kiln if…

- **You publish more than posts.** Events, products, docs, people, anything
  with its own fields gets its own content type, with an API to match
  ([extending content](../extending-content.md)). Ghost has posts and pages.
- **You need a headless front end, or a write API beyond Ghost's Admin API.**
  Kiln's GraphQL and JSON:API are generated from the content model, and
  scoped API keys gate them ([API overview](../api.md)).
- **You publish in several languages** on one site
  ([localization](../localization-workflows.md)).
- **You want editorial workflow:** review states, scheduled releases,
  per-field permissions, version history
  ([content lifecycles](../content-lifecycles.md),
  [releases](../content-releases.md)).
- **You want to send newsletters without a third-party mail service.** Kiln
  can deliver straight to recipients' mail servers
  ([direct delivery](../direct-email-delivery.md)).

## Moving from Ghost

`mix kiln.import.ghost` reads Ghost's JSON export. It brings over posts, pages,
tags, feature and body images, SEO fields, authors and publication dates. It
keeps members-only posts gated, and turns every old URL into a redirect.
Members themselves move separately. See
[Migrating from Ghost](migrating-from-ghost.md).

## Sources

All checked 2026-10-06.

- [Ghost licence][ghost-license]
- [Installing Ghost on Ubuntu][ghost-install]
- [Ghost configuration][ghost-config]
- [Ghost 6.0.0 release][ghost-6]
- [Ghost database schema][ghost-schema]
- [Content API][ghost-content-api]
- [Admin API][ghost-admin-api]
- [Ghost pricing][ghost-pricing]
- [Ghost translation FAQ][ghost-i18n]
- [Staff roles][ghost-staff]
- [Editor presence PR (closed)][ghost-presence]

[ghost-license]: https://github.com/TryGhost/Ghost/blob/main/LICENSE
[ghost-install]: https://docs.ghost.org/install/ubuntu
[ghost-config]: https://docs.ghost.org/config
[ghost-6]: https://github.com/TryGhost/Ghost/releases/tag/v6.0.0
[ghost-schema]: https://github.com/TryGhost/Ghost/blob/main/ghost/core/core/server/data/schema/schema.js
[ghost-content-api]: https://docs.ghost.org/content-api
[ghost-admin-api]: https://docs.ghost.org/admin-api
[ghost-pricing]: https://ghost.org/pricing/
[ghost-i18n]: https://docs.ghost.org/faq/translation/
[ghost-staff]: https://docs.ghost.org/staff
[ghost-presence]: https://github.com/TryGhost/Ghost/pull/28230
[kiln-license]: https://github.com/The-Verscienta/kiln_cms/blob/main/LICENSE
[kiln-changelog]: https://github.com/The-Verscienta/kiln_cms/blob/main/CHANGELOG.md
