# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Breaking

<a id="some-graphql-queries-that-ran-before-are-now-refused-as-too-costly-and-a"></a>

- **Some GraphQL queries that ran before are now refused as too costly, and a
  refused introspection query gets a GraphQL error instead of a 403.** A
  to-many relationship with no `limit` (`tags`, `relatedPosts`,
  `featuredPosts`) now costs five rows, not one, under the same cap of 200. A
  query that lists such relationships for each row of a 25-row page can go over
  it: `publishedPosts { results { title tags { name } relatedPosts { title } } }`
  costs 300. Ask for a smaller page or pass `limit` on the relationship.
  Documents nested more than 15 fields deep or longer than 2,000 tokens are
  refused, as is a batched `/gql` body of more than 10 operations. With
  introspection off (production), `__schema` and `__type` are refused with a
  `200` and `errors`, like any invalid document; the old plug answered `403`.
  `docs/headless-graphql-api.md` has a new section, "Query cost".

## Added

<a id="one-click-deploy-templates-for-render-railway-flyio-and-digitalocean"></a>

- **One-click deploy templates for Render, Railway, Fly.io and DigitalOcean.**
  `render.yaml` (with a Deploy to Render button), `fly.toml`, `.do/app.yaml`
  and a Railway recipe each run the published image at a pinned tag, with
  Postgres 17 and pgvector and with media kept across restarts. The steps,
  costs and caveats for each are in `docs/deploy-platforms.md`, including
  what none of them solves yet: no platform documents its proxy's address
  range, so per-IP rate limiting behind one is per-deployment until a
  follow-up reads the platform's client-IP header. None has yet been deployed
  end to end; the page says so.
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529))

<a id="kilnmediaroot-a-stable-directory-for-local-media"></a>

- **`KILN_MEDIA_ROOT`: a stable directory for local media.** Unset, the Local
  storage adapter writes under the release's own `priv/uploads` — in the image
  `/app/lib/kiln_cms-<version>/priv/uploads`, a path that moves with every
  version, so no volume could be mounted to keep uploads across an upgrade or
  a PaaS restart. Set, public files go to `<dir>/public` (served at
  `/uploads`, which now reads the adapter's root per request instead of a
  compiled-in path) and private ones to `<dir>/private`. The in-app backup and
  `scripts/backup.sh` default `MEDIA_DIR` to it, the image creates
  `/app/media` owned by `nobody`, and boot reports a directory the app cannot
  write to. Ignored under S3.
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529))

## Fixed

<a id="buttons-links-badges-and-fields-that-rendered-unstyled-now-look-like-what-they"></a>

- **Buttons, links, badges and fields that rendered unstyled now look like what
  they are.** The console's component kit borrows DaisyUI's class names without
  the dependency, and a dozen templates still used DaisyUI classes the kit never
  defined — so they compiled, rendered, and styled nothing. "Turn on outbound
  checking" on `/editor/links` read as plain text: `<.button class="…">`
  replaced the component's own `btn btn-primary` classes instead of adding to
  them, which also stripped mail settings' "Unsuppress". The same shape was
  behind the social accounts "Remove" button (`btn-error`), sixteen `class="link"`
  anchors that Tailwind's preflight had reduced to body text, borderless date and
  note fields in the editor's task form (`input`, `textarea`), status pills on
  experiments, federation and governance (`badge-*`, now `<.badge>`), the error
  on a passphrase-protected page (`alert`), and oversized `btn-xs` buttons. The
  kit gains `.link` and `.field-label` for the call sites that already used them,
  and a test now fails on any DaisyUI-named class in the web layer that
  `assets/css/app.css` does not define.

<a id="a-paas-health-check-no-longer-gets-a-redirect-and-phxhost-falls-back-to-the"></a>

- **A PaaS health check no longer gets a redirect, and `PHX_HOST` falls back
  to the platform's hostname.** `force_ssl` answered a platform's
  plain-HTTP probe of `/up` with a 301, which a platform that counts only 2xx
  reads as a failed deploy; `/live` and `/up` now answer over plain HTTP
  (`/ready`, which carries queue depths, still redirects). With `PHX_HOST`
  unset or blank the host is now `RENDER_EXTERNAL_HOSTNAME`,
  `RAILWAY_PUBLIC_DOMAIN` or `<FLY_APP_NAME>.fly.dev` before `example.com`, so
  a fresh deploy's editor connects; a blank `PHX_HOST` used to become an empty
  host.
  ([#1529](https://github.com/The-Verscienta/kiln_cms/issues/1529))

## Security

<a id="wsgql-runs-under-the-same-cost-limits-as-gql-batches-are-counted-per-operation"></a>

- **`/ws/gql` runs under the same cost limits as `/gql`, batches are counted per
  operation, and introspection is refused however a document arrives.** The
  complexity cap was an `Absinthe.Plug` option on the `/gql` forward, so the
  GraphQL socket never had one. An anonymous `/ws/gql` client could send
  queries, mutations and subscriptions of any cost. Setting the option on the
  socket would not have been enough: `Absinthe.Phoenix.Channel` replaces a
  socket's options after its first document. Both transports now build their
  document pipeline with `KilnCMSWeb.GraphqlLimits`, which pins the complexity
  cap (200) and a token limit (2,000) over any option a caller passes, and adds
  a depth limit (15). A JSON array body ran every element as its own operation,
  with no maximum, for one hit on the 60-a-minute `:gql` bucket.
  `KilnCMSWeb.Plugs.GraphqlBatchLimit` refuses a batch of more than 10
  operations and charges the bucket once per operation. The production
  introspection block read `params["query"]` only, so `[{"query":
  "{__schema{…}}"}]` returned the whole schema, write mutations included, and
  the socket was never checked at all. The block is now a pipeline phase that
  reads the parsed document, on both transports. To-many relationships with no
  `limit` were priced as one row, so `relatedPosts { relatedPosts { … } }`
  cost about 2 a level while returning k^depth rows. They are now priced at
  five rows, and at `limit` rows when one is given.

<a id="each-document-sent-over-wsgql-now-counts-against-the-gql-rate-limit-and-a"></a>

- **Each document sent over `/ws/gql` now counts against the `:gql` rate limit,
  and a malformed document no longer strips a GraphQL socket of its tenant and
  actor.** Only the connect was counted (`:gql_join`), so an anonymous client
  could connect once and send any number of documents, each allowed the full
  complexity cap. `KilnCMSWeb.GraphqlLimits.SocketDocumentBudget`, the first
  phase of the socket's document pipeline, now charges every document the
  client sends to `:gql`, the 60-a-minute bucket `/gql` requests use, under the
  address the connect was charged under. A client has one GraphQL budget
  whichever transport it uses. The key is the address, not the account as for
  `/ws/collab` frames (decision record 0002): documents are not a per-keystroke
  stream, and an anonymous socket has no account. A subscription's pushes are
  not charged. They re-run only the phases `Absinthe.Phase.Init` recorded, and
  the budget runs before Init. Over budget, the document is answered before it
  is parsed with a GraphQL error whose `extensions` are
  `{code: "too_many_requests", retry_after: <seconds>}`, and the socket and its
  subscriptions stay up. A second defect turned up on the way:
  `Absinthe.Phoenix.Channel` keeps the context a document ends with as the
  socket's context, and a document refused before Absinthe copied the context
  onto it (a syntax error, the token limit) ended with none. One malformed
  document left the socket with no tenant, no actor and no pubsub until it
  reconnected, so its next query ran with no tenant and its next subscription
  crashed the channel. The budget phase now puts the context on the document
  before any other phase runs. This closes the `/ws/gql` part of threat-model
  residual item 10; `/live` events are still uncounted.

