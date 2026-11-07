defmodule KilnCMSWeb.FieldConditionsAdminTest do
  @moduledoc """
  The "Conditions" disclosure in the fields admin (`/editor/fields`, #2277):
  an admin adds Show when / Required when rows on a new field, an existing
  one and a group's sub-field; the rows are saved as the rule JSON, and a rule
  the resource refuses is reported next to the disclosure.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition

  defp sign_in(role) do
    email = "fca-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => "password123456"},
        []
      )

    user
  end

  defp open(conn, admin) do
    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    {:ok, lv, _html} = live(conn, ~p"/editor/fields")
    lv
  end

  defp field!(admin, attrs),
    do: CMS.create_field_definition!(Map.merge(%{content_type: :post}, attrs), actor: admin)

  defp rule_row(index, field, op, value),
    do: %{to_string(index) => %{"field" => field, "op" => op, "value" => value}}

  # The page lists what exists when it mounts, so a test that defines fields
  # of its own opens it afterwards.
  defp reopen(ctx), do: open(ctx.conn, ctx.admin)

  setup %{conn: conn} do
    admin = sign_in(:admin)

    kind =
      field!(admin, %{name: "kind", label: "Kind", field_type: :select, options: ["a", "other"]})

    %{conn: conn, admin: admin, kind: kind, lv: open(conn, admin)}
  end

  test "an admin authors a rule on a new field", ctx do
    ctx.lv |> form("#new-field-form", field_definition: %{scopes: ["post"]}) |> render_change()

    refute has_element?(ctx.lv, "#new-field-conditions-visible_when-row-0")
    ctx.lv |> element("#new-field-conditions-visible_when-add") |> render_click()
    assert has_element?(ctx.lv, "#new-field-conditions-visible_when-row-0")
    # A choice field is tested against its options.
    assert has_element?(ctx.lv, "#new-field-conditions-visible_when-row-0-value option", "other")

    ctx.lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["post"],
        name: "other_detail",
        label: "Other detail",
        field_type: "string",
        conditions: %{
          visible_when: %{rows: rule_row(0, "kind", "eq", "other")}
        }
      }
    )
    |> render_submit()

    definition =
      Enum.find(
        CMS.field_definitions_for!(:post, authorize?: false),
        &(&1.name == "other_detail")
      )

    assert definition.visible_when == %{"field" => "kind", "op" => "eq", "value" => "other"}
    assert definition.required_when == nil
  end

  test "several rows join with all or any", ctx do
    ctx.lv |> form("#new-field-form", field_definition: %{scopes: ["post"]}) |> render_change()
    ctx.lv |> element("#new-field-conditions-required_when-add") |> render_click()
    ctx.lv |> element("#new-field-conditions-required_when-add") |> render_click()
    assert has_element?(ctx.lv, "#new-field-conditions-required_when-mode")

    # "is one of" takes a comma-separated list, so the value box becomes text.
    ctx.lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["post"],
        conditions: %{required_when: %{rows: rule_row(1, "kind", "in", "")}}
      }
    )
    |> render_change()

    ctx.lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["post"],
        name: "either",
        label: "Either",
        field_type: "string",
        conditions: %{
          required_when: %{
            mode: "any",
            rows: Map.merge(rule_row(0, "kind", "eq", "other"), rule_row(1, "kind", "in", "a, b"))
          }
        }
      }
    )
    |> render_submit()

    definition =
      Enum.find(CMS.field_definitions_for!(:post, authorize?: false), &(&1.name == "either"))

    assert definition.required_when == %{
             "any" => [
               %{"field" => "kind", "op" => "eq", "value" => "other"},
               %{"field" => "kind", "op" => "in", "value" => ["a", "b"]}
             ]
           }
  end

  test "a rule the resource refuses is reported and nothing is saved", ctx do
    ctx.lv |> form("#new-field-form", field_definition: %{scopes: ["post"]}) |> render_change()
    ctx.lv |> element("#new-field-conditions-visible_when-add") |> render_click()

    ctx.lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["post"],
        name: "broken",
        label: "Broken",
        field_type: "string",
        # "is one of" with nothing to be one of.
        conditions: %{visible_when: %{rows: rule_row(0, "kind", "in", "")}}
      }
    )
    |> render_submit()

    assert has_element?(
             ctx.lv,
             "#new-field-conditions-visible_when-error",
             "not a valid condition"
           )

    refute Enum.any?(CMS.field_definitions_for!(:post, authorize?: false), &(&1.name == "broken"))
  end

  test "an existing rule is shown, edited and removed", ctx do
    note =
      field!(ctx.admin, %{
        name: "note",
        label: "Note",
        field_type: :string,
        required_when: %{"field" => "kind", "op" => "eq", "value" => "other"}
      })

    lv = reopen(ctx)
    lv |> element("#field-#{note.id} button[phx-click=edit]") |> render_click()
    row = "#edit-field-conditions-#{note.id}-required_when-row-0"
    assert has_element?(lv, "#{row}-field option[selected]", "Kind")
    assert has_element?(lv, "#{row}-value option[selected]", "other")

    lv
    |> element("#{row} button[phx-click=cond_remove]")
    |> render_click()

    refute has_element?(lv, row)

    lv |> form("#edit-field-#{note.id}") |> render_submit()

    assert CMS.get_field_definition!(note.id, authorize?: false).required_when == nil
  end

  test "a rule can't read the field itself or a private one", ctx do
    secret =
      field!(ctx.admin, %{name: "secret", label: "Secret", field_type: :string, private: true})

    note = field!(ctx.admin, %{name: "note", label: "Note", field_type: :string})

    lv = reopen(ctx)
    lv |> element("#field-#{note.id} button[phx-click=edit]") |> render_click()
    lv |> element("#edit-field-conditions-#{note.id}-visible_when-add") |> render_click()

    html = lv |> element("#edit-field-conditions-#{note.id}") |> render()
    assert html =~ "Kind"
    refute html =~ "Secret"
    refute html =~ ~s(value="note")
    refute is_nil(secret)
  end

  test "a group sub-field's conditions read its siblings", ctx do
    group =
      field!(ctx.admin, %{name: "dosages", label: "Dosages", field_type: :group, multiple: true})

    sub = fn attrs ->
      CMS.create_field_definition!(Map.put(attrs, :group_of_id, group.id), actor: ctx.admin)
    end

    sub.(%{
      name: "unit",
      label: "Unit",
      field_type: :select,
      options: ["g", "other"],
      position: 0
    })

    ctx = %{ctx | lv: reopen(ctx)}

    ctx.lv
    |> element("#field-#{group.id}-sub-fields-add")
    |> render_click()

    form_id = "#link-field-form-new-#{group.id}"
    ctx.lv |> element("#{form_id}-conditions-visible_when-add") |> render_click()
    assert has_element?(ctx.lv, "#{form_id}-conditions-visible_when-row-0-field option", "Unit")
    # Not the top-level "Kind" field: a sub-field reads same-row siblings only.
    refute ctx.lv |> element("#{form_id}-conditions") |> render() =~ "Kind"

    ctx.lv
    |> form(form_id,
      link_field: %{
        label: "Unit note",
        name: "unit_note",
        field_type: "string",
        conditions: %{visible_when: %{rows: rule_row(0, "unit", "eq", "other")}}
      }
    )
    |> render_submit()

    saved =
      CMS.get_field_definition!(group.id, authorize?: false, load: [:group_fields])
      |> FieldDefinition.group_fields()
      |> Enum.find(&(&1.name == "unit_note"))

    assert saved.visible_when == %{"field" => "unit", "op" => "eq", "value" => "other"}
  end

  test "an editor can't open the page", %{conn: conn} do
    editor = sign_in(:editor)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(editor)

    assert {:error, {kind, _}} = live(conn, ~p"/editor/fields")
    assert kind in [:redirect, :live_redirect]
  end
end
