defmodule KilnCMS.Seo.PatternTest do
  @moduledoc """
  The SEO pattern vocabulary (#805). Pure — the record/branding side lives in
  `KilnCMS.Seo.PatternsTest`.

  The property most of these are aimed at: this is **prose**, so unlike
  `KilnCMS.Slug.Pattern` nothing is lowercased, stripped of stop words or
  hyphenated, and an empty token must not leave punctuation behind.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Seo.Pattern

  defp prose_context, do: %{title: "Kiln guide", site_name: "Acme"}

  describe "expand/2" do
    test "keeps the title as written, unlike a slug pattern" do
      context = %{title: "A Guide to the Kiln", site_name: "Acme"}

      assert Pattern.expand("[title] | [site-name]", context) == "A Guide to the Kiln | Acme"
      # The same tokens through the slug engine, for contrast.
      assert KilnCMS.Slug.Pattern.expand("[title]", context) == "guide-kiln"
    end

    test "an empty token takes its separator with it" do
      context = %{title: "Kiln guide"}

      assert Pattern.expand("[title] | [category]", context) == "Kiln guide"
      assert Pattern.expand("[category] | [title]", context) == "Kiln guide"
      assert Pattern.expand("[category] — [title] — [site-name]", context) == "Kiln guide"
    end

    test "an interior gap collapses to a single separator, not two" do
      context = %{title: "Kiln guide", site_name: "Acme"}

      assert Pattern.expand("[site-name] | [category] | [title]", context) ==
               "Acme | Kiln guide"
    end

    # The first implementation repaired the expanded STRING, which only worked
    # when every separator was its own split part. Each of the cases below
    # shipped malformed output; they are the review's own reproductions.

    test "a preposition between tokens goes with the empty one" do
      assert Pattern.expand("[title] in [category]", prose_context()) == "Kiln guide"
      assert Pattern.expand("[title] - a [category] post", prose_context()) == "Kiln guide"
    end

    test "a parenthetical around an empty token does not survive" do
      assert Pattern.expand("[title] (in [category]) | [site-name]", prose_context()) ==
               "Kiln guide | Acme"
    end

    test "leading prose attached to an empty token drops with it" do
      assert Pattern.expand("Guides: [category] | [title]", prose_context()) == "Kiln guide"
      assert Pattern.expand("[excerpt] — Acme Pottery", prose_context()) == nil
    end

    test "an unusual separator is still elided" do
      assert Pattern.expand("[category] » [title]", prose_context()) == "Kiln guide"
      assert Pattern.expand("[title] • [site-name]", prose_context()) == "Kiln guide • Acme"
    end

    # Adjacent tokens produce a ZERO-WIDTH gap. The run-collapse used to pick
    # it over the real separator beside it and fuse two values into one word.
    test "an empty token between two adjacent tokens still separates them" do
      assert Pattern.expand("[title][category] | [site-name]", prose_context()) ==
               "Kiln guide | Acme"
    end

    # ...but genuinely adjacent tokens must stay adjacent.
    test "two present adjacent tokens are not pushed apart" do
      assert Pattern.expand("[title][site-name]", prose_context()) == "Kiln guideAcme"
    end

    # The regression that motivated the rewrite: a separator between two
    # PRESENT tokens is the operator's, and load-bearing.
    test "a date pattern keeps its own hyphens" do
      assert Pattern.expand("[yyyy]-[mm]-[dd]", %{date: ~D[2026-01-05]}) == "2026-01-05"
    end

    test "literal prose between tokens survives" do
      context = %{title: "Kiln guide", site_name: "Acme"}

      assert Pattern.expand("[title] on [site-name]", context) == "Kiln guide on Acme"
    end

    test "a pattern with nothing usable is nil, not a bare separator" do
      assert Pattern.expand("[title] | [site-name]", %{}) == nil
      assert Pattern.expand("[category]", %{title: "x"}) == nil
    end

    test "a pattern of pure literal text still expands" do
      assert Pattern.expand("Acme Docs", %{}) == "Acme Docs"
    end

    test "the category token uses the name, not a slug" do
      context = %{title: "Post", category_name: "Kiln Care"}

      assert Pattern.expand("[category]: [title]", context) == "Kiln Care: Post"
    end

    test "date tokens accept a Date or a DateTime and default to today" do
      assert Pattern.expand("[yyyy]-[mm]-[dd]", %{date: ~D[2026-01-05]}) == "2026-01-05"
      assert Pattern.expand("[yyyy]", %{date: ~U[2026-12-31 23:00:00Z]}) == "2026"

      today = Date.utc_today()
      assert Pattern.expand("[yyyy]", %{}) == Integer.to_string(today.year)
    end

    test "a custom field expands as written, and a non-scalar expands empty" do
      fields = %{"author_note" => "  Second Edition  ", "sizes" => ["s", "m"]}
      context = %{title: "Guide", custom_fields: fields}

      assert Pattern.expand("[title] — [field:author_note]", context) ==
               "Guide — Second Edition"

      assert Pattern.expand("[title] — [field:sizes]", context) == "Guide"
      assert Pattern.expand("[title] — [field:missing]", context) == "Guide"
    end

    test "a numeric field renders as its number" do
      context = %{title: "Guide", custom_fields: %{"edition" => 2}}

      assert Pattern.expand("[title] (ed. [field:edition])", context) == "Guide (ed. 2)"
    end

    test "nil pattern is nil" do
      assert Pattern.expand(nil, %{title: "x"}) == nil
    end

    # A blank excerpt is the common case for a description pattern, and it must
    # not publish whitespace.
    test "a whitespace-only value counts as empty" do
      assert Pattern.expand("[excerpt]", %{excerpt: "   "}) == nil
      assert Pattern.expand("[title] | [excerpt]", %{title: "T", excerpt: "\n"}) == "T"
    end
  end

  describe "validate/1" do
    test "accepts the vocabulary" do
      for token <- Pattern.tokens() do
        assert Pattern.validate("x [#{token}] y") == :ok
      end

      assert Pattern.validate("[field:anything_here]") == :ok
      assert Pattern.validate(nil) == :ok
      assert Pattern.validate("no tokens at all") == :ok
    end

    test "rejects a typo and names it" do
      assert {:error, message} = Pattern.validate("[titel] | [site-name]")
      assert message =~ "[titel]"
      assert message =~ "[title]"
    end

    # #804's field-type tokens are legitimate in a slug pattern and deliberately
    # not here — see the moduledoc: resolving them costs a database read, and
    # this runs on every delivery render rather than once per write.
    test "rejects a field-type-declared token" do
      assert {:error, _message} = Pattern.validate("[field:location.lat]")
    end

    test "rejects a blank-but-present pattern" do
      assert {:error, message} = Pattern.validate("   ")
      assert message =~ "leave it unset"
    end
  end

  describe "validate!/1" do
    test "returns the pattern or raises" do
      assert Pattern.validate!("[title]") == "[title]"
      assert Pattern.validate!(nil) == nil

      assert_raise ArgumentError, ~r/\[titel\]/, fn -> Pattern.validate!("[titel]") end
    end
  end
end
