defmodule KilnCMSWeb.LinkFieldsAdminTest do
  @moduledoc """
  Link fields in the fields admin (`/editor/fields`, R3): under a reference
  field, "Details on each connection" adds, edits, orders and deletes the
  data an editor fills in for every record the field connects.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition

  @password "password123456"

  defp authed_user(role) do
    email = "lfa-#{System.unique_integer([:positive])}@example.com"

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

  setup %{conn: conn} do
    admin = authed_user(:admin)

    field =
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "ingredients_#{System.unique_integer([:positive])}",
          label: "Ingredients",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        actor: admin
      )

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
    %{admin: admin, field: field, lv: lv}
  end

  defp links(field),
    do:
      CMS.get_field_definition!(field.id, authorize?: false, load: [:link_fields])
      |> FieldDefinition.link_fields()

  defp panel(field), do: "#field-#{field.id}-details"

  test "a reference field offers details on each connection, in plain words", ctx do
    assert has_element?(ctx.lv, panel(ctx.field), "Details on each connection")
    assert has_element?(ctx.lv, panel(ctx.field), "for every Page this field connects")
    assert has_element?(ctx.lv, panel(ctx.field), "No details yet.")
  end

  test "an admin adds a detail; the name follows the label; only plain types", ctx do
    ctx.lv |> element("#{panel(ctx.field)}-add") |> render_click()
    form = "#link-field-form-new-#{ctx.field.id}"
    assert has_element?(ctx.lv, form)

    # The kinds offered are the plain ones.
    assert has_element?(ctx.lv, "#{form} select option[value=integer]")
    refute has_element?(ctx.lv, "#{form} select option[value=reference]")
    refute has_element?(ctx.lv, "#{form} select option[value=media]")

    ctx.lv
    |> form(form, link_field: %{label: "Amount (g)", field_type: "integer"})
    |> render_change()

    assert has_element?(ctx.lv, ~s(#{form} input[name="link_field[name]"][value=amount_g]))

    ctx.lv
    |> form(form, link_field: %{label: "Amount (g)", field_type: "integer", required: "true"})
    |> render_submit()

    assert [%{name: "amount_g", field_type: :integer, required: true, position: 0}] =
             links(ctx.field)

    assert has_element?(ctx.lv, panel(ctx.field), "Amount (g)")
    refute has_element?(ctx.lv, form)

    # A choice takes its options.
    ctx.lv |> element("#{panel(ctx.field)}-add") |> render_click()
    ctx.lv |> form(form, link_field: %{label: "Role", field_type: "select"}) |> render_change()

    ctx.lv
    |> form(form, link_field: %{label: "Role", field_type: "select", options: "main\ngarnish"})
    |> render_submit()

    assert [_, %{name: "role", options: ["main", "garnish"], position: 1}] = links(ctx.field)
  end

  test "edit, reorder and delete a detail", ctx do
    for {name, position} <- [{"quantity", 0}, {"note", 1}] do
      CMS.create_field_definition!(
        %{
          link_of_id: ctx.field.id,
          name: name,
          label: String.capitalize(name),
          field_type: :string,
          position: position
        },
        actor: ctx.admin
      )
    end

    {:ok, lv, _html} = ctx.conn |> log_in(ctx.admin) |> live(~p"/editor/fields")
    [quantity, note] = links(ctx.field)

    # Listed under the reference, not as fields of the type.
    refute has_element?(lv, "#field-#{quantity.id}")
    assert has_element?(lv, "#link-field-#{quantity.id}", "Quantity")

    lv |> element("#link-field-#{quantity.id} button[phx-click=link_edit]") |> render_click()

    lv
    |> form("#link-field-form-#{quantity.id}", link_field: %{label: "Amount", name: "amount"})
    |> render_submit()

    assert [%{label: "Amount", name: "amount"}, _] = links(ctx.field)

    lv |> element("#link-field-#{note.id} button[phx-value-dir=up]") |> render_click()
    assert Enum.map(links(ctx.field), & &1.name) == ["note", "amount"]

    lv |> element("#link-field-#{note.id} button[phx-click=delete]") |> render_click()
    assert Enum.map(links(ctx.field), & &1.name) == ["amount"]
    refute has_element?(lv, "#link-field-#{note.id}")
  end

  test "a field that is not a reference has no details panel", ctx do
    text =
      CMS.create_field_definition!(
        %{content_type: :post, name: "note_#{System.unique_integer([:positive])}", label: "Note"},
        actor: ctx.admin
      )

    {:ok, lv, _html} = ctx.conn |> log_in(ctx.admin) |> live(~p"/editor/fields")
    refute has_element?(lv, panel(text))
  end
end
