defmodule KilnCMSWeb.GroupFieldsAdminTest do
  @moduledoc """
  `:group` fields in the fields admin (`/editor/fields`): offered as a type,
  set to one row or repeating rows with item bounds, and given their
  sub-fields under "Fields in each row" — added, edited, ordered and deleted
  in place, with only the plain types on offer.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition

  @password "password123456"

  defp authed_admin do
    email = "gfa-#{System.unique_integer([:positive])}@example.com"

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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp subs(group),
    do:
      CMS.get_field_definition!(group.id, authorize?: false, load: [:group_fields])
      |> FieldDefinition.group_fields()

  defp panel(group), do: "#field-#{group.id}-sub-fields"

  setup %{conn: conn} do
    admin = authed_admin()
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
    %{admin: admin, lv: lv}
  end

  test "an admin creates a repeating group with row bounds", %{lv: lv} do
    name = "dosages_#{System.unique_integer([:positive])}"
    rows_radio = "#new-field-form input[name='field_definition[multiple]'][value=true]"

    assert has_element?(lv, "#new-field-form select option[value=group]")

    lv |> form("#new-field-form", field_definition: %{field_type: "group"}) |> render_change()
    assert has_element?(lv, rows_radio)
    assert has_element?(lv, "#new-field-multiple-sub-fields-hint")

    lv
    |> form("#new-field-form", field_definition: %{field_type: "group", multiple: "true"})
    |> render_change()

    assert has_element?(lv, "#new-field-multiple-bounds", "How many rows")

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["page"],
        name: name,
        label: "Dosages",
        field_type: "group",
        multiple: "true",
        min_items: "1",
        max_items: "4"
      }
    )
    |> render_submit()

    group =
      :page |> CMS.field_definitions_for!(authorize?: false) |> Enum.find(&(&1.name == name))

    assert %{field_type: :group, multiple: true, min_items: 1, max_items: 4} = group
    assert lv |> element("#field-#{group.id}") |> render() =~ "repeating"
    assert has_element?(lv, "#field-#{group.id}-bounds", "Between 1 and 4 rows.")

    # Its sub-fields panel is there, empty, saying what it is for.
    assert has_element?(lv, panel(group), "Fields in each row")
    assert has_element?(lv, panel(group), "No fields yet")
  end

  describe "sub-fields" do
    setup %{admin: admin, conn: conn} do
      group =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "dosages_#{System.unique_integer([:positive])}",
            label: "Dosages",
            field_type: :group,
            multiple: true
          },
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      %{group: group, lv: lv}
    end

    test "an admin adds sub-fields; the name follows the label; only plain types", ctx do
      ctx.lv |> element("#{panel(ctx.group)}-add") |> render_click()
      form = "#link-field-form-new-#{ctx.group.id}"
      assert has_element?(ctx.lv, form)

      assert has_element?(ctx.lv, "#{form} select option[value=float]")
      assert has_element?(ctx.lv, "#{form} select option[value=select]")

      for type <- ~w(group reference media computed geolocation) do
        refute has_element?(ctx.lv, "#{form} select option[value=#{type}]")
      end

      ctx.lv
      |> form(form, link_field: %{label: "Amount", field_type: "float"})
      |> render_change()

      assert has_element?(ctx.lv, ~s(#{form} input[name="link_field[name]"][value=amount]))

      ctx.lv
      |> form(form, link_field: %{label: "Amount", field_type: "float", required: "true"})
      |> render_submit()

      assert [%{name: "amount", field_type: :float, required: true, position: 0} = amount] =
               subs(ctx.group)

      assert amount.group_of_id == ctx.group.id
      assert is_nil(amount.link_of_id)

      # Listed under its group, not as a field of the type.
      refute has_element?(ctx.lv, "#field-#{amount.id}")
      assert has_element?(ctx.lv, "#link-field-#{amount.id}", "Amount")
      refute has_element?(ctx.lv, form)

      ctx.lv |> element("#{panel(ctx.group)}-add") |> render_click()
      ctx.lv |> form(form, link_field: %{label: "Unit", field_type: "select"}) |> render_change()

      ctx.lv
      |> form(form, link_field: %{label: "Unit", field_type: "select", options: "g\nmg"})
      |> render_submit()

      assert [_, %{name: "unit", options: ["g", "mg"], position: 1}] = subs(ctx.group)
    end

    test "edit, reorder and delete a sub-field", ctx do
      for {name, position} <- [{"amount", 0}, {"unit", 1}] do
        CMS.create_field_definition!(
          %{
            group_of_id: ctx.group.id,
            name: name,
            label: String.capitalize(name),
            field_type: :string,
            position: position
          },
          actor: ctx.admin
        )
      end

      {:ok, lv, _html} = ctx.conn |> log_in(ctx.admin) |> live(~p"/editor/fields")
      [amount, unit] = subs(ctx.group)

      lv |> element("#link-field-#{amount.id} button[phx-click=link_edit]") |> render_click()

      lv
      |> form("#link-field-form-#{amount.id}", link_field: %{label: "Dose", name: "dose"})
      |> render_submit()

      assert [%{label: "Dose", name: "dose"}, _] = subs(ctx.group)

      lv |> element("#link-field-#{unit.id} button[phx-value-dir=up]") |> render_click()
      assert Enum.map(subs(ctx.group), & &1.name) == ["unit", "dose"]

      lv |> element("#link-field-#{unit.id} button[phx-click=delete]") |> render_click()
      assert Enum.map(subs(ctx.group), & &1.name) == ["dose"]
      refute has_element?(lv, "#link-field-#{unit.id}")
    end

    test "turning repeating rows into one row warns before saving", ctx do
      ctx.lv |> element("#field-#{ctx.group.id} button[phx-click=edit]") |> render_click()
      refute has_element?(ctx.lv, "#edit-field-multiple-#{ctx.group.id}-narrowing")

      ctx.lv
      |> form("#edit-field-#{ctx.group.id}", field_definition: %{multiple: "false"})
      |> render_change()

      assert has_element?(
               ctx.lv,
               "#edit-field-multiple-#{ctx.group.id}-narrowing",
               "keeps only the first row"
             )
    end
  end
end
