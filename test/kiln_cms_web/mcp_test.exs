defmodule KilnCMSWeb.McpTest do
  @moduledoc """
  The `/mcp` endpoint — API-key-only authentication and tool execution under
  the key's `access` scope (see docs/mcp.md).
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "mcp-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner, access) do
    key =
      Accounts.mint_api_key!(
        owner.id,
        "mcp",
        DateTime.add(DateTime.utc_now(), 30, :day),
        %{access: access},
        actor: user(:admin)
      )

    Ash.Resource.get_metadata(key, :plaintext_api_key)
  end

  defp rpc(conn, plaintext, method, params \\ %{}) do
    conn
    |> then(fn conn ->
      if plaintext,
        do: put_req_header(conn, "authorization", "Bearer #{plaintext}"),
        else: conn
    end)
    |> put_req_header("content-type", "application/json")
    |> post(~p"/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end

  test "rejects requests without an API key", %{conn: conn} do
    conn = rpc(conn, nil, "tools/list")
    assert conn.status == 401
  end

  test "rejects a non-key bearer token (no JWT access here)", %{conn: conn} do
    conn = rpc(conn, "not-a-kiln-key", "tools/list")
    assert conn.status == 401
  end

  test "initialize handshake succeeds and issues a session id", %{conn: conn} do
    plaintext = mint(user(:viewer), :read)

    conn =
      rpc(conn, plaintext, "initialize", %{
        protocolVersion: "2024-11-05",
        capabilities: %{},
        clientInfo: %{name: "test", version: "0"}
      })

    assert %{"result" => %{"protocolVersion" => _}} = json_response(conn, 200)
    assert [_session_id] = get_resp_header(conn, "mcp-session-id")
  end

  test "tools/list scopes the toolset to what the key may do", %{conn: conn} do
    # A read-write editor key sees the full authoring toolset…
    plaintext = mint(user(:editor), :read_write)

    conn = rpc(conn, plaintext, "tools/list")
    %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    names = Enum.map(tools, & &1["name"]) |> MapSet.new()

    for name <- ~w(read_pages read_posts read_entries read_type_definitions
                   create_page update_page submit_page_for_review create_post
                   create_entry create_tag create_category) do
      assert name in names, "expected tool #{name} to be exposed"
    end

    # …but publishing and destroying are never exposed as tools, for anyone.
    refute "publish_page" in names
    refute "destroy_page" in names

    # A read-only key sees the read tools and none of the authoring ones
    # (exposed_tools filters by what the actor is authorized to do).
    plaintext = mint(user(:viewer), :read)

    conn = rpc(build_conn(), plaintext, "tools/list")
    %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    names = Enum.map(tools, & &1["name"]) |> MapSet.new()

    assert "read_pages" in names
    refute "create_page" in names
    refute "update_page" in names
  end

  # The `tools` block on the domain declares a tool; `config :kiln_cms,
  # :mcp_tools` is what the `/mcp` forward actually serves. A tool present in
  # only the first is dead code that no client can reach, and the inclusion
  # assertions above can't catch it — they only check names someone remembered
  # to list. This compares the two sets directly.
  test "every tool declared on the domain is served by the /mcp forward" do
    declared = KilnCMS.CMS |> AshAi.Info.tools() |> Enum.map(& &1.name) |> MapSet.new()
    served = :kiln_cms |> Application.fetch_env!(:mcp_tools) |> MapSet.new()

    assert MapSet.difference(declared, served) |> Enum.to_list() == [],
           "declared on KilnCMS.CMS but missing from config :kiln_cms, :mcp_tools"

    assert MapSet.difference(served, declared) |> Enum.to_list() == [],
           "listed in config :kiln_cms, :mcp_tools but not declared on KilnCMS.CMS"
  end

  # #521 — the MCP surface is the sharpest case: a model asked to "tag this as
  # Elixir" sends the one id it knows. The merge verbs have to be in the tool's
  # input schema, and the description has to point at them, or the model keeps
  # reaching for the replacing `tag_ids`.
  test "update_* tools offer the tag merge verbs and say so", %{conn: conn} do
    plaintext = mint(user(:editor), :read_write)

    conn = rpc(conn, plaintext, "tools/list")
    %{"result" => %{"tools" => tools}} = json_response(conn, 200)

    # Derived, not a literal list: the file already learned this lesson for the
    # declared-vs-served check below — a hand-kept list only proves the names
    # someone remembered, so a future `update_<type>` tool would ship without
    # the hint and stay green.
    update_tools =
      KilnCMS.CMS
      |> AshAi.Info.tools()
      |> Enum.filter(&(&1.action == :update))
      |> Enum.map(&to_string(&1.name))

    assert length(update_tools) >= 3

    for name <- update_tools do
      tool = Enum.find(tools, &(&1["name"] == name))
      assert tool, "expected tool #{name} to be exposed"

      properties = get_in(tool, ["inputSchema", "properties", "input", "properties"]) || %{}

      for arg <- ~w(tag_ids add_tag_ids remove_tag_ids) do
        assert Map.has_key?(properties, arg), "#{name} is missing the #{arg} input"
      end

      assert tool["description"] =~ "add_tag_ids"
      assert tool["description"] =~ "REPLACES"
    end
  end

  # The schema/description assertions above pass even if the manage does
  # nothing, so drive a real merge through tools/call.
  test "update_post over MCP merges tags instead of replacing them", %{conn: conn} do
    editor = user(:editor)
    plaintext = mint(editor, :read_write)
    admin = user(:admin)

    a =
      KilnCMS.CMS.create_tag!(%{name: "a", slug: "mcp-a-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    b =
      KilnCMS.CMS.create_tag!(%{name: "b", slug: "mcp-b-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    post =
      KilnCMS.CMS.create_post!(
        %{title: "Tagged", slug: "mcp-p-#{System.unique_integer([:positive])}", tag_ids: [a.id]},
        actor: editor
      )

    conn =
      rpc(conn, plaintext, "tools/call", %{
        name: "update_post",
        arguments: %{id: post.id, input: %{add_tag_ids: [b.id]}}
      })

    assert %{"result" => %{"isError" => false}} = json_response(conn, 200)

    reloaded = KilnCMS.CMS.get_post!(post.id, actor: admin, load: [:tags])
    assert MapSet.new(reloaded.tags, & &1.id) == MapSet.new([a.id, b.id])
  end

  # #640. `remove_tag_ids` is `on_no_match: :ignore` so removal stays
  # idempotent, which means it is silent about an id matching no tag at all — a
  # hallucinated uuid returns the same 200 as a real detach. The tool result is
  # the record's public attributes, and `tags` is a relationship, so a model had
  # nothing in the response to check its work against and would report a
  # removal that never happened.
  test "an update_* result carries the tags, so a no-op removal is visible", %{conn: conn} do
    editor = user(:editor)
    plaintext = mint(editor, :read_write)
    admin = user(:admin)

    keeper =
      KilnCMS.CMS.create_tag!(
        %{name: "keeper", slug: "mcp-k-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    post =
      KilnCMS.CMS.create_post!(
        %{
          title: "Verifiable",
          slug: "mcp-v-#{System.unique_integer([:positive])}",
          tag_ids: [keeper.id]
        },
        actor: editor
      )

    # An id that matches no tag at all — what a model sends when it guesses.
    conn =
      rpc(conn, plaintext, "tools/call", %{
        name: "update_post",
        arguments: %{id: post.id, input: %{remove_tag_ids: [Ecto.UUID.generate()]}}
      })

    assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
             json_response(conn, 200)

    # The removal was a no-op, and the response says so by still listing the
    # tag. Before this the payload was indistinguishable from a real detach.
    assert text =~ "keeper"
    assert text =~ keeper.id

    # And a real detach is distinguishable from that.
    conn =
      build_conn()
      |> rpc(plaintext, "tools/call", %{
        name: "update_post",
        arguments: %{id: post.id, input: %{remove_tag_ids: [keeper.id]}}
      })

    assert %{"result" => %{"isError" => false, "content" => [%{"text" => after_text}]}} =
             json_response(conn, 200)

    refute after_text =~ keeper.id
  end

  test "a :read_write key on an editor account can create a draft page", %{conn: conn} do
    plaintext = mint(user(:editor), :read_write)
    slug = "mcp-#{System.unique_integer([:positive])}"

    conn =
      rpc(conn, plaintext, "tools/call", %{
        name: "create_page",
        arguments: %{input: %{title: "Written over MCP", slug: slug}}
      })

    assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
             json_response(conn, 200)

    assert text =~ slug

    # The page really exists, as a draft.
    admin = user(:admin)
    [page] = KilnCMS.CMS.list_pages!(actor: admin, query: [filter: [slug: slug]])
    assert page.state == :draft
    assert page.title == "Written over MCP"
  end

  test "a :read key cannot write through a tool, even on an admin account", %{conn: conn} do
    plaintext = mint(user(:admin), :read)
    slug = "mcp-ro-#{System.unique_integer([:positive])}"

    conn =
      rpc(conn, plaintext, "tools/call", %{
        name: "create_page",
        arguments: %{input: %{title: "Should be forbidden", slug: slug}}
      })

    # The authoring tool isn't even exposed to a read-scoped key (and the
    # content policy would forbid the write regardless — see ApiKeyTest).
    assert %{"error" => %{"message" => "Tool not found: create_page"}} =
             json_response(conn, 200)

    # Nothing was created.
    admin = user(:admin)
    assert [] = KilnCMS.CMS.list_pages!(actor: admin, query: [filter: [slug: slug]])
  end

  test "read tools work with a :read key and scope to the owner's visibility", %{conn: conn} do
    editor = user(:editor)

    draft =
      KilnCMS.CMS.create_page!(
        %{title: "Draft only", slug: "mcp-draft-#{System.unique_integer([:positive])}"},
        actor: editor
      )

    # A viewer-owned key can't see the draft; an editor-owned key can.
    for {owner, expect_draft?} <- [{user(:viewer), false}, {editor, true}] do
      plaintext = mint(owner, :read)

      conn =
        rpc(build_conn(), plaintext, "tools/call", %{
          name: "read_pages",
          arguments: %{input: %{}, filter: %{slug: %{eq: draft.slug}}}
        })

      assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
               json_response(conn, 200)

      if expect_draft? do
        assert text =~ draft.slug
      else
        refute text =~ draft.slug
      end
    end

    _ = conn
  end
end
