defmodule KilnCMSWeb.DraftWriteKeyMcpTest do
  @moduledoc """
  The `:draft_write` API-key scope (#2273) over `/mcp`, with a real `kiln_`
  bearer key. `/mcp` runs the raw `AshAuthentication` API-key plug rather than
  `KilnCMSWeb.Plugs.ApiKeyAuth`, so it is its own surface to prove: the key may
  create and update its own drafts through the tools, and every other tool —
  submit-for-review, taxonomy writes, an update of a live or foreign row — is
  refused.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "dw-mcp-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner) do
    owner.id
    |> Accounts.mint_api_key!(
      "svc",
      DateTime.add(DateTime.utc_now(), 7, :day),
      %{access: :draft_write},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp slug, do: "dw-mcp-#{System.unique_integer([:positive])}"

  defp call(key, name, arguments) do
    conn =
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

    json_response(conn, 200)
  end

  defp refused?(%{"result" => %{"isError" => true}}), do: true
  defp refused?(%{"error" => _}), do: true
  defp refused?(_), do: false

  setup do
    owner = user(:viewer)
    %{owner: owner, key: mint(owner), admin: user(:admin)}
  end

  test "create_post and update_post work on the key's own draft", ctx do
    s = slug()

    resp = call(ctx.key, "create_post", %{input: %{title: "Via MCP", slug: s}})
    refute refused?(resp), inspect(resp)

    [post] = CMS.list_posts!(actor: ctx.admin, query: [filter: [slug: s]])
    assert post.state == :draft
    assert post.author_id == ctx.owner.id
    # Provenance rides the action, so MCP records the key even without a header.
    assert post.created_via_key_name == "svc"
    assert post.on_behalf_of == nil

    resp = call(ctx.key, "update_post", %{id: post.id, input: %{title: "Edited"}})
    refute refused?(resp), inspect(resp)
    assert CMS.get_post!(post.id, actor: ctx.admin).title == "Edited"
  end

  test "submit_*_for_review is refused, and the draft stays a draft", ctx do
    post = CMS.create_post!(%{title: "Mine", slug: slug()}, actor: ctx.admin)
    # Re-author as the key's owner so only the allowlist (not authorship) refuses.
    post = Ash.Seed.update!(post, %{author_id: ctx.owner.id})

    resp = call(ctx.key, "submit_post_for_review", %{id: post.id})
    assert refused?(resp), inspect(resp)
    assert CMS.get_post!(post.id, actor: ctx.admin).state == :draft
  end

  test "update of a published row, or another author's draft, is refused", ctx do
    live =
      Ash.Seed.seed!(CMS.Post, %{
        title: "Live",
        slug: slug(),
        state: :published,
        author_id: ctx.owner.id
      })

    theirs =
      Ash.Seed.seed!(CMS.Post, %{
        title: "Theirs",
        slug: slug(),
        state: :draft,
        author_id: user(:editor).id
      })

    assert refused?(call(ctx.key, "update_post", %{id: live.id, input: %{title: "X"}}))
    assert refused?(call(ctx.key, "update_post", %{id: theirs.id, input: %{title: "X"}}))

    assert CMS.get_post!(live.id, actor: ctx.admin).title == "Live"
    assert CMS.get_post!(theirs.id, actor: ctx.admin).title == "Theirs"
  end

  test "create_tag and create_category are refused", ctx do
    assert refused?(call(ctx.key, "create_tag", %{input: %{name: "t", slug: slug()}}))
    assert refused?(call(ctx.key, "create_category", %{input: %{name: "c", slug: slug()}}))

    assert CMS.list_tags!(actor: ctx.admin) |> Enum.filter(&(&1.name == "t")) == []
  end

  test "read_posts shows published rows and the key's own drafts, nobody else's", ctx do
    mine =
      Ash.Seed.seed!(CMS.Post, %{
        title: "Mine",
        slug: slug(),
        state: :draft,
        author_id: ctx.owner.id
      })

    theirs =
      Ash.Seed.seed!(CMS.Post, %{
        title: "Theirs",
        slug: slug(),
        state: :draft,
        author_id: user(:editor).id
      })

    resp = call(ctx.key, "read_posts", %{})
    refute refused?(resp), inspect(resp)
    text = inspect(resp)
    assert text =~ mine.id
    refute text =~ theirs.id
  end

  test "the toolset offers no publish or destroy tool, and no authoring beyond drafting", ctx do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{ctx.key}")
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/mcp",
        Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}})
      )

    %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    names = MapSet.new(tools, & &1["name"])

    # What it may do: read, and draft.
    for name <- ~w(read_posts create_post update_post create_page update_entry) do
      assert name in names, "expected #{name}"
    end

    # What it may not is not even offered (and tools/call refuses a hidden
    # tool, so the calls above are a second layer, not the only one).
    for name <- ~w(submit_post_for_review submit_page_for_review submit_entry_for_review
                   create_tag create_category publish_post destroy_post) do
      refute name in names, "unexpected #{name}"
    end
  end

  # Minting refuses an editor-capable owner, so this is the state a promotion
  # AFTER the mint creates. The scope must hold there: its forbid sits above
  # the admin bypass and does not read the owner's role.
  describe "owner promoted to admin after the key was minted" do
    setup ctx do
      %{owner: Ash.Seed.update!(ctx.owner, %{role: :admin})}
    end

    test "submit-for-review, update of a live row and of a foreign draft stay refused", ctx do
      own =
        Ash.Seed.seed!(CMS.Post, %{
          title: "Own",
          slug: slug(),
          state: :draft,
          author_id: ctx.owner.id
        })

      live =
        Ash.Seed.seed!(CMS.Post, %{
          title: "Live",
          slug: slug(),
          state: :published,
          author_id: ctx.owner.id
        })

      theirs =
        Ash.Seed.seed!(CMS.Post, %{
          title: "Theirs",
          slug: slug(),
          state: :draft,
          author_id: user(:editor).id
        })

      assert refused?(call(ctx.key, "submit_post_for_review", %{id: own.id}))
      assert refused?(call(ctx.key, "update_post", %{id: live.id, input: %{title: "X"}}))
      assert refused?(call(ctx.key, "update_post", %{id: theirs.id, input: %{title: "X"}}))
      assert refused?(call(ctx.key, "create_tag", %{input: %{name: "t", slug: slug()}}))

      assert CMS.get_post!(own.id, actor: ctx.admin).state == :draft
      assert CMS.get_post!(live.id, actor: ctx.admin).title == "Live"
      assert CMS.get_post!(theirs.id, actor: ctx.admin).title == "Theirs"
    end

    test "it still drafts, and the toolset still omits review and taxonomy writes", ctx do
      s = slug()
      refute refused?(call(ctx.key, "create_post", %{input: %{title: "Still drafts", slug: s}}))
      [post] = CMS.list_posts!(actor: ctx.admin, query: [filter: [slug: s]])
      assert post.state == :draft

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ctx.key}")
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/mcp",
          Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}})
        )

      %{"result" => %{"tools" => tools}} = json_response(conn, 200)
      names = MapSet.new(tools, & &1["name"])

      for name <- ~w(submit_post_for_review create_tag create_category) do
        refute name in names, "unexpected #{name}"
      end
    end
  end
end
