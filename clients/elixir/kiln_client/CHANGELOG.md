# Changelog — kiln_client

Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html);
before 1.0 a minor bump may change behaviour and says so here. Releases are
tagged `kiln_client-vX.Y.Z` in the
[KilnCMS repository](https://github.com/The-Verscienta/kiln_cms).

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
