# Changelog — @kiln-cms/client

Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html);
before 1.0 a minor bump may change behaviour and says so here. Releases are
tagged `client-js-vX.Y.Z` in the
[KilnCMS repository](https://github.com/The-Verscienta/kiln_cms).

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
