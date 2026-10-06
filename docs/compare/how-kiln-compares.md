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
