# 0061. Site-level values stay out of per-document artifacts

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2582 in 1.9.0.
- **References** — [#2580](https://github.com/The-Verscienta/kiln_cms/issues/2580),
  which asked for this record;
  [#2258](https://github.com/The-Verscienta/kiln_cms/issues/2258) and
  [#2582](https://github.com/The-Verscienta/kiln_cms/pull/2582) (the `social`
  object); [#1929](https://github.com/The-Verscienta/kiln_cms/issues/1929)
  (the signed provenance manifest kept beside each body);
  [ADR 0060](0060-an-artifact-change-bumps-format-version-only-when-every-existing-document-needs-it.md)
  for what a change to the artifact's keys costs.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#twitter-card-upgrade).

## The problem

#2258 put a `social` object on the `json` artifact so a headless front end can
write the same Open Graph and X (Twitter) card tags Kiln's own pages do
(`KilnCMSWeb.Layouts.social_meta/1`). Some of what those tags say comes from
the document: the effective SEO title and description, and the SEO image. The
rest comes from the site's Branding settings: the site's X username
(`twitter:site`), the brand's default social image when the document has
none, and so the card type, which is `summary_large_image` whenever there is
an image, the brand's fallback included.

A fired artifact is one document's body, compiled when that document is
published or edited (decision D9), stored per document and surface
(`KilnCMS.Firing.PublishedArtifact`), and signed (its provenance `manifest`).
Saving Branding re-fires nothing: `Changes.BustBranding` busts the branding
cache, `llms.txt` and the `<head>` generation, and leaves every artifact as
it is. A Branding value copied into an artifact is therefore the value the site
had when that document was last fired, and documents fired at different times
disagree.

## Decision

**A per-document artifact carries only values that belong to the document.
Site-level values stay out, and a consumer gets them elsewhere.** `social`
(`Engine.put_social/2`) carries `title`, `description` and `image` and nothing
else. The card type, `twitter:site` and the fallback image are left to the
consumer ([headless consumer guide](../headless-consumer-guide.md),
"What you supply yourself").

Values that already bake site data in at fire time stay, as accepted
exceptions. Each needs a re-fire (`mix kiln.refire_all`) after the site value
it reads changes. By a grep for `Tenant.base_url`, `absolute_url` and
`Branding` in `lib/kiln_cms/firing` and `lib/kiln_cms/seo`, they are:

- **The `[site-name]` pattern token.** `KilnCMS.Seo.Patterns` resolves it from
  `Branding.for_org/1` when the document is fired, into `social.title` and
  `social.description` on `json` and `description` on `json_ld`
  (`Firing.SchemaOrg`). Re-fire after changing the site name.
- **Absolute URLs on the site's host.** `social.image`
  (`KilnCMSWeb.Tenant.absolute_url/2`) and each byline person's `url` on
  `json_ld` (`Firing.Bylines`, from `Tenant.base_url/1`). Re-fire after a
  site's custom domain or slug, or the deployment's `PUBLIC_BASE_URL`, changes.

`Firing.StaticExport` also reads `Tenant.base_url/1`, but writes a fresh
export on each run, not a stored artifact.

They stay because each is a per-document value that happens to read the site:
a title made from a pattern is that document's title, and a link preview needs
an absolute image URL. The alternative, resolving them on every read, gives up
what firing is for: the body served is the body compiled and signed.

## Rejected

- **Put the site values in `social` too.** Every Branding save would leave
  every artifact stale, and only a whole-corpus re-fire would fix it; a site
  whose artifacts were fired before and after the save would serve both.
  Making the save re-fire instead turns a settings edit into a sweep of every
  document on the site.
- **Fill site values in at read time.** The served body would no longer be the
  fired body, so its provenance manifest would not match it, and the delivery
  path would read Branding on every request.

## Consequences

- A headless consumer supplies the card type, its X handle and a fallback
  image from its own configuration: Branding is on no API yet. Kiln's rule for the card type is in the
  guide: `summary_large_image` with an image, `summary` without.
- After a site-name, custom-domain, slug or `PUBLIC_BASE_URL` change, an
  operator runs `mix kiln.refire_all`. Kiln's own pages resolve the host and
  Branding per request and need nothing.
- A new site-level value wanted on a document's preview goes on a site-level
  surface, not into the artifact.
