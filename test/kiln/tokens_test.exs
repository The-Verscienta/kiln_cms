defmodule Kiln.TokensTest do
  @moduledoc """
  The shared `[token]` substitution engine (#468), tested independently of
  any consumer's vocabulary. `KilnCMS.Slug.PatternTest` covers the same
  engine through its most elaborate consumer.
  """
  use ExUnit.Case, async: true

  alias Kiln.Tokens

  defp definitions do
    [
      %{match: "name", resolve: fn _token, ctx -> ctx[:name] end},
      %{match: "shout", resolve: fn _token, ctx -> ctx[:name] && String.upcase(ctx[:name]) end},
      %{match: ~r/\Afield:[a-z0-9_]+\z/, resolve: &field/2}
    ]
  end

  defp field("field:" <> name, ctx), do: get_in(ctx, [:fields, name])

  describe "expand/3" do
    test "substitutes every known token" do
      assert Tokens.expand("Hi [name], aka [shout]", definitions(), %{name: "ada"}) ==
               "Hi ada, aka ADA"
    end

    test "an unknown token expands to empty rather than raising" do
      assert Tokens.expand("[name] the [unknown]", definitions(), %{name: "ada"}) == "ada the "
    end

    test "a resolver returning nil expands to empty, not the literal \"nil\"" do
      assert Tokens.expand("[shout]!", definitions(), %{}) == "!"
    end

    test "a family definition (Regex match) resolves the variable part" do
      ctx = %{fields: %{"size" => "14mm"}}
      assert Tokens.expand("Size: [field:size]", definitions(), ctx) == "Size: 14mm"
    end

    test "literal text with no brackets passes through unchanged" do
      assert Tokens.expand("just text", definitions(), %{}) == "just text"
    end
  end

  describe "validate/2" do
    test "nil pattern is always ok" do
      assert Tokens.validate(nil, definitions()) == :ok
    end

    test "a pattern using only known tokens is ok" do
      assert Tokens.validate("[name] / [field:size]", definitions()) == :ok
    end

    test "an unknown token is reported" do
      assert {:error, ["typo"]} = Tokens.validate("[typo]", definitions())
    end

    test "every unknown token is reported, not just the first" do
      assert {:error, unknown} = Tokens.validate("[a] [b] [name]", definitions())
      assert Enum.sort(unknown) == ["a", "b"]
    end

    test "duplicate unknown tokens are reported once" do
      assert {:error, ["typo"]} = Tokens.validate("[typo] and [typo] again", definitions())
    end

    test "the empty-bracket pattern is caught as unknown, not silently accepted" do
      assert {:error, [""]} = Tokens.validate("[]", definitions())
    end
  end

  describe "uses?/2" do
    test "true when the pattern mentions the token, false otherwise" do
      assert Tokens.uses?("[name]!", "name")
      refute Tokens.uses?("[name]!", "shout")
      refute Tokens.uses?(nil, "name")
    end
  end

  describe "names/1" do
    test "lists only literal token names, not the family's regex" do
      assert Tokens.names(definitions()) == ["name", "shout"]
    end
  end
end
