defmodule Kiln.FieldTypeTest do
  @moduledoc """
  `Kiln.FieldType`'s own helpers — the part of the custom-field-type contract
  (D18) that is a function rather than a callback. The callbacks themselves,
  and the registry that dispatches to them, are covered by
  `Kiln.FieldTypesTest`.
  """
  use ExUnit.Case, async: true

  doctest Kiln.FieldType, only: [parse_float: 1]

  describe "parse_float/1" do
    test "is total across toolchain versions" do
      # `Float.parse/1` is version-dependent for an overflow literal: it returns
      # `:error` on Elixir 1.20 but *raises* ArgumentError from
      # `:erlang.list_to_float/1` on 1.19 — the version `.tool-versions` pins and
      # CI runs. Anything pattern-matching its result must go through this.
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
end
