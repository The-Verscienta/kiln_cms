defmodule KilnCMS.CMS.Computed.RecipesTest do
  @moduledoc """
  The formula builder's recipes: each writes a formula the evaluator accepts,
  reads back from its own output, and refuses slot input that would change the
  formula's structure rather than fill it.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.Computed
  alias KilnCMS.CMS.Computed.Recipes

  # Slot values that fill every recipe's required slots.
  @filled %{
    "source" => "body",
    "value" => "size",
    "first" => "price",
    "second" => "quantity",
    "primary" => "subtitle",
    "fallback" => "title",
    "part" => "quantity",
    "whole" => "price",
    "start" => "starts_on",
    "finish" => "ends_on",
    "date" => "ends_on",
    "compare" => "40",
    "then" => "Large"
  }

  defp build!(id, slots \\ %{}) do
    {:ok, formula} =
      Recipes.build(id, Recipes.defaults(id) |> Map.merge(@filled) |> Map.merge(slots))

    formula
  end

  test "every recipe builds a formula that parses, and recognizes its own output" do
    for %{id: id} <- Recipes.all() do
      formula = build!(id)
      assert {:ok, _template} = Computed.parse(formula), "#{id} wrote #{formula}"
      assert {:ok, ^id, _slots} = Recipes.recognize(formula), "#{id} didn't read back #{formula}"
    end
  end

  test "recognizing returns the slots the formula was built from" do
    formula = build!("conditional", %{"operator" => "greater_than", "otherwise" => "Small"})
    assert formula == ~s|{{ if(greater_than(size, 40), "Large", "Small") }}|

    assert {:ok, "conditional", slots} = Recipes.recognize(formula)
    assert %{"value" => "size", "operator" => "greater_than", "compare" => "40"} = slots
    assert %{"then" => "Large", "otherwise" => "Small"} = slots
  end

  test "the built formulas compute what their recipe says" do
    context = %{
      document: %{"title" => "Hello", "body" => String.duplicate("word ", 460)},
      fields: %{
        "price" => 20,
        "quantity" => "3",
        "size" => 42,
        "starts_on" => "2026-10-01",
        "ends_on" => "2026-10-17"
      }
    }

    eval = &Computed.evaluate(&1, context)

    assert eval.(build!("reading_time")) == "2 min read"
    assert eval.(build!("word_count")) == 460
    assert eval.(build!("label", %{"prefix" => "Size", "suffix" => "EU"})) == "Size 42 EU"
    assert eval.(build!("combine")) == "20 3"
    assert eval.(build!("total")) == 23
    assert eval.(build!("multiply")) == 60
    assert eval.(build!("percentage")) == "15%"
    assert eval.(build!("percentage", %{"decimals" => "1"})) == "15.0%"
    assert eval.(build!("fallback")) == "Hello"
    assert eval.(build!("conditional", %{"operator" => "greater_than"})) == "Large"
    assert eval.(build!("conditional", %{"operator" => "less_than"})) == nil

    assert eval.(build!("conditional", %{"operator" => "is_empty", "value" => "missing"})) ==
             "Large"

    assert eval.(build!("days_between")) == "16 days"
  end

  test "the date recipes read the pinned date, and say they do" do
    context = %{
      fields: %{"ends_on" => "2026-10-20", "born" => "1990-10-18"},
      today: ~D[2026-10-17]
    }

    eval = &Computed.evaluate(&1, context)

    assert build!("days_until") == "{{ days_between(today(), ends_on) }} days"
    assert eval.(build!("days_until")) == "3 days"
    assert eval.(build!("days_until", %{"suffix" => ""})) == 3

    assert build!("age", %{"date" => "born"}) == "{{ years_between(born, today()) }}"
    assert eval.(build!("age", %{"date" => "born"})) == 35
    # The birthday: the same formula, a day later.
    assert Computed.evaluate(build!("age", %{"date" => "born"}), %{
             context
             | today: ~D[2026-10-18]
           }) ==
             36

    for id <- ~w(days_until age), do: assert(Computed.time_dependent?(build!(id)))
    refute Computed.time_dependent?(build!("days_between"))
  end

  test "on a document that hasn't filled the values in, every recipe is blank" do
    # The blanks a recipe reads are empty or unusable: no fields at all, and a
    # zero to divide by. Literal text around them (a suffix, a label, a "%")
    # must not survive as a value, and a missing factor or part must not be
    # treated as 1 or 100.
    context = %{document: %{"title" => "", "body" => ""}, fields: %{"zero" => 0}}

    for %{id: id} <- Recipes.all(), id not in ~w(reading_time word_count) do
      formula = build!(id, %{"whole" => "zero", "operator" => "greater_than"})
      assert Computed.evaluate(formula, context) == nil, "#{id}: #{formula}"
    end

    # A count of nothing is a count: zero words, read in no time.
    assert Computed.evaluate(build!("word_count"), context) == 0
    assert Computed.evaluate(build!("reading_time"), context) == "0 min read"
  end

  test "multiply and percentage need every number they use" do
    context = %{document: %{}, fields: %{"price" => 20, "quantity" => nil}}

    assert Computed.evaluate(build!("multiply"), context) == nil
    assert Computed.evaluate(build!("percentage"), context) == nil
  end

  test "the empty test sees list and map values for what they hold" do
    formula = build!("conditional", %{"operator" => "is_empty", "value" => "gallery"})

    assert Computed.evaluate(formula, %{fields: %{"gallery" => [%{"id" => "x"}]}}) == nil
    assert Computed.evaluate(formula, %{fields: %{"gallery" => []}}) == "Large"
    assert Computed.evaluate(formula, %{fields: %{"gallery" => %{}}}) == "Large"
  end

  test "optional slots drop out of the formula" do
    assert build!("combine", %{"third" => ""}) == ~s|{{ join(" ", price, quantity) }}|
    assert build!("combine", %{"third" => "size"}) == ~s|{{ join(" ", price, quantity, size) }}|
    assert build!("word_count", %{"suffix" => ""}) == "{{ word_count(body) }}"

    assert build!("conditional", %{"operator" => "is_empty"}) ==
             ~s|{{ if(is_empty(size), "Large") }}|
  end

  describe "slot input is filled in, never spliced in" do
    test "a value must be a reference" do
      assert {:error, message} = Recipes.build("slug", %{"source" => "title) }}{{ body"})
      assert message =~ "isn't a value"
    end

    test "text can't open or close an expression" do
      assert {:error, _} = Recipes.build("label", %{"value" => "title", "prefix" => "{{ body }}"})
      assert {:error, _} = Recipes.build("conditional", Map.merge(@filled, %{"then" => "}}"}))
    end

    test "text takes whichever quote mark it doesn't contain" do
      assert build!("conditional", %{"then" => ~s|say "hi"|}) =~ ~s|'say "hi"'|

      assert {:error, _} =
               Recipes.build("conditional", Map.merge(@filled, %{"then" => ~s|"it's"|}))
    end

    test "a comparison with a number stays numeric, anything else is quoted" do
      assert build!("conditional", %{"compare" => "100"}) =~ "equals(size, 100)"
      assert build!("conditional", %{"compare" => "yes"}) =~ ~s|equals(size, "yes")|
    end

    test "numbers are bounded whole numbers" do
      assert {:error, _} = Recipes.build("excerpt", %{"source" => "body", "length" => "abc"})
      assert {:error, _} = Recipes.build("percentage", Map.merge(@filled, %{"decimals" => "9"}))
    end
  end

  test "a missing required slot names itself" do
    assert {:error, message} = Recipes.build("multiply", %{"first" => "price"})
    assert message =~ "Times"

    assert {:error, message} =
             Recipes.build(
               "conditional",
               Map.merge(@filled, %{"operator" => "equals", "compare" => ""})
             )

    assert message =~ "compare"
  end

  test "an unknown recipe is refused" do
    assert {:error, _} = Recipes.build("nope", %{})
    assert {:error, _} = Recipes.build(nil, %{})
  end

  test "a hand-edited formula is never squeezed into a recipe" do
    # One function too many, a reordered argument, a differently quoted literal:
    # each is close to a recipe, and recognizing it would rewrite it on save.
    for formula <- [
          "{{ upcase(slugify(title)) }}",
          "{{ reading_time(body, 180) }} min read",
          "{{ product(price, 2) }}",
          ~s|{{ if(equals(size, "40"), "Large") }}|,
          "Size:{{ size }}",
          "{{ title }} and {{ slug }}"
        ] do
      assert Recipes.recognize(formula) == :error, "#{formula} was recognized"
    end

    assert Recipes.recognize(nil) == :error
    assert Recipes.recognize("{{ broken(") == :error
  end
end
