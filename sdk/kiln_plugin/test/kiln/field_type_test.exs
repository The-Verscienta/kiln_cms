defmodule Kiln.FieldTypeTest do
  @moduledoc """
  `Kiln.FieldType`'s own helpers — the part of the custom-field-type contract
  (D18) that is a function rather than a callback. The callbacks themselves,
  and the registry that dispatches to them, are covered by
  `Kiln.FieldTypesTest`.
  """
  use ExUnit.Case, async: true

  doctest Kiln.FieldType, only: [parse_float: 1, widget: 2]

  describe "parse_float/1" do
    test "is total across toolchain versions" do
      # `Float.parse/1` is version-dependent for an overflow literal: it returns
      # `:error` on Elixir 1.20 but *raises* ArgumentError from
      # `:erlang.list_to_float/1` on 1.19, which `.tool-versions` pinned until
      # the move to 1.20. Anything pattern-matching its result goes through this.
      assert Kiln.FieldType.parse_float(String.duplicate("9", 400) <> ".0") == :error
      assert Kiln.FieldType.parse_float("not a number") == :error
    end

    test "otherwise answers exactly as Float.parse/1 does" do
      assert Kiln.FieldType.parse_float("1.5") == {1.5, ""}
      assert Kiln.FieldType.parse_float("2.5kg") == {2.5, "kg"}
      assert Kiln.FieldType.parse_float("-0.25") == {-0.25, ""}
      assert Kiln.FieldType.parse_float("3") == {3.0, ""}
      assert Kiln.FieldType.parse_float("") == :error
    end
  end

  defmodule Stars do
    use Kiln.FieldType
    def cast(value, _definition), do: {:ok, value}
    def widgets(_definition), do: [:number, {:stars, "Stars"}]
  end

  defmodule ByMultiple do
    use Kiln.FieldType
    def cast(value, _definition), do: {:ok, value}
    def widgets(%{multiple: true}), do: [:list]
    def widgets(_definition), do: [:one, :other]
  end

  defmodule NoWidgets do
    use Kiln.FieldType
    def cast(value, _definition), do: {:ok, value}
  end

  defmodule EmptyWidgets do
    use Kiln.FieldType
    def cast(value, _definition), do: {:ok, value}
    def widgets(_definition), do: []
  end

  defmodule MessyWidgets do
    use Kiln.FieldType
    def cast(value, _definition), do: {:ok, value}
    def widgets(_definition), do: [:Number, "text", {:bad, :label}, :stars, :stars, :wide]
  end

  defmodule RaisingWidgets do
    use Kiln.FieldType
    def cast(value, _definition), do: {:ok, value}
    def widgets(_definition), do: raise("boom")
  end

  describe "widgets/1" do
    test "is optional and not defaulted by use Kiln.FieldType" do
      assert {:widgets, 1} in Kiln.FieldType.behaviour_info(:optional_callbacks)
      refute function_exported?(NoWidgets, :widgets, 1)
    end
  end

  describe "widget/2" do
    test "answers the stored widget while the type offers it" do
      assert Kiln.FieldType.widget(%{widget: "stars"}, Stars) == "stars"
      assert Kiln.FieldType.widget(%{widget: "number"}, Stars) == "number"
    end

    test "falls back to the first widget when none is stored, or one no longer offered" do
      assert Kiln.FieldType.widget(%{widget: nil}, Stars) == "number"
      assert Kiln.FieldType.widget(%{}, Stars) == "number"
      assert Kiln.FieldType.widget(%{widget: "dropped"}, Stars) == "number"
    end

    test "asks the type with the definition itself" do
      assert Kiln.FieldType.widget(%{multiple: true, widget: "one"}, ByMultiple) == "list"
      assert Kiln.FieldType.widget(%{multiple: false, widget: "other"}, ByMultiple) == "other"
    end

    test "is nil for a type that offers no widgets" do
      assert Kiln.FieldType.widget(%{widget: "stars"}, NoWidgets) == nil
      assert Kiln.FieldType.widget(%{widget: "stars"}, EmptyWidgets) == nil
    end

    test "drops malformed, non-machine and repeated names, as the host does" do
      assert Kiln.FieldType.widget(%{widget: nil}, MessyWidgets) == "stars"
      assert Kiln.FieldType.widget(%{widget: "Number"}, MessyWidgets) == "stars"
      assert Kiln.FieldType.widget(%{widget: "wide"}, MessyWidgets) == "wide"
    end

    test "offers nothing, rather than raising, when widgets/1 raises" do
      assert Kiln.FieldType.widget(%{widget: "stars"}, RaisingWidgets) == nil
    end
  end
end
