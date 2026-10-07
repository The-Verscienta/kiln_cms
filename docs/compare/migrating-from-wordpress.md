# Migrating from WordPress

<!-- seo-description: Move a WordPress site to Kiln CMS: export, dry run,
import posts, pages, images, categories, tags and authors, and keep every old
URL working with automatic redirects. -->

This guide moves a WordPress site to Kiln. It brings over posts, pages,
categories, tags, featured and body images, authors and publication dates. Every
old permalink becomes a redirect, so links and search rankings keep working.
It takes three commands, and you can re-run it safely.

The importer's full reference, including every decision it makes on your
behalf, is in [content portability](../content-portability.md). This page is the
walkthrough.

## Before you start

- **A running Kiln site**, with an admin account. A fresh install's `/setup`
  wizard creates one ([getting started](../getting-started.md)).
- **A way to run the importer.** The commands below use `mix`, from a
  checkout with the same configuration as the site (the same `DATABASE_URL`,
  secrets and media storage settings). On a Docker or Coolify deploy there is
  no Mix, so run the same import inside the running container instead. Copy the
  export in, then call the release function through `rpc`:

  ```bash
  docker cp wordpress.xml <container>:/tmp/wordpress.xml
  docker exec -it <container> /app/bin/kiln_cms rpc 'KilnCMS.Release.import_wordpress("/tmp/wordpress.xml", dry_run: true)'
  ```

  Each `--flag` below becomes a keyword option: `--dry-run` is `dry_run: true`,
  `--limit 20` is `limit: 20`, `--author-map jo=jo@example.com` is
  `author_map: %{"jo" => "jo@example.com"}`. Use `rpc`, not `eval`: the
  import needs the running application. The full table is in
  [content portability](../content-portability.md#from-a-release).
- **The WordPress site still online.** Images are downloaded from their
  original URLs during the import, so keep the old site up until you have
  checked the result.

## 1. Export from WordPress

In the WordPress dashboard, go to **Tools → Export**, choose **All content** and
download the file. You get one `.xml` file in WordPress's WXR format. It holds
posts, pages, terms and authors, and each image's URL; the image files
themselves stay on the old site.

A very large site may need a split export (one file per post type or date
range). The importer refuses files over 64 MB and tells you so. Each file
imports on its own, and re-running is safe.

## 2. Dry run

```bash
mix kiln.import.wordpress wordpress.xml --dry-run
```

The dry run reads everything, decides what each record would become, writes
nothing and fetches nothing, then prints the same report a real run prints.
Read it before going further:

- **Records**: how many posts and pages would be created, and how many already
  exist and would be skipped.
- **Authors**: every author in the file, and whether each one matched a Kiln
  user by email. Unmatched authors' content is credited to the user running the
  import. Fix that now with `--author-map login=kiln@email`, which you can
  repeat for each author:

  ```bash
  mix kiln.import.wordpress wordpress.xml --dry-run \
    --author-map jo=jo@example.com --author-map sam=sam@example.com
  ```

- **Media**: how many images would be fetched.

Pass `--actor EMAIL` to run as a specific user, and `--org SLUG` on a multi-site
install ([multi-tenancy](../multi-tenancy.md)).

## 3. Import a slice

```bash
mix kiln.import.wordpress wordpress.xml --limit 20
```

Open a few imported posts in the editor and on the site. Check the body
formatting, the images, the category and tags, and the publication date.

## 4. Import the rest

```bash
mix kiln.import.wordpress wordpress.xml
```

Records that already exist (matched by slug and locale) are skipped, so this
picks up where the slice left off. The report ends by listing anything that did
not come over exactly as WordPress had it, and why.

If you ran the import somewhere no Kiln node is processing background jobs, add
`--drain-media`. Without it, imported images are served full size until a
running node generates their smaller versions.

## 5. Check redirects, then switch over

Kiln serves posts at `/blog/<slug>` and pages at `/<slug>`. Each old permalink,
such as `/2024/03/hello-world/`, now redirects to its new address. You can see
and edit them under **Redirects** at `/editor/redirects`.

When you are happy, point your domain at Kiln. For the first few weeks, watch
the **404s** tab under **Redirects**. It records the paths visitors asked for
that matched nothing, so you can redirect any your old theme or plugins created.

## What does not come over

The importer brings over content, not the site around it. These need a
decision from you, so it does not guess:

| WordPress | What to do in Kiln |
|---|---|
| Comments | Not imported. Kiln has no reader comments; its [comments](../comments.md) are editors' notes on a draft. Keep them with an external comment service if you need them. |
| Users | Not imported. Invite your team at `/editor/team`, ideally *before* the import, so authors match by email. |
| Menus | Rebuild under [navigation menus](../navigation-menus.md). |
| Theme | Restyle with [public theming](../public-theming.md), or use a headless front end. |
| Plugin data, shortcodes | `[caption]` and `[embed]` become captions and embeds. Other shortcodes are removed from the body, and plugin data is not read. Custom fields need a Kiln [content type](../extending-content.md) to go into. |
| Multiple categories | Kiln has one category per record, so the first is kept. |
| Scheduled posts | Imported as drafts with their date, so nothing goes live early. Schedule them again in the editor. |
| Revisions | Not imported. History starts at the import. |
| Custom post types | Only `post` and `page` are read. |

## Related

- [Kiln vs WordPress](kiln-vs-wordpress.md)
- [Content portability](../content-portability.md): the importer reference
- [Migrating from Ghost](migrating-from-ghost.md)
