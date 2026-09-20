defmodule KilnCMSWeb.GraphqlLimits do
  @moduledoc """
  What any one GraphQL document may cost. Every transport that runs a document
  uses the same limits: `POST`/`GET /gql` through `Absinthe.Plug` (`plug_pipeline/2`)
  and `/ws/gql` through `Absinthe.Phoenix` (`socket_pipeline/2`).

  Before this module the limits were Absinthe.Plug options on the `/gql` forward.
  The socket never saw them, so an anonymous `/ws/gql` client could send any
  document it liked. The limits are enforced where the document pipeline is built,
  not passed in as options, because both transports can lose the options:

    * Absinthe.Phoenix.Channel replaces a socket's options with `[context: …]`
      after it runs the first document. A cap set with `put_options/2` at connect
      would stop applying from the second document on.
    * A plug that calls `Absinthe.Plug.put_options/2` can override the
      transport's raw options for a single request.

  Each pipeline builder therefore pins the options (`options/0`) over whatever
  it receives. It also adds two phases that Absinthe does not have:

    * `KilnCMSWeb.GraphqlLimits.MaxDepth` limits how deeply fields may nest.
      Complexity cannot catch deep nesting on its own, because a chain of
      to-one fields (`featuredImage`) or of fields on a hand-written object (a
      menu's `children`) costs one per level.
      Nesting through to-many relationships is priced per row by
      `list_complexity/3`.
    * `KilnCMSWeb.GraphqlLimits.NoIntrospection` refuses `__schema` and `__type`
      where introspection is disabled (production). It checks the parsed
      document, so it covers every way a document can arrive. The regex plug it
      replaced only read `params["query"]`, and a batched body (`_json`) or a
      socket document got past it.

  HTTP batching (a JSON array body, one document per element) is limited
  separately by `KilnCMSWeb.Plugs.GraphqlBatchLimit`. Each document in a batch
  goes through this pipeline on its own, so no phase here can see the size of
  the batch.
  """

  alias Absinthe.Phase

  # The cost cap the `/gql` forward has always had. Only the documents it covers
  # have changed (the socket, now).
  @max_complexity 200

  # The GraphiQL introspection query is the deepest legitimate document here: 13
  # levels (`__schema > types > fields > args > type`, then seven `ofType`s and a
  # leaf). The playground depends on it in dev, so the limit leaves it some room.
  # No documented delivery query goes past 4.
  @max_depth 15

  # Parsing is the one step that runs before any other check, so its cost is
  # limited by counting tokens. By the lexer's count the introspection query is
  # about 150 tokens and the largest documented delivery query about 60, so 2,000
  # is roomy for a real client. It still refuses a multi-megabyte document before
  # that document is parsed into a blueprint.
  @token_limit 2_000

  # Ash does not cap a relationship list that is loaded without a `limit`, and
  # ash_graphql prices that list as `child + 1`, the cost of one row. So
  # `relatedPosts { relatedPosts { … } }` cost about 2 per level while returning
  # k^depth rows. This is the number of rows assumed instead. It is a price, not
  # a cap: the load still returns every row. What it bounds is nesting, since two
  # unlimited list levels cost 5 × 5 = 25 × child and four cost 625, over the cap.
  # A client that passes `limit` pays for that many rows, so small lists stay cheap.
  #
  # Inside a page the price is multiplied by the page size, which is 25 by
  # default. `publishedPosts { results { title tags { name } } }` costs
  # 25 × (1 + 1 + 5) = 175. Add a second list per row and a client has to ask for
  # a smaller page or pass `limit` on the lists.
  @unlimited_list_rows 5

  @doc "The complexity cap, enforced by Absinthe's complexity result phase."
  @spec max_complexity() :: pos_integer()
  def max_complexity, do: @max_complexity

  @doc "The deepest field nesting a document may have (`KilnCMSWeb.GraphqlLimits.MaxDepth`)."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc "The token limit Absinthe's parse phase applies."
  @spec token_limit() :: pos_integer()
  def token_limit, do: @token_limit

  @doc """
  The Absinthe options every document runs with. They are merged *over* the
  options a transport passes, so no caller can loosen them.
  """
  @spec options() :: keyword()
  def options do
    [analyze_complexity: true, max_complexity: @max_complexity, token_limit: @token_limit]
  end

  @doc "`Absinthe.Plug`'s `:pipeline` callback for `/gql` (see `KilnCMSWeb.Router.graphql_opts/0`)."
  @spec plug_pipeline(map(), keyword()) :: Absinthe.Pipeline.t()
  def plug_pipeline(config, pipeline_opts) do
    config
    |> Absinthe.Plug.default_pipeline(pin(pipeline_opts))
    |> add_phases()
  end

  @doc "`Absinthe.Phoenix.Socket`'s `:pipeline` callback for `/ws/gql` (see `KilnCMSWeb.GraphqlSocket`)."
  @spec socket_pipeline(Absinthe.Schema.t(), keyword()) :: Absinthe.Pipeline.t()
  def socket_pipeline(schema, pipeline_opts) do
    # The same pipeline `Absinthe.Phoenix.Channel.default_pipeline/2` builds.
    schema
    |> Absinthe.Pipeline.for_document(pin(pipeline_opts))
    |> add_phases()
  end

  defp pin(pipeline_opts), do: Keyword.merge(pipeline_opts, options())

  # Both phases add their errors before the validation result phase, so a refused
  # document is answered like any other invalid document, with `errors` and no
  # `data`. Its resolvers never run.
  defp add_phases(pipeline) do
    Absinthe.Pipeline.insert_before(pipeline, Phase.Document.Validation.Result, [
      {KilnCMSWeb.GraphqlLimits.MaxDepth, max_depth: @max_depth},
      KilnCMSWeb.GraphqlLimits.NoIntrospection
    ])
  end

  @doc """
  Whether a document may use `__schema` and `__type`. The value is
  `config :kiln_cms, :graphql_introspection`: `true` by default and `false` in
  `config/prod.exs`. It is read on every document so a test can change it.
  """
  @spec introspection_enabled?() :: boolean()
  def introspection_enabled?, do: Application.get_env(:kiln_cms, :graphql_introspection, true)

  @doc """
  The complexity of a relationship list field. Set as the `graphql` `complexity`
  of every resource that is the destination of a to-many relationship on the
  GraphQL surface. ash_graphql reads that option for the relationship fields
  that point *at* the resource.

  With a row count — `limit`, or relay's `first`/`last` — the list is priced at
  that many rows, as ash_graphql prices it. Without one it is priced at
  `#{@unlimited_list_rows}` rows, not 1. The price never drops to 0: `limit: 0`
  still costs a row, so an empty limit cannot make its subtree free (ash_graphql
  prices that at 0, which would make the whole subtree free).
  """
  @spec list_complexity(map(), non_neg_integer(), term()) :: pos_integer()
  def list_complexity(args, child_complexity, _info) do
    rows =
      case args do
        %{limit: limit} when is_integer(limit) -> max(limit, 1)
        %{first: first} when is_integer(first) -> max(first, 1)
        %{last: last} when is_integer(last) -> max(last, 1)
        _no_row_count -> @unlimited_list_rows
      end

    rows * max(child_complexity, 1)
  end
end
