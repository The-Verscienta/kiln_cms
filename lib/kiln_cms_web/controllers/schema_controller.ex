defmodule KilnCMSWeb.SchemaController do
  @moduledoc """
  The live delivery schema for this site (#430).

  `GET /api/schema` returns the JSON Schema describing what
  `GET /api/content/:type/:slug?surface=json` serves: the `_type`-discriminated
  block union and one document schema per content type. A typed client can
  fetch it at build time instead of vendoring a copy that goes stale the moment
  an admin adds a custom field.

  Per **site**, not per deployment: dynamic content types and custom fields are
  organization-scoped, so the schema is built for the org the request host
  resolves to.

      GET /api/schema                 # every content type on this site
      GET /api/schema?type=post,page  # just these
      GET /api/schema?blocks=only     # the block union alone, no DB read
      GET /api/schema?format=typescript          # the same types as a .d.ts
      GET /api/schema?format=typescript-graphql  # + GraphQL custom-field fragments
      GET /api/schema?format=swift               # Swift Codable models
      GET /api/schema?format=swift-graphql       # Swift models + the same fragments
      GET /api/schema?format=kotlin              # Kotlin models, package kiln
      GET /api/schema?format=kotlin&package=com.example.kiln
      GET /api/schema?format=kotlin-graphql      # Kotlin models + the same fragments
      GET /api/schema?format=openapi             # the same schemas as OpenAPI 3.1 components

  `format` is a closed set: `json` (the default, and what every request without
  it gets), `typescript` (`KilnCMS.SchemaExport.TypeScript.emit/1`) and
  `typescript-graphql` (`emit_graphql/1`, a `.ts` module: per content type a
  `Fields` type and a ready GraphQL fragment for the typed custom-field readers,
  #2290), `swift` / `kotlin` (`KilnCMS.SchemaExport.Swift` / `Kotlin`
  `emit/1`: the native-app models, byte for byte what `mix kiln.export.schema
  --format swift|kotlin` writes, #2362), `swift-graphql` / `kotlin-graphql`
  (`emit_graphql/1`: the same models plus the per-type result type and
  fragment), and `openapi` (`KilnCMS.SchemaExport.OpenApi.emit/1`: the `json`
  document's `$defs` as OpenAPI 3.1 `components.schemas`, #2274). Anything
  else is a 400. Each format is cached under its own key; the list is
  `KilnCMS.SchemaExport.served_formats/0`, which the cache bust reads too.

  `package` (#2363) sets the Kotlin file's package for `kotlin` and
  `kotlin-graphql` (default `kiln`). It must pass
  `KilnCMS.SchemaExport.Kotlin.valid_package?/1` and is a 400 otherwise, or
  with any other format. The default package is served from the cached body;
  any other is re-emitted from the cached JSON document, so a caller-chosen
  name never becomes a cache key.

  ## What this discloses, and what it withholds

  It publishes **shape**: block type names, content type names, custom-field
  names and their JSON types. All of that is already inferable from a single
  published document of each type, and every route it describes stays behind
  the same policies and API-key scopes it did before — the argument
  `KilnCMSWeb.Plugs.ApiDocs` makes for the OpenAPI document, with the
  difference that gated it there absent here: this describes the **read**
  surface only, so it is not a map of the mutation API.

  A reference field's `selection` (#2285) is published as `x-kiln-selection`
  by the same rule: only its live conditions, and never one that names a
  private field (so none a #2281 read grant could hide, which are private
  fields). What remains is states, owner, sort, tag and category ids and the
  equality values on non-private fields: configuration of which records a
  field accepts, not content, and the tags and categories are world-readable.
  The endpoint is anonymous, so this is what an anonymous caller learns.

  It deliberately withholds the parts of the field registry that are editorial
  rather than structural, because those are *not* inferable from published
  output and `KilnCMS.CMS.FieldDefinition`'s own read policy is editor-gated:
  `help_text` (admin-authored guidance, rendered on no public surface) and a
  `:select`'s option list. The org id is withheld too — it is the value
  threaded as `tenant:` on every Ash read, and a typed client has no use for
  it.

  A site whose *type and field names* are themselves sensitive — an unannounced
  dynamic type is visible here before anything is published — needs a gate this
  endpoint does not yet have; see the follow-up issue linked from
  `KilnCMS.SchemaExport`.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Cache
  alias KilnCMS.SchemaExport
  alias KilnCMS.SchemaExport.Kotlin
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Params
  alias KilnCMSWeb.Tenant

  # The schema changes only when an admin edits the type/field registry, and
  # `Cache.bust_type_registry/1` already fires on exactly those writes — so the
  # TTL is a backstop, not the freshness signal.
  @cache_ttl :timer.minutes(5)
  @max_age_seconds 300

  @kotlin_formats ["kotlin", "kotlin-graphql"]

  # Far past any real package name; a cap so the validity check never runs on
  # a caller-sized string.
  @max_package_bytes 255

  # Rebuilding costs a registry scan plus one `field_definitions` read per
  # content type, so only the unparameterized document — the one a build step
  # actually fetches — is cached. A filtered request is rarer and cheaper, and
  # caching every `?type=` combination would be an attacker-chosen key space.
  def show(conn, params) do
    with {:ok, format} <- format(params),
         {:ok, package} <- package(params, format) do
      show(conn, params, format, package)
    else
      {:error, code, message} -> ApiError.send(conn, :bad_request, code, message)
    end
  end

  defp show(conn, params, format, package) do
    org = Tenant.current_org(conn)
    types = types_param(params)
    blocks_only? = Params.string(params, "blocks", "") == "only"

    opts =
      [org_id: org.id, base_url: Tenant.base_url(org)]
      |> put_unless_empty(:types, types)
      |> put_if(:blocks_only, blocks_only?)
      |> put_if(:graphql, String.ends_with?(format, "-graphql"))

    case build(opts, types, blocks_only?, org.id, format, package) do
      {:ok, body} ->
        conn = put_resp_header(conn, "cache-control", "public, max-age=#{@max_age_seconds}")
        send_body(conn, format, body)

      {:error, message} ->
        ApiError.send(conn, :bad_request, "invalid_type", message)
    end
  end

  defp send_body(conn, "json", document), do: json(conn, document)
  defp send_body(conn, "openapi", document), do: json(conn, document)

  # A literal content type per clause: a variable one reads to Sobelow as a
  # response whose type a request could choose.
  defp send_body(conn, swift, body) when swift in ["swift", "swift-graphql"] do
    conn |> put_resp_content_type("text/x-swift") |> send_resp(200, body)
  end

  defp send_body(conn, kotlin, body) when kotlin in ["kotlin", "kotlin-graphql"] do
    conn |> put_resp_content_type("text/x-kotlin") |> send_resp(200, body)
  end

  defp send_body(conn, _typescript, body) do
    conn |> put_resp_content_type("application/typescript") |> send_resp(200, body)
  end

  # Absent or empty is JSON, so the unparameterized request is unchanged.
  defp format(params) do
    case Params.string(params, "format", "") do
      format when format in ["", "json"] ->
        {:ok, "json"}

      format ->
        if format in SchemaExport.served_formats(), do: {:ok, format}, else: invalid_format()
    end
  end

  defp invalid_format do
    {:error, "invalid_format",
     "unknown format. Known: " <> Enum.join(["json" | SchemaExport.served_formats()], ", ")}
  end

  # `nil` for the default package, so absent, empty and an explicit `kiln` all
  # take the cached body. The length cap comes first: `valid_package?/1` splits
  # and regex-matches every segment, and a query string is caller-sized.
  defp package(params, format) do
    case Params.string(params, "package", "") do
      "" ->
        {:ok, nil}

      _package when format not in @kotlin_formats ->
        {:error, "invalid_package", "package applies to format=kotlin and kotlin-graphql only."}

      package when byte_size(package) > @max_package_bytes ->
        invalid_package()

      package ->
        cond do
          package == Kotlin.default_package() -> {:ok, nil}
          Kotlin.valid_package?(package) -> {:ok, package}
          true -> invalid_package()
        end
    end
  end

  defp invalid_package,
    do:
      {:error, "invalid_package", "package is not a Kotlin package name (e.g. com.example.kiln)."}

  # The unparameterized document takes no caller input that can be rejected, so
  # it needs no rescue — and only successes ever reach the cache.
  defp build(opts, [], false, org_id, "json", nil), do: {:ok, cached_document(opts, org_id)}

  defp build(opts, [], false, org_id, format, nil) do
    {:ok,
     Cache.fetch(Cache.delivery_schema_key(org_id, format), @cache_ttl, fn ->
       format_document(SchemaExport.json_schema(opts), format, nil)
     end)}
  end

  # A non-default package is caller-chosen, so its body is not cached under
  # its own key; it is re-emitted from the cached document instead, which is
  # the expensive half (the registry scan and field reads).
  defp build(opts, [], false, org_id, format, package) do
    {:ok, format_document(cached_document(opts, org_id), format, package)}
  end

  defp build(opts, _types, _blocks_only?, _org_id, format, package) do
    with {:ok, document} <- export(opts), do: {:ok, format_document(document, format, package)}
  end

  # The JSON document a format is rendered from: the plain one (also the
  # `json` response) or the one annotated for the GraphQL formats. Each under
  # its own key, both busted by `Cache.bust_type_registry/1`.
  defp cached_document(opts, org_id) do
    key =
      if opts[:graphql],
        do: Cache.delivery_schema_graphql_key(org_id),
        else: Cache.delivery_schema_key(org_id)

    Cache.fetch(key, @cache_ttl, fn -> SchemaExport.json_schema(opts) end)
  end

  defp format_document(document, "json", _package), do: document

  defp format_document(document, "typescript", _package),
    do: SchemaExport.TypeScript.emit(document)

  defp format_document(document, "typescript-graphql", _package),
    do: SchemaExport.TypeScript.emit_graphql(document)

  defp format_document(document, "swift", _package), do: SchemaExport.Swift.emit(document)

  defp format_document(document, "swift-graphql", _package),
    do: SchemaExport.Swift.emit_graphql(document)

  defp format_document(document, "kotlin", package),
    do: Kotlin.emit(document, kotlin_opts(package))

  defp format_document(document, "kotlin-graphql", package),
    do: Kotlin.emit_graphql(document, kotlin_opts(package))

  defp format_document(document, "openapi", _package), do: SchemaExport.OpenApi.emit(document)

  defp kotlin_opts(nil), do: []
  defp kotlin_opts(package), do: [package: package]

  # The rescue is around this call alone, not the action body. `Tenant.current_org/1`
  # raises `ArgumentError` **by design** (#563) when the tenant did not resolve,
  # and a function-wide rescue would turn that deliberate loud failure into a
  # 400 nothing alerts on — while echoing its internal diagnostic, assign keys
  # included, to an unauthenticated caller.
  defp export(opts) do
    {:ok, SchemaExport.json_schema(opts)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp types_param(params) do
    params |> Params.string("type", "") |> String.split(",", trim: true)
  end

  defp put_unless_empty(opts, _key, []), do: opts
  defp put_unless_empty(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_if(opts, _key, false), do: opts
  defp put_if(opts, key, true), do: Keyword.put(opts, key, true)
end
