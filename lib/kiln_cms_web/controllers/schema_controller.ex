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
      GET /api/schema?format=swift-graphql       # Swift models + the same fragments
      GET /api/schema?format=kotlin-graphql      # Kotlin models + the same fragments
      GET /api/schema?format=openapi             # the same schemas as OpenAPI 3.1 components

  `format` is a closed set: `json` (the default, and what every request without
  it gets), `typescript` (`KilnCMS.SchemaExport.TypeScript.emit/1`) and
  `typescript-graphql` (`emit_graphql/1`, a `.ts` module: per content type a
  `Fields` type and a ready GraphQL fragment for the typed custom-field readers,
  #2290), and `swift-graphql` / `kotlin-graphql` (`KilnCMS.SchemaExport.Swift` /
  `Kotlin` `emit_graphql/1`: the native-app models of the `json` artifact plus
  the same per-type result type and fragment, in package `kiln` for Kotlin),
  and `openapi` (`KilnCMS.SchemaExport.OpenApi.emit/1`: the `json` document's
  `$defs` as OpenAPI 3.1 `components.schemas`, #2274). Anything else is a 400.
  Each format is cached under its own key; the list is
  `KilnCMS.SchemaExport.served_formats/0`, which the cache bust reads too.

  ## What this discloses, and what it withholds

  It publishes **shape**: block type names, content type names, custom-field
  names and their JSON types. All of that is already inferable from a single
  published document of each type, and every route it describes stays behind
  the same policies and API-key scopes it did before — the argument
  `KilnCMSWeb.Plugs.ApiDocs` makes for the OpenAPI document, with the
  difference that gated it there absent here: this describes the **read**
  surface only, so it is not a map of the mutation API.

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
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Params
  alias KilnCMSWeb.Tenant

  # The schema changes only when an admin edits the type/field registry, and
  # `Cache.bust_type_registry/1` already fires on exactly those writes — so the
  # TTL is a backstop, not the freshness signal.
  @cache_ttl :timer.minutes(5)
  @max_age_seconds 300

  # Rebuilding costs a registry scan plus one `field_definitions` read per
  # content type, so only the unparameterized document — the one a build step
  # actually fetches — is cached. A filtered request is rarer and cheaper, and
  # caching every `?type=` combination would be an attacker-chosen key space.
  def show(conn, params) do
    case format(params) do
      {:ok, format} -> show(conn, params, format)
      :error -> ApiError.send(conn, :bad_request, "invalid_format", invalid_format_message())
    end
  end

  defp show(conn, params, format) do
    org = Tenant.current_org(conn)
    types = types_param(params)
    blocks_only? = Params.string(params, "blocks", "") == "only"

    opts =
      [org_id: org.id, base_url: Tenant.base_url(org)]
      |> put_unless_empty(:types, types)
      |> put_if(:blocks_only, blocks_only?)
      |> put_if(:graphql, String.ends_with?(format, "-graphql"))

    case build(opts, types, blocks_only?, org.id, format) do
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
  defp send_body(conn, "swift-graphql", body) do
    conn |> put_resp_content_type("text/x-swift") |> send_resp(200, body)
  end

  defp send_body(conn, "kotlin-graphql", body) do
    conn |> put_resp_content_type("text/x-kotlin") |> send_resp(200, body)
  end

  defp send_body(conn, _typescript, body) do
    conn |> put_resp_content_type("application/typescript") |> send_resp(200, body)
  end

  # Absent or empty is JSON, so the unparameterized request is unchanged.
  defp format(params) do
    case Params.string(params, "format", "") do
      format when format in ["", "json"] -> {:ok, "json"}
      format -> if format in SchemaExport.served_formats(), do: {:ok, format}, else: :error
    end
  end

  defp invalid_format_message,
    do: "unknown format. Known: " <> Enum.join(["json" | SchemaExport.served_formats()], ", ")

  # The unparameterized document takes no caller input that can be rejected, so
  # it needs no rescue — and only successes ever reach the cache.
  defp build(opts, [], false, org_id, "json") do
    {:ok,
     Cache.fetch(Cache.delivery_schema_key(org_id), @cache_ttl, fn ->
       SchemaExport.json_schema(opts)
     end)}
  end

  defp build(opts, [], false, org_id, format) do
    {:ok,
     Cache.fetch(Cache.delivery_schema_key(org_id, format), @cache_ttl, fn ->
       format_document(SchemaExport.json_schema(opts), format)
     end)}
  end

  defp build(opts, _types, _blocks_only?, _org_id, format) do
    with {:ok, document} <- export(opts), do: {:ok, format_document(document, format)}
  end

  defp format_document(document, "json"), do: document
  defp format_document(document, "typescript"), do: SchemaExport.TypeScript.emit(document)

  defp format_document(document, "typescript-graphql"),
    do: SchemaExport.TypeScript.emit_graphql(document)

  defp format_document(document, "swift-graphql"), do: SchemaExport.Swift.emit_graphql(document)
  defp format_document(document, "kotlin-graphql"), do: SchemaExport.Kotlin.emit_graphql(document)
  defp format_document(document, "openapi"), do: SchemaExport.OpenApi.emit(document)

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
