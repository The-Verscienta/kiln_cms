# Kiln vs WordPress

<!-- seo-description: Kiln CMS compared with WordPress: licence, stack, APIs,
content modeling, multilingual, newsletters and hosting, with sources and a
check date on every claim. -->

> **Facts checked 2026-10-06.** Review owner: the Kiln maintainers. The
> sources are listed [at the end](#sources). See
> [how these pages stay honest](how-kiln-compares.md#how-these-pages-stay-honest).

WordPress runs 40.1% of all websites and has 58.6% of the CMS market
([W3Techs][w3techs]). Nothing else comes close on themes, plugins, hosts or
people who already know how to use it. Kiln does not try to match that. It is
for teams who want structured content, a headless API and editorial workflow
built in, rather than assembled from plugins.

## At a glance

| | WordPress (self-hosted, 7.1) | Kiln (1.0) |
|---|---|---|
| Licence | GPL-2.0-or-later ([licence][wp-license]) | MIT ([licence][kiln-license]) |
| Stack | PHP and MySQL/MariaDB; PHP 8.3+ and MySQL 8.0+ / MariaDB 10.11+ recommended ([requirements][wp-req]) | Elixir and PostgreSQL 17 with pgvector, one OTP release ([deploy](../deploy.md)) |
| Latest major | 7.1, released 2026-08-19 ([releases][wp-releases]) | 1.0.0, released 2026-10-02 ([changelog][kiln-changelog]) |
| Read/write API | REST in core; Application Passwords or cookie auth; OAuth and JWT need plugins ([auth docs][wp-rest-auth]) | JSON:API and GraphQL, both read and write, plus MCP; scoped API keys ([JSON:API](../json-api.md), [GraphQL](../headless-graphql-api.md), [MCP](../mcp.md)) |
| GraphQL | Plugin (WPGraphQL) ([plugin][wpgraphql]) | Built in, with subscriptions ([GraphQL](../headless-graphql-api.md)) |
| Custom content types | Registered in code; no admin UI in core, so plugins such as ACF fill the gap ([handbook][wp-cpt]) | In code, or with no deploy at `/editor/types` ([extending content](../extending-content.md)) |
| Roles | Five fixed roles, plus Super Admin on multisite; custom roles in code or by plugin ([roles][wp-roles]) | Admin/editor/viewer, plus custom roles with per-type and per-field grants in the UI ([RBAC](../granular-rbac.md)) |
| Multilingual | Not in core; needs a plugin or multisite ([docs][wp-i18n]) | Built in: one record per locale, fallback chains, hreflang ([localization](../localization-workflows.md)) |
| Newsletters and paid memberships | Not in core. Jetpack adds them and charges 2–10% on top of Stripe's fees, depending on plan ([Jetpack fees][jetpack-fees]) | Built in. Its own DKIM-signing mail server, and Stripe memberships with no Kiln fee ([newsletter](../newsletter.md), [memberships](../memberships.md)) |
| Real-time co-editing | Not shipped. Pulled from 7.0 during RC, and not in 7.1 ([7.0 notes][wp-70], [7.1][wp-71]) | Presence and field locks; simultaneous typing is off in production ([details](../multiplayer-preview.md)) |
| Plugins | 70,529 in the directory ([API count][wp-plugins]) | Compile-time plugins only; no runtime marketplace ([why](../plugin-extensibility.md)) |
| Managed hosting | Many hosts, including WordPress.com from $4/month billed annually ([pricing][wpcom-pricing]) | None. Self-host, or use a one-click platform ([deploy platforms](../deploy-platforms.md)) |

## Choose WordPress if…

- **The ecosystem is the point.** You need a specific theme, plugin or agency,
  or editors who already know the dashboard. Seventy thousand plugins is a
  real advantage, not a vanity number.
- **You want cheap, managed hosting today.** Kiln has none.
- **Your team writes PHP**, and nobody wants to run a BEAM application.

## Choose Kiln if…

- **You are going headless, or will later.** In Kiln the write API, GraphQL,
  webhooks and scoped API keys are core features, governed by the same
  policies as the editor ([API overview](../api.md)). In WordPress you assemble
  them from plugins and maintain them yourself.
- **Your content is structured.** Content types, fields, validation and
  per-field permissions come from one declaration, and editors can add types
  without a deploy ([extending content](../extending-content.md)).
- **You publish in several languages**, and want translation status and
  fallbacks without a plugin ([localization](../localization-workflows.md)).
- **You want fewer moving parts.** Kiln has no plugin update treadmill. Search,
  email, jobs and caching ship inside one release that needs only PostgreSQL
  ([deploy](../deploy.md)).

## Moving from WordPress

`mix kiln.import.wordpress` reads WordPress's own export file. It brings over
posts, pages, categories, tags, featured and body images, publication dates and
authors, and it turns every old permalink into a redirect. See
[Migrating from WordPress](migrating-from-wordpress.md).

## Sources

All checked 2026-10-06.

- [W3Techs: CMS usage][w3techs]
- [WordPress licence][wp-license]
- [WordPress requirements][wp-req]
- [WordPress releases][wp-releases]
- [REST API authentication][wp-rest-auth]
- [WPGraphQL][wpgraphql]
- [Registering custom post types][wp-cpt]
- [Roles and capabilities][wp-roles]
- [Multilingual WordPress][wp-i18n]
- [Jetpack transaction fees][jetpack-fees]
- [WordPress 7.0 development notes][wp-70]
- [WordPress 7.1 "Mary Lou"][wp-71]
- [Plugin directory API][wp-plugins]
- [WordPress.com pricing][wpcom-pricing]

[w3techs]: https://w3techs.com/technologies/overview/content_management
[wp-license]: https://core.svn.wordpress.org/trunk/license.txt
[wp-req]: https://wordpress.org/about/requirements/
[wp-releases]: https://wordpress.org/download/releases/
[wp-rest-auth]: https://developer.wordpress.org/rest-api/using-the-rest-api/authentication/
[wpgraphql]: https://wordpress.org/plugins/wp-graphql/
[wp-cpt]: https://developer.wordpress.org/plugins/post-types/registering-custom-post-types/
[wp-roles]: https://wordpress.org/documentation/article/roles-and-capabilities/
[wp-i18n]: https://developer.wordpress.org/advanced-administration/wordpress/multilingual/
[jetpack-fees]: https://jetpack.com/support/jetpack-earn-transaction-fees/
[wp-70]: https://make.wordpress.org/core/tag/7.0/
[wp-71]: https://wordpress.org/news/2026/08/mary-lou/
[wp-plugins]: https://api.wordpress.org/plugins/info/1.2/?action=query_plugins&request[per_page]=1
[wpcom-pricing]: https://wordpress.com/pricing/
[kiln-license]: https://github.com/The-Verscienta/kiln_cms/blob/main/LICENSE
[kiln-changelog]: https://github.com/The-Verscienta/kiln_cms/blob/main/CHANGELOG.md
