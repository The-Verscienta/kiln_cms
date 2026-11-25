defmodule KilnCMSWeb.PortableTextWriteCheckTest do
  @moduledoc """
  A headless write's Portable Text is checked against the published
  `portable_text_block` schema (#2768): JSON:API, GraphQL and MCP all send the
  body as `block_tree`, and a shape that would crash or misrender a reader is
  refused there with its path, naming the type it found and never the value.
  Scalars are coerced, a `nil` mark is dropped, and nothing is written for a
  refused body.

  Every refusal test here fails on the code before #2768, where each of these
  bodies was stored.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  import KilnCMS.MalformedPortableText, only: [block: 1, block: 2, span: 2]

  @accept "application/vnd.api+json"

  # {name, body, the error the path must carry}
  @refused [
    {"marks as a string", [block([span("Bold", "strong")])],
     "body[0].children[0].marks must be a list of strings (got a string)"},
    {"an object mark", [block([span("Bold", [%{"x" => 1}])])],
     "body[0].children[0].marks[0] must be a string (got an object)"},
    {"children as a string", [block("String children")],
     "body[0].children must be a list (got a string)"},
    {"a null child", [block([nil])], "body[0].children[0] must be an object (got null)"},
    {"an object text", [block([span(%{"secret" => "x"}, [])])],
     "body[0].children[0].text must be a string (got an object)"},
    {"a string markDefs entry", [block([span("a", [])], %{"markDefs" => ["x"]})],
     "body[0].markDefs[0] must be an object (got a string)"},
    {"a top-level string node", ["x"], "body[0] must be an object (got a string)"},
    {"an object style", [block([span("a", [])], %{"style" => %{"h" => 2}})],
     "body[0].style must be a string (got an object)"},
    {"a non-numeric level", [block([span("a", [])], %{"listItem" => "bullet", "level" => "two"})],
     "body[0].level must be an integer (got a non-numeric string)"},
    {"a list listItem", [block([span("a", [])], %{"listItem" => ["bullet"]})],
     "body[0].listItem must be a string (got a list)"},
    {"string children on a custom node", [%{"_type" => "callout", "children" => "Callout"}],
     "body[0].children must be a list (got a string)"},
    {"marks as a string in a table cell",
     [
       %{
         "_type" => "table",
         "rows" => [%{"cells" => [%{"children" => [span("Cell", "strong")]}]}]
       }
     ], "body[0].rows[0].cells[0].children[0].marks must be a list of strings (got a string)"}
  ]

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pt-write-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner) do
    key =
      Accounts.mint_api_key!(
        owner.id,
        "pt-write",
        DateTime.add(DateTime.utc_now(), 30, :day),
        %{access: :read_write},
        actor: user(:admin)
      )

    Ash.Resource.get_metadata(key, :plaintext_api_key)
  end

  defp slug, do: "pt-write-#{System.unique_integer([:positive])}"

  defp rich_text(body), do: [%{"_type" => "rich_text", "body" => body}]

  defp stored_body(%{blocks: [%Ash.Union{value: %{body: body}}]}), do: body

  # --- JSON:API -------------------------------------------------------------

  defp json_api(method, path, data, key) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")
      |> dispatch(@endpoint, method, path, Jason.encode!(%{data: data}))

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp assert_json_api_refusal({status, body}, expected) do
    assert status == 400

    assert [
             %{
               "code" => "invalid_attribute",
               "detail" => detail,
               "source" => %{"pointer" => "/data/attributes/block_tree"}
             }
           ] = body["errors"]

    assert detail == "is not valid Portable Text: block_tree[0].#{expected}"
    refute detail =~ "secret"
  end

  describe "JSON:API" do
    test "POST refuses each shape with its path and creates nothing" do
      key = mint(user(:editor))

      for {name, body, expected} <- @refused do
        s = slug()

        response =
          json_api(
            :post,
            "/api/json/posts",
            %{type: "post", attributes: %{title: name, slug: s, block_tree: rich_text(body)}},
            key
          )

        assert_json_api_refusal(response, expected)
        assert [] = CMS.list_posts!(authorize?: false, query: [filter: [slug: s]])
      end
    end

    test "PATCH refuses each shape and leaves the body as it was" do
      editor = user(:editor)
      key = mint(editor)
      kept = rich_text([block([span("Kept", [])])])
      post = CMS.create_post!(%{title: "Patch", slug: slug(), block_tree: kept}, actor: editor)

      for {_name, body, expected} <- @refused do
        response =
          json_api(
            :patch,
            "/api/json/posts/#{post.id}",
            %{type: "post", id: post.id, attributes: %{block_tree: rich_text(body)}},
            key
          )

        assert_json_api_refusal(response, expected)
        assert stored_body(CMS.get_post!(post.id, authorize?: false)) == hd(kept)["body"]
      end
    end

    test "more than five errors are capped with a count" do
      body = for _ <- 1..7, do: "x"

      {400, response} =
        json_api(
          :post,
          "/api/json/posts",
          %{type: "post", attributes: %{title: "Cap", slug: slug(), block_tree: rich_text(body)}},
          mint(user(:editor))
        )

      [%{"detail" => detail}] = response["errors"]

      assert detail ==
               "is not valid Portable Text: " <>
                 Enum.map_join(
                   0..4,
                   "; ",
                   &"block_tree[0].body[#{&1}] must be an object (got a string)"
                 ) <>
                 "; and 2 more"
    end
  end

  # --- GraphQL --------------------------------------------------------------

  defp gql(query, variables, key) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> post("/gql", Jason.encode!(%{query: query, variables: variables}))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  # `blockTree` is a list of JSON strings on the GraphQL surface.
  defp gql_tree(tree), do: Enum.map(tree, &Jason.encode!/1)

  describe "GraphQL" do
    test "createPost refuses each shape: errors, a null result, nothing written" do
      key = mint(user(:editor))

      query = """
      mutation ($input: CreatePostInput!) {
        createPost(input: $input) { result { id } errors { message } }
      }
      """

      for {_name, body, expected} <- @refused do
        s = slug()
        input = %{title: "GQL", slug: s, blockTree: gql_tree(rich_text(body))}

        assert %{"result" => nil, "errors" => [%{"message" => message}]} =
                 gql(query, %{input: input}, key)["data"]["createPost"]

        assert message =~ "block_tree[0].#{expected}"
        assert [] = CMS.list_posts!(authorize?: false, query: [filter: [slug: s]])
      end
    end

    test "updatePost refuses each shape and leaves the body as it was" do
      editor = user(:editor)
      key = mint(editor)
      kept = rich_text([block([span("Kept", [])])])
      post = CMS.create_post!(%{title: "GQL", slug: slug(), block_tree: kept}, actor: editor)

      query = """
      mutation ($id: ID!, $input: UpdatePostInput!) {
        updatePost(id: $id, input: $input) { result { id } errors { message } }
      }
      """

      for {_name, body, expected} <- @refused do
        assert %{"result" => nil, "errors" => [%{"message" => message}]} =
                 gql(query, %{id: post.id, input: %{blockTree: gql_tree(rich_text(body))}}, key)[
                   "data"
                 ][
                   "updatePost"
                 ]

        assert message =~ "block_tree[0].#{expected}"
        assert stored_body(CMS.get_post!(post.id, authorize?: false)) == hd(kept)["body"]
      end
    end
  end

  # --- MCP ------------------------------------------------------------------

  defp tool(name, arguments, key) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{key}")
    |> put_req_header("content-type", "application/json")
    |> post(
      ~p"/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: arguments}
      })
    )
    |> json_response(200)
  end

  defp assert_tool_refusal(response, expected) do
    assert %{"result" => %{"isError" => true, "content" => [%{"text" => text} | _]}} = response
    assert text =~ "block_tree[0].#{expected}"
  end

  describe "MCP" do
    test "create_page refuses each shape and creates nothing" do
      key = mint(user(:editor))

      for {_name, body, expected} <- @refused do
        s = slug()

        "create_page"
        |> tool(%{input: %{title: "MCP", slug: s, block_tree: rich_text(body)}}, key)
        |> assert_tool_refusal(expected)

        assert [] = CMS.list_pages!(authorize?: false, query: [filter: [slug: s]])
      end
    end

    test "update_page refuses each shape on a draft" do
      editor = user(:editor)
      key = mint(editor)
      kept = rich_text([block([span("Kept", [])])])
      page = CMS.create_page!(%{title: "MCP", slug: slug(), block_tree: kept}, actor: editor)

      for {_name, body, expected} <- @refused do
        "update_page"
        |> tool(%{id: page.id, input: %{block_tree: rich_text(body)}}, key)
        |> assert_tool_refusal(expected)

        assert stored_body(CMS.get_page!(page.id, authorize?: false)) == hd(kept)["body"]
      end
    end

    test "save_page_working_copy refuses each shape and holds nothing" do
      admin = user(:admin)
      key = mint(user(:editor))

      page =
        %{title: "Live", slug: slug(), block_tree: rich_text([block([span("Live", [])])])}
        |> CMS.create_page!(actor: admin)
        |> CMS.publish_page!(%{}, actor: admin)

      for {_name, body, expected} <- @refused do
        "save_page_working_copy"
        |> tool(%{id: page.id, input: %{block_tree: rich_text(body)}}, key)
        |> assert_tool_refusal(expected)

        assert CMS.get_page!(page.id, authorize?: false).working_copy_at == nil
      end
    end
  end

  # --- What is accepted -----------------------------------------------------

  describe "accepted bodies" do
    setup do
      editor = user(:editor)
      %{editor: editor, key: mint(editor)}
    end

    defp post_body(key, block_tree) do
      s = slug()

      {201, _} =
        json_api(
          :post,
          "/api/json/posts",
          %{type: "post", attributes: %{title: "Ok", slug: s, block_tree: block_tree}},
          key
        )

      [post] = CMS.list_posts!(authorize?: false, query: [filter: [slug: s]])
      post
    end

    test "a valid body round-trips unchanged", %{key: key} do
      body = [
        block([span("Plain ", []), span("linked", ["strong", "lk"])], %{
          "markDefs" => [%{"_key" => "lk", "_type" => "link", "href" => "https://example.com"}]
        }),
        block([span("item", [])], %{"_key" => "b1", "listItem" => "bullet", "level" => 2}),
        %{"_type" => "callout", "_key" => "c0", "tone" => %{"any" => ["shape"]}},
        %{"_type" => "block", "children" => [%{"text" => "no marks"}]}
      ]

      assert stored_body(post_body(key, rich_text(body))) == body
    end

    # A reader leaves these alone, so the check does too: a body a client got
    # back from a `:json` artifact can always be sent again.
    test "a custom node's, inline object's and annotation's own fields are kept as sent",
         %{key: key} do
      body = [
        %{
          "_type" => "callout",
          "_key" => %{"not" => "a string"},
          "style" => ["warning"],
          "level" => %{"severity" => 3},
          "children" => [
            %{"_type" => "span", "text" => "Inside", "marks" => ["fn"]},
            %{"_type" => "mention", "text" => %{"id" => 1}, "_key" => [1], "marks" => []}
          ],
          "markDefs" => [%{"_key" => "fn", "_type" => ["footnote"], "body" => %{"x" => 1}}]
        }
      ]

      assert stored_body(post_body(key, rich_text(body))) == body
    end

    # The cast reads a `type`/`value` envelope beside a `"_type": null` as the
    # envelope, so the check does too.
    test "an envelope with a null _type is checked", %{key: key} do
      tree = [
        %{
          "_type" => nil,
          "type" => "rich_text",
          "value" => %{"body" => [block([span("a", "strong")])]}
        }
      ]

      {400, response} =
        json_api(
          :post,
          "/api/json/posts",
          %{type: "post", attributes: %{title: "Env", slug: slug(), block_tree: tree}},
          key
        )

      assert [%{"detail" => detail}] = response["errors"]

      assert detail ==
               "is not valid Portable Text: block_tree[0].value.body[0].children[0].marks " <>
                 "must be a list of strings (got a string)"
    end

    test "scalars are coerced, as the #2743 rule coerces them", %{key: key} do
      body = [
        block([span(42, [1, "em"])], %{"_key" => 3, "listItem" => "number", "level" => "2"})
      ]

      assert [
               %{
                 "_key" => "3",
                 "level" => 2,
                 "children" => [%{"text" => "42", "marks" => ["1", "em"]}]
               }
             ] = stored_body(post_body(key, rich_text(body)))
    end

    test "a null mark is dropped, not refused", %{key: key} do
      body = [block([span("Bold", [nil, "strong", nil])])]

      assert [%{"children" => [%{"marks" => ["strong"]}]}] =
               stored_body(post_body(key, rich_text(body)))
    end

    test "a JSON-string body is decoded and checked", %{key: key} do
      {400, response} =
        json_api(
          :post,
          "/api/json/posts",
          %{
            type: "post",
            attributes: %{
              title: "String",
              slug: slug(),
              block_tree: rich_text(Jason.encode!([block("String children")]))
            }
          },
          key
        )

      assert [%{"detail" => detail}] = response["errors"]
      assert detail =~ "block_tree[0].body[0].children must be a list (got a string)"

      post = post_body(key, rich_text(Jason.encode!([block([span(7, [])])])))
      assert [%{"children" => [%{"text" => "7"}]}] = stored_body(post)
    end

    # The editor's own shape: converted, and what the conversion makes is
    # repaired rather than checked, so no path points into a body the client
    # did not send.
    test "a TipTap document body is converted, not refused", %{key: key} do
      doc = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "text" => "Doc", "marks" => "bold"}]
          }
        ]
      }

      assert [%{"children" => [%{"text" => "Doc", "marks" => []}]}] =
               stored_body(post_body(key, rich_text(doc)))
    end
  end

  describe "nested in columns" do
    test "a child's body is checked with its full path" do
      tree = [
        %{
          "_type" => "columns",
          "columns" => [
            %{"blocks" => []},
            %{"blocks" => rich_text([block([span("a", "strong")])])}
          ]
        }
      ]

      {400, response} =
        json_api(
          :post,
          "/api/json/posts",
          %{type: "post", attributes: %{title: "Cols", slug: slug(), block_tree: tree}},
          mint(user(:editor))
        )

      assert [%{"detail" => detail}] = response["errors"]

      assert detail ==
               "is not valid Portable Text: block_tree[0].columns[1].blocks[0].body[0]" <>
                 ".children[0].marks must be a list of strings (got a string)"
    end

    test "a child's coerced body is what is stored" do
      editor = user(:editor)

      tree = [
        %{"_type" => "columns", "columns" => [%{"blocks" => rich_text([block([span(5, [])])])}]}
      ]

      page = CMS.create_page!(%{title: "Cols", slug: slug(), block_tree: tree}, actor: editor)

      [%Ash.Union{value: columns}] = page.blocks
      [%{"blocks" => [child]}] = columns.columns
      assert [%{"children" => [%{"text" => "5"}]}] = child["body"]
    end
  end

  # A plugin block's `:rich_text` field (the `note` fixture's `summary`).
  describe "a plugin block's :rich_text field" do
    test "is checked like a core body" do
      tree = [%{"_type" => "note", "title" => "N", "summary" => [block([span("a", "strong")])]}]

      {400, response} =
        json_api(
          :post,
          "/api/json/posts",
          %{type: "post", attributes: %{title: "Note", slug: slug(), block_tree: tree}},
          mint(user(:editor))
        )

      assert [%{"detail" => detail}] = response["errors"]

      assert detail ==
               "is not valid Portable Text: block_tree[0].summary[0].children[0].marks " <>
                 "must be a list of strings (got a string)"
    end

    # Fails on the code before #2768: a plugin field was stored as sent.
    test "has its link hrefs scrubbed, through the API and an internal write" do
      editor = user(:editor)

      summary = [
        block([span("click", ["lk"])], %{
          "markDefs" => [%{"_key" => "lk", "_type" => "link", "href" => "javascript:alert(1)"}]
        })
      ]

      tree = [%{"_type" => "note", "title" => "N", "summary" => summary}]

      for attrs <- [%{block_tree: tree}, %{blocks: tree}] do
        page = CMS.create_page!(Map.merge(%{title: "Note", slug: slug()}, attrs), actor: editor)

        [%Ash.Union{value: note}] = page.blocks
        assert [%{"markDefs" => [%{"href" => ""}]}] = note.summary
      end
    end

    # Fails on the code before #2768: an internal write stored the shape as sent.
    test "is repaired, not refused, on an internal write" do
      editor = user(:editor)
      tree = [%{"_type" => "note", "title" => "N", "summary" => [block([span("a", "strong")])]}]

      page = CMS.create_page!(%{title: "Note", slug: slug(), blocks: tree}, actor: editor)

      [%Ash.Union{value: note}] = page.blocks
      assert [%{"children" => [%{"marks" => ["strong"]}]}] = note.summary
    end
  end
end
