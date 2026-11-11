# Changelog — @kiln-cms/client

Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html);
before 1.0 a minor bump may change behaviour and says so here. Releases are
tagged `client-js-vX.Y.Z` in the
[KilnCMS repository](https://github.com/The-Verscienta/kiln_cms).

## Unreleased

- **OpenAPI components (kiln_cms#2274):** `kiln.schemaComponents(options)`
  fetches `GET /api/schema?format=openapi`, the delivery schema as an OpenAPI
  3.1 document, typed as the new exported `OpenApiComponentsDocument`. It
  takes the same `types` and `blocksOnly` options as `schema()`. Needs a
  server with #2274; an older one answers `400` (`invalid_format`), thrown as
  `KilnHttpError`. `schema()` is unchanged.
- **Human verification on forms (kiln_cms#2249):** `FormSchema` gains an
  optional `challenge` (`FormChallenge | null`, new exported type), what a
  front end needs to draw the form's Turnstile widget: `provider`,
  `site_key`, `script_url`, `action` and `field` (`"_kiln_challenge"`).
  `FormSubmitResult` gains an optional `challenge`, `"verified"` or
  `"held"` (stored for review, not acted on). Relay the widget's token in
  `submitForm`'s values under `challenge.field`; a refused token is a
  `KilnValidationError` whose `fieldErrors()` name `_kiln_challenge`. Both
  fields are absent from servers older than this and from forms that do not
  ask, so nothing changes for existing callers.
- **Any provider's widget (kiln_cms#2249):** `FormChallenge` gains optional
  `global`, `onload_param`, `render_options`, `action_option`,
  `interactive` and `api`, so a front end can draw the operator's provider,
  whether Cloudflare Turnstile, Google reCAPTCHA v2 or a plugin's, with one
  piece of code: load `script_url` (adding `<onload_param>=<callback>` and
  waiting for it when `onload_param` is set), then call
  `window[global].render(element, options)` with `render_options`,
  `sitekey` and, only when `action_option` is not `null`, `action` under
  that name. reCAPTCHA's `action_option` is `null`. Types only; the client
  passes the schema through unchanged.

## 0.4.0

- `textSearch` / `semanticSearch` take `customSort` (kiln_cms#2292). The server
  also accepts a custom field's bare name in `filter` / `sort`, but this client
  keeps emitting `custom_filter` / `custom_sort`, the stable form.

- **`:draft_write` keys (kiln_cms#2273):** `create()` takes `onBehalfOf`
  (`CreateOptions`), sent as the `X-Kiln-On-Behalf-Of` header, which Kiln
  records on a draft created with a `:draft_write` API key so reviewers see
  which of your users it was for. Stored only, never authorization; other
  writes never send it (the server reads it on `POST` only). New
  `ContentProvenance` type for the three optional attributes a created record
  carries back (`created_via_key_id`, `created_via_key_name`, `on_behalf_of`):
  `create<Item & ContentProvenance>(…)`. Needs a Kiln server newer than 1.8;
  an older one ignores the header.

## 0.3.0

- **Headless routing, navigation and forms (kiln_cms#2128):**
  `resolvePath(path)` (`GET /api/resolve`), `menus()` and `menu(key)`
  (`GET /api/menus[/:key]`), `locales()` (`GET /api/locales`),
  `related(type, slug)` (`GET /api/content/:type/:slug/related`), and
  `form(slug)` / `submitForm(slug, values)` (`GET`/`POST /api/forms/:slug`).
  `resolvePath` resolves to the server's `not_found` verdict instead of
  throwing on its 404. `submitForm` never sends the client's API key.
- `menu`, `related` and `resolvePath` take `fallback` and `fallbackLocale`
  beside `locale` (`DeliveryLocaleOptions`).
- `KilnValidationError.fieldErrors()` also reads a refused form submission's
  `{ errors: { field: message } }` body.
- `kiln-types` reads a nullable `$ref` (`anyOf: [$ref, {"type": "null"}]`) as
  `Target | null`. Kiln's schema export now states the shared media snapshot
  that way. Before this, such a field typed as `Record<string, unknown> | null`.
- `kiln-types` writes a `:reference` field's allowed target types as a
  `/* links to: "post" | "page" */` comment ahead of its type, the same as
  `mix kiln.export.schema --format ts`. It used to leave the comment out.

## 0.2.0

### Added

- **Writes against the JSON:API write surface (kiln_cms#330):** `create()`,
  `update()`, `delete()` (the reversible soft-delete), and `transition()` with
  wrappers for the four verbs the server routes — `submitForReview()`,
  `returnToDraft()`, `publish()`, `unpublish()`. Every write needs a
  `:read_write` `apiKey` and throws `KilnConfigError` without sending anything
  when the client has none.
- **`graphql()`** — `POST /gql`, resolves to `data`; a top-level `errors`
  array throws `KilnGraphQLError`.
- **Media uploads (kiln_cms#1576):** `uploadMedia(file)` (multipart
  `POST /api/media`), `importMediaFromUrl(url)`, `updateMedia(id, changes)`
  for alt text, caption, the decorative flag, the focal point and tags, and
  `uploadMediaDirect(file)` — which presigns, `PUT`s straight to object
  storage and completes; `beginDirectUpload()` / `completeDirectUpload()` are
  the two legs on their own. Uploads are writes: they follow the same
  `apiKey` rule, so an anonymous one throws `KilnConfigError` rather than
  transferring the file to be refused. They use `uploadTimeoutMs` (default
  five minutes) rather than `timeoutMs`.
- **An error hierarchy** under a new `KilnError` base: `KilnAuthError`
  (401/403), `KilnNotFoundError`, `KilnValidationError` (400/422, with
  `pointers` and `fieldErrors()`), `KilnConflictError` (409, with
  `currentState`), `KilnRateLimitError` (429), `KilnServerError` (5xx), plus
  `KilnNetworkError`, `KilnGraphQLError` and `KilnConfigError`. Every error
  carries `code`, the JSON:API `errors` array and `retryAfter` (seconds, from
  `Retry-After`).

### Changed

- HTTP errors from reads are now the matching `KilnHttpError` **subclass**.
  `KilnHttpError`, `isKilnHttpError()`, `status`, `url` and `body` are
  unchanged, so existing checks keep working; the message now appends the
  server's first `detail` when there is one.
- A `fetch` that rejects for a reason other than an abort (DNS, connection
  refused, TLS) now throws `KilnNetworkError` with the original error as
  `cause`, instead of the runtime's bare `TypeError`. Aborts and timeouts
  still reject with the platform's `AbortError` / `TimeoutError`.

## 0.1.0

- First version: typed JSON:API reads, per-type and hybrid search, fired
  artifacts, `?as_of=` point-in-time reads, preview tokens, and the
  `kiln-types` generator (kiln_cms#1404). Not published to npm.
