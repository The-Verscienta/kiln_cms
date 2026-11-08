defmodule KilnCMSWeb.EnumerationApiReadsTest do
  @moduledoc """
  The content APIs do not let a caller probe for an account by address (#2255,
  surface 7).

  `User` is deliberately not a JSON:API resource, a GraphQL type or an MCP
  tool. The one way left to ask a question about an author is through the
  content's own `author` relationship: a filter or sort that reaches into it
  (`filter[author][email]=…`, `sort=author.email`, an MCP filter on
  `author.email`). Each is asked here as an anonymous reader, a viewer and an
  editor, once with an address that belongs to an account (the post's author)
  and once with one that does not, and the two answers are compared whole by
  `KilnCMS.EnumerationAssertions`.

  The admin control matters as much as the refusals: it proves the question is
  one the API can actually answer, so the empty result everyone else gets comes
  from `User`'s read policy and not from a filter that never matched anything.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.EnumerationAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"
  @password "password123456"

  defp user(role, email) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp token(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => user.email, "password" => @password},
        []
      )

    signed_in.__metadata__.token
  end

  defp uniq, do: System.unique_integer([:positive])

  # An author who owns an account and one published post, and an address that
  # owns nothing.
  setup do
    known = "enum-author-#{uniq()}@example.com"
    unknown = "enum-nobody-#{uniq()}@example.com"
    author = user(:admin, known)
    known_name = "Enum Author #{uniq()}"
    unknown_name = "Enum Nobody #{uniq()}"
    author = Ash.Seed.update!(author, %{name: known_name})

    post =
      CMS.create_post!(%{title: "Byline probe", slug: "enum-api-#{uniq()}"}, actor: author)
      |> then(&CMS.publish_post!(&1, %{}, actor: author))

    %{
      known: known,
      unknown: unknown,
      author: author,
      post: post,
      known_name: known_name,
      unknown_name: unknown_name,
      emails: [known, unknown, known_name, unknown_name],
      viewer: user(:viewer, "enum-viewer-#{uniq()}@example.com"),
      editor: user(:editor, "enum-editor-#{uniq()}@example.com")
    }
  end

  # A JSON:API GET as `who` (`nil` = anonymous). The `id` of an error is a fresh
  # UUID per response, which says nothing about the request, so it is masked.
  defp json_get(path, who) do
    conn = put_req_header(build_conn(), "accept", @accept)

    conn =
      case who do
        nil -> conn
        user -> put_req_header(conn, "authorization", "Bearer #{token(user)}")
      end

    conn = get(conn, path)

    if conn.status >= 400,
      do: %{
        conn
        | resp_body: Regex.replace(~r/"id":"[0-9a-f-]{36}"/, conn.resp_body, ~s("id":"-"))
      },
      else: conn
  end

  describe "JSON:API" do
    for {label, query, key} <- [
          {"filter on author email", "filter[author][email]=%s", :email},
          {"filter on author name", "filter[author][name]=%s", :name},
          {"filter on author email through a dotted path", "filter[author.email]=%s", :email},
          {"sort by author email", "sort=author.email&filter[slug]=%s", :email}
        ] do
      test "#{label}: a known and an unknown value look alike to every non-admin", ctx do
        {known, unknown} =
          if unquote(key) == :email,
            do: {ctx.known, ctx.unknown},
            else: {ctx.known_name, ctx.unknown_name}

        for who <- [nil, ctx.viewer, ctx.editor] do
          path = fn value ->
            "/api/json/posts?" <>
              String.replace(unquote(query), "%s", URI.encode_www_form(value))
          end

          assert_indistinguishable(
            fn -> json_get(path.(known), who) end,
            fn -> json_get(path.(unknown), who) end,
            ctx.emails
          )
        end
      end
    end

    test "the author's email never appears in a non-admin's answer", ctx do
      for who <- [nil, ctx.viewer, ctx.editor] do
        conn = json_get("/api/json/posts?filter[author][email]=#{ctx.known}", who)
        assert conn.status in [200, 400]

        refute String.replace(conn.resp_body, "filter[author][email]=#{ctx.known}", "") =~
                 ctx.known
      end
    end

    test "control: an admin can ask the question, so the refusals above are the policy",
         ctx do
      admin = user(:admin, "enum-reader-#{uniq()}@example.com")

      conn = json_get("/api/json/posts?filter[author][email]=#{ctx.known}", admin)
      assert %{"data" => [%{"id" => id}]} = Jason.decode!(conn.resp_body)
      assert id == ctx.post.id

      conn = json_get("/api/json/posts?filter[author][email]=#{ctx.unknown}", admin)
      assert %{"data" => []} = Jason.decode!(conn.resp_body)

      name = URI.encode_www_form(ctx.known_name)
      conn = json_get("/api/json/posts?filter[author][name]=#{name}", admin)
      assert %{"data" => [%{"id" => ^id}]} = Jason.decode!(conn.resp_body)
    end
  end

  describe "GraphQL" do
    @schema KilnCMSWeb.GraphqlSchema

    test "no type, field or filter exposes an account address, role or author object" do
      {:ok, %{data: data}} =
        Absinthe.run(
          "{ __schema { types { name fields { name } inputFields { name } } } }",
          @schema
        )

      types = data["__schema"]["types"]

      refute Enum.any?(types, &(&1["name"] == "User"))

      offenders =
        for t <- types,
            f <- (t["fields"] || []) ++ (t["inputFields"] || []),
            f["name"] in ["email", "author", "role", "hashedPassword"],
            do: "#{t["name"]}.#{f["name"]}"

      assert offenders == []
    end

    test "a filter on the author's email is a schema error, the same for either address",
         ctx do
      query = fn email ->
        ~s|{ publishedPosts(filter: {author: {email: {eq: "#{email}"}}}) { results { id } } }|
      end

      for who <- [nil, ctx.viewer, ctx.editor] do
        run = fn email ->
          Absinthe.run(query.(email), @schema, context: %{actor: who})
        end

        assert_indistinguishable(
          fn -> run.(ctx.known) end,
          fn -> run.(ctx.unknown) end,
          ctx.emails
        )

        assert {:ok, %{errors: [_ | _]}} = run.(ctx.known)
      end
    end
  end

  describe "MCP" do
    defp mcp_key(owner, admin) do
      key =
        Accounts.mint_api_key!(
          owner.id,
          "enum",
          DateTime.add(DateTime.utc_now(), 30, :day),
          %{access: :read},
          actor: admin
        )

      Ash.Resource.get_metadata(key, :plaintext_api_key)
    end

    defp rpc(plaintext, method, params) do
      build_conn()
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
    end

    test "no tool reads or looks up an account", ctx do
      plaintext = mcp_key(ctx.editor, ctx.author)
      conn = rpc(plaintext, "tools/list", %{})
      names = Jason.decode!(conn.resp_body)["result"]["tools"] |> Enum.map(& &1["name"])

      assert names != []
      refute Enum.any?(names, &(&1 =~ ~r/user|account|member|author|email/i))
    end

    test "a filter on the author's email answers the same for either address", ctx do
      for owner <- [ctx.viewer, ctx.editor] do
        plaintext = mcp_key(owner, ctx.author)

        call = fn email ->
          rpc(plaintext, "tools/call", %{
            name: "read_posts",
            arguments: %{filter: %{field: "author.email", operator: "eq", value: email}}
          })
        end

        seen =
          assert_indistinguishable(
            fn -> call.(ctx.known) end,
            fn -> call.(ctx.unknown) end,
            ctx.emails
          )

        refute seen.body =~ ctx.known
      end
    end
  end
end
