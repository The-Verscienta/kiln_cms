defmodule KilnCMSWeb.GraphqlLimitsTest do
  @moduledoc """
  The document limits `KilnCMSWeb.GraphqlLimits` puts on both GraphQL
  transports: complexity, depth, token count, per-row pricing of relationship
  lists, and the production introspection block. The API review of 2026-09-19
  found that `/ws/gql` ran with no limits at all, that a batched `/gql` body got
  past the introspection block, and that relationship lists nested almost for
  free. Each has a test here, on the transport where it was found.
  """
  # async: false — the introspection tests flip a global app env, and the
  # socket tests register on the shared endpoint.
  use KilnCMSWeb.ConnCase, async: false

  # ConnCase imports `Phoenix.ConnTest`, which has a `connect/2` of its own, so
  # the socket one is called qualified.
  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]

  use Absinthe.Phoenix.SubscriptionTest, schema: KilnCMSWeb.GraphqlSchema

  alias KilnCMSWeb.GraphqlLimits
  alias KilnCMSWeb.GraphqlSocket

  defp gql(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/gql", Jason.encode!(body))
    |> json_response(200)
  end

  defp messages(%{"errors" => errors}), do: Enum.map(errors, & &1["message"])
  defp messages(_no_errors), do: []

  defp socket! do
    {:ok, socket} = Phoenix.ChannelTest.connect(GraphqlSocket, %{})
    {:ok, socket} = join_absinthe(socket)
    socket
  end

  # `__type(name: "Post") { ofType { … { name } } }`, nested `depth` fields
  # deep. Introspection fields are cheap and need no data, so the depth limit
  # is the only one this document can hit.
  defp nested(depth) do
    inner = depth - 2

    ~s|{ __type(name: "Post") { | <>
      String.duplicate("ofType { ", inner) <> "name" <> String.duplicate(" }", inner) <> " } }"
  end

  # `relatedPosts` inside itself `levels` times, from a single post.
  defp related_chain(levels, args \\ "") do
    ~s|{ postBySlug(slug: "none", locale: "en") { | <>
      String.duplicate("relatedPosts#{args} { ", levels) <>
      "title" <> String.duplicate(" }", levels) <> " } }"
  end

  describe "depth" do
    test "a document nested past the limit is refused, and one at the limit is not", %{
      conn: conn
    } do
      max = GraphqlLimits.max_depth()

      assert %{"data" => %{"__type" => %{}}} = gql(conn, %{query: nested(max)})

      refused = gql(conn, %{query: nested(max + 1)})
      refute Map.has_key?(refused, "data")

      assert messages(refused) == [
               "Operation is too deep: fields nest #{max + 1} levels and the maximum is #{max}"
             ]
    end

    test "a fragment adds no depth of its own but hides none either", %{conn: conn} do
      inner = GraphqlLimits.max_depth() - 1

      query = """
      { __type(name: "Post") { ...Chain } }
      fragment Chain on __Type {
        #{String.duplicate("ofType { ", inner)}name#{String.duplicate(" }", inner)}
      }
      """

      assert [message] = messages(gql(conn, %{query: query}))
      assert message =~ "Operation is too deep"
    end

    # In the pipeline Absinthe's own cycle check aborts first, so this runs the
    # phase alone on a blueprint that still has the cycle.
    test "the check ends on a fragment cycle instead of walking it forever" do
      query = """
      { __type(name: "Post") { ...A } }
      fragment A on __Type { ofType { ...B } }
      fragment B on __Type { ofType { ...A } }
      """

      to_blueprint =
        KilnCMSWeb.GraphqlSchema
        |> Absinthe.Pipeline.for_document()
        |> Absinthe.Pipeline.upto(Absinthe.Phase.Blueprint)

      {:ok, blueprint, _phases} = Absinthe.Pipeline.run(query, to_blueprint)

      assert {:ok, %{operations: [operation]}} =
               GraphqlLimits.MaxDepth.run(blueprint, max_depth: 2)

      assert [%{message: "Operation is too deep: fields nest 3 levels and the maximum is 2"}] =
               operation.errors
    end
  end

  test "a document over the token limit is refused before it is parsed", %{conn: conn} do
    query = "{ " <> String.duplicate("health ", GraphqlLimits.token_limit()) <> "}"

    assert messages(gql(conn, %{query: query})) == ["Token limit exceeded"]
  end

  describe "the socket" do
    # The channel replaces a socket's Absinthe options with `[context: …]` after
    # every document, so a cap set at connect would hold for the first document
    # only. The over-limit documents go second on purpose.
    test "runs every document under the limits /gql has, not only the first" do
      socket = socket!()

      ref = push_doc(socket, "{ health }")
      assert_reply(ref, :ok, %{data: %{"health" => "ok"}})

      ref = push_doc(socket, related_chain(4))
      assert_reply(ref, :error, %{errors: [%{message: too_complex} | _]})
      assert too_complex =~ "is too complex"

      ref = push_doc(socket, nested(GraphqlLimits.max_depth() + 1))
      assert_reply(ref, :error, %{errors: [%{message: too_deep}]})
      assert too_deep =~ "Operation is too deep"
    end

    test "refuses introspection where it is disabled" do
      Application.put_env(:kiln_cms, :graphql_introspection, false)
      on_exit(fn -> Application.put_env(:kiln_cms, :graphql_introspection, true) end)

      ref = push_doc(socket!(), "{ __schema { types { name } } }")
      assert_reply(ref, :error, %{errors: [%{message: "GraphQL introspection is disabled"}]})
    end
  end

  test "a caller's options cannot loosen the limits" do
    pipeline =
      GraphqlLimits.socket_pipeline(KilnCMSWeb.GraphqlSchema,
        analyze_complexity: false,
        max_complexity: :infinity,
        token_limit: :infinity
      )

    assert {:ok, %{result: %{errors: [%{message: message} | _]}}, _phases} =
             Absinthe.Pipeline.run(related_chain(4), pipeline)

    assert message =~ "is too complex"
  end

  describe "relationship lists" do
    test "are priced per row, so a list nested in itself runs out of budget", %{conn: conn} do
      # 5 × 5 × 5 × title, then the post: 126.
      assert %{"data" => %{"postBySlug" => nil}} = gql(conn, %{query: related_chain(3)})

      assert [message | _] = messages(gql(conn, %{query: related_chain(4)}))
      assert message =~ "is too complex"
    end

    test "with a limit cost that many rows", %{conn: conn} do
      assert %{"data" => %{"postBySlug" => nil}} =
               gql(conn, %{query: related_chain(8, "(limit: 1)")})
    end

    test "list_complexity/3 prices a row count at its rows, none at five, and never at zero" do
      assert GraphqlLimits.list_complexity(%{limit: 3}, 4, nil) == 12
      assert GraphqlLimits.list_complexity(%{}, 4, nil) == 20
      assert GraphqlLimits.list_complexity(%{}, 0, nil) == 5

      # Relay pages count their rows too (ash_graphql reads `first`/`last` as of
      # 1.12); a zero row count still costs one row, where ash_graphql's own
      # pricing would make the subtree free.
      assert GraphqlLimits.list_complexity(%{first: 3}, 4, nil) == 12
      assert GraphqlLimits.list_complexity(%{last: 3}, 4, nil) == 12
      assert GraphqlLimits.list_complexity(%{limit: 0}, 4, nil) == 4
      assert GraphqlLimits.list_complexity(%{first: 0}, 4, nil) == 4
    end
  end

  describe "introspection, disabled as in production" do
    setup do
      Application.put_env(:kiln_cms, :graphql_introspection, false)
      on_exit(fn -> Application.put_env(:kiln_cms, :graphql_introspection, true) end)
    end

    test "is refused in a single query", %{conn: conn} do
      refused = gql(conn, %{query: "{ __schema { types { name } } }"})

      refute Map.has_key?(refused, "data")
      assert messages(refused) == ["GraphQL introspection is disabled"]
    end

    # The bypass the review found: the old plug read `params["query"]` alone,
    # and a JSON array body has none (Plug puts it under `_json`).
    test "is refused in every operation of a batched body", %{conn: conn} do
      assert [first, second] =
               gql(conn, [
                 %{query: "{ health }"},
                 %{query: "{ __schema { types { name } } }"}
               ])

      assert first["payload"]["data"] == %{"health" => "ok"}
      refute Map.has_key?(second["payload"], "data")
      assert messages(second["payload"]) == ["GraphQL introspection is disabled"]
    end

    test "is refused through an alias and over GET", %{conn: conn} do
      assert messages(gql(conn, %{query: ~s|{ t: __type(name: "Post") { name } }|})) ==
               ["GraphQL introspection is disabled"]

      assert conn
             |> get("/gql", %{query: "{ __schema { queryType { name } } }"})
             |> json_response(200)
             |> messages() == ["GraphQL introspection is disabled"]
    end

    test "leaves __typename alone", %{conn: conn} do
      assert %{"data" => %{"__typename" => "RootQueryType"}} =
               gql(conn, %{query: "{ __typename }"})
    end
  end

  test "introspection still answers where it is enabled (dev, the playground)", %{conn: conn} do
    assert %{"data" => %{"__schema" => %{"queryType" => %{"name" => "RootQueryType"}}}} =
             gql(conn, %{query: "{ __schema { queryType { name } } }"})
  end
end
