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

    test "every advertised function parses AND evaluates" do
      # Parsing only consults the `@functions` allowlist, so a name listed there
      # with no matching `call/2` clause would parse fine and then raise at
      # runtime — swallowed by `evaluate/2`'s rescue into a silently blank field
      # on every record. Evaluate each one so the allowlist can't outrun the
      # implementation.
      ctx = context(%{fields: %{"n" => 2, "d" => "2026-01-01"}})

      for name <- Computed.functions() do
        # Both a text-shaped and a number-shaped call, since the allowlist mixes
        # string functions with arithmetic ones.
        sources = [
          "{{ #{name}(title) }}",
          "{{ #{name}(title, n) }}",
          "{{ #{name}(title, title, title) }}",
          "{{ #{name}(n) }}",
          "{{ #{name}(n, n) }}",
          "{{ #{name}(n, n, n) }}",
          # And date-shaped, for the date functions.
          "{{ #{name}(d) }}",
          "{{ #{name}(d, d) }}"
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
      # Text around a blank is a label for a value that isn't there, so the
      # whole template is blank — but one present value keeps it.
      assert eval("before {{ nonsense }} after") == nil
      assert eval("{{ title }} {{ nonsense }} after") == "Hello World  after"
    end
  end

  describe "computed fields feeding each other" do
    defp computed(name, compute), do: %{name: name, compute: compute}

    test "references lists the custom fields a formula reads, not document scalars" do
      assert Computed.references("{{ concat(title, price, field.slug, price) }} {{ tax }}") ==
               ["price", "slug", "tax"]

      assert Computed.references("{{ reading_time(body) }}") == []
      assert Computed.references("{{ broken(") == []
    end

    test "order puts a field after the fields it reads, else keeps the given order" do
      defs = [
        computed("total", "{{ sum(subtotal, tax) }}"),
        computed("tax", "{{ product(subtotal, 0.2) }}"),
        computed("subtotal", "{{ price }}"),
        computed("words", "{{ word_count(body) }}")
      ]

      assert defs |> Computed.order() |> Enum.map(& &1.name) ==
               ["subtotal", "tax", "total", "words"]
    end

    test "fields on a cycle, and any reading one, go last in their given order" do
      defs = [
        computed("a", "{{ b }}"),
        computed("reads_a", "{{ a }}"),
        computed("b", "{{ a }}"),
        computed("free", "{{ title }}")
      ]

      assert defs |> Computed.order() |> Enum.map(& &1.name) == ["free", "a", "reads_a", "b"]
    end

    test "cycle names the loop, including a field that reads itself" do
      assert Computed.cycle([computed("a", "{{ b }}"), computed("b", "{{ a }}")]) == [
               "a",
               "b",
               "a"
             ]

      assert Computed.cycle([computed("a", "{{ upcase(a) }}")]) == ["a", "a"]
      assert Computed.cycle([computed("a", "{{ b }}"), computed("b", "{{ title }}")]) == nil

      # Only a loop through the named field counts.
      defs = [computed("x", "{{ y }}"), computed("y", "{{ x }}"), computed("z", "{{ x }}")]
      assert Computed.cycle(defs, "z") == nil
      assert Computed.cycle(defs, "y") == ["y", "x", "y"]
    end

    test "readers are the fields that read one, directly or through another" do
      defs = [computed("b", "{{ a }}"), computed("c", "{{ b }}"), computed("d", "{{ title }}")]

      assert Computed.readers(defs, "a") == MapSet.new(["b", "c"])
      assert Computed.readers(defs, "d") == MapSet.new()
    end

    test "derive evaluates in dependency order, three deep" do
      defs = [
        computed("shout", "{{ upcase(label) }}!"),
        computed("label", "{{ slug_part }} ({{ word_count(body) }})"),
        computed("slug_part", "{{ slugify(title) }}")
      ]

      assert Computed.derive(defs, context(), %{}) == %{
               "slug_part" => "hello-world",
               "label" => "hello-world (5)",
               "shout" => "HELLO-WORLD (5)!"
             }
    end

    test "derive leaves a blank result out, and a cycle derives without raising" do
      assert Computed.derive([computed("gone", "{{ nothing }}")], context(), %{}) == %{}

      assert Computed.derive(
               [computed("a", "{{ concat('x', b) }}"), computed("b", "{{ concat('y', a) }}")],
               context(),
               %{}
             ) ==
               %{"a" => "x", "b" => "yx"}
    end
  end

  describe "evaluation" do
    test "a lone expression keeps its native type; interpolation stringifies" do
      assert eval("{{ word_count(body) }}") == 5
      assert eval("{{ word_count(body) }} words") == "5 words"
    end

    test "reading time rounds up and respects a custom rate" do
      body = String.duplicate("word ", 450)

      # The default rate is `:reading_time_wpm` (230), shared with the
      # `reading_time_minutes` calculation since #492 — this used to be a local
      # 200 that ignored the config, so the same document got two answers
      # depending on which surface asked.
      assert eval("{{ reading_time(body) }}", %{document: %{"body" => body}}) == 2
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

  describe "conditions, comparisons and dates" do
    test "if picks a branch by truthiness, blank when there's no otherwise" do
      ctx = %{fields: %{"on" => true, "off" => false, "zero" => 0, "word" => "false", "n" => 5}}

      assert eval(~s|{{ if(on, "yes", "no") }}|, ctx) == "yes"
      assert eval(~s|{{ if(off, "yes", "no") }}|, ctx) == "no"
      assert eval(~s|{{ if(zero, "yes", "no") }}|, ctx) == "no"
      assert eval(~s|{{ if(word, "yes", "no") }}|, ctx) == "no"
      assert eval(~s|{{ if(missing, "yes", "no") }}|, ctx) == "no"
      assert eval(~s|{{ if(n, "yes") }}|, ctx) == "yes"
      assert eval(~s|{{ if(off, "yes") }}|, ctx) == nil
    end

    test "comparisons are numeric when both sides are numbers, else case-folded text" do
      ctx = %{fields: %{"price" => "10", "tier" => "Gold"}}

      assert eval("{{ greater_than(price, 9) }}", ctx) == true
      assert eval(~s|{{ less_than(price, "9") }}|, ctx) == false
      assert eval(~s|{{ equals(tier, "gold") }}|, ctx) == true
      assert eval(~s|{{ equals(missing, "gold") }}|, ctx) == false
      assert eval(~s|{{ contains(title, "WORLD") }}|) == true
      assert eval(~s|{{ contains(title, "") }}|) == false
    end

    test "a blank is neither more nor less than anything" do
      ctx = %{fields: %{"price" => "", "zero" => 0}}

      assert eval("{{ less_than(price, -5) }}", ctx) == false
      assert eval("{{ greater_than(price, -5) }}", ctx) == false
      assert eval("{{ less_than(missing, 100) }}", ctx) == false
      assert eval("{{ less_than(zero, 100) }}", ctx) == true
    end

    test "lists and maps are empty only when they hold nothing" do
      ctx = %{fields: %{"tags" => ["a"], "none" => [], "geo" => %{"lat" => 1}, "nomap" => %{}}}

      assert eval("{{ is_empty(tags) }}", ctx) == false
      assert eval("{{ is_empty(geo) }}", ctx) == false
      assert eval("{{ is_empty(none) }}", ctx) == true
      assert eval("{{ is_empty(nomap) }}", ctx) == true
      assert eval(~s|{{ if(none, "y", "n") }}|, ctx) == "n"
      assert eval(~s|{{ if(nomap, "y", "n") }}|, ctx) == "n"
      assert eval(~s|{{ if(tags, "y", "n") }}|, ctx) == "y"
      assert eval(~s|{{ default(tags, "x") }}|, ctx) == ["a"]
    end

    test "product has no answer without every factor" do
      ctx = %{fields: %{"price" => 20, "qty" => "3"}}

      assert eval("{{ product(price, qty) }}", ctx) == 60
      assert eval("{{ product(price, missing) }}", ctx) == nil
      assert eval("{{ round(product(divide(price, 0), 100)) }}%", ctx) == nil
    end

    test "replace refuses an output past the cap before building it" do
      body = String.duplicate("w ", 20_000)
      ctx = %{document: %{"body" => body}}

      assert eval(~s|{{ replace(body, " ", body) }}|, ctx) == nil

      assert eval(~s|{{ replace(body, "w", "x") }}|, ctx) == String.replace(body, "w", "x")
    end

    test "and, or, not and is_empty" do
      ctx = %{fields: %{"a" => "x", "b" => ""}}

      assert eval("{{ and(a, title) }}", ctx) == true
      assert eval("{{ and(a, b) }}", ctx) == false
      assert eval("{{ or(b, a) }}", ctx) == true
      assert eval("{{ not(b) }}", ctx) == true
      assert eval("{{ is_empty(b) }}", ctx) == true
      assert eval("{{ is_empty(a) }}", ctx) == false
    end

    test "replace" do
      assert eval(~s|{{ replace(title, "World", "Kiln") }}|) == "Hello Kiln"
      assert eval(~s|{{ replace(title, "", "x") }}|) == "Hello World"
    end

    test "dates read ISO dates and datetimes, and blank anything else" do
      ctx = %{fields: %{"from" => "2026-02-27", "to" => "2026-03-02T09:30:00", "junk" => "soon"}}

      assert eval("{{ days_between(from, to) }}", ctx) == 3
      assert eval("{{ days_between(to, from) }}", ctx) == -3
      assert eval("{{ days_between(from, junk) }}", ctx) == nil
      assert eval("{{ year(to) }}", ctx) == 2026
      assert eval(~s|{{ format_date(from, "%B %-d, %Y") }}|, ctx) == "February 27, 2026"
      assert eval(~s|{{ format_date(from, "") }}|, ctx) == "2026-02-27"
      assert eval(~s|{{ format_date(junk, "%Y") }}|, ctx) == nil
    end
  end

  describe "the catalog" do
    test "lists exactly the callable functions, with their real arities" do
      catalog = Computed.catalog()

      assert Enum.map(catalog, & &1.name) |> Enum.sort() == Computed.functions()

      for %{name: name, signature: signature, summary: summary, arities: arities} <- catalog do
        assert String.starts_with?(signature, name <> "("), "#{name}'s signature is #{signature}"
        assert summary != ""

        arity = if arities == :variadic, do: 2, else: Enum.max(arities)
        args = List.duplicate("title", arity) |> Enum.join(", ")
        assert {:ok, _} = Computed.parse("{{ #{name}(#{args}) }}")
      end
    end
  end
end
