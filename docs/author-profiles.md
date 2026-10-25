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
`:reference` field with `multiple`, link fields and a reverse field). One
setting on the reference field, `schema_org_property`, makes its targets the
page's `author` or `contributor` in structured data and in the "By" line of
Kiln's own pages. The [last section](#what-kiln-does-not-do-yet) lists what
still has to happen outside Kiln.

## The author type

Create the type at `/editor/types`, or in code or seeds:

```elixir
alias KilnCMS.CMS

{:ok, author_type} =
  CMS.create_type_definition(%{
    name: "author", label: "Author", plural_label: "Authors",
    path_segment: "authors",
    # A page about a person: its JSON-LD names the person as `mainEntity`.
    schema_org_type: "ProfilePage"
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

A staff writer often also has a Kiln account. Link the two with a `:user`
field, which names one of the site's people (an admin, or a member with any
role) by their account id:

```elixir
CMS.create_field_definition!(%{
  type_definition_id: author_type.id, name: "account",
  label: "Kiln account", field_type: :user,
  help_text: "Optional. The account this author signs in with."
}, actor: admin)
```

A `:user` field is always **private**. Editors and admins see it, and pick
from the site's people in the editor. Everyone else never does: it is left out
of the author's artifacts, out of every API read below editor, and out of
filters, the same as a `User` is never delivered. Kiln checks that the value
names someone on the site when it is written. It does nothing else with the
value. Your own code can use it, for example an overlay that fills a new
article's `authors` from the signed-in editor. A contributor with no account
simply leaves the field empty.

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
schema_org_type: "ProfilePage"`), and create the fields with
`content_type: :author` instead of `type_definition_id:`. A dynamic `author`
type that has already collected entries is promoted with
`mix kiln.gen.content --from author` and `mix kiln.promote_data author`
([extending-content.md](extending-content.md), section 4). Record ids
survive the promotion, so every byline that points at an author keeps
pointing at it.

## The byline fields

A byline is a list of references from the article to the people on it. Use
two fields: one for the authors and one for everyone else who worked on the
piece. The examples put them on the built-in `post` type. On an overlay's own
`article` type, use `content_type: :article`.

```elixir
CMS.create_field_definition!(%{
  content_type: :post, name: "authors", label: "Authors",
  field_type: :reference, target_type: "author", multiple: true,
  # Its targets are the page's schema.org `author`, and its "By" line.
  schema_org_property: :author,
  # The other side: every author's editor lists the articles it is on,
  # and GraphQL answers `referencedBy(inverse: "articles")`.
  inverse_label: "Articles", inverse_name: "articles",
  # An author who still has bylines cannot be purged.
  on_target_delete: :restrict
}, actor: admin)

contributors =
  CMS.create_field_definition!(%{
    content_type: :post, name: "contributors", label: "Contributors",
    field_type: :reference, target_type: "author", multiple: true,
    schema_org_property: :contributor,
    inverse_label: "Contributions", inverse_name: "contributions",
    on_target_delete: :restrict
  }, actor: admin)

# What each contributor did on this article, stored on the connection.
CMS.create_field_definition!(%{
  link_of_id: contributors.id, name: "role", label: "Role",
  field_type: :select, options: ~w(photographer illustrator editor researcher)
}, actor: admin)
```

What each setting buys:

- **`multiple: true`** makes a field an ordered list. The order the editor
  arranges is the order of the names in the byline. The same person cannot
  appear twice in one list.
- **`schema_org_property`** says what the targets are to the page:
  `:author` or `:contributor`. It is the *What they are to the page* step
  of a relationship in the fields admin. Setting it, changing it or clearing
  it re-fires every published document of the type.
- **`role`** is a link field: data about this person *on this article*, not
  about the person. Grace can be the photographer on one piece and the
  illustrator on another.
- **`inverse_name`** gives each profile its list of articles with no field
  to maintain on the author. There is one source of truth, the article's
  lists.
- **`on_target_delete: :restrict`** refuses to purge an author while any
  article still names them. `:clear` would instead remove them from every
  byline. Trashing an author purges nothing, so a trashed author can be
  restored with every byline intact.

Keeping the two kinds of credit in two fields, rather than one field with a
role that says "author", is what lets Kiln tell them apart: the schema.org
meaning belongs to the field, and each list filters on its own
(`custom_filter[authors][has][]=…` and `custom_filter[contributors][has][]=…`).

Editors fill the fields from the reference picker. In code, a write names
each person by id, with the link values under `"link"`:

```elixir
CMS.create_post!(%{
  title: "What the trial found", slug: "what-the-trial-found",
  custom_fields: %{
    "authors" => [%{"id" => ada.id}, %{"id" => alan.id}],
    "contributors" => [%{"id" => grace.id, "link" => %{"role" => "photographer"}}]
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
      {"id": "…", "type": "author", "slug": "ada-lovelace", "title": "Ada Lovelace"},
      {"id": "…", "type": "author", "slug": "alan-turing", "title": "Alan Turing"}
    ],
    "contributors": [
      {"id": "…", "type": "author", "slug": "grace-hopper", "title": "Grace Hopper",
       "link": {"role": "photographer"}}
    ]
  }
}
```

Two rules keep that byline honest without any work on your side, here and
in the structured data and "By" line below:

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
curl -s 'http://localhost:4000/api/content/post/what-the-trial-found?expand=authors,contributors'
```

See [api.md](api.md#expanding-references) for the limits.

### The profile page

The author's own artifact is at `GET /api/content/author/ada-lovelace`. Its
article lists come from the reverse fields. In GraphQL, ask for them by name:

```graphql
query ($slug: String!, $type: ID!) {
  entryBySlug(slug: $slug, locale: "en", typeDefinitionId: $type) {
    title
    customFields
    written: referencedBy(inverse: "articles", limit: 20) {
      source { title slug publishedAt }
    }
    contributed: referencedBy(inverse: "contributions", limit: 20) {
      link
      source { title slug publishedAt }
    }
  }
}
```

`link` carries the role, so the page can say "Photography for *What the
trial found*". An anonymous reader sees only published articles. A compiled
`Author` type answers the same fields on `authorBySlug(slug:, locale:)`.

Over JSON:API, the same lists are filters on the articles:

```
GET /api/json/posts/published?custom_filter[authors][has][]=<author id>
GET /api/json/posts/published?custom_filter[contributors][has][]=<author id>
```

To list only the pieces a contributor photographed, tie the role to that
person with `target`. Without it, the role condition is met by *any*
contributor on the article:

```
GET /api/json/posts/published?custom_filter[contributors.link.role][eq]=photographer&custom_filter[contributors.link.role][target]=<author id>
```

See [json-api.md](json-api.md) for the link-field operators.

## Structured data

With `schema_org_property` set, the fired `:json_ld` artifact's main node
carries the byline, one `Person` per person in each list, in order:

```json
{
  "@type": "NewsArticle",
  "headline": "What the trial found",
  "author": [
    {"@type": "Person", "name": "Ada Lovelace",
     "url": "https://news.example.com/authors/ada-lovelace"},
    {"@type": "Person", "name": "Alan Turing",
     "url": "https://news.example.com/authors/alan-turing"}
  ],
  "contributor": [
    {"@type": "Person", "name": "Grace Hopper",
     "url": "https://news.example.com/authors/grace-hopper"}
  ]
}
```

The JSON-LD inlined in Kiln's own pages carries the same nodes, and their
"By" line names the same people, linked to their profiles: "By Ada Lovelace
and Alan Turing · With Grace Hopper" (`KilnCMSWeb.ContentHTML.byline/1`,
styled through the `public-byline` and `public-byline-name` classes). All
three read the byline through `KilnCMS.Firing.Bylines`, so they cannot
disagree. Without an `author` field, Kiln's pages keep naming the console
user who created the post, as before.

Some details of that output:

- `name` is the person's current title and `url` their page in the site's
  default locale, `/<path_segment>/<slug>`. A snapshot does not carry the
  person's locale or path alias.
- When two fields name the same property, their people are joined in field
  order, and someone listed in both is named once.
- An Event carries neither property. `author` and `contributor` are
  `CreativeWork` properties, and an Event is not one; the same rule keeps
  `articleBody` off it.

The author's own page fires as a `ProfilePage` whose `mainEntity` is the
person:

```json
{"@type": "ProfilePage", "headline": "Ada Lovelace",
 "mainEntity": {"@type": "Person", "name": "Ada Lovelace"}}
```

Kiln names the person and nothing more. A front end that wants a richer
`Person` adds the rest from the author's `json` artifact:

| Author field | `Person` property |
|---|---|
| `bio` | `description` |
| `photo` | `image` |
| `job_title` | `jobTitle` |
| `same_as[].url` | `sameAs` |

## What Kiln does not do yet

Each of these is a gap in the code, not in the recipe:

- **Kiln's own templates do not render custom fields.** An author's profile
  page, with its bio and article lists, is a front end's or an overlay's
  page, not one Kiln serves.
- **The `Person` nodes carry a name and a URL only.** A profile's bio, photo
  and other profiles are not read into them.
