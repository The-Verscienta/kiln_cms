defmodule KilnCMSWeb.EditorLiveFieldFiltersTest do
  @moduledoc """
  The content list's custom-field conditions and field sort, driven by the URL
  (#2293): what a `cf` narrows to, how a field sort orders (page 2 included),
  what a forged condition or a vanished field does, and the bounded count.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.Repo

  @password "password123456"

  defp uniq, do: System.unique_integer([:positive])

  defp authed_user(role) do
    email = "ff-#{uniq()}@example.com"

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
      slug: "ff-#{uniq()}",
      state: :draft,
      custom_fields: custom_fields
    })
  end

  defp open(conn, prefix, params \\ %{}) do
    query = URI.encode_query(Map.merge(%{"type" => "page", "q" => prefix}, params))
    {:ok, lv, html} = live(conn, "/editor?" <> query)
    {lv, html}
  end

  # The page ids on screen, in order.
  defp ids(html) do
    ~r/id="page-([0-9a-f-]{36})"/ |> Regex.scan(html) |> Enum.map(&List.last/1)
  end

  setup %{conn: conn} do
    admin = authed_user(:admin)
    prefix = "FF#{uniq()}"

    price = define!(admin, "price", %{field_type: :integer})
    define!(admin, "note", %{field_type: :string})
    define!(admin, "shape", %{field_type: :group})

    # A private field of ANOTHER type: unknown to a page list.
    CMS.create_field_definition!(
      %{content_type: :post, name: "secret", label: "Secret", field_type: :string, private: true},
      actor: admin
    )

    %{conn: log_in(conn, admin), admin: admin, prefix: prefix, price: price}
  end

  describe "cf in the URL" do
    test "narrows the list, and the count follows", %{conn: conn, prefix: prefix} do
      cheap = a_page(prefix, %{"price" => 5})
      mid = a_page(prefix, %{"price" => 15})
      high = a_page(prefix, %{"price" => 25})
      bare = a_page(prefix, %{})

      {lv, html} = open(conn, prefix)
      assert Enum.sort(ids(html)) == Enum.sort([cheap.id, mid.id, high.id, bare.id])

      {lv2, html} = open(conn, prefix, %{"cf" => "price:gte:10;price:lte:20"})
      assert ids(html) == [mid.id]
      assert has_element?(lv2, "#content-count", "1 item")
      refute render(lv) =~ "1 item"
    end

    test "a text condition is a case-insensitive substring, metacharacters literal", %{
      conn: conn,
      prefix: prefix
    } do
      hit = a_page(prefix, %{"note" => "Save 50% today"})
      _miss = a_page(prefix, %{"note" => "Save 500 today"})

      {_lv, html} = open(conn, prefix, %{"cf" => "note:contains:" <> URI.encode_www_form("50%")})
      assert ids(html) == [hit.id]
    end

    test "forged conditions are dropped: unknown, another type's private field, an unfilterable one",
         %{conn: conn, prefix: prefix} do
      a = a_page(prefix, %{"price" => 1})
      b = a_page(prefix, %{"price" => 2})

      for cf <- ["ghost:eq:1", "secret:eq:x", "shape:eq:1", "price:eq:abc", "price:bogus:1"] do
        {lv, html} = open(conn, prefix, %{"cf" => cf})
        assert Enum.sort(ids(html)) == Enum.sort([a.id, b.id]), cf
        assert has_element?(lv, "#content-count", "2 items")
      end
    end

    test "with several types in play cf and a field sort do nothing", %{
      conn: conn,
      prefix: prefix
    } do
      a = a_page(prefix, %{"price" => 1})
      b = a_page(prefix, %{"price" => 2})
      query = URI.encode_query(%{"q" => prefix, "cf" => "price:gte:2", "sort" => "field:price"})
      {:ok, _lv, html} = live(conn, "/editor?" <> query)
      assert Enum.sort(ids(html)) == Enum.sort([a.id, b.id])
    end
  end

  describe "field sort" do
    test "orders by the field, missing values last, and Load more continues it", %{
      conn: conn,
      prefix: prefix
    } do
      rows = for n <- 1..60, do: {n, a_page(prefix, %{"price" => rem(n, 7)})}
      bare = for _ <- 1..3, do: a_page(prefix, %{})
      by_id = Map.new(rows, fn {n, page} -> {page.id, rem(n, 7)} end)
      bare_ids = MapSet.new(bare, & &1.id)

      for {sort, dir} <- [{"field:price", :asc}, {"-field:price", :desc}] do
        {lv, html} = open(conn, prefix, %{"sort" => sort})
        first = ids(html)
        assert length(first) == 50

        lv |> element("button", "Load more") |> render_click()
        all = ids(render(lv))

        assert length(all) == 63
        assert all == Enum.uniq(all), "a row repeated across the page boundary"

        {valued, missing} = Enum.split(all, 60)
        assert MapSet.new(missing) == bare_ids

        prices = Enum.map(valued, &Map.fetch!(by_id, &1))
        assert prices == Enum.sort(prices, dir)
      end
    end

    test "a field sort that is not valid falls back to the default order", %{
      conn: conn,
      prefix: prefix
    } do
      older = a_page(prefix, %{"price" => 1})
      newer = a_page(prefix, %{"price" => 2})

      for sort <- ["field:ghost", "field:shape", "-field:"] do
        {_lv, html} = open(conn, prefix, %{"sort" => sort})
        assert ids(html) == [newer.id, older.id], sort
      end
    end
  end

  describe "events" do
    test "add_field_filter patches the URL; remove_field_filter takes it back", %{
      conn: conn,
      prefix: prefix
    } do
      low = a_page(prefix, %{"price" => 1})
      high = a_page(prefix, %{"price" => 9})
      {lv, _} = open(conn, prefix)

      render_hook(lv, "add_field_filter", %{"field" => "price", "op" => "gte", "value" => "5"})
      patched = assert_patch(lv)

      assert %{"cf" => "price:gte:5"} =
               patched |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert ids(render(lv)) == [high.id]

      render_hook(lv, "remove_field_filter", %{"field" => "price", "op" => "gte"})
      patched = assert_patch(lv)
      refute patched =~ "cf="
      assert Enum.sort(ids(render(lv))) == Enum.sort([low.id, high.id])
    end

    test "forged payloads change nothing and say so", %{conn: conn, prefix: prefix} do
      a_page(prefix, %{"price" => 1})
      {lv, _} = open(conn, prefix)

      for payload <- [
            %{"field" => "ghost", "op" => "eq", "value" => "1"},
            %{"field" => "secret", "op" => "eq", "value" => "x"},
            %{"field" => "price", "op" => "contains", "value" => "1"},
            %{"field" => "price", "op" => "eq", "value" => "nope"}
          ] do
        html = render_hook(lv, "add_field_filter", payload)
        assert html =~ "not valid here"
      end

      # Wrong shapes reach the catch-all, not a crash.
      render_hook(lv, "add_field_filter", %{"field" => ["price"], "op" => "eq", "value" => "1"})
      render_hook(lv, "remove_field_filter", %{"field" => %{"a" => 1}, "op" => "eq"})
      assert render(lv) =~ "FF"
    end

    test "a fifth condition is refused out loud", %{conn: conn, prefix: prefix} do
      a_page(prefix, %{})

      {lv, _} =
        open(conn, prefix, %{
          "cf" => "note:eq:a;note:contains:b;price:eq:1;price:gte:1"
        })

      html =
        render_hook(lv, "add_field_filter", %{"field" => "price", "op" => "lte", "value" => "9"})

      assert html =~ "at most 4 field filters"
    end

    test "changing the type clears the conditions and the field sort", %{
      conn: conn,
      prefix: prefix
    } do
      a_page(prefix, %{"price" => 1})
      {lv, _} = open(conn, prefix, %{"cf" => "price:gte:1", "sort" => "field:price"})

      render_hook(lv, "filter", %{"type" => "post"})
      path = assert_patch(lv)
      refute path =~ "cf="
      refute path =~ "field%3Aprice"
      assert path =~ "type=post"
    end
  end

  describe "bounded count" do
    test "past the cap the list says N+ instead of counting every row", %{
      conn: conn,
      prefix: prefix
    } do
      Repo.query!(
        """
        INSERT INTO pages (title, slug, locale, state, org_id, custom_fields)
        SELECT $1 || ' ' || g, 'ffbulk-' || g || '-' || $2::text, 'en', 'draft', $3,
               jsonb_build_object('price', g)
        FROM generate_series(1, 1010) g
        """,
        [prefix, to_string(uniq()), Ecto.UUID.dump!(KilnCMS.Accounts.default_org_id())]
      )

      {lv, _} = open(conn, prefix, %{"cf" => "price:gte:1"})
      assert has_element?(lv, "#content-count", "1000+ items")

      {lv, _} = open(conn, prefix, %{"cf" => "price:gte:1005"})
      assert has_element?(lv, "#content-count", "6 items")
    end
  end

  describe "a field that goes away" do
    test "a saved view naming a deleted field opens, narrows less, and says so", %{
      conn: conn,
      admin: admin,
      prefix: prefix,
      price: price
    } do
      low = a_page(prefix, %{"price" => 1})
      high = a_page(prefix, %{"price" => 99})

      view =
        CMS.create_saved_view!(
          %{name: "Pricey", params: %{"type" => "page", "q" => prefix, "cf" => "price:gte:50"}},
          actor: admin
        )

      {:ok, lv, _html} = live(conn, "/editor?type=page&q=#{prefix}")
      lv |> element("#view-#{view.id}") |> render_click()
      assert ids(render(lv)) == [high.id]
      refute render(lv) =~ "no longer applies"

      CMS.destroy_field_definition!(price, actor: admin)

      {:ok, lv, _html} = live(conn, "/editor?type=page&q=#{prefix}")
      lv |> element("#view-#{view.id}") |> render_click()
      html = render(lv)
      assert Enum.sort(ids(html)) == Enum.sort([low.id, high.id])
      assert html =~ "named a field that no longer applies"
      refute assert_patch(lv) =~ "cf="
    end

    test "a read that fails after validation clears the field filter and flashes, on Load more too",
         %{conn: conn, admin: admin, prefix: prefix, price: price} do
      for n <- 1..60, do: a_page(prefix, %{"price" => n})
      {lv, html} = open(conn, prefix, %{"cf" => "price:gte:1", "sort" => "field:price"})
      assert length(ids(html)) == 50

      # The list is open on conditions that were valid; the field goes away.
      CMS.destroy_field_definition!(price, actor: admin)

      html = lv |> element("button", "Load more") |> render_click()
      assert html =~ "could no longer be applied"

      path = assert_patch(lv)
      refute path =~ "cf="
      refute path =~ "sort="
    end
  end

  describe "review fixes" do
    test "a saved view with only a field sort keeps it, is the active pill, and goes stale",
         %{conn: conn, admin: admin, prefix: prefix, price: price} do
      low = a_page(prefix, %{"price" => 1})
      high = a_page(prefix, %{"price" => 9})

      view =
        CMS.create_saved_view!(
          %{
            name: "By price",
            params: %{"type" => "page", "q" => prefix, "sort" => "-field:price"}
          },
          actor: admin
        )

      {:ok, lv, _html} = live(conn, "/editor?type=page&q=#{prefix}")
      lv |> element("#view-#{view.id}") |> render_click()
      path = assert_patch(lv)
      assert path =~ "sort=-field%3Aprice"
      assert ids(render(lv)) == [high.id, low.id]
      assert has_element?(lv, "#view-#{view.id}[aria-current=page]")
      refute render(lv) =~ "no longer applies"

      CMS.destroy_field_definition!(price, actor: admin)

      {:ok, lv, _html} = live(conn, "/editor?type=page&q=#{prefix}")
      lv |> element("#view-#{view.id}") |> render_click()
      assert render(lv) =~ "named a field that no longer applies"
      refute assert_patch(lv) =~ "sort="
    end

    test "a failing first load clears the field query once and ends on the plain list", %{
      conn: conn,
      admin: admin,
      prefix: prefix,
      price: price
    } do
      a = a_page(prefix, %{"price" => 1})
      {lv, _} = open(conn, prefix, %{"cf" => "price:gte:0"})
      assert ids(render(lv)) == [a.id]

      CMS.destroy_field_definition!(price, actor: admin)

      # Reloads the list under the filters the page still holds.
      html = render_hook(lv, "set_columns", %{"type" => "page", "columns" => []})
      assert html =~ "could no longer be applied"
      refute assert_patch(lv) =~ "cf="
      assert ids(render(lv)) == [a.id]
    end

    test "only the preparation's refusals count as a vanished field" do
      invalid = fn field ->
        Ash.Error.Invalid.exception(
          errors: [Ash.Error.Query.InvalidArgument.exception(field: field, message: "x")]
        )
      end

      assert KilnCMSWeb.EditorLive.field_query_error?(invalid.(:custom_filter))
      assert KilnCMSWeb.EditorLive.field_query_error?(invalid.(:custom_sort))
      refute KilnCMSWeb.EditorLive.field_query_error?(invalid.(:locale))

      refute KilnCMSWeb.EditorLive.field_query_error?(
               Ash.Error.Invalid.exception(errors: [Ash.Error.Query.NotFound.exception([])])
             )

      refute KilnCMSWeb.EditorLive.field_query_error?(Ash.Error.Unknown.exception(errors: []))
    end

    test "forged and stale field events on a multi-type list change nothing", %{
      conn: conn,
      prefix: prefix
    } do
      a_page(prefix, %{"price" => 1})
      {:ok, lv, _html} = live(conn, "/editor?q=#{prefix}")

      render_hook(lv, "field_filter_draft", %{"field" => "price", "op" => "gte", "value" => "5"})
      render_hook(lv, "field_filter_draft", %{})

      html =
        render_hook(lv, "add_field_filter", %{"field" => "price", "op" => "gte", "value" => "5"})

      assert html =~ "not valid here"

      for payload <- [%{}, %{"field" => "price"}, %{"field" => 1, "op" => 2, "value" => 3}] do
        render_hook(lv, "add_field_filter", payload)
        render_hook(lv, "remove_field_filter", payload)
      end

      assert render(lv) =~ prefix
    end

    test "a half-typed value does not follow a type change to another type's field", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      define!(admin, "note", %{content_type: :post, field_type: :string})
      a_page(prefix, %{})
      {lv, _} = open(conn, prefix)

      render_hook(lv, "toggle_filters", %{})
      draft = %{"field" => "note", "op" => "eq", "value" => "halfway"}
      # The first event picks the field (a new field starts empty); the second types.
      render_hook(lv, "field_filter_draft", draft)
      render_hook(lv, "field_filter_draft", draft)
      assert has_element?(lv, ~s(#field-filter-value[value="halfway"]))

      render_hook(lv, "filter", %{"type" => "post"})
      assert_patch(lv)
      refute has_element?(lv, ~s(#field-filter-value[value="halfway"]))
    end
  end
end
