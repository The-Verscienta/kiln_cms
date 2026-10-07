# How Kiln compares

<!-- seo-description: Honest, sourced comparisons of Kiln CMS with WordPress,
Ghost, Strapi, Payload and Directus, plus step-by-step migration guides from
WordPress and Ghost. -->

> **Facts checked 2026-10-06.** Review owner: the Kiln maintainers
> ([@The-Verscienta](https://github.com/The-Verscienta)).

These pages compare Kiln with the systems people most often weigh it against.
Each page says where the other system is the better choice, as well as where
Kiln is.

| Compare | In one line |
|---|---|
| [Kiln vs WordPress](kiln-vs-wordpress.md) | The default choice. It has the largest ecosystem by far, built on PHP and plugins. |
| [Kiln vs Ghost](kiln-vs-ghost.md) | A focused, polished platform for publishing, newsletters and paid memberships. |
| [Kiln vs Strapi](kiln-vs-strapi.md) | An open-source headless CMS on Node, with models built in the admin UI and a managed cloud. |
| [Kiln vs Payload](kiln-vs-payload.md) | A code-first headless CMS in TypeScript that lives inside a Next.js app. |
| [Kiln vs Directus](kiln-vs-directus.md) | A data platform that sits on top of an SQL database, under a source-available licence. |

Moving over:

- [Migrating from WordPress](migrating-from-wordpress.md): `mix kiln.import.wordpress`
- [Migrating from Ghost](migrating-from-ghost.md): `mix kiln.import.ghost`

## Feature grid

The main differences side by side. Each cell links to its source: Kiln's own
documentation for Kiln, and the vendor's documentation, pricing page or
licence for everything else. All checked 2026-10-06. Each product's page has
the detail behind a cell.

| | Kiln | [WordPress](kiln-vs-wordpress.md) | [Ghost](kiln-vs-ghost.md) | [Strapi](kiln-vs-strapi.md) | [Payload](kiln-vs-payload.md) | [Directus](kiln-vs-directus.md) |
|---|---|---|---|---|---|---|
| **Licence** | [MIT][kiln-license] | [GPL-2.0-or-later][wp-license] | [MIT][ghost-license] | [MIT, plus paid enterprise code][strapi-license] | [MIT][payload-license] | [Source-available (MSCL-1.0-GPL)][directus-license] |
| **Stack** | [Elixir][kiln-deploy] | [PHP][wp-req] | [Node.js][ghost-install] | [Node.js][strapi-db] | [TypeScript, inside Next.js][payload-db] | [Node.js][directus-db] |
| **Databases** | [PostgreSQL][kiln-deploy] | [MySQL, MariaDB][wp-req] | [MySQL][ghost-install] | [PostgreSQL, MySQL, MariaDB, SQLite][strapi-db] | [MongoDB, PostgreSQL, SQLite][payload-db] | [PostgreSQL, MySQL, Oracle, SQL Server, SQLite, CockroachDB][directus-db] |
| **Custom content types** | [Yes, in code or the admin UI][kiln-types] | [In code, or by plugin][wp-cpt] | [No: posts and pages][ghost-schema] | [Yes, admin UI in development][strapi-ctb] | [Yes, in code][payload-access] | [Yes, from your database][directus-overview] |
| **Read/write API** | [Yes][kiln-api] | [Yes (REST)][wp-rest-auth] | [Yes (Admin API)][ghost-admin-api] | [Yes][strapi-tokens] | [Yes][payload-keys] | [Yes][directus-overview] |
| **GraphQL** | [Built in][kiln-graphql] | [Plugin][wpgraphql] | [No][ghost-content-api] | [Built in][strapi-self] | [Built in][payload-keys] | [Built in][directus-overview] |
| **Custom roles** | [Yes, in the admin UI][kiln-rbac] | [In code, or by plugin][wp-roles] | [No: fixed roles][ghost-staff] | [Yes][strapi-rbac] | [Written as code][payload-access] | [Yes][directus-access] |
| **Multilingual content** | [Built in][kiln-l10n] | [Plugin][wp-i18n] | [No: one site per language][ghost-i18n] | [Built in][strapi-i18n] | [Built in][payload-l10n] | [Built in][directus-l10n] |
| **Real-time co-editing** | [Presence and field locks; typing together is off in production][kiln-coedit] | [No][wp-71] | [No][ghost-presence] | [Not documented][strapi-preview] | [Not documented][payload-preview] | [Yes][directus-collab] |
| **Newsletters and paid memberships** | [Built in][kiln-newsletter] | [Plugin (Jetpack)][jetpack-fees] | [Built in][ghost-pricing] | — | — | — |
| **Plugins** | [Compile-time only][kiln-plugins] | [70,529 in the directory][wp-plugins] | [Theme and integration directories][ghost-integrations] | [Marketplace][strapi-market] | [Official plugins, no marketplace][payload-plugins] | [Marketplace][directus-extensions] |
| **Managed hosting** | [None][kiln-platforms] | [WordPress.com, from $4/month billed annually][wpcom-pricing] | [Ghost(Pro), from $18/month billed yearly][ghost-pricing] | [Strapi Cloud, from $35 per project per month][strapi-cloud] | [Enterprise teams only][payload-new] | [Cloud add-on, $99/month][directus-pricing] |
| **Move to Kiln with** | — | [`mix kiln.import.wordpress`][kiln-wp-import] | [`mix kiln.import.ghost`][kiln-ghost-import] | [JSON envelope or API][kiln-portability] | [JSON envelope or API][kiln-portability] | [JSON envelope or API][kiln-portability] |

A dash means the feature is not one these pages compare for that product. It
does not mean the product cannot do it.

## The short version

Kiln is a self-hosted CMS built on Elixir, Phoenix and Ash. One deployment
serves your website and a read/write headless API (JSON:API, GraphQL, MCP).
It needs nothing beyond PostgreSQL. Search, outbound email (its own
DKIM-signing mail server), background jobs and real-time updates all ship
inside it.

What Kiln gives up to get there:

- **No managed hosting.** You run it, or someone runs it for you.
- **No runtime plugin marketplace.** Plugins are compile-time code
  ([why](../plugin-extensibility.md)).
- **No production co-editing yet.** Several people can be in one document,
  with presence and field locks, but they cannot type in the same field at
  once ([details](../multiplayer-preview.md)).
- **It is young.** 1.0.0 shipped on
  [2026-10-02](https://github.com/The-Verscienta/kiln_cms/blob/main/CHANGELOG.md).
- **Fewer people know Elixir** than PHP or JavaScript.

If none of those rule it out, the pages above show where Kiln is ahead.

## How these pages stay honest

Facts about other products go stale, so the pages follow four rules:

1. **Every claim about another product links to its source.** We prefer the
   vendor's own docs, pricing page or licence file. A claim we could not trace
   to a primary source is left out, not paraphrased from a blog.
2. **Every page shows the date its facts were checked.** Prices, licences and
   version numbers are only as good as that date. If you are reading this long
   after it, check the linked source.
3. **Claims about Kiln link to Kiln's own documentation,** so you can check
   them as well.
4. **A named owner reviews every page** at least every 90 days, and whenever
   a compared product ships a new major version or changes its licence or
   pricing. The review re-checks every source and updates the date.

Found something wrong or out of date?
[Open an issue](https://github.com/The-Verscienta/kiln_cms/issues/new) with a
link to the source. Corrections that make a competitor look better are just
as welcome.

[kiln-license]: https://github.com/The-Verscienta/kiln_cms/blob/main/LICENSE
[kiln-deploy]: ../deploy.md
[kiln-types]: ../extending-content.md
[kiln-api]: ../api.md
[kiln-graphql]: ../headless-graphql-api.md
[kiln-rbac]: ../granular-rbac.md
[kiln-l10n]: ../localization-workflows.md
[kiln-coedit]: ../multiplayer-preview.md
[kiln-newsletter]: ../newsletter.md
[kiln-plugins]: ../plugin-extensibility.md
[kiln-platforms]: ../deploy-platforms.md
[kiln-wp-import]: migrating-from-wordpress.md
[kiln-ghost-import]: migrating-from-ghost.md
[kiln-portability]: ../content-portability.md
[wp-license]: https://core.svn.wordpress.org/trunk/license.txt
[wp-req]: https://wordpress.org/about/requirements/
[wp-cpt]: https://developer.wordpress.org/plugins/post-types/registering-custom-post-types/
[wp-rest-auth]: https://developer.wordpress.org/rest-api/using-the-rest-api/authentication/
[wpgraphql]: https://wordpress.org/plugins/wp-graphql/
[wp-roles]: https://wordpress.org/documentation/article/roles-and-capabilities/
[wp-i18n]: https://developer.wordpress.org/advanced-administration/wordpress/multilingual/
[wp-71]: https://wordpress.org/news/2026/08/mary-lou/
[jetpack-fees]: https://jetpack.com/support/jetpack-earn-transaction-fees/
[wp-plugins]: https://api.wordpress.org/plugins/info/1.2/?action=query_plugins&request[per_page]=1
[wpcom-pricing]: https://wordpress.com/pricing/
[ghost-license]: https://github.com/TryGhost/Ghost/blob/main/LICENSE
[ghost-install]: https://docs.ghost.org/install/ubuntu
[ghost-schema]: https://github.com/TryGhost/Ghost/blob/main/ghost/core/core/server/data/schema/schema.js
[ghost-admin-api]: https://docs.ghost.org/admin-api
[ghost-content-api]: https://docs.ghost.org/content-api
[ghost-staff]: https://docs.ghost.org/staff
[ghost-i18n]: https://docs.ghost.org/faq/translation/
[ghost-presence]: https://github.com/TryGhost/Ghost/pull/28230
[ghost-pricing]: https://ghost.org/pricing/
[ghost-integrations]: https://ghost.org/integrations/
[strapi-license]: https://github.com/strapi/strapi/blob/develop/LICENSE
[strapi-db]: https://docs.strapi.io/cms/configurations/database
[strapi-ctb]: https://docs.strapi.io/cms/features/content-type-builder
[strapi-tokens]: https://docs.strapi.io/cms/features/api-tokens
[strapi-self]: https://strapi.io/pricing-self-hosted
[strapi-rbac]: https://docs.strapi.io/cms/features/rbac
[strapi-i18n]: https://docs.strapi.io/cms/features/internationalization
[strapi-preview]: https://docs.strapi.io/cms/features/preview
[strapi-market]: https://market.strapi.io
[strapi-cloud]: https://strapi.io/pricing-cloud
[payload-license]: https://github.com/payloadcms/payload/blob/main/LICENSE.md
[payload-db]: https://payloadcms.com/docs/database/overview
[payload-access]: https://payloadcms.com/docs/access-control/overview
[payload-keys]: https://payloadcms.com/docs/authentication/api-keys
[payload-l10n]: https://payloadcms.com/docs/configuration/localization
[payload-preview]: https://payloadcms.com/docs/live-preview/overview
[payload-plugins]: https://payloadcms.com/docs/plugins/overview
[payload-new]: https://payloadcms.com/new
[directus-license]: https://github.com/directus/directus/blob/main/license
[directus-db]: https://directus.com/docs/configuration/database
[directus-overview]: https://directus.com/docs/getting-started/overview
[directus-access]: https://directus.com/docs/guides/auth/access-control
[directus-l10n]: https://directus.com/docs/configuration/translations
[directus-collab]: https://directus.com/docs/guides/content/collaborative-editing
[directus-extensions]: https://directus.com/docs/guides/extensions/overview
[directus-pricing]: https://directus.com/pricing
