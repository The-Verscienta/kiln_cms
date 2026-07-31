defmodule KilnCMS.CMS.ComputedTest do
  @moduledoc """
  The computed-field expression language (#429) on its own: parsing, the
  function allowlist, and evaluation. No database — this is the part that has
  to be total and sandboxed, so it's tested as a pure function.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.Computed

  defp context(overrides \\ %{}) do
    document =
      Map.merge(
        %{
          "title" => "Hello World",
          "slug" => "hello-world",
          "body" => "one two three four five",
          "excerpt" => nil
        },
        Map.get(overrides, :document, %{})
      )

    %{document: document, fields: Map.get(overrides, :fields, %{})}
  end

  defp eval(source, overrides \\ %{}), do: Computed.evaluate(source, context(overrides))

  describe "parsing" do
    test "a template must contain an expression" do
      assert {:error, message} = Computed.parse("just some words")
      assert message =~ "at least one"
    end

    test "blank and oversized templates are rejected" do
      assert {:error, "can't be blank"} = Computed.parse("   ")
      assert {:error, "can't be blank"} = Computed.parse(nil)

      assert {:error, "is too long"} =
               Computed.parse("{{ title }}" <> String.duplicate("x", 2000))
    end

    test "an unknown function is a parse error, not a silent blank" do
      assert {:error, message} = Computed.parse("{{ slugfy(title) }}")
      assert message =~ "unknown function slugfy/1"
    end

    test "arity is checked against the allowlist" do
      assert {:error, message} = Computed.parse("{{ round(1, 2, 3) }}")
      assert message =~ "takes 1 or 2 argument(s), got 3"

      assert {:error, message} = Computed.parse("{{ sum() }}")
      assert message =~ "at least one argument"
    end

    test "malformed syntax is reported rather than raised" do
      assert {:error, message} = Computed.parse("{{ word_count(body }}")
      assert message =~ "closing parenthesis"

      assert {:error, message} = Computed.parse("{{ 'unclosed }}")
      assert message =~ "unterminated string"

      assert {:error, _} = Computed.parse("{{ ! }}")
    end

    test "an unterminated {{ is rejected, not silently treated as an expression" do
      assert {:error, message} = Computed.parse("{{ title")
      assert message =~ "never closed"

      # The tail of a well-formed expression plus a stray opener must not be
      # parsed as a second expression and silently dropped.
      assert {:error, _} = Computed.parse("{{ title }}{{ oops")
    end

    test "surrounding whitespace does not demote a lone expression" do
      ctx = context()

      assert Computed.evaluate("{{ word_count(body) }}", ctx) === 5
      assert Computed.evaluate("  {{ word_count(body) }}  ", ctx) === 5
      assert Computed.evaluate("{{ word_count(body) }}\n", ctx) === 5
    end

    test "a literal that overflows a float parses and evaluates without raising" do
      huge = String.duplicate("9", 320) <> ".5"

      assert {:ok, _} = Computed.parse("{{ round(#{huge}, 2) }}")
      assert is_number(Computed.evaluate("{{ round(#{huge}, 2) }}", context()))
    end

    test "safe_float/1 is total across toolchain versions" do
      # `Float.parse/1` is version-dependent for an overflow literal: it returns
      # `:error` on Elixir 1.20 but *raises* ArgumentError from
      # `:erlang.list_to_float/1` on 1.19 — the version `.tool-versions` pins and
      # CI runs. Anything pattern-matching its result must go through this.
      assert Computed.safe_float(String.duplicate("9", 400) <> ".0") == :error
      assert Computed.safe_float("not a number") == :error
      assert Computed.safe_float("1.5") == {1.5, ""}
      assert Computed.safe_float("2.5kg") == {2.5, "kg"}
    end

    test "every advertised function parses AND evaluates" do
      # Parsing only consults the `@functions` allowlist, so a name listed there
      # with no matching `call/2` clause would parse fine and then raise at
      # runtime — swallowed by `evaluate/2`'s rescue into a silently blank field
      # on every record. Evaluate each one so the allowlist can't outrun the
      # implementation.
      ctx = context(%{fields: %{"n" => 2}})

      for name <- Computed.functions() do
        # Both a text-shaped and a number-shaped call, since the allowlist mixes
        # string functions with arithmetic ones.
        sources = [
          "{{ #{name}(title) }}",
          "{{ #{name}(title, n) }}",
          "{{ #{name}(title, title, title) }}",
          "{{ #{name}(n) }}",
          "{{ #{name}(n, n) }}",
          "{{ #{name}(n, n, n) }}"
        ]

        assert Enum.any?(sources, fn source ->
                 match?({:ok, _}, Computed.parse(source)) and
                   Computed.evaluate(source, ctx) != nil
               end),
               "#{name} did not both parse and evaluate at any arity from 1 to 3"
      end
    end
  end

  describe "references" do
    test "bare names resolve document scalars first, then custom fields" do
      assert eval("{{ title }}") == "Hello World"
      assert eval("{{ author }}", %{fields: %{"author" => "Ada"}}) == "Ada"
    end

    test "a document scalar wins a name collision; field. reaches past it" do
      overrides = %{fields: %{"title" => "The custom one"}}

      assert eval("{{ title }}", overrides) == "Hello World"
      assert eval("{{ field.title }}", overrides) == "The custom one"
    end

    test "an unknown reference is blank, not an error" do
      # Definitions come and go independently of the formulas naming them, so a
      # stale reference must never block a save.
      assert eval("{{ nonsense }}") == nil
      assert eval("before {{ nonsense }} after") == "before  after"
    end
  end

  describe "evaluation" do
    test "a lone expression keeps its native type; interpolation stringifies" do
      assert eval("{{ word_count(body) }}") == 5
      assert eval("{{ word_count(body) }} words") == "5 words"
    end

    test "reading time rounds up and respects a custom rate" do
      body = String.duplicate("word ", 450)

      assert eval("{{ reading_time(body) }}", %{document: %{"body" => body}}) == 3
      assert eval("{{ reading_time(body, 100) }}", %{document: %{"body" => body}}) == 5
      assert eval("{{ reading_time(body) }}", %{document: %{"body" => ""}}) == 0
    end

    test "numeric functions ignore non-numeric arguments" do
      fields = %{"price" => 10.5, "tax" => "2.25", "shipping" => nil}

      assert eval("{{ sum(price, tax, shipping) }}", %{fields: fields}) == 12.75
      assert eval("{{ round(sum(price, tax), 1) }}", %{fields: fields}) == 12.8
      assert eval("{{ product(2, 3, 4) }}") == 24
      assert eval("{{ subtract(10, 4) }}") == 6
    end

    test "divide by zero and non-numeric arithmetic yield blank, not a crash" do
      assert eval("{{ divide(1, 0) }}") == nil
      assert eval("{{ subtract(title, 1) }}") == nil
      assert eval("{{ sum(title) }}") == nil
    end

    test "string functions" do
      assert eval("{{ slugify(title) }}") == "hello-world"
      assert eval("{{ upcase(title) }}") == "HELLO WORLD"
      assert eval("{{ truncate(title, 5) }}") == "Hello…"
      assert eval("{{ concat('SKU-', upcase(slug)) }}") == "SKU-HELLO-WORLD"
      assert eval("{{ join(' / ', title, missing, slug) }}") == "Hello World / hello-world"
    end

    test "default/2 falls back on a blank value" do
      assert eval("{{ default(excerpt, title) }}") == "Hello World"
      assert eval("{{ default(title, 'unused') }}") == "Hello World"
    end

    test "an all-blank result is nil rather than an empty string" do
      assert eval("{{ nonsense }}") == nil
      assert eval("  {{ nonsense }}  ") == nil
    end

    test "a non-scalar value interpolates as blank rather than leaking a term" do
      # A geolocation value is a map; a formula naming it must not splice an
      # inspected Elixir term into delivered content.
      assert eval("[{{ place }}]", %{fields: %{"place" => %{"lat" => 1.0, "lng" => 2.0}}}) ==
               "[]"
    end

    test "an unparseable template evaluates to nil" do
      assert Computed.evaluate("{{ slugfy(title) }}", context()) == nil
    end
  end
end
