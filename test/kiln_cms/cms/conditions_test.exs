defmodule KilnCMS.CMS.ConditionsTest do
  @moduledoc """
  The pure rule module behind conditional custom fields (#2277). Evaluation is
  run from `test/support/fixtures/conditions_cases.json`, the same file the
  editor's JavaScript evaluator is tested against, so the two cannot drift.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.Conditions

  @cases "test/support/fixtures/conditions_cases.json"
         |> File.read!()
         |> Jason.decode!()

  @external_resource "test/support/fixtures/conditions_cases.json"

  for %{"name" => name, "rule" => rule, "values" => values, "expected" => expected} <- @cases do
    test "fixture: #{name}" do
      assert Conditions.evaluate(unquote(Macro.escape(rule)), unquote(Macro.escape(values))) ==
               unquote(expected)
    end
  end

  test "the fixture covers every operator" do
    ops =
      @cases
      |> Enum.flat_map(&Conditions.leaves(&1["rule"]))
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.sort()

    assert ops == Enum.sort(Conditions.ops())
  end

  defp leaf(field \\ "a", op \\ "eq", value \\ "x"),
    do: %{"field" => field, "op" => op, "value" => value}

  describe "normalize/1" do
    test "no rule is nil" do
      assert Conditions.normalize(nil) == nil
      assert Conditions.normalize(%{}) == nil
    end

    test "atom keys and operators become strings, recursively" do
      assert Conditions.normalize(%{all: [%{field: "a", op: :eq, value: "x"}]}) ==
               %{"all" => [leaf()]}
    end
  end

  describe "check_shape/1" do
    test "accepts a leaf, a combinator, and a value-less operator" do
      assert Conditions.valid_shape?(leaf())
      assert Conditions.valid_shape?(%{"any" => [leaf(), %{"all" => [leaf("b"), leaf("c")]}]})
      assert Conditions.valid_shape?(%{"field" => "a", "op" => "empty"})
      assert Conditions.valid_shape?(%{field: "a", op: :in, value: ["x", 1]})
    end

    test "refuses what is not a rule" do
      for bad <- [nil, %{}, "x", [], %{"foo" => 1}, %{"field" => "a"}, %{"op" => "eq"}] do
        refute Conditions.valid_shape?(bad), inspect(bad)
      end
    end

    test "refuses an unknown operator, key, or an empty field" do
      refute Conditions.valid_shape?(leaf("a", "like"))
      refute Conditions.valid_shape?(Map.put(leaf(), "extra", 1))
      refute Conditions.valid_shape?(leaf(""))
    end

    test "checks the arity of the value per operator" do
      refute Conditions.valid_shape?(%{"field" => "a", "op" => "eq"})
      refute Conditions.valid_shape?(leaf("a", "eq", ["x"]))
      refute Conditions.valid_shape?(leaf("a", "in", "x"))
      refute Conditions.valid_shape?(leaf("a", "in", []))
      refute Conditions.valid_shape?(leaf("a", "in", Enum.to_list(1..51)))
      refute Conditions.valid_shape?(leaf("a", "empty", "x"))
    end

    test "refuses empty and mixed combinators" do
      refute Conditions.valid_shape?(%{"all" => []})
      refute Conditions.valid_shape?(%{"all" => [leaf()], "any" => [leaf()]})
      refute Conditions.valid_shape?(%{"all" => leaf()})
    end

    test "limits depth to 3 and size to 10 nodes" do
      assert Conditions.valid_shape?(%{"all" => [%{"any" => [leaf()]}]})
      refute Conditions.valid_shape?(%{"all" => [%{"any" => [%{"all" => [leaf()]}]}]})

      nine = for n <- 1..9, do: leaf("f#{n}")
      assert Conditions.valid_shape?(%{"all" => nine})
      refute Conditions.valid_shape?(%{"all" => nine ++ [leaf("f10")]})
    end
  end

  describe "references/1, leaves/1 and rename/3" do
    test "references are unique and ordered" do
      rule = %{"all" => [leaf("b"), %{"any" => [leaf("a"), leaf("b", "empty", nil)]}]}
      assert Conditions.references(rule) == ["b", "a"]
      assert Conditions.references(nil) == []
    end

    test "rename rewrites every leaf and leaves other rules alone" do
      rule = %{"all" => [leaf("old"), %{"any" => [leaf("old", "gt", 1), leaf("keep")]}]}

      assert Conditions.rename(rule, "old", "new") ==
               %{"all" => [leaf("new"), %{"any" => [leaf("new", "gt", 1), leaf("keep")]}]}

      assert Conditions.rename(leaf("keep"), "old", "new") == leaf("keep")
      assert Conditions.rename(nil, "old", "new") == nil
    end
  end

  describe "evaluate/2 never raises" do
    test "absent, broken, or odd input is false" do
      refute Conditions.evaluate(nil, %{})
      refute Conditions.evaluate(%{"nope" => 1}, %{"a" => 1})
      refute Conditions.evaluate(leaf(), nil)
      refute Conditions.evaluate(leaf("a", "gt", 1), %{"a" => %{"x" => 1}})
      refute Conditions.evaluate(leaf("a", "eq", "x"), %{"a" => %{"x" => 1}})
    end

    test "values may be atom-keyed" do
      assert Conditions.evaluate(leaf(), %{a: "x"})
    end
  end

  describe "effective/3" do
    defp def_(name, attrs),
      do: Map.merge(%{name: name, required: false, visible_when: nil, required_when: nil}, attrs)

    test "a hidden field is not required, even when statically required" do
      defs = [def_("note", %{required: true, visible_when: leaf("kind", "eq", "other")})]

      assert %{"note" => %{hidden?: true, required?: false}} =
               Conditions.effective(defs, %{"kind" => "a"})

      assert %{"note" => %{hidden?: false, required?: true}} =
               Conditions.effective(defs, %{"kind" => "other"})
    end

    test "required_when makes a field required while it holds" do
      defs = [def_("why", %{required_when: leaf("kind", "eq", "other")})]

      assert %{"why" => %{required?: true}} = Conditions.effective(defs, %{"kind" => "other"})
      assert %{"why" => %{required?: false}} = Conditions.effective(defs, %{})

      assert %{"why" => %{required?: false}} =
               Conditions.effective(defs, %{"kind" => "other"}, required_when: false)
    end

    test "a rule that cannot be read neither hides nor requires" do
      defs = [def_("x", %{visible_when: %{"bogus" => 1}, required_when: %{"bogus" => 1}})]
      assert %{"x" => %{hidden?: false, required?: false}} = Conditions.effective(defs, %{})
    end

    test "apply_to/3 leaves definitions without rules untouched" do
      defs = [def_("plain", %{required: true})]
      assert Conditions.apply_to(defs, %{}) == defs
    end
  end
end
