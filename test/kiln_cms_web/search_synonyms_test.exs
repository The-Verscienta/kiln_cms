defmodule KilnCMSWeb.SearchSynonymsTest do
  @moduledoc """
  A search synonym added in the console (`/editor/search-synonyms`) changes
  every search surface alike, with no consumer code (A7): `/api/search`
  (which reports `also_searched`), the `/mcp` `search_content` tool, and
  `/api/ask` retrieval.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp user(role) do
    email = "synweb-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp uniq, do: System.unique_integer([:positive])

  defp mcp_key(owner) do
    KilnCMS.Accounts.mint_api_key!(
      owner.id,
      "mcp",
      DateTime.add(DateTime.utc_now(), 30, :day),
      %{access: :read},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp mcp_search(key, query) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{key}")
    |> put_req_header("content-type", "application/json")
    |> post(
      ~p"/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "search_content", arguments: %{input: %{query: query}}}
      })
    )
    |> json_response(200)
    |> then(fn %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} ->
      Jason.decode!(text)
    end)
  end

  # The rule, written through the console form the way an editor would.
  defp add_rule_in_console(conn, editor, terms) do
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/search-synonyms")

    html =
      lv
      |> form("#synonym-form", rule: %{kind: "group", terms: terms, enabled: "true"})
      |> render_submit()

    assert html =~ "Synonym rule saved"
    lv
  end

  setup do
    admin = user(:admin)
    n = uniq()

    post =
      %{title: "Zorb#{n} Plim handbook", slug: "synweb-#{uniq()}"}
      |> CMS.create_post!(actor: admin)
      |> CMS.publish_post!(%{}, actor: admin)

    %{n: n, post: post, query: "qwyx#{n}"}
  end

  test "before any rule, no surface finds the record", %{conn: conn, query: query} do
    search = conn |> get(~p"/api/search?q=#{query}") |> json_response(200)
    assert search["results"]["posts"] == []
    assert search["also_searched"] == []

    assert mcp_search(mcp_key(user(:viewer)), query)["results"] == []

    assert build_conn()
           |> get(~p"/api/ask?q=#{query}")
           |> json_response(200)
           |> Map.get("sources") ==
             []
  end

  test "a rule added in the console changes /api/search, /mcp and /api/ask alike",
       %{conn: conn, n: n, post: post, query: query} do
    add_rule_in_console(conn, user(:editor), "#{query}, zorb#{n} plim")

    search = build_conn() |> get(~p"/api/search?q=#{query}") |> json_response(200)
    assert search["also_searched"] == ["zorb#{n} plim"]
    assert [hit] = search["results"]["posts"]
    assert hit["id"] == post.id
    assert "synonym" in hit["legs"]

    mcp = mcp_search(mcp_key(user(:viewer)), query)
    assert mcp["also_searched"] == ["zorb#{n} plim"]
    assert [%{"id" => id, "type" => "post", "legs" => legs}] = mcp["results"]
    assert id == post.id
    assert "synonym" in legs

    ask = build_conn() |> get(~p"/api/ask?q=#{query}") |> json_response(200)
    assert Enum.map(ask["sources"], & &1["title"]) == [post.title]
  end

  test "a rule turned off in the console stops applying", %{conn: conn, n: n, query: query} do
    lv = add_rule_in_console(conn, user(:editor), "#{query}, zorb#{n} plim")
    [rule] = CMS.list_search_synonyms!(authorize?: false)

    lv |> element("#synonym-#{rule.id} button", "Turn off") |> render_click()

    search = build_conn() |> get(~p"/api/search?q=#{query}") |> json_response(200)
    assert search["also_searched"] == []
    assert search["results"]["posts"] == []
  end

  test "the console's trial box shows what a query is also searched as",
       %{conn: conn, n: n, query: query} do
    lv = add_rule_in_console(conn, user(:editor), "#{query}, zorb#{n} plim")

    html = lv |> form("#synonym-try", q: "#{query} tea") |> render_change()
    assert html =~ "zorb#{n} plim tea"
  end

  test "an editor is not offered delete; an admin is", %{conn: conn, query: query} do
    CMS.create_search_synonym!(%{terms: [query, "other#{uniq()}"]}, actor: user(:editor))

    {:ok, _lv, html} = conn |> log_in(user(:editor)) |> live(~p"/editor/search-synonyms")
    refute html =~ ~s(aria-label="Delete rule")

    {:ok, lv, html} = build_conn() |> log_in(user(:admin)) |> live(~p"/editor/search-synonyms")
    assert html =~ ~s(aria-label="Delete rule")

    lv |> element(~s(button[aria-label="Delete rule"])) |> render_click()
    assert CMS.list_search_synonyms!(authorize?: false) == []
  end

  test "a viewer cannot open the console", %{conn: conn} do
    assert {:error, {:redirect, _}} =
             conn |> log_in(user(:viewer)) |> live(~p"/editor/search-synonyms")
  end
end
