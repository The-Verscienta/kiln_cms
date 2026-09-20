defmodule KilnCMSWeb.ApiSpecs do
  @moduledoc """
  The two machine-readable descriptions of the headless API, rendered the same
  way wherever they are needed:

    * `graphql_sdl/0` — the GraphQL schema behind `/gql`, as SDL;
    * `open_api/0` — the OpenAPI 3 document for the JSON:API surface
      (`KilnCMSWeb.AshJsonApiRouter`, enriched by `KilnCMSWeb.OpenApi`).

  ## Why both are committed

  A production build turns GraphQL introspection off and does not serve the
  OpenAPI document (#567). Both are right for an anonymous caller, but they
  left a client author nothing to point codegen at: the spec only existed on a
  dev server. So `mix kiln.api.specs` writes both into `docs/api/`, CI fails
  when they fall behind the code (`mix kiln.api.specs --check`), and the
  documentation build publishes them.

  The committed files describe the **stock** build. A downstream project that
  adds content domains (`config :kiln_cms, :content_domains`) grows both
  schemas, so the committed copies are a starting point for such a site, not
  its contract. Its own running instance is: `KilnCMSWeb.ApiSpecController`
  serves the running schema's SDL, and `KilnCMSWeb.Plugs.ApiDocs` lets the
  OpenAPI route answer, to a caller holding an API key.

  ## Stable output

  Both renderings are sorted where the source order is incidental, so that
  regenerating an unchanged schema is a no-op and a real change is a readable
  diff: SDL type and directive definitions by name (fields keep the order the
  resources declare them in), and every JSON object's keys. Neither sort
  changes what the document means.
  """

  alias Absinthe.Blueprint.Schema.SchemaDefinition

  @schema Module.concat(["KilnCMSWeb.GraphqlSchema"])

  # The committed OpenAPI document cannot name a host: it is the same file for
  # every deployment. A server variable says so in the one place OpenAPI has
  # for it, and codegen tools that need a base URL take it from their own
  # configuration anyway.
  @placeholder_server %OpenApiSpex.Server{
    url: "{origin}",
    description: "Your KilnCMS site",
    variables: %{
      "origin" => %OpenApiSpex.ServerVariable{
        default: "http://localhost:4000",
        description: "The site's origin — scheme, host and port, no trailing slash"
      }
    }
  }

  @doc "Where `mix kiln.api.specs` writes the GraphQL SDL, relative to the project root."
  @spec sdl_path() :: String.t()
  def sdl_path, do: "docs/api/schema.graphql"

  @doc "Where `mix kiln.api.specs` writes the OpenAPI document, relative to the project root."
  @spec open_api_path() :: String.t()
  def open_api_path, do: "docs/api/openapi.json"

  @doc """
  Whether the request was authenticated with an API key.

  The one credential that opens the specs where they are otherwise closed —
  see `KilnCMSWeb.Plugs.ApiDocs` for why a key and not a JWT. Reads the actor
  `KilnCMSWeb.Plugs.ApiKeyAuth` set: AshAuthentication's API-key sign-in marks
  it `using_api_key?`, and an invalid key never gets this far (the plug 401s).
  """
  @spec api_key_caller?(Plug.Conn.t()) :: boolean()
  def api_key_caller?(conn) do
    match?(%{__metadata__: %{using_api_key?: true}}, Ash.PlugHelpers.get_actor(conn))
  end

  @doc """
  `graphql_sdl/0`, rendered once per compiled schema.

  Rendering runs the schema pipeline — tens of milliseconds, far more than a
  lookup — and the result cannot change while the same schema module is
  loaded. Keyed by the module's MD5, so a recompiled schema in development is
  rendered afresh instead of served stale.
  """
  @spec cached_graphql_sdl() :: String.t()
  def cached_graphql_sdl do
    key = {__MODULE__, :graphql_sdl, @schema.module_info(:md5)}

    case :persistent_term.get(key, nil) do
      nil ->
        sdl = graphql_sdl()
        :persistent_term.put(key, sdl)
        sdl

      sdl ->
        sdl
    end
  end

  @doc """
  The GraphQL schema as SDL, type definitions sorted by name.

  The same pipeline as `Absinthe.Schema.to_sdl/1`, with one step between
  running it and rendering it: the sort.
  """
  @spec graphql_sdl() :: String.t()
  def graphql_sdl do
    pipeline =
      @schema
      |> Absinthe.Pipeline.for_schema(prototype_schema: @schema.__absinthe_prototype_schema__())
      |> Absinthe.Pipeline.upto({Absinthe.Phase.Schema.Validation.Result, pass: :final})
      |> Absinthe.Schema.apply_modifiers(@schema)

    # Assertive for the reason `to_sdl/1` is: the schema compiled through this
    # same pipeline, so it cannot fail here without having failed the build.
    {:ok, blueprint, _phases} = Absinthe.Pipeline.run(@schema.__absinthe_blueprint__(), pipeline)

    blueprint
    |> Map.update!(:schema_definitions, fn definitions -> Enum.map(definitions, &sort/1) end)
    |> inspect(pretty: true)
  end

  defp sort(%SchemaDefinition{} = definition) do
    %{
      definition
      | type_definitions: Enum.sort_by(definition.type_definitions, & &1.name),
        directive_definitions: Enum.sort_by(definition.directive_definitions, & &1.name)
    }
  end

  @doc """
  The OpenAPI document as pretty-printed JSON with sorted keys, naming a
  placeholder origin rather than a host (see `@placeholder_server`).

  The same document `GET /api/json/open_api` serves, built the way
  `KilnCMSWeb.AshJsonApiRouter` builds it, minus the request: the served copy
  names the host it was requested from instead.
  """
  @spec open_api() :: String.t()
  def open_api do
    [
      domains: KilnCMSWeb.AshJsonApiRouter.domains(),
      prefix: "/api/json",
      modify_open_api: {KilnCMSWeb.OpenApi, :modify, []},
      # Without a conn, `KilnCMSWeb.OpenApi.modify/3` falls back to the
      # endpoint's URL, which needs a started endpoint, and `mix kiln.api.specs`
      # does not start one. A server given up front is used as it is — and
      # then replaced by the full one, variables and all.
      open_api_servers: [@placeholder_server.url]
    ]
    |> AshJsonApi.OpenApi.spec()
    |> Map.put(:servers, [@placeholder_server])
    # Through JSON and back first: the spec is a tree of OpenApiSpex structs,
    # and their `Jason.Encoder` is what drops the nil fields.
    |> Jason.encode!()
    |> Jason.decode!()
    |> ordered()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp ordered(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value
end
