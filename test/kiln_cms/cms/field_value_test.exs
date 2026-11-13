defmodule KilnCMS.CMS.FieldValueTest do
  @moduledoc """
  `KilnCMS.CMS.FieldValue`: one custom field value as the text it stores or
  compares, and the per-type coercion writes share with filter operands.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.FieldValue

  @not_single "must be a single value, not an object or a list"

  describe "text/1" do
    test "a scalar is its text, as to_string/1 gives it" do
      for {term, text} <- [
            {"a", "a"},
            {42, "42"},
            {1.5, "1.5"},
            {true, "true"},
            {:atom, "atom"},
            {nil, ""},
            {Decimal.new("1.50"), "1.50"},
            {~D[2026-03-01], "2026-03-01"},
            {~T[09:30:00], "09:30:00"},
            {~N[2026-03-01 10:00:00], "2026-03-01 10:00:00"},
            {URI.parse("https://example.com"), "https://example.com"}
          ] do
        assert {term, FieldValue.text(term)} == {term, {:ok, text}}
      end
    end

    test "an object, a list or a struct with no text form is not one value" do
      for term <- [%{}, %{"en" => "x"}, [], ["a", "b"], ~c"ab", MapSet.new(["a"])] do
        assert {term, FieldValue.text(term)} == {term, :error}
      end
    end
  end

  describe "coerce/2" do
    test "an object or a list is refused for every core scalar type" do
      for type <- [:text, :string, :url, :select, :integer, :float, :boolean, :date, :datetime],
          value <- [%{"en" => "x"}, %{}, [], ["a", "b"]] do
        definition = %{field_type: type, options: ["a"]}

        assert {type, value, FieldValue.coerce(value, definition)} ==
                 {type, value, {:error, @not_single}}
      end
    end

    test "a struct is one value: a date is coerced, not refused" do
      assert FieldValue.coerce(~D[2026-03-01], %{field_type: :date}) == {:ok, "2026-03-01"}

      assert FieldValue.coerce(MapSet.new(["a"]), %{field_type: :string}) ==
               {:error, @not_single}
    end

    test "a plugin type's own cast decides: a composite takes an object" do
      assert {:ok, _point} =
               FieldValue.coerce(%{"lat" => "51.5", "lng" => "-0.12"}, %{
                 field_type: :geolocation
               })
    end

    test "an overflowing float literal is a number error" do
      assert FieldValue.coerce("1e400", %{field_type: :float}) == {:error, "must be a number"}
    end
  end

  describe "canonical/2" do
    test "the tidying types give what a write stores" do
      for {definition, raw, canonical} <- [
            {%{field_type: :color}, "#FFF", "#ffffff"},
            {%{field_type: :email}, "a@Example.com", "a@example.com"},
            {%{field_type: :telephone}, "+44 20 7946 0958", "+442079460958"},
            {%{field_type: :time}, "9:30", "09:30"},
            {%{field_type: :slug}, "Hello World", "hello-world"},
            {%{field_type: :url}, " https://x.example ", "https://x.example"},
            {%{field_type: :string}, " plain ", "plain"},
            {%{field_type: :string}, 42, "42"},
            {%{field_type: :select, options: ["ny"], option_labels: %{"ny" => "New York"}},
             "New York", "ny"}
          ] do
        assert {definition.field_type, FieldValue.canonical(definition, raw)} ==
                 {definition.field_type, {:ok, canonical}}
      end
    end

    test "the types compared as sent, and operands a field could never hold, are :none" do
      for {definition, raw} <- [
            {%{field_type: :text}, " <b>x</b> "},
            {%{field_type: :datetime}, "2026-03-01T10:00"},
            {%{field_type: :integer}, "10"},
            {%{field_type: :date}, "2026-03-01"},
            {%{field_type: :no_such_plugin_type}, "x"},
            {%{field_type: :email}, "not an address"},
            {%{field_type: :telephone}, String.duplicate("1", 100_000)},
            {%{field_type: :select, options: ["ny"]}, "Paris"},
            {%{field_type: :string}, %{"x" => 1}},
            {%{field_type: :string}, ["a"]},
            {%{field_type: :string}, true}
          ] do
        assert {definition.field_type, raw, FieldValue.canonical(definition, raw)} ==
                 {definition.field_type, raw, :none}
      end
    end
  end
end
