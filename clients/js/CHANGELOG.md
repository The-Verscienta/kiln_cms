# Changelog — @kiln-cms/client

Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html);
before 1.0 a minor bump may change behaviour and says so here. Releases are
tagged `client-js-vX.Y.Z` in the
[KilnCMS repository](https://github.com/The-Verscienta/kiln_cms).

## Unreleased

### Changed

- **An empty 2xx body throws `KilnUnexpectedBodyError`, except on a content
  or media write (kiln_cms#3129).** No read route answers a 2xx with an empty body, so an
  empty one is not Kiln's answer, but the client took it as one. JSON:API
  collection reads such as `list()` and `releases()` resolved an empty list,
  `one()` resolved `null`, `release()` an object holding only `included`,
  and the plain-JSON reads (`search()`, `syncPage()`, `menus()`, `locales()`,
  `artifact()`, `preview()`, `resolvePath()`, `schema()`, `related()` and
  the rest) resolved `null`. `revision()`, `sync()` and `restoreRevision()`
  threw a `TypeError`; `graphql()` resolved `{}`; `mintPreview()` and
  `submitForm()` resolved `null`. Each of these now throws
  `KilnUnexpectedBodyError` with `code: "unexpected_body"`, the 2xx
  `status`, `url`, `body: ""` and no `cause`; its message ends "with an
  empty body".

  `one()` therefore throws on an empty 2xx where it used to resolve `null`.
  A real empty match, `{"data": []}`, still resolves `null`.

  The content and media writes are unchanged. `delete()` still resolves on a 204 or an empty 200.
  The other content writes and the media writes still throw `KilnError` with
  `code: "empty_response"`. `beginDirectUpload()` now throws that same
  `empty_response` error on an empty answer instead of a `TypeError`.

- **A missing image transform key throws `KilnConfigError`
  (kiln_cms#3130).** `signedImageUrl()` and `signedImageSrcset()` on a client
  created without `imageTransformKey` threw a plain `Error`; they now throw
  `KilnConfigError` with `code: "missing_image_transform_key"`. The exported
  `signedTransformPath()` and `signedTransformSrcset()` reject with the same
  error for an empty key, and with `code: "webcrypto_unavailable"` in a
  runtime without `globalThis.crypto.subtle`. The messages are unchanged and
  the errors are still `instanceof Error`, so a check on the message keeps
  working; branch on `code` instead.

- **A 2xx JSON body of the wrong shape throws `KilnUnexpectedBodyError` on
  every read that promises a shape (kiln_cms#3151).** A body that is valid
  JSON but not what the route answers (`null`, `{}`) used to pass for an
  answer: `list()`, `byIds()`, `textSearch()`, `semanticSearch()`,
  `autocomplete()`, `releases()` and `releaseItems()` resolved an empty
  list, `one()` resolved `null`, `release()` resolved a record holding only
  `included`, the plain-JSON reads resolved the decoded value, and `sync()`,
  `revision()` and `restoreRevision()` threw a `TypeError`. Each now throws
  `KilnUnexpectedBodyError` with `code: "unexpected_body"`, the 2xx
  `status`, `url`, the raw text (its first 1 KiB) in `body` and no `cause`;
  its message ends "with a JSON body of the wrong shape". What each read
  requires:

  | Read                                                                                                                                  | A 2xx body must be                                                                                                                                  |
  | ------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
  | `list()`, `one()`, `byIds()`, `textSearch()`, `semanticSearch()`, `autocomplete()`, `releases()`, `releaseItems()`                    | a JSON:API document: an object whose `data` is `null`, an object or an array of objects, and whose `included`, when present, is an array of objects |
  | `release()`, `revision()`, `restoreRevision()`                                                                                        | an object whose `data` is an object                                                                                                                 |
  | `sync()`, `syncPage()`                                                                                                                | an object with an `items` array and a `cursor` key                                                                                                  |
  | `listRevisions()`                                                                                                                     | an object whose `data` is an array                                                                                                                  |
  | `search()`                                                                                                                            | an object whose `results` is an object                                                                                                              |
  | `resolvePath()`                                                                                                                       | an object with a `status` key                                                                                                                       |
  | `artifact()`, `contentAsOf()`, `preview()`, `schema()`, `schemaComponents()`, `menus()`, `menu()`, `locales()`, `related()`, `form()` | an object                                                                                                                                           |

  A document with no resources, `{"data": []}`, is still a valid empty
  result, and `one()` still resolves `null` on it. Writes are unchanged: a
  content or media write answered `200 {}` still throws `KilnError` with
  `code: "empty_response"`, and `graphql()`, `mintPreview()` and
  `submitForm()` check no shape.

  To migrate: code that treated an empty list or `null` from a `{}` answer
  as "no results" now gets the error; catch `KilnUnexpectedBodyError` and
  treat it as a broken answer, not an empty one.

- **`KilnUnexpectedBodyError`'s constructor takes an optional fifth
  parameter, `wrongShape` (default `false`).** It only changes the message,
  to "a JSON body of the wrong shape". Code that constructs the error itself,
  in a test double for example, keeps working unchanged.

### Fixed

- **Fix: a 2xx answer that isn't JSON throws `KilnUnexpectedBodyError`
  (kiln_cms#2735).** A captive portal, a CDN error page or a proxy answering
  `200 text/html` in Kiln's place made the client throw the raw `SyntaxError`
  from `JSON.parse`. It now throws the new exported `KilnUnexpectedBodyError`,
  a `KilnError` with `code: "unexpected_body"`, the 2xx `status`, `url`, the
  first 1 KiB of the text in `body` (cut on a UTF-8 character boundary, kept
  out of `message`) and the `SyntaxError` as `cause`. It is not a
  `KilnHttpError`, which stays reserved for non-2xx answers, so
  `isKilnHttpError(err)` is false for it. An empty 2xx body throws it too,
  except on a content or media write (kiln_cms#3129, under Changed).
- **Fix: a body that breaks off mid-read throws `KilnNetworkError`.** When
  the connection dropped after the headers arrived, reading the body rejected
  with the platform's own error. It is now a `KilnNetworkError` with that
  error as `cause`. An abort (your `signal` or the client's timeout) is still
  the platform's `AbortError` / `TimeoutError`.
- **Fix: an empty media answer throws `KilnError`.** A media write (upload, import,
  metadata update, direct-upload completion) whose answer had no media item
  threw a plain `Error`; it now throws a `KilnError` with
  `code: "empty_response"`, as the content writes already did.
- **Fix: `restoreRevision` fails fast without a key (kiln_cms#2734).** A
  client with no `apiKey` sent an anonymous `POST` and got a
  `KilnAuthError` (401). Like every other write, it now throws
  `KilnConfigError` (`code: "missing_api_key"`) without sending anything.

- **Fix: `kiln-types` can no longer be made to emit code by the schema it
  reads.** The `x-kiln.artifact_format_version` went into a `//` comment
  unescaped, and `$defs` names into type names, so a line break or a `;` from
  the server (or from anyone on the path to an `http://` one) could put code
  into the generated `.ts` file. Line breaks in the comment now become spaces,
  and type names keep only identifier characters (CodeQL
  `js/http-to-file-access`).

- **Fix: trimming trailing slashes off `baseUrl` takes linear time.** The
  constructor used `/\/+$/`, which takes quadratic time on a long run of `/`
  (CodeQL `js/polynomial-redos`). `baseUrl` is the integrator's own config,
  so this was never reachable by an attacker. It now trims in a loop, with the
  same result.
- **Fix: the default `fetch` works in browsers and Workers.** The client
  stored `globalThis.fetch` and called it as a method of itself, which
  browsers and Cloudflare Workers reject with `TypeError: Illegal
invocation`, so every request failed as a `KilnNetworkError` unless a
  `fetch` option was passed. Node does not check, so it went unnoticed.
- **Fix: `signedTransformSrcset()` checks the key before the media's size
  (kiln_cms#3153).** With an empty key and media whose `width`/`height` are
  unknown, it resolved `null`, so a missing key showed up only on items of
  known size. It now rejects with `KilnConfigError`
  `code: "missing_image_transform_key"` whatever the media, and with
  `code: "webcrypto_unavailable"` in a runtime without
  `globalThis.crypto.subtle`. When both the key and the options are bad, the
  key error is the one thrown. With a key, media of unknown size still
  resolves `null`. `signedImageSrcset()` on the client already checked its
  key first.

### Added

- **`site()` and the `Site` type, for `GET /api/site` (kiln_cms#3168).** It
  resolves the site's link-preview defaults, for the Open Graph and X card
  tags a front end renders when a document's own `social` object leaves them
  out: `{ site_name, twitter_site, social_image_url }`. Every key is always
  present; `twitter_site` (`"@handle"`) and `social_image_url` (an absolute
  URL) are `null` when unset. A 2xx missing one of the three throws
  `KilnUnexpectedBodyError`. It is sent without the client's API key, even
  when one is configured: the answer is the same either way, and only an
  anonymous one can be shared by a cache. A 503 throws `KilnServerError` with
  `retryAfter`. The route comes with kiln_cms#3167, so `site()` needs a
  server that includes it.

- **`FormField.condition` (`FormCondition` / `FormRule` types) and
  `FormSubmitResult.discarded` (kiln_cms#2262).** Newer servers send each
  form field's show/hide rule, and list the fields whose values were dropped
  because their condition hid them. `condition` is `null` for a field that
  is always shown, or `{ action: "show" | "hide", rule }`; evaluate the
  fields in order, and treat a field its condition hides as having no value
  for the rules after it. `submitForm()` still resolves `ok: true` when the
  server drops a value sent for a hidden field, so a front end that doesn't
  evaluate conditions loses that value without an error; `discarded` names
  those fields, and is absent when there are none or from an older server.
  Types only: no runtime change.

## 0.5.0

- **`kiln-types --check <file>` (kiln_cms#2274):** fetches the live schema (or
  reads `--from`), renders the declarations `--out <file>` would write, and
  compares them with the file, writing nothing. It exits `1` when the file is
  missing or differs, naming the first differing line and what the export
  has there, so a TypeScript frontend in its own repository can fail CI on
  stale generated types without running Kiln.
  Mirrors `mix kiln.export.schema --check`; refused together with `--out`.
  Additive: every other flag behaves as before.
- **OpenAPI components (kiln_cms#2274):** `kiln.schemaComponents(options)`
  fetches `GET /api/schema?format=openapi`, the delivery schema as an OpenAPI
  3.1 document, typed as the new exported `OpenApiComponentsDocument`. It
  takes the same `types` and `blocksOnly` options as `schema()`. Needs a
  server with #2274; an older one answers `400` (`invalid_format`), thrown as
  `KilnHttpError`. `schema()` is unchanged.
- **Range fields typed by kind (kiln_cms#2548):** `kiln-types` reads an
  `anyOf` of closed inline objects (optionally with `{"type": "null"}`) beside
  an object schema as a union of those objects. Against a server with #2548,
  a range custom field is now
  `{ max?: number; min?: number } | { max?: string; min?: string } | null`
  instead of `{ max?: number | string; min?: number | string } | null`:
  both bounds numbers or both `YYYY-MM-DD` dates, which is what the server
  has always required on save. Reading code compiles as before; code that
  builds a value of the type with one number and one date bound (fixtures,
  mocks, `satisfies`) stops compiling after regenerating. Any other `anyOf`
  types as before.
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
- **Richer form field types (kiln_cms#2261):** `FormField.type` gains `radio`,
  `checkboxes`, `phone`, `url`, `hidden`, `number` and `rating`, and a field
  carries `min`, `max` and `step`. New `FormValue` and `FormSubmittedData`
  types: a `checkboxes` answer is a `string[]`, `number`/`rating` are numbers.
  Treat a `type` you do not know as `"text"`.

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
