# Author profiles and bylines

Kiln has no `Author` resource. A public author is a content type you compose,
and a byline is a `:reference` field that points at it.

That is a deliberate split. A content item's `author` is the console
`KilnCMS.Accounts.User` who created it. It holds one person, it is how the
editor knows who wrote a draft, and it is never delivered: `User` is not on
JSON:API, and an account's email has no business on a public page. A news
site needs something else entirely. It needs a profile page with a bio and a
photo, several names on one article in a set order, and contributors such as
a freelance photographer or a guest columnist who will never sign in. All of
that is published, world-readable content, so it lives in a content type.

This page builds that type from parts Kiln already has: a content type,
[custom fields](extending-content.md), and the 1.5 relationships (a
`:reference` field with `multiple`, link fields and a reverse field). Nothing
here needs a core change. The [last section](#what-kiln-does-not-do-yet)
lists what still has to happen outside Kiln.

## The author type

Create the type at `/editor/types`, or in code or seeds:

```elixir
alias KilnCMS.CMS

{:ok, author_type} =
  CMS.create_type_definition(%{
    name: "author", label: "Author", plural_label: "Authors",
    path_segment: "authors",
    # Kiln has no `ProfilePage` or `Person` in its allowlist yet; `WebPage`
    # keeps a profile from firing as the default `Article`.
    schema_org_type: "WebPage"
  }, actor: admin)
```

An author is now an entry like any other. It has a title (the display name),
a slug (`/authors/ada-lovelace`), drafts, review, version history and
publishing. A contributor with no console account is simply an author nobody
links to a `User`.

Give it the profile fields:

```elixir
for {name, label, type} <- [
      {"bio", "Bio", :text},
      {"photo", "Photo", :media},
      {"job_title", "Job title", :string},
      {"website", "Website", :url}
    ] do
  CMS.create_field_definition!(%{
    type_definition_id: author_type.id, name: name, label: label, field_type: type
  }, actor: admin)
end
```

Links to the author's other profiles, which become schema.org `sameAs`, are a
repeating group with one sub-field:

```elixir
same_as =
  CMS.create_field_definition!(%{
    type_definition_id: author_type.id, name: "same_as", label: "Other profiles",
    field_type: :group, multiple: true
  }, actor: admin)

CMS.create_field_definition!(%{
  group_of_id: same_as.id, name: "url", label: "URL", field_type: :url
}, actor: admin)
```

### Linking an author to a console user

The issue behind this recipe asks for an optional link to a `User`, for a
staff writer who also has an account. Kiln has no field type that points at
a `User`, and every custom field is delivered publicly with the record. So
the link is a plain field holding the user's **id**, never the email:

```elixir
CMS.create_field_definition!(%{
  type_definition_id: author_type.id, name: "console_user_id",
  label: "Console account (user id)", field_type: :string,
  help_text: "Optional. The id of this author's Kiln account. Delivered publicly."
}, actor: admin)
```

Kiln does not resolve, check or act on this value. It is a note your own
code can use, for example an overlay that fills a new article's `authors`
from the signed-in editor. If an opaque id on a public payload is still too
much, keep the mapping in that overlay instead and leave the field out.

### As a compiled type

The same type can be compiled into an overlay, which gives it its own table,
its own JSON:API resource (`/api/json/authors`) and its own GraphQL queries
(`authorBySlug`) in place of the shared `Entry` tier:

```bash
mix kiln.gen.content Author --published
mix ash.codegen add_authors && mix ash.migrate
```

Then declare the schema.org type on the generated resource by hand, the way
`KilnCMS.CMS.Page` does (`use KilnCMS.CMS.Content, type: :author,
schema_org_type: "WebPage"`), and create the fields with
`content_type: :author` instead of `type_definition_id:`. A dynamic `author`
type that has already collected entries is promoted with
`mix kiln.gen.content --from author` and `mix kiln.promote_data author`
([extending-content.md](extending-content.md), section 4). Record ids
survive the promotion, so every byline that points at an author keeps
pointing at it.

## The byline field

A byline is a list of references from the article to its authors. The
examples below put it on the built-in `post` type. On an overlay's own
`article` type, use `content_type: :article`.

```elixir
authors =
  CMS.create_field_definition!(%{
    content_type: :post, name: "authors", label: "Authors",
    field_type: :reference, target_type: "author", multiple: true,
    # The other side: every author's editor lists the articles it is on,
    # and GraphQL answers `referencedBy(inverse: "articles")`.
    inverse_label: "Articles", inverse_name: "articles",
    # An author who still has bylines cannot be purged.
    on_target_delete: :restrict
  }, actor: admin)

# What each person did on this article, stored on the connection.
CMS.create_field_definition!(%{
  link_of_id: authors.id, name: "role", label: "Role",
  field_type: :select, options: ~w(author contributor photographer illustrator),
  default: "author"
}, actor: admin)
```

What each setting buys:

- **`multiple: true`** makes the field an ordered list. The order the editor
  arranges is the order of the names in the byline. The same author cannot
  appear twice in one list.
- **`role`** is a link field: data about this person *on this article*, not
  about the person. Ada can be the author of one piece and the photographer
  on another.
- **`inverse_name`** gives the author's profile its list of articles with no
  second field to maintain. There is one source of truth, the article's
  `authors` list.
- **`on_target_delete: :restrict`** refuses to purge an author while any
  article still names them. `:clear` would instead remove them from every
  byline. Trashing an author purges nothing, so a trashed author can be
  restored with every byline intact.

Editors fill the field from the reference picker. In code, a write names each
author by id, with the link values under `"link"`:

```elixir
CMS.create_post!(%{
  title: "What the trial found", slug: "what-the-trial-found",
  custom_fields: %{
    "authors" => [
      %{"id" => ada.id, "link" => %{"role" => "author"}},
      %{"id" => grace.id, "link" => %{"role" => "photographer"}}
    ]
  }
}, actor: editor)
```

## What a reader gets

### The article

The fired `json` artifact carries the byline in `custom_fields`, in the
editor's order, with each connection's role:

```json
{
  "custom_fields": {
    "authors": [
      {"id": "…", "type": "author", "slug": "ada-lovelace", "title": "Ada Lovelace",
       "link": {"role": "author"}},
      {"id": "…", "type": "author", "slug": "grace-hopper", "title": "Grace Hopper",
       "link": {"role": "photographer"}}
    ]
  }
}
```

Two rules keep that byline honest without any work on your side:

- **A rename reaches every article.** The stored snapshot is taken when the
  article is saved, but firing reads the author's *current* title and slug.
  Editing a published author re-fires every article that references them,
  so a corrected name reaches every byline it is on
  (`KilnCMS.Firing.CustomFields`).
- **An unpublished author is left out.** The artifact keeps only the authors
  an anonymous reader could open: published, public and not locked. A
  profile still in review drops out of the byline, and publishing it re-fires
  the article, which brings it back.

To render the profiles alongside the article in one request, expand the
field. Each author comes back with its own fired `json` artifact (bio, photo,
links):

```bash
curl -s 'http://localhost:4000/api/content/post/what-the-trial-found?expand=authors'
```

See [api.md](api.md#expanding-references) for the limits.

### The profile page

The author's own artifact is at `GET /api/content/author/ada-lovelace`. Its
article list comes from the reverse field. In GraphQL, ask for it by name:

```graphql
query ($slug: String!, $type: ID!) {
  entryBySlug(slug: $slug, locale: "en", typeDefinitionId: $type) {
    title
    customFields
    referencedBy(inverse: "articles", limit: 20) {
      link
      source { title slug publishedAt }
    }
  }
}
```

`link` carries the role, so the page can say "Photography by Ada Lovelace".
An anonymous reader sees only published articles. A compiled `Author` type
answers the same field on `authorBySlug(slug:, locale:)`.

Over JSON:API, the same list is a filter on the articles:

```
GET /api/json/posts/published?custom_filter[authors][has][]=<author id>
```

This filter cannot narrow by role. `custom_filter[authors.link.role]=author`
is a separate condition, met by *any* connection on the article, so adding
it to `has` for a photographer still returns the articles where somebody
else is the author. To split a profile's list into "written" and
"photographed", read the roles: GraphQL's `referencedBy` above returns each
connection's `link`, and so does the article's own `authors` list.

## Structured data

schema.org's `author` takes a list of `Person` nodes. A byline maps onto it
one to one:

| Byline | schema.org |
|---|---|
| each item of `authors`, in order | one `Person` in `author` |
| the item's `title` | `name` |
| `/<path_segment>/<slug>` (`/authors/ada-lovelace`) | `url` |
| the author's `photo` | `image` |
| the author's `job_title` | `jobTitle` |
| the author's `same_as[].url` | `sameAs` |
| an item whose role is not `author` | `contributor` instead of `author` |

So the article's main node should carry:

```json
{
  "@type": "NewsArticle",
  "headline": "What the trial found",
  "author": [
    {"@type": "Person", "name": "Ada Lovelace",
     "url": "https://news.example.com/authors/ada-lovelace"}
  ],
  "contributor": [
    {"@type": "Person", "name": "Grace Hopper",
     "url": "https://news.example.com/authors/grace-hopper"}
  ]
}
```

The profile page is a `ProfilePage` whose `mainEntity` is the same `Person`,
with `description` from the bio and `image`, `jobTitle` and `sameAs` from
the fields.

**Kiln does not emit this mapping yet.** The fired `:json_ld` surface
(`KilnCMS.Firing.SchemaOrg`) carries no `author` at all, and the JSON-LD
inlined in Kiln's own article pages (`KilnCMSWeb.StructuredData`) names the
console `User`. Until it does, a headless front end builds these nodes from
the `json` artifact above, which has everything the table needs. A front end
that also serves Kiln's own article pages should know that those pages say
"By" the console user, and that their inline JSON-LD does too.

## What Kiln does not do yet

Each of these is a gap in the code, not in the recipe:

- **No `author` on the fired `:json_ld` surface.** There is no covered way
  for a reference field to contribute a property to the main node. A block's
  `:json_ld` render adds a node to the `@graph`; it cannot set the article's
  `author`.
- **No `ProfilePage` or `Person` in the schema.org allowlist**
  (`KilnCMS.Firing.SchemaOrg.types/0`). The nearest allowed type for a
  profile is `WebPage`.
- **Kiln's own templates render the console `User`**, both the "By" line on
  `/blog/:slug` and the inline `author` in its JSON-LD, and they do not
  render custom fields. An author's profile page is a front end's or an
  overlay's page, not one Kiln serves with its bio and article list.
- **No field type points at a `User`, and no custom field is private.** The
  optional account link above is an id in a public string field.
- **A link-field filter is not tied to one target.** `custom_filter` cannot
  ask for "articles where *this* author has role `author`"; the role is
  read client-side from `link`.
