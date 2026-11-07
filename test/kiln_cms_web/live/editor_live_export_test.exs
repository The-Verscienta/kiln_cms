defmodule KilnCMSWeb.EditorLiveExportTest do
  @moduledoc """
  The content list's Export disclosure and the bulk bar's "Export selected"
  (#2293): the links carry the list's filters (field conditions and field sort
  included), a selection travels as `ids`, the private-fields checkbox exists
  only where there is a private field, and a selection past the URL's limit
  is refused on screen. The download itself is `ContentExportController`'s.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp uniq, do: System.unique_integer([:positive])

  defp authed_user(role) do
    email = "exp-#{uniq()}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp define!(admin, name, attrs) do
    CMS.create_field_definition!(
      Map.merge(
        %{content_type: :page, name: name, label: String.capitalize(name), field_type: :string},
        attrs
      ),
      actor: admin
    )
  end

  defp a_page(prefix, custom_fields \\ %{}) do
    Ash.Seed.seed!(Page, %{
      title: "#{prefix} page #{uniq()}",
      slug: "exp-#{uniq()}",
      state: :draft,
      custom_fields: custom_fields
    })
  end

  defp open(conn, prefix, params \\ %{}) do
    query = URI.encode_query(Map.merge(%{"type" => "page", "q" => prefix}, params))
    {:ok, lv, _html} = live(conn, "/editor?" <> query)
    lv
  end

  defp href(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("href")
    |> List.first()
  end

  defp query_of(href), do: href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  setup %{conn: conn} do
    admin = authed_user(:admin)
    define!(admin, "price", %{field_type: :integer})
    %{conn: log_in(conn, admin), admin: admin, prefix: "Exp#{uniq()}"}
  end

  test "the links are plain downloads that carry the list's filters", %{
    conn: conn,
    prefix: prefix
  } do
    a_page(prefix, %{"price" => 5})
    lv = open(conn, prefix, %{"status" => "draft"})

    assert has_element?(lv, "#content-export #content-export-toggle[aria-expanded=false]")

    for {id, path, ext} <- [
          {"#export-csv", href(lv, "#export-csv"), "csv"},
          {"#export-json", href(lv, "#export-json"), "json"}
        ] do
      assert path =~ "/editor/content/export.#{ext}?"
      assert %{"type" => "page", "q" => ^prefix, "status" => "draft"} = query_of(path)
      refute has_element?(lv, "#{id}[phx-click]")
    end
  end

  test "field conditions and a field sort ride along on both links", %{conn: conn, prefix: prefix} do
    a_page(prefix, %{"price" => 5})
    cf = "price:gte:3"
    lv = open(conn, prefix, %{"cf" => cf, "sort" => "-field:price"})

    for selector <- ["#export-csv", "#export-json"] do
      assert %{"cf" => ^cf, "sort" => "-field:price"} = query_of(href(lv, selector))
    end
  end

  test "Export selected carries the ticked rows' ids and only the type", %{
    conn: conn,
    prefix: prefix
  } do
    one = a_page(prefix)
    two = a_page(prefix)
    _untouched = a_page(prefix)
    lv = open(conn, prefix, %{"status" => "draft"})

    refute has_element?(lv, "#bulk-export-selected")

    for page <- [one, two],
        do: render_click(lv, "toggle_select", %{"key" => "page:#{page.id}"})

    params = query_of(href(lv, "#bulk-export-selected"))
    assert params |> Map.keys() |> Enum.sort() == ["ids", "type"]
    assert params["type"] == "page"
    assert params["ids"] |> String.split(",") |> Enum.sort() == Enum.sort([one.id, two.id])
  end

  test "Export selected is off, with the reason, past the id limit", %{conn: conn, prefix: prefix} do
    a_page(prefix)
    lv = open(conn, prefix)

    for _n <- 1..(KilnCMSWeb.EditorLive.ListScope.max_ids() + 1),
        do: render_click(lv, "toggle_select", %{"key" => "page:#{Ecto.UUID.generate()}"})

    assert has_element?(lv, "button#bulk-export-selected[disabled]")
    refute has_element?(lv, "a#bulk-export-selected")
    assert has_element?(lv, "#bulk-export-limit", "Select at most 100 rows to export.")
  end

  describe "Include private fields" do
    test "is absent when the type has no private field", %{conn: conn, prefix: prefix} do
      a_page(prefix)
      lv = open(conn, prefix)

      refute has_element?(lv, "#export-private")
      refute href(lv, "#export-csv") =~ "private"
      assert has_element?(lv, "#content-export-panel", "Exports the columns shown in the list.")
    end

    test "appears for a private field and adds private=1 to every link when ticked", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      define!(admin, "secret", %{field_type: :string, private: true})
      page = a_page(prefix)
      lv = open(conn, prefix)

      assert has_element?(lv, "#export-private:not([checked])")
      refute href(lv, "#export-csv") =~ "private"

      lv |> element("#export-private") |> render_click()

      assert has_element?(lv, "#export-private[checked]")
      assert %{"private" => "1"} = query_of(href(lv, "#export-csv"))
      assert %{"private" => "1"} = query_of(href(lv, "#export-json"))

      render_click(lv, "toggle_select", %{"key" => "page:#{page.id}"})
      assert %{"private" => "1", "ids" => _} = query_of(href(lv, "#bulk-export-selected"))
    end

    test "a person field counts: it is always private", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      define!(admin, "owner", %{field_type: :user})
      a_page(prefix)
      lv = open(conn, prefix)

      assert has_element?(lv, "#export-private")
    end
  end

  test "a viewer never reaches the list, so never the export controls", %{prefix: prefix} do
    a_page(prefix)
    viewer = authed_user(:viewer)
    conn = log_in(Phoenix.ConnTest.build_conn(), viewer)

    # A viewer cannot open the editor at all; the export controls never render.
    assert {:error, _redirect} = live(conn, "/editor?type=page&q=#{prefix}")
  end

  test "the count is not known until the disclosure opens, then labels the summary", %{
    conn: conn,
    prefix: prefix
  } do
    for _n <- 1..3, do: a_page(prefix)
    lv = open(conn, prefix)

    assert has_element?(lv, "#export-summary", "Export matching")
    refute has_element?(lv, "#export-summary", "3 matching")

    lv |> element("#content-export-toggle") |> render_click()

    assert has_element?(lv, "#export-summary", "Export 3 matching")
    assert has_element?(lv, "#export-csv")
  end

  test "changing the filter forgets the count", %{conn: conn, prefix: prefix} do
    for _n <- 1..2, do: a_page(prefix)
    lv = open(conn, prefix)
    lv |> element("#content-export-toggle") |> render_click()
    assert has_element?(lv, "#export-summary", "Export 2 matching")

    lv |> form("#content-filter", %{"status" => "draft"}) |> render_change()

    assert has_element?(lv, "#export-summary", "Export matching")
  end
end
