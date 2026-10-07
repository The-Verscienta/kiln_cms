# Migrating from Ghost

<!-- seo-description: Move a Ghost site to Kiln CMS: export your content, dry
run, import posts, pages, tags, images, SEO fields and members-only posts, and
keep every old URL working with redirects. -->

This guide moves a Ghost site to Kiln. It covers Ghost 4, 5 and 6, self-hosted
or on Ghost(Pro). It brings over posts, pages, tags, feature and body images,
SEO titles and descriptions, authors and publication dates. Members-only posts
stay members-only, and every old URL becomes a redirect.

`mix kiln.import.ghost` shares its import engine with the WordPress importer,
so the dry run, the re-run behaviour and the report work the same way. See
[content portability](../content-portability.md) for that engine's reference.

## Before you start

- **A running Kiln site**, with an admin account
  ([getting started](../getting-started.md)).
- **A way to run the importer.** The commands below use `mix`, from a
  checkout with the same configuration as the site (the same `DATABASE_URL`,
  secrets and media storage settings). On a Docker or Coolify deploy there is
  no Mix, so run the same import inside the running container instead. Copy the
  export in, then call the release function through `rpc`:

  ```bash
  docker cp ghost-export.json <container>:/tmp/ghost-export.json
  docker exec -it <container> /app/bin/kiln_cms rpc 'KilnCMS.Release.import_ghost("/tmp/ghost-export.json", site_url: "https://blog.example.com", dry_run: true)'
  ```

  Each `--flag` below becomes a keyword option: `--dry-run` is `dry_run: true`,
  `--limit 20` is `limit: 20`, `--author-map jo=jo@example.com` is
  `author_map: %{"jo" => "jo@example.com"}`. Use `rpc`, not `eval`: the
  import needs the running application. The full table is in
  [content portability](../content-portability.md#from-a-release).
- **The Ghost site still online.** The export has image *addresses*, not image
  files, so the importer downloads each one from your Ghost site. Keep it up
  until you have checked the result.

## 1. Export from Ghost

In Ghost Admin, go to **Settings → Advanced → Import/Export** and choose
**Export** under content. You get one `.json` file. It holds your settings,
staff users, posts, pages and tags
([Ghost's export docs](https://ghost.org/help/exports/)).

You also need your site's address, such as `https://blog.example.com`. Ghost
writes its own URLs into the export as a `__GHOST_URL__` placeholder, so the
importer needs the address to find your images.

## 2. Dry run

```bash
mix kiln.import.ghost ghost-export.json --site-url https://blog.example.com --dry-run
```

Nothing is written and nothing is downloaded. Read the report:

- **Records**: how many posts and pages would be created or skipped.
- **Not as Ghost had it**: posts the importer changed on purpose (see
  [decisions](#decisions-the-importer-makes)).
- **Unreadable**: posts whose body could not be converted. This only happens
  to very old posts that Ghost stored without rendered HTML. Open each one in
  Ghost, save it once, and export again.
- **Authors**: each Ghost staff author, matched to a Kiln user by email.
  Unmatched authors' posts are credited to the user running the import. Map
  them with `--author-map`, using the author's Ghost slug:

  ```bash
  mix kiln.import.ghost ghost-export.json --site-url https://blog.example.com \
    --dry-run --author-map jo=jo@example.com
  ```

## 3. Import a slice, then the rest

```bash
mix kiln.import.ghost ghost-export.json --site-url https://blog.example.com --limit 20
mix kiln.import.ghost ghost-export.json --site-url https://blog.example.com
```

Check the slice in the editor and on the site before running the rest.
Re-running skips everything that already exists. Add `--drain-media` if no Kiln
node is processing background jobs where you run it.

## 4. Check redirects, then switch over

Ghost serves both posts and pages at `/<slug>/`. In Kiln, posts are at
`/blog/<slug>` and pages stay at `/<slug>`. The importer adds a redirect from
each old address, which you can see under **Redirects** at
`/editor/redirects`.

If you changed Ghost's URL structure with a custom `routes.yaml` (for example
`/blog/{slug}/` or dated URLs), the importer cannot know that. Add those
redirects yourself, and use the **404s** tab under **Redirects** to catch any
you missed after switching your domain over.

## Decisions the importer makes

| Ghost | Kiln |
|---|---|
| Post / page | Post / page |
| Rendered HTML | Typed blocks: text, images, embeds |
| Gallery card | One image block per image |
| Bookmark card | A paragraph linking its title to the bookmarked page |
| Video, audio and file cards | **Not imported.** The post is listed so you can move the files by hand |
| Callout, toggle and other cards | Their text, as prose |
| Links to your own posts | Made root-relative (`/other-post/`), so they reach the redirects |
| Public tags | Tags, in Ghost's order |
| Internal `#tags` | Not imported. They are theme plumbing, never shown to readers |
| Primary tag | Just the first tag. Kiln's category is left for you to set |
| Feature image and its alt text | Featured image |
| Meta title and description | SEO title and description |
| Custom excerpt | Excerpt |
| Canonical URL | Not carried. It would point search engines back at Ghost |
| `published` | Published, with Ghost's publication date |
| `scheduled` | **Draft**, with its date. Schedule it again in Kiln, so nothing goes live early |
| Email-only (`sent`) | **Draft**. It was never on your site, so it is not published now |
| `draft` | Draft |
| Visibility `members` | Published to the `member` audience, so it stays gated |
| Visibility `paid` or a tier | Published to a `paid` audience if you configure one; otherwise to `member`, with a note |

On gated posts: Kiln has one gated audience, `member`, unless you configure
more ([memberships](../memberships.md)). If paid and free members must see
different things, add a `paid` audience
(`config :kiln_cms, :audiences, [:public, :member, :paid]`) **before**
importing. Paid and tier posts then go into it. Without it they go into
`member`, which free members can read, and the import lists each one. On a
site configured with no gated audience at all, gated posts import as drafts
rather than being made public.

The importer needs `--site-url` for exports from older Ghost versions too:
they store images as `/content/images/…` paths, which only resolve against the
old site.

## What does not come over

| Ghost | What to do in Kiln |
|---|---|
| Members and subscribers | Not imported. Export them from Ghost's **Members** screen as CSV. Kiln has no subscriber import yet, and a migration is a good moment to ask people to confirm their subscription again ([newsletter](../newsletter.md)). |
| Paid subscriptions | They live in your Stripe account, not in Ghost's export. Set up tiers in Kiln ([memberships](../memberships.md)) before moving paying members. |
| Newsletters already sent | Not imported; email-only posts arrive as drafts. |
| Comments | Not imported. |
| Tiers, offers, benefits | Recreate them as [membership tiers](../memberships.md). |
| Code injection | Not imported. Kiln has [site-wide code injection](../code-injection.md). |
| Navigation, theme | Rebuild with [navigation menus](../navigation-menus.md) and [public theming](../public-theming.md). |
| Staff users | Not imported. Invite your team at `/editor/team` first, so authors match by email. |
| Post history | Not imported. History starts at the import. |

## Related

- [Kiln vs Ghost](kiln-vs-ghost.md)
- [Content portability](../content-portability.md): the import engine's reference
- [Migrating from WordPress](migrating-from-wordpress.md)
