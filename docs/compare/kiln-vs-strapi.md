# Kiln vs Strapi

<!-- seo-description: Kiln CMS compared with Strapi: licence, databases, APIs,
roles, review workflows, localization and cloud pricing, with sources and a
check date on every claim. -->

> **Facts checked 2026-10-06.** Review owner: the Kiln maintainers. The
> sources are listed [at the end](#sources). See
> [how these pages stay honest](how-kiln-compares.md#how-these-pages-stay-honest).

Strapi is the best-known open-source headless CMS. You model content in its
admin UI, it serves REST and GraphQL, and it has a managed cloud. Kiln covers
the same headless ground. It also serves your website itself and ships editorial
workflow in the free product, where Strapi keeps several of those features on
paid plans.

## At a glance

| | Strapi (5.x) | Kiln (1.0) |
|---|---|---|
| Licence | MIT, except code under `ee/` directories, which is under the Strapi Enterprise licence ([licence][strapi-license]) | MIT, all of it ([licence][kiln-license]) |
| Stack | Node.js. PostgreSQL 14+, MySQL 8.0+, MariaDB 10.3+ or SQLite ([databases][strapi-db]) | Elixir and PostgreSQL 17 with pgvector ([deploy](../deploy.md)) |
| Latest major | 5.0.0, released 2024-09-18 ([releases][strapi-releases]) | 1.0.0, released 2026-10-02 ([changelog][kiln-changelog]) |
| APIs | REST and GraphQL; API tokens can be read-only, full access or custom ([API tokens][strapi-tokens]) | JSON:API and GraphQL, both read and write, plus MCP; scoped API keys ([API overview](../api.md)) |
| Modeling | Content-Type Builder in the admin UI, which works in development only and writes the model to code ([builder][strapi-ctb]) | In code, or in the admin UI on a running site with no deploy ([extending content](../extending-content.md)) |
| Custom roles, field-level permissions | Free ([RBAC][strapi-rbac]) | Free ([RBAC](../granular-rbac.md)) |
| Review workflows | Enterprise only ([review workflows][strapi-review]) | Built in: draft, in review, published, with notifications ([content lifecycles](../content-lifecycles.md)) |
| Content history | Growth plan (14 days) or Enterprise ([history][strapi-history]) | Built in: every version kept, with a tamper-evident history ([provenance](../provenance.md)) |
| Scheduled publishing | Releases, on Growth or Enterprise ([releases][strapi-rel]) | Built in: scheduled publish and content releases ([releases](../content-releases.md)) |
| SSO | Enterprise, or Growth plus a $150/month add-on ([SSO][strapi-sso]) | Built in: OpenID Connect, one provider per install ([SSO](../sso.md)) |
| Audit logs | Enterprise only ([audit logs][strapi-audit]) | Built in: an editorial audit trail per item ([governance](../governance-dashboard.md)) |
| Localization | Free and built in, but off by default ([i18n][strapi-i18n]) | Built in ([localization](../localization-workflows.md)) |
| Managed hosting | Strapi Cloud from $35 per project per month; self-hosted Growth licence $45/month for 3 seats ([cloud][strapi-cloud], [self-hosted][strapi-self]) | None. Self-host, or use a one-click platform ([deploy platforms](../deploy-platforms.md)) |

## Choose Strapi if…

- **Your team lives in JavaScript,** and wants to extend the CMS in it.
- **You want managed hosting** from the vendor.
- **You need MySQL, MariaDB or SQLite.** Kiln runs on PostgreSQL only.
- **You want a plugin marketplace** you can install from at runtime. Kiln's
  plugins are compile-time code ([why](../plugin-extensibility.md)).

## Choose Kiln if…

- **You want the editorial features in the free product.** Review workflows,
  version history, scheduling, SSO and audit logs are all built in and all
  MIT-licensed.
- **You want the site and the API from one deployment.** Kiln renders your
  public site itself, so a separate front end is optional
  ([theming](../public-theming.md)).
- **You want to model content on a live site.** Editors can add content types
  and fields in production without a deploy
  ([extending content](../extending-content.md)).
- **You want search, email and real-time updates with no extra services.**
  They ship inside Kiln, and PostgreSQL is the only dependency
  ([deploy](../deploy.md)).

## Moving from Strapi

There is no Strapi importer yet. Kiln's portable JSON format and its write API
are the way in. See [content portability](../content-portability.md) and
[the JSON:API guide](../json-api.md).

## Sources

All checked 2026-10-06.

- [Strapi licence][strapi-license]
- [Database configuration][strapi-db]
- [Strapi releases][strapi-releases]
- [API tokens][strapi-tokens]
- [Content-Type Builder][strapi-ctb]
- [RBAC][strapi-rbac]
- [Review workflows][strapi-review]
- [Content history][strapi-history]
- [Releases][strapi-rel]
- [SSO][strapi-sso]
- [Audit logs][strapi-audit]
- [Internationalization][strapi-i18n]
- [Strapi Cloud pricing][strapi-cloud]
- [Self-hosted pricing][strapi-self]

[strapi-license]: https://github.com/strapi/strapi/blob/develop/LICENSE
[strapi-db]: https://docs.strapi.io/cms/configurations/database
[strapi-releases]: https://github.com/strapi/strapi/releases
[strapi-tokens]: https://docs.strapi.io/cms/features/api-tokens
[strapi-ctb]: https://docs.strapi.io/cms/features/content-type-builder
[strapi-rbac]: https://docs.strapi.io/cms/features/rbac
[strapi-review]: https://docs.strapi.io/cms/features/review-workflows
[strapi-history]: https://docs.strapi.io/cms/features/content-history
[strapi-rel]: https://docs.strapi.io/cms/features/releases
[strapi-sso]: https://docs.strapi.io/cms/features/sso
[strapi-audit]: https://docs.strapi.io/cms/features/audit-logs
[strapi-i18n]: https://docs.strapi.io/cms/features/internationalization
[strapi-cloud]: https://strapi.io/pricing-cloud
[strapi-self]: https://strapi.io/pricing-self-hosted
[kiln-license]: https://github.com/The-Verscienta/kiln_cms/blob/main/LICENSE
[kiln-changelog]: https://github.com/The-Verscienta/kiln_cms/blob/main/CHANGELOG.md
