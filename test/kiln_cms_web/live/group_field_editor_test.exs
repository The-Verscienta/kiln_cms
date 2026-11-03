defmodule KilnCMSWeb.GroupFieldEditorTest do
  @moduledoc """
  A `:group` custom field in the content editor: a single group as one
  fieldset of its sub-fields, a repeating one as rows an editor adds,
  removes and reorders — each edit a change of the form, saved as the
  ordered list `ApplyCustomFields` coerces, with every problem shown next to
  the row and sub-field it names.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "gfe-#{System.unique_integer([:positive])}@example.com"

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
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp sub!(admin, group, attrs),
    do: CMS.create_field_definition!(Map.put(attrs, :group_of_id, group.id), actor: admin)

  setup %{conn: conn} do
    admin = authed_admin()

    dosages =
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "dosages",
          label: "Dosages",
          field_type: :group,
          multiple: true,
          max_items: 3,
          position: 0
        },
        actor: admin
      )

    sub!(admin, dosages, %{name: "amount", label: "Amount", field_type: :float, position: 0})

    sub!(admin, dosages, %{
      name: "unit",
      label: "Unit",
      field_type: :select,
      options: ["g", "mg"],
      required: true,
      position: 1
    })

    sub!(admin, dosages, %{
      name: "with_food",
      label: "With food",
      field_type: :boolean,
      position: 2
    })

    size =
      CMS.create_field_definition!(
        %{content_type: :page, name: "size", label: "Size", field_type: :group, position: 1},
        actor: admin
      )

    sub!(admin, size, %{name: "width", label: "Width", field_type: :integer, position: 0})
    sub!(admin, size, %{name: "height", label: "Height", field_type: :integer, position: 1})

    page =
      CMS.create_page!(
        %{
          title: "Dosed",
          slug: "gfe-#{System.unique_integer([:positive])}",
          custom_fields: %{
            "dosages" => [%{"amount" => 2, "unit" => "g"}, %{"amount" => 5, "unit" => "mg"}],
            "size" => %{"width" => 10, "height" => 20}
          }
        },
        actor: admin
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/#{page.id}")
    %{admin: admin, page: page, lv: lv, conn: conn}
  end

  defp row(n), do: "#cf-group-dosages-row-#{n}"

  defp amount(lv, n) do
    case lv |> element("#custom-field-dosages-#{n}-amount") |> render() do
      html -> html |> Floki.parse_fragment!() |> Floki.attribute("value") |> List.first()
    end
  end

  defp stored(ctx), do: CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields

  test "a single group is one fieldset; a repeating group is rows with their values", ctx do
    assert has_element?(ctx.lv, "fieldset#custom-field-size legend", "Size")
    assert has_element?(ctx.lv, ~s(#custom-field-size-width[value="10"]))
    assert has_element?(ctx.lv, ~s(input[name="form[custom_fields][size][height]"][value="20"]))

    assert has_element?(ctx.lv, row(0))
    assert has_element?(ctx.lv, row(1))
    refute has_element?(ctx.lv, row(2))
    assert amount(ctx.lv, 0) =~ "2"

    assert has_element?(
             ctx.lv,
             ~s(#{row(1)} select[name="form[custom_fields][dosages][1][unit]"] option[value=mg][selected])
           )

    assert has_element?(ctx.lv, "#custom-field-dosages", "2 of 3 rows")
    # The rows are a drag-to-reorder list.
    assert has_element?(
             ctx.lv,
             ~s(#custom-field-dosages-rows[phx-hook=Sortable][data-sort-event=group_row_reorder])
           )
  end

  test "add a row up to max_items; remove one", ctx do
    ctx.lv |> element("#custom-field-dosages-add") |> render_click()
    assert has_element?(ctx.lv, row(2))
    assert amount(ctx.lv, 2) in [nil, ""]

    # Full at three: "Add row" is disabled and says why.
    assert has_element?(ctx.lv, "#custom-field-dosages-add[disabled]")
    assert render(ctx.lv) =~ "the most this field holds"

    ctx.lv |> element("#{row(0)} button[phx-click=group_row_remove]") |> render_click()
    refute has_element?(ctx.lv, row(2))
    assert amount(ctx.lv, 0) =~ "5"
    refute has_element?(ctx.lv, "#custom-field-dosages-add[disabled]")
  end

  test "move a row with the arrows, or by the dragged order", ctx do
    ctx.lv |> element("#{row(1)} button[phx-value-dir=up]") |> render_click()
    assert amount(ctx.lv, 0) =~ "5"
    assert amount(ctx.lv, 1) =~ "2"

    ctx.lv
    |> element("#custom-field-dosages-rows")
    |> render_hook("group_row_reorder", %{"field" => "dosages", "order" => ["1", "0"]})

    assert amount(ctx.lv, 0) =~ "2"

    # An order that is not the rows' own positions changes nothing.
    ctx.lv
    |> element("#custom-field-dosages-rows")
    |> render_hook("group_row_reorder", %{"field" => "dosages", "order" => ["0", "0"]})

    assert amount(ctx.lv, 0) =~ "2"
    assert amount(ctx.lv, 1) =~ "5"
  end

  test "edited, added and reordered rows save as an ordered list", ctx do
    ctx.lv |> element("#custom-field-dosages-add") |> render_click()

    # The first edit of the session posted only the group's rows; every other
    # field still shows its stored value rather than a blank the save posts.
    assert has_element?(ctx.lv, ~s(#custom-field-size-height[value="20"]))

    ctx.lv
    |> form("#page-editor", %{
      "form" => %{
        "custom_fields" => %{
          "dosages" => %{
            "0" => %{"amount" => "2.5"},
            "2" => %{"amount" => "1", "unit" => "mg", "with_food" => "true"}
          },
          "size" => %{"width" => "11"}
        }
      }
    })
    |> render_change()

    ctx.lv |> element("#{row(2)} button[phx-value-dir=up]") |> render_click()
    ctx.lv |> form("#page-editor") |> render_submit()

    assert %{
             "dosages" => [
               %{"amount" => 2.5, "unit" => "g"},
               %{"amount" => 1.0, "unit" => "mg", "with_food" => true},
               %{"amount" => 5.0, "unit" => "mg"}
             ],
             "size" => %{"width" => 11, "height" => 20}
           } = stored(ctx)
  end

  test "removing every row clears the group", ctx do
    ctx.lv |> element("#{row(0)} button[phx-click=group_row_remove]") |> render_click()
    ctx.lv |> element("#{row(0)} button[phx-click=group_row_remove]") |> render_click()
    assert has_element?(ctx.lv, "#custom-field-dosages", "No rows yet.")

    ctx.lv |> form("#page-editor") |> render_submit()
    refute Map.has_key?(stored(ctx), "dosages")
  end

  test "a problem shows next to its row and sub-field, and nothing is saved", ctx do
    ctx.lv |> element("#custom-field-dosages-add") |> render_click()

    ctx.lv
    |> form("#page-editor", %{
      "form" => %{"custom_fields" => %{"dosages" => %{"2" => %{"amount" => "lots"}}}}
    })
    |> render_change()

    ctx.lv |> form("#page-editor") |> render_submit()

    row = ctx.lv |> element(row(2)) |> render()
    assert row =~ "Amount must be a number"
    assert row =~ "Unit is required"
    refute ctx.lv |> element(row(0)) |> render() =~ "is required"
    assert has_element?(ctx.lv, ~s(#custom-field-dosages-2-amount[aria-invalid="true"]))

    assert [_, _] = stored(ctx)["dosages"]
  end

  test "a save that does not name the group keeps its rows", ctx do
    render_hook(ctx.lv, "save", %{"form" => %{"title" => "Renamed"}})

    assert %{"dosages" => [%{"amount" => 2.0}, %{"amount" => 5.0}]} = stored(ctx)
    assert CMS.get_page!(ctx.page.id, actor: ctx.admin).title == "Renamed"
  end

  test "an autosave keeps a row just added on screen", ctx do
    ctx.lv |> element("#custom-field-dosages-add") |> render_click()
    send(ctx.lv.pid, :autosave)
    _ = render(ctx.lv)

    assert has_element?(ctx.lv, row(2))
    assert [_, _] = stored(ctx)["dosages"]
  end

  test "a group with no sub-fields yet says so and posts nothing", ctx do
    CMS.create_field_definition!(
      %{content_type: :page, name: "specs", label: "Specs", field_type: :group, multiple: true},
      actor: ctx.admin
    )

    {:ok, lv, _html} = live(ctx.conn, ~p"/editor/content/page/#{ctx.page.id}")
    assert has_element?(lv, "#custom-field-specs", "This group has no fields yet")
    refute has_element?(lv, ~s(input[name^="form[custom_fields][specs]"]))
  end
end
