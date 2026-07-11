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
