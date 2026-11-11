defmodule KilnCMSWeb.EditorLiveFieldFilterFormTest do
  @moduledoc """
  The content list's add-a-condition form, chips and field sort control
  (#2293): the value control follows the field, a condition narrows the list
  and shows as a removable chip, the sort option survives a filter-form
  submit, and a forged event changes nothing.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    email = "ffform-#{uniq()}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
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
      slug: "ffform-#{uniq()}",
      state: :draft,
      custom_fields: custom_fields
    })
  end

  defp open(conn, prefix, params \\ %{}) do
    query = URI.encode_query(Map.merge(%{"type" => "page", "q" => prefix}, params))
    {:ok, lv, _html} = live(conn, "/editor?" <> query)
    lv |> element("#toggle-filters") |> render_click()
    lv
  end

  defp ids(html) do
    ~r/id="page-([0-9a-f-]{36})"/ |> Regex.scan(html) |> Enum.map(&List.last/1)
  end

  # The form changing to `field` / `op` (what the browser sends).
  defp pick(lv, field, op, value \\ "") do
    lv
    |> element("#field-filter-form")
    |> render_change(%{"field" => field, "op" => op, "value" => value})
  end

  defp add(lv, field, op, value) do
    lv
    |> element("#field-filter-form")
    |> render_submit(%{"field" => field, "op" => op, "value" => value})
  end

  setup %{conn: conn} do
    admin = admin()
    prefix = "FFF#{uniq()}"

    define!(admin, "price", %{field_type: :integer})
    define!(admin, "weight", %{field_type: :float})
    define!(admin, "note", %{field_type: :string})
    define!(admin, "active", %{field_type: :boolean})
    define!(admin, "due", %{field_type: :date})
    define!(admin, "owner", %{field_type: :user})
    define!(admin, "shape", %{field_type: :group})

    define!(admin, "color", %{
      field_type: :select,
      options: ["red", "blue"],
      option_labels: %{"red" => "Ruby"}
    })

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    %{conn: conn, admin: admin, prefix: prefix}
  end

  describe "the form" do
    test "the value control follows the chosen field", %{conn: conn, prefix: prefix} do
      lv = open(conn, prefix)
      assert has_element?(lv, "#field-filters #field-filter-field")

      # Whatever is first offered, each pick re-renders the right control.
      pick(lv, "price", "gte")
      assert has_element?(lv, "#field-filter-value[type=number][step='1']")

      pick(lv, "weight", "lt")
      assert has_element?(lv, "#field-filter-value[type=number][step=any]")

      pick(lv, "due", "gte")
      assert has_element?(lv, "#field-filter-value[type=date]")

      pick(lv, "note", "contains")
      assert has_element?(lv, "#field-filter-value[type=text]")

      pick(lv, "owner", "eq")
      assert has_element?(lv, "#field-filter-value[type=text][placeholder]")

      pick(lv, "active", "eq")
      assert has_element?(lv, "select#field-filter-value option[value=true]")
      assert has_element?(lv, "select#field-filter-value option[value=false]")

      pick(lv, "color", "eq")
      assert has_element?(lv, "select#field-filter-value option[value=red]", "Ruby")
      assert has_element?(lv, "select#field-filter-value option[value=blue]", "blue")

      # "Empty or not" asks empty/has-a-value whatever the field type.
      pick(lv, "price", "null")
      assert has_element?(lv, "select#field-filter-value option[value=true]")
    end

    test "the op menu offers only what the field type allows", %{conn: conn, prefix: prefix} do
      lv = open(conn, prefix)
      pick(lv, "active", "eq")
      assert has_element?(lv, "#field-filter-op option[value=eq]")
      refute has_element?(lv, "#field-filter-op option[value=gt]")

      pick(lv, "price", "eq")
      assert has_element?(lv, "#field-filter-op option[value=gt]")
    end

    test "fields that cannot be filtered are not offered", %{conn: conn, prefix: prefix} do
      lv = open(conn, prefix)
      refute has_element?(lv, "#field-filter-field option[value=shape]")
    end

    test "a forged draft falls back to the first field and op", %{conn: conn, prefix: prefix} do
      lv = open(conn, prefix)
      html = render_hook(lv, "field_filter_draft", %{"field" => "ghost", "op" => "nope"})
      assert html =~ ~s(id="field-filter-field")
      assert Process.alive?(lv.pid)
    end

    test "with several types in play there is a hint and no form", %{conn: conn, prefix: prefix} do
      {:ok, lv, _html} = live(conn, "/editor?q=#{prefix}")
      lv |> element("#toggle-filters") |> render_click()

      assert has_element?(lv, "#field-filters-hint")
      refute has_element?(lv, "#field-filters")
      refute has_element?(lv, "#field-filter-form")
    end
  end

  describe "adding and removing a condition" do
    test "a number condition narrows the list and shows a chip; removing it restores", %{
      conn: conn,
      prefix: prefix
    } do
      cheap = a_page(prefix, %{"price" => 5})
      dear = a_page(prefix, %{"price" => 50})
      lv = open(conn, prefix)
      assert Enum.sort(ids(render(lv))) == Enum.sort([cheap.id, dear.id])

      add(lv, "price", "gte", "10")
      assert_patch(lv)

      assert ids(render(lv)) == [dear.id]
      assert has_element?(lv, "#field-filter-chip-0", "Price ≥ 10")
      assert has_element?(lv, "#content-count", "1 item")

      lv |> element("#field-filter-chip-0") |> render_click()
      assert_patch(lv)

      assert Enum.sort(ids(render(lv))) == Enum.sort([cheap.id, dear.id])
      refute has_element?(lv, "#field-filter-chip-0")
    end

    test "a select condition shows the option's label", %{conn: conn, prefix: prefix} do
      red = a_page(prefix, %{"color" => "red"})
      _blue = a_page(prefix, %{"color" => "blue"})
      lv = open(conn, prefix)

      add(lv, "color", "eq", "red")
      assert_patch(lv)

      assert ids(render(lv)) == [red.id]
      assert has_element?(lv, "#field-filter-chip-0", "Color is Ruby")
    end

    test "a boolean condition, and a second one beside it", %{conn: conn, prefix: prefix} do
      on = a_page(prefix, %{"active" => true, "price" => 20})
      _off = a_page(prefix, %{"active" => false, "price" => 20})
      _cheap = a_page(prefix, %{"active" => true, "price" => 1})
      lv = open(conn, prefix)

      add(lv, "active", "eq", "true")
      assert_patch(lv)
      add(lv, "price", "gt", "10")
      assert_patch(lv)

      assert ids(render(lv)) == [on.id]
      assert has_element?(lv, "#field-filter-chip-0")
      assert has_element?(lv, "#field-filter-chip-1")
    end

    test "an emptiness condition reads as a sentence", %{conn: conn, prefix: prefix} do
      bare = a_page(prefix, %{})
      _priced = a_page(prefix, %{"price" => 3})
      lv = open(conn, prefix)

      add(lv, "price", "null", "true")
      assert_patch(lv)

      assert ids(render(lv)) == [bare.id]
      assert has_element?(lv, "#field-filter-chip-0", "Price is empty")
    end

    test "forged add_field_filter changes nothing and says so", %{conn: conn, prefix: prefix} do
      a = a_page(prefix, %{"price" => 1})
      lv = open(conn, prefix)

      for {field, op, value} <- [
            {"ghost", "eq", "1"},
            {"price", "contains", "1"},
            {"price", "eq", "abc"},
            {"shape", "eq", "1"}
          ] do
        html =
          render_hook(lv, "add_field_filter", %{"field" => field, "op" => op, "value" => value})

        assert html =~ "not valid here"
        refute has_element?(lv, "#field-filter-chip-0")
      end

      assert ids(render(lv)) == [a.id]
    end

    test "a fifth condition is refused out loud", %{conn: conn, prefix: prefix} do
      a_page(prefix, %{"price" => 1})
      lv = open(conn, prefix)

      for op <- ~w(eq gt gte lt) do
        add(lv, "price", op, "1")
        assert_patch(lv)
      end

      html = add(lv, "weight", "gt", "1")
      assert html =~ "at most"
      assert has_element?(lv, "#field-filter-chip-3")
      refute has_element?(lv, "#field-filter-chip-4")
    end

    test "changing the type drops the conditions", %{conn: conn, prefix: prefix} do
      a_page(prefix, %{"price" => 1})
      lv = open(conn, prefix)
      add(lv, "price", "eq", "1")
      assert_patch(lv)
      assert has_element?(lv, "#field-filter-chip-0")

      lv |> form("#content-filter", %{"type" => "post"}) |> render_change()
      refute assert_patch(lv) =~ "cf="
      refute has_element?(lv, "#field-filter-chip-0")
    end
  end

  describe "the field sort" do
    test "the sort menu lists sortable fields and keeps the choice across a filter submit", %{
      conn: conn,
      prefix: prefix
    } do
      low = a_page(prefix, %{"price" => 1})
      high = a_page(prefix, %{"price" => 9})
      lv = open(conn, prefix, %{"sort" => "-field:price"})

      assert has_element?(lv, "#field-sort option[value='field:price']", "Field: Price (↑)")
      assert has_element?(lv, "#field-sort option[value='-field:price']", "Field: Price (↓)")
      refute has_element?(lv, "#field-sort option[value='field:shape']")
      refute has_element?(lv, "#field-sort option[value='field:owner']")
      assert has_element?(lv, "#content-sort option[selected][value='-field:price']")
      assert ids(render(lv)) == [high.id, low.id]

      # Submitting the form with another facet must not reset the sort.
      lv |> form("#content-filter", %{"status" => "draft"}) |> render_change()
      assert assert_patch(lv) =~ "sort=-field%3Aprice"
      assert has_element?(lv, "#content-sort option[selected][value='-field:price']")
      assert ids(render(lv)) == [high.id, low.id]

      # And choosing the other direction reorders.
      lv |> form("#content-filter", %{"sort" => "field:price"}) |> render_change()
      assert_patch(lv)
      assert ids(render(lv)) == [low.id, high.id]
    end

    test "there is no field group when several types are listed", %{conn: conn, prefix: prefix} do
      {:ok, lv, _html} = live(conn, "/editor?q=#{prefix}")
      refute has_element?(lv, "#field-sort")
    end
  end

  describe "saved views" do
    test "a view that names a deleted field is marked", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      price = CMS.field_definitions_for!(:page, actor: admin) |> Enum.find(&(&1.name == "price"))

      view =
        CMS.create_saved_view!(
          %{name: "Pricey", params: %{"type" => "page", "cf" => "price:gte:5"}},
          actor: admin
        )

      {:ok, lv, _html} = live(conn, "/editor?type=page&q=#{prefix}")
      refute has_element?(lv, "#view-stale-#{view.id}")

      CMS.destroy_field_definition!(price, actor: admin)

      {:ok, lv, _html} = live(conn, "/editor?type=page&q=#{prefix}")
      assert has_element?(lv, "#view-stale-#{view.id}")
    end
  end
end
