# Changelog — kiln_client

Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html);
before 1.0 a minor bump may change behaviour and says so here. Releases are
tagged `kiln_client-vX.Y.Z` in the
[KilnCMS repository](https://github.com/The-Verscienta/kiln_cms).

## Unreleased

### Changed (breaking)

- **Reads return `%KilnClient.Error{}` too.** `list/2`, `one/3`, `by_ids/3`,
  the searches, `artifact/3`, `sync/1`, the revision and release reads, and
  `restore_revision/4` now fail with `{:error, %KilnClient.Error{}}`, the same
  struct the writes and `graphql/3` already returned, with the same `:reason`,
  `:status`, `:code`, `:errors`, `:retry_after`, `:method` and `:path`. This
  is the JS client's model (one `KilnError` hierarchy), and it means one
  error handler covers every call. Upgrading:

  | Before (0.4) | Now |
  |---|---|
  | `{:error, {:http_status, status, body}}` | `{:error, %KilnClient.Error{status: status, body: body}}` |
  | `{:error, %Req.TransportError{} = e}` (any exception) | `{:error, %KilnClient.Error{reason: :transport, exception: e}}` |
  | `one/3`: `{:error, :not_found}` | `{:error, %KilnClient.Error{reason: :not_found, status: 404}}` |

  `KilnClient.Error.normalize/1` still converts the old shapes, so code that
  already normalized keeps working unchanged. A 404 from a read is still not
  logged.

## 0.4.0

### Added

- **`KilnClient.Webhook` documents `data.affected`** (kiln_cms#1925): on a
  content event, Kiln 1.3.0 and later list the published documents whose
  fired artifacts embed the changed one, each
  `%{"type", "id", "slug", "locale"}`, so a cache can drop those pages in the
  same step as the document itself. The decoded payload is a plain map, so
  nothing in the client's API changes.

### Changed

- **Media writes return `%KilnClient.Error{reason: :unexpected_body}`** when
  Kiln answers 2xx without a `data` resource. `upload_media/2`,
  `import_media/2` and `complete_direct_upload/2` used to return a bare
  `{:error, {:unexpected_body, body}}` tuple, contradicting the documented
  `{:error, %KilnClient.Error{}}`; the body is now in `:body` and the endpoint
  in `:path`, matching `begin_direct_upload/3`. Code matching the old tuple
  needs updating.

### Fixed

- `KilnClient.Error`'s `reason` type, its moduledoc and the README's Errors
  table now list `:storage_refused` (a direct upload's `PUT` to object storage
  answered non-2xx) and `:unexpected_body`, which the client already returned.

## 0.3.0

### Added

- **Writes against the JSON:API write surface (kiln_cms#330):** `create/3`,
  `update/4`, `delete/3` (the reversible soft-delete), and `transition/4` with
  wrappers for the four verbs the server routes — `submit_for_review/3`,
  `return_to_draft/3`, `publish/3`, `unpublish/3`. Every write needs a
  `:read_write` API key, per call (`api_key:`) or configured, and returns
  `{:error, %KilnClient.Error{reason: :no_api_key}}` without sending anything
  when there is none.
- **`graphql/3`** — `POST /gql`, returns `{:ok, data}`; a top-level `errors`
  array is `{:error, %KilnClient.Error{reason: :graphql}}`.
- **Media uploads (kiln_cms#1576):** `upload_media/2` (multipart
  `POST /api/media`, streamed from disk), `import_media/2`,
  `update_media/3` for alt text, caption, the decorative flag, the focal point
  and tags, and `upload_media_direct/2` — which presigns, `PUT`s straight to
  object storage and completes; `begin_direct_upload/3` /
  `complete_direct_upload/2` are the two legs on their own. Uploads are
  writes: they take the key per call (`api_key:`) or from config, refuse with
  `reason: :no_api_key` before sending anything, and return the same
  `%KilnClient.Error{}` as every other write.
- **`KilnClient.Error`** — the error writes and `graphql/3` return, with a
  `:reason` atom per failure class (`:forbidden`, `:validation`, `:conflict`,
  `:rate_limited`, …), the JSON:API `errors` list, `:retry_after` from the
  `Retry-After` header, and `pointers/1` / `field_errors/1` /
  `current_state/1` helpers.
- `KilnClient.Error.normalize/1` converts a read function's error into the
  struct, for callers that want one error handler.

### Unchanged

- The read functions keep their return shapes exactly, including
  `{:error, {:http_status, status, body}}` — no read caller needs to change.

## 0.2.2

- `by_ids/3` chunks id lists at the server's 100-row page cap; past it,
  existing records were silently indistinguishable from misses
  (kiln_cms#1404).

## 0.2.1

- Per-type searches forward `:tag_ids` (kiln_cms#1219).

## 0.2.0

- Per-call `:req` overrides; `:sort` and `:limit` on the per-type searches
  (kiln_cms#511).

## 0.1.0

- First version: published-by-default JSON:API reads, per-type and hybrid
  search, fired artifacts (kiln_cms#317).
