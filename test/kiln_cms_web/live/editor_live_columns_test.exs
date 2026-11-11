defmodule KilnCMSWeb.EditorLiveColumnsTest do
  @moduledoc """
  The content list's custom-field columns: the Columns picker (one type at a
  time), the choice remembered per user, and the field strip on each row. The
  strip never prints a reference target the viewer cannot read, nor a person's
  email address.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post

  @password "password123456"

  defp uniq, do: System.unique_integer([:positive])

  defp authed_user(role) do
    email = "cols-#{uniq()}@example.com"

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

  defp a_page(prefix, custom_fields) do
    Ash.Seed.seed!(Page, %{
      title: "#{prefix} page #{uniq()}",
      slug: "col-#{uniq()}",
      state: :draft,
      custom_fields: custom_fields
    })
  end

  defp snapshot(target, title) do
    %{"id" => target.id, "type" => "post", "slug" => target.slug, "title" => title}
  end

  defp strip(lv, page), do: lv |> element("#row-fields-page-#{page.id}") |> render()

  setup %{conn: conn} do
    admin = authed_user(:admin)
    prefix = "Cols#{uniq()}"

    define!(admin, "price", %{field_type: :integer})

    define!(admin, "color", %{
      field_type: :select,
      options: ["red", "blue"],
      option_labels: %{"red" => "Crimson"}
    })

    define!(admin, "flag", %{field_type: :boolean})
    define!(admin, "related", %{field_type: :reference, target_type: "post"})
    define!(admin, "owner", %{field_type: :user})
    define!(admin, "shape", %{field_type: :group})

    %{conn: log_in(conn, admin), admin: admin, prefix: prefix}
  end

  defp open(conn, prefix, params \\ %{}) do
    query = URI.encode_query(Map.merge(%{"type" => "page", "q" => prefix}, params))
    {:ok, lv, html} = live(conn, "/editor?" <> query)
    {lv, html}
  end

  defp pick(lv, names),
    do: render_hook(lv, "set_columns", %{"type" => "page", "columns" => names})

  test "a type offers the picker with its displayable fields; no strip until one is chosen", %{
    conn: conn,
    prefix: prefix
  } do
    page = a_page(prefix, %{"price" => 12})
    {lv, _html} = open(conn, prefix)

    assert has_element?(lv, "#content-columns #content-columns-toggle[aria-expanded=false]")

    for name <- ~w(price color flag related owner) do
      assert has_element?(lv, ~s(#content-columns-form input[type=checkbox][value="#{name}"]))
    end

    refute has_element?(lv, ~s(#content-columns-form input[value="shape"]))
    refute has_element?(lv, "#row-fields-page-#{page.id}")
  end

  test "chosen columns render on every row, are remembered, and survive a fresh visit", %{
    conn: conn,
    admin: admin,
    prefix: prefix
  } do
    page =
      a_page(prefix, %{"price" => 12, "color" => "red", "flag" => true, "ignored" => "nope"})

    {lv, _html} = open(conn, prefix)
    pick(lv, ["price", "color", "flag"])

    html = strip(lv, page)
    assert html =~ "Price"
    assert html =~ "12"
    assert html =~ "Crimson"
    assert html =~ "Yes"
    refute html =~ "nope"
    assert has_element?(lv, ~s(#content-columns-form input[value="price"][checked]))

    stored = Accounts.get_user!(admin.id, actor: admin)

    assert KilnCMS.CMS.ListFields.stored_columns(
             stored,
             Accounts.default_org_id(),
             "page"
           ) == ["price", "color", "flag"]

    # A new session (a reload) reads the remembered choice back.
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, again} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => to_string(admin.email), "password" => @password},
        []
      )

    {:ok, lv2, _} =
      live(log_in(Phoenix.ConnTest.build_conn(), again), "/editor?type=page&q=#{prefix}")

    assert has_element?(lv2, "#row-fields-page-#{page.id}", "Crimson")
  end

  test "at most four columns show on a row, and a fifth is stored but not drawn", %{
    conn: conn,
    prefix: prefix
  } do
    page = a_page(prefix, %{})
    {lv, _html} = open(conn, prefix)
    pick(lv, ~w(price color flag related owner))

    assert lv
           |> element("#row-fields-page-#{page.id}")
           |> render()
           |> Floki.parse_fragment!()
           |> Floki.find("dt")
           |> length() == 4
  end

  test "type=all offers no picker and draws no strip, only a hint", %{conn: conn, prefix: prefix} do
    page = a_page(prefix, %{"price" => 12})
    {lv, _html} = open(conn, prefix)
    pick(lv, ["price"])
    assert has_element?(lv, "#row-fields-page-#{page.id}")

    {:ok, all, _html} = live(conn, "/editor?q=#{prefix}")
    refute has_element?(all, "#content-columns")
    assert has_element?(all, "#content-columns-hint")
    refute has_element?(all, "#row-fields-page-#{page.id}")
  end

  test "a forged set_columns changes nothing: another type, an unoffered field, a bad shape", %{
    conn: conn,
    prefix: prefix
  } do
    page = a_page(prefix, %{"price" => 12})
    {lv, _html} = open(conn, prefix)

    render_hook(lv, "set_columns", %{"type" => "post", "columns" => ["price"]})
    render_hook(lv, "set_columns", %{"type" => "page", "columns" => ["shape"]})
    render_hook(lv, "set_columns", %{"type" => "page", "columns" => ["nope"]})
    render_hook(lv, "set_columns", %{"type" => "page", "columns" => "price"})
    render_hook(lv, "set_columns", %{"type" => "page", "columns" => [1]})
    render_hook(lv, "set_columns", %{"type" => ["page"], "columns" => ["price"]})
    render_hook(lv, "set_columns", %{"type" => "page", "columns" => Enum.map(1..7, &"f#{&1}")})

    refute has_element?(lv, "#row-fields-page-#{page.id}")
    assert render(lv) =~ prefix
  end

  test "an unreadable reference target is Unavailable, and its snapshot title is printed nowhere",
       %{conn: conn, prefix: prefix} do
    other = KilnCMS.OrgFixtures.org("cols-other")

    secret =
      Ash.Seed.seed!(Post, %{
        title: "SECRET-TITLE-#{uniq()}",
        slug: "secret-#{uniq()}",
        state: :draft,
        org_id: other.id
      })

    readable =
      Ash.Seed.seed!(Post, %{title: "Readable-#{uniq()}", slug: "ok-#{uniq()}", state: :draft})

    hidden_page = a_page(prefix, %{"related" => snapshot(secret, secret.title)})
    shown_page = a_page(prefix, %{"related" => snapshot(readable, "stale snapshot title")})

    {lv, _html} = open(conn, prefix)
    pick(lv, ["related"])

    assert strip(lv, hidden_page) =~ "Unavailable"
    refute render(lv) =~ secret.title
    refute render(lv) =~ secret.slug

    assert strip(lv, shown_page) =~ readable.title
    refute render(lv) =~ "stale snapshot title"
  end

  test "a person shows by name, never by email, and one off the roster is Unavailable", %{
    conn: conn,
    prefix: prefix
  } do
    email = "nameless-#{uniq()}@example.com"

    nameless =
      Ash.Seed.seed!(User, %{
        email: email,
        hashed_password: Bcrypt.hash_pwd_salt(@password),
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })

    named =
      Ash.Seed.seed!(User, %{
        email: "named-#{uniq()}@example.com",
        name: "Ada Lovelace",
        hashed_password: Bcrypt.hash_pwd_salt(@password),
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })

    a = a_page(prefix, %{"owner" => nameless.id})
    b = a_page(prefix, %{"owner" => named.id})
    c = a_page(prefix, %{"owner" => Ecto.UUID.generate()})

    {lv, _html} = open(conn, prefix)
    pick(lv, ["owner"])

    assert strip(lv, a) =~ "Unnamed user"
    assert strip(lv, b) =~ "Ada Lovelace"
    assert strip(lv, c) =~ "Unavailable"
    refute render(lv) =~ email
  end

  test "choosing columns keeps the selection", %{conn: conn, prefix: prefix} do
    page = a_page(prefix, %{"price" => 3})
    {lv, _html} = open(conn, prefix)

    lv |> element("#page-#{page.id} input[phx-click=toggle_select]") |> render_click()
    assert has_element?(lv, "#content-selected-count", "1 selected")

    pick(lv, ["price"])

    assert has_element?(lv, "#content-selected-count", "1 selected")
    assert has_element?(lv, "#row-fields-page-#{page.id}")
  end

  test "an emptied choice removes the strip", %{conn: conn, prefix: prefix} do
    page = a_page(prefix, %{"price" => 3})
    {lv, _html} = open(conn, prefix)
    pick(lv, ["price"])
    assert has_element?(lv, "#row-fields-page-#{page.id}")

    pick(lv, [])
    refute has_element?(lv, "#row-fields-page-#{page.id}")
  end

  test "load more keeps the strip on the rows it adds", %{conn: conn, prefix: prefix} do
    pages = for n <- 1..52, do: a_page(prefix, %{"price" => n})
    {lv, _html} = open(conn, prefix)
    pick(lv, ["price"])

    lv |> element("button[phx-click=load_more]") |> render_click()

    for page <- pages, do: assert(has_element?(lv, "#row-fields-page-#{page.id}"))
  end
end
