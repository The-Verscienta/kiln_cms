defmodule KilnCMS.CMS.FieldWidgetDefinitionTest do
  @moduledoc """
  A field definition's editor `widget` (#2284): which the definition accepts
  (`Validations.FieldWidget`), which it drops when its settings change
  (`Changes.ClearWidget`), and who may set one. The allow-list itself is
  `KilnCMS.CMS.FieldWidgetsTest`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fw-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp attrs(attrs),
    do:
      Map.merge(
        %{content_type: :page, name: "f#{System.unique_integer([:positive])}", label: "F"},
        attrs
      )

  defp define(attrs, actor), do: CMS.create_field_definition(attrs(attrs), actor: actor)
  defp define!(attrs, actor), do: CMS.create_field_definition!(attrs(attrs), actor: actor)

  defp widget_error({:error, error}) do
    assert %Ash.Error.Invalid{errors: errors} = error

    assert [%{field: :widget} = invalid | _] =
             Enum.filter(errors, &(Map.get(&1, :field) == :widget))

    Exception.message(invalid)
  end

  defp widget_error({:ok, field}),
    do: flunk("expected a widget error, stored #{inspect(field.widget)}")

  @single_select %{field_type: :select, options: ~w(a b)}
  @multiple_select %{field_type: :select, multiple: true, options: ~w(a b)}
  @plain_text %{field_type: :text, format: :plain}
  @single_reference %{field_type: :reference, target_type: "page"}

  describe "accepts" do
    test "each widget a field's settings offer, stored as given" do
      admin = user(:admin)

      for {settings, widgets} <- [
            {@single_select, ~w(dropdown radios buttons)},
            {@multiple_select, ~w(tags checkboxes)},
            {@plain_text, ~w(textarea single_line)},
            {@single_reference, ~w(autocomplete dropdown)},
            {%{field_type: :rating}, ~w(number stars)}
          ],
          widget <- widgets do
        assert define!(Map.put(settings, :widget, widget), admin).widget == widget
      end
    end

    test "no widget: the type's default, stored as nil" do
      assert define!(@single_select, user(:admin)).widget == nil
    end

    test "a blank widget is no widget" do
      assert define!(Map.put(@single_select, :widget, ""), user(:admin)).widget == nil
    end
  end

  describe "refuses" do
    test "a widget of another type" do
      admin = user(:admin)

      assert widget_error(define(Map.put(@plain_text, :widget, "radios"), admin)) =~
               "radios is not an editor input for this field (use one of: textarea, single_line)"

      assert widget_error(
               define(%{field_type: :text, format: :rich, widget: "single_line"}, admin)
             ) =~
               "this field has no choice of editor input"

      assert widget_error(
               define(Map.merge(@single_reference, %{multiple: true, widget: "dropdown"}), admin)
             ) =~ "no choice of editor input"

      assert widget_error(define(%{field_type: :string, widget: "radios"}, admin)) =~
               "no choice of editor input"
    end

    test "an unknown widget" do
      assert widget_error(define(Map.put(@single_select, :widget, "sparkle"), user(:admin))) =~
               "sparkle is not an editor input for this field"
    end

    # The specific message proves `ClearMultiple` (a change) settled
    # `allow_custom` before this validation read it.
    test "checkboxes on an open vocabulary, with a message saying why" do
      result =
        define(
          Map.merge(@multiple_select, %{allow_custom: true, widget: "checkboxes"}),
          user(:admin)
        )

      assert widget_error(result) =~ "checkboxes can't take terms of their own"
    end

    test "a plugin type's widget it does not declare" do
      assert widget_error(define(%{field_type: :rating, widget: "bogus"}, user(:admin))) =~
               "bogus is not an editor input for this field (use one of: number, stars)"
    end

    test "any widget on a link field" do
      admin = user(:admin)
      reference = define!(Map.put(@single_reference, :multiple, true), admin)

      result =
        CMS.create_field_definition(
          %{
            link_of_id: reference.id,
            name: "role",
            label: "Role",
            field_type: :select,
            options: ~w(lead support),
            widget: "radios"
          },
          actor: admin
        )

      assert widget_error(result) =~ "no choice of editor input"
    end

    test "any widget on a group sub-field" do
      admin = user(:admin)
      group = define!(%{field_type: :group, multiple: true}, admin)

      result =
        CMS.create_field_definition(
          %{
            group_of_id: group.id,
            name: "unit",
            label: "Unit",
            field_type: :select,
            options: ~w(g mg),
            widget: "radios"
          },
          actor: admin
        )

      assert widget_error(result) =~ "no choice of editor input"
    end
  end

  describe "a settings change" do
    test "retyping the field drops its widget" do
      admin = user(:admin)
      field = define!(Map.put(@single_select, :widget, "radios"), admin)

      assert CMS.update_field_definition!(field, %{field_type: :string}, actor: admin).widget ==
               nil
    end

    test "making a single select multiple drops a single-select widget" do
      admin = user(:admin)
      field = define!(Map.put(@single_select, :widget, "radios"), admin)

      assert CMS.update_field_definition!(field, %{multiple: true}, actor: admin).widget == nil
    end

    test "making plain text rich drops its widget" do
      admin = user(:admin)
      field = define!(Map.put(@plain_text, :widget, "single_line"), admin)

      assert CMS.update_field_definition!(field, %{format: :rich}, actor: admin).widget == nil
    end

    test "opening the vocabulary drops checkboxes" do
      admin = user(:admin)
      field = define!(Map.put(@multiple_select, :widget, "checkboxes"), admin)

      assert CMS.update_field_definition!(field, %{allow_custom: true}, actor: admin).widget ==
               nil
    end

    test "keeps a widget the new settings still offer" do
      admin = user(:admin)
      field = define!(Map.put(@single_select, :widget, "radios"), admin)

      assert CMS.update_field_definition!(field, %{options: ~w(a b c)}, actor: admin).widget ==
               "radios"
    end

    test "naming a widget the new settings don't offer is refused, not dropped" do
      admin = user(:admin)
      field = define!(Map.put(@single_select, :widget, "radios"), admin)

      assert widget_error(
               CMS.update_field_definition(field, %{multiple: true, widget: "buttons"},
                 actor: admin
               )
             ) =~ "buttons is not an editor input for this field (use one of: tags, checkboxes)"
    end

    # Ash drops a change equal to the stored value, so the widget must count
    # as named from the input itself, or a FieldSync import repeating the
    # stored widget would be silently cleared.
    test "naming the stored widget alongside settings that don't offer it is refused" do
      admin = user(:admin)
      field = define!(Map.put(@single_select, :widget, "radios"), admin)

      assert widget_error(
               CMS.update_field_definition(field, %{multiple: true, widget: "radios"},
                 actor: admin
               )
             ) =~ "radios is not an editor input"

      assert CMS.get_field_definition!(field.id, actor: admin).widget == "radios"
    end
  end

  describe "authorization" do
    test "an editor can't set a widget" do
      admin = user(:admin)
      field = define!(@single_select, admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_field_definition(field, %{widget: "radios"}, actor: user(:editor))

      assert {:error, %Ash.Error.Forbidden{}} =
               define(Map.put(@single_select, :widget, "radios"), user(:editor))
    end
  end
end
