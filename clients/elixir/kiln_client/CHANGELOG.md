# Changelog — kiln_client

Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html);
before 1.0 a minor bump may change behaviour and says so here. Releases are
tagged `kiln_client-vX.Y.Z` in the
[KilnCMS repository](https://github.com/The-Verscienta/kiln_cms).

## Unreleased

### Fixed

- **`by_ids/3` keeps the caller's `:filter`.** It replaced the filter with
  the id list, so `by_ids("entries", ids, filter: %{locale: "fr"})` returned
  entries in every locale. The id condition is now merged into the caller's
  filter, as the JavaScript client already did.

## 0.8.0

### Added

- **OpenAPI components (kiln_cms#2274):** `schema/1` takes `format:
  :openapi` (or `"openapi"`), which asks for `GET /api/schema?format=openapi`,
  the delivery schema as an OpenAPI 3.1 document; the result is a map either
  way. `:json` (or `"json"`) is the default and sends no `format`. Any other
  value raises `ArgumentError` before a request is made, since the text
  formats (`typescript`, `swift-graphql`, ...) are not maps. Needs a server
  with #2274; an older one answers `400` (`invalid_format`).

- **Human verification on forms (kiln_cms#2249):** `form/2` and
  `submit_form/3` document the new response keys. A form's schema may carry
  `"challenge"`, `nil` or the widget's `"provider"`, `"site_key"`,
  `"script_url"`, `"action"` and `"field"` (`"_kiln_challenge"`); relay the
  visitor's token in the params under that name. The submit result then
  carries `"challenge" => "verified"` or `"held"` (stored for review, not
  acted on); a refused token is `reason: :validation` with
  `"_kiln_challenge"` in its field errors. Documentation only: the client
  passes both through unchanged, and servers older than this send neither.

- **Any provider's widget (kiln_cms#2249):** the documented `"challenge"`
  keys now include `"global"`, `"onload_param"`, `"render_options"`,
  `"action_option"`, `"interactive"` and `"api"`, which describe how the
  visitor's browser draws the operator's provider (Cloudflare Turnstile,
  Google reCAPTCHA v2 or a plugin's). A server relaying a browser's
  reCAPTCHA submission may find the token under `"g-recaptcha-response"`;
  the server accepts it there too. Documentation only.

## 0.7.0

### Added

- `text_search/3` and `semantic_search/3` take `:custom_sort` (kiln_cms#2292).
  The server also accepts a custom field's bare name in `:filter` / `:sort`,
  but this client keeps emitting `custom_filter` / `custom_sort`, the stable form.

- **`:draft_write` keys (kiln_cms#2273):** `create/3` takes `on_behalf_of:`,
  sent as the `X-Kiln-On-Behalf-Of` header, which Kiln records on a draft
  created with a `:draft_write` API key so reviewers see which of your users
  it was for. Stored only, never authorization; `nil` sends nothing, and
  other writes never send it (the server reads it on `POST` only). The module
  doc and README describe what a `:draft_write` key may do, and the three
  optional provenance attributes (`"created_via_key_id"`,
  `"created_via_key_name"`, `"on_behalf_of"`) a created record carries back.
  Needs a Kiln server newer than 1.8; an older one ignores the header.

## 0.6.0

### Added

- **Parity with the JS client (kiln_cms#2127):** `artifact/3` takes `:as_of`
  for a point-in-time read (a `DateTime`, `NaiveDateTime`, `Date` or ISO 8601
  string). `content_as_of/3` reads a collection as it was then.
  `mint_preview/3` mints a draft preview token, needing a key like the writes.
  `schema/1` reads the live delivery schema. `sync_page/2` reads one page of
  `/api/sync` for callers that stream.
- **Headless routing, navigation and forms (kiln_cms#2128):**
  `resolve_path/2` (`GET /api/resolve`), `menus/1` and `menu/2`
  (`GET /api/menus[/:key]`), `locales/1`, `related/3`
  (`GET /api/content/:type/:slug/related`), and `form/2` / `submit_form/3`
  (`GET`/`POST /api/forms/:slug`). `resolve_path/2` returns the server's
  `"not_found"` verdict as `{:ok, %{"status" => "not_found"}}`, not an error.
  `submit_form/3` never sends the configured API key.
- `menu/2`, `related/3` and `resolve_path/2` take `:fallback` and
  `:fallback_locale` beside `:locale`.
- `KilnClient.Error.field_errors/1` also reads a refused form submission's
  `%{"errors" => %{field => message}}` body.

`resolve_path/2` is not named `resolve`, because `resolve/3` already joins a
relationship through an included lookup.

## 0.5.0

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

## 0.4.1

### Security

- **Requires Req 0.6.1 or later** (`>= 0.6.1 and < 1.0.0`, was `~> 0.5`).
  The old requirement let Mix resolve Req 0.5.x, which has two published
  advisories: EEF-CVE-2026-49755 (HIGH, a decompression bomb in auto-decoded
  response bodies) and EEF-CVE-2026-49756 (LOW, header injection in multipart
  uploads, the encoding `upload_media/2` uses). Both are fixed in Req 0.6.1.
  Nothing else changes. If your lock already has Req 0.6.1 or later, this
  release changes nothing for you. If it has 0.5.x, `mix deps.update req`
  moves it.

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
