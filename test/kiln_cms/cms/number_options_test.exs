defmodule KilnCMS.CMS.NumberOptionsTest do
  @moduledoc """
  A number field's editor options (#2432): `step`, `prefix` and `suffix` on a
  `FieldDefinition` — what the definition accepts (`Validations.NumberOptions`),
  what it clears (`Changes.ClearNumberOptions`), the slider widget that needs
  bounds, and who may write any of it.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "num-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp attrs(attrs),
    do:
      Map.merge(
        %{
          content_type: :page,
          name: "n#{System.unique_integer([:positive])}",
          label: "N",
          field_type: :integer
        },
        attrs
      )

  defp define(attrs, actor), do: CMS.create_field_definition(attrs(attrs), actor: actor)
  defp define!(attrs, actor), do: CMS.create_field_definition!(attrs(attrs), actor: actor)

  defp error_on({:error, %Ash.Error.Invalid{errors: errors}}, field) do
    assert [invalid | _] = Enum.filter(errors, &(Map.get(&1, :field) == field))
    Exception.message(invalid)
  end

  defp error_on({:ok, record}, field),
    do: flunk("expected an error on #{field}, stored #{inspect(record)}")

  @bounds %{"min" => 0, "max" => 100}

  describe "stores" do
    test "a step, prefix and suffix on an integer and a float" do
      admin = user(:admin)

      integer = define!(%{step: 5, prefix: "#", suffix: "pts", validation: @bounds}, admin)
      assert {integer.step, integer.prefix, integer.suffix} == {5.0, "#", "pts"}

      float = define!(%{field_type: :float, step: 0.25, prefix: "$"}, admin)
      assert {float.step, float.prefix, float.suffix} == {0.25, "$", nil}
    end

    test "none of them by default" do
      field = define!(%{}, user(:admin))
      assert {field.step, field.prefix, field.suffix} == {nil, nil, nil}
    end

    test "blank options are nothing" do
      field = define!(%{step: "", prefix: "", suffix: ""}, user(:admin))
      assert {field.step, field.prefix, field.suffix} == {nil, nil, nil}
    end

    test "on a multiple number: each item is a number input" do
      field = define!(%{multiple: true, step: 2, suffix: "kg"}, user(:admin))
      assert {field.step, field.suffix} == {2.0, "kg"}
    end
  end

  describe "refuses" do
    test "a step of zero or less" do
      admin = user(:admin)

      for step <- [0, -1, -0.5] do
        assert define(%{step: step}, admin) |> error_on(:step) =~ "greater than"
      end
    end

    test "a fractional step on an integer field" do
      assert define(%{step: 0.5}, user(:admin)) |> error_on(:step) =~ "whole number"
      assert {:ok, _float} = define(%{field_type: :float, step: 0.5}, user(:admin))
    end

    test "a step wider than the span between min and max" do
      admin = user(:admin)

      assert define(%{step: 101, validation: @bounds}, admin) |> error_on(:step) =~
               "more than the span"

      assert {:ok, _} = define(%{step: 100, validation: @bounds}, admin)
      # One bound alone is no span.
      assert {:ok, _} = define(%{step: 1_000, validation: %{"min" => 0}}, admin)
    end

    test "a prefix or suffix over 16 characters" do
      admin = user(:admin)
      long = String.duplicate("x", 17)

      assert {:error, _} = define(%{prefix: long}, admin)
      assert {:error, _} = define(%{suffix: long}, admin)
    end

    test "an editor and a viewer writing a definition at all" do
      for role <- [:editor, :viewer] do
        assert {:error, %Ash.Error.Forbidden{}} = define(%{step: 5}, user(role))
      end
    end
  end

  describe "clears" do
    test "all three when the field is not a number" do
      field = define!(%{step: 5, prefix: "$", suffix: "kg"}, user(:admin))

      for type <- [:string, :boolean, :date] do
        retyped = CMS.update_field_definition!(field, %{field_type: type}, actor: user(:admin))
        assert {retyped.step, retyped.prefix, retyped.suffix} == {nil, nil, nil}, "#{type}"
      end
    end

    test "options posted in the same write that retypes the field to text" do
      field = define!(%{}, user(:admin))

      retyped =
        CMS.update_field_definition!(
          field,
          %{field_type: :string, step: 5, prefix: "$", suffix: "kg"},
          actor: user(:admin)
        )

      assert {retyped.step, retyped.prefix, retyped.suffix} == {nil, nil, nil}
    end

    test "options on a create that is not a number" do
      field = define!(%{field_type: :string, step: 5, prefix: "$", suffix: "kg"}, user(:admin))
      assert {field.step, field.prefix, field.suffix} == {nil, nil, nil}
    end

    test "on a plugin field type: its own input attributes are left alone" do
      field = define!(%{field_type: :rating, step: 5, prefix: "$"}, user(:admin))
      assert {field.step, field.prefix} == {nil, nil}
    end

    test "a number keeps them across an unrelated update" do
      admin = user(:admin)
      field = define!(%{step: 5, suffix: "kg", validation: @bounds}, admin)
      updated = CMS.update_field_definition!(field, %{label: "Renamed"}, actor: admin)

      assert {updated.step, updated.suffix} == {5.0, "kg"}
    end
  end

  describe "slider widget" do
    test "is stored on a bounded single number" do
      admin = user(:admin)

      for type <- [:integer, :float] do
        assert define!(%{field_type: type, validation: @bounds, widget: "slider"}, admin).widget ==
                 "slider"
      end
    end

    test "is refused without both bounds" do
      admin = user(:admin)

      for validation <- [%{}, %{"min" => 0}, %{"max" => 5}] do
        assert define(%{validation: validation, widget: "slider"}, admin) |> error_on(:widget) =~
                 "slider is not an editor input for this field (use one of: number)"
      end
    end

    test "is refused on a multiple number" do
      assert define(%{multiple: true, validation: @bounds, widget: "slider"}, user(:admin))
             |> error_on(:widget) =~ "no choice of editor input"
    end

    test "is dropped when the bounds go, unless the write names it again" do
      admin = user(:admin)
      field = define!(%{validation: @bounds, widget: "slider"}, admin)

      relaxed = CMS.update_field_definition!(field, %{validation: %{"min" => 0}}, actor: admin)
      assert relaxed.widget == nil

      assert {:error, _} =
               CMS.update_field_definition(
                 field,
                 %{validation: %{"min" => 0}, widget: "slider"},
                 actor: admin
               )
    end

    test "is dropped when the field becomes multiple" do
      admin = user(:admin)
      field = define!(%{validation: @bounds, widget: "slider"}, admin)

      assert CMS.update_field_definition!(field, %{multiple: true}, actor: admin).widget == nil
    end
  end
end
