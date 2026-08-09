defmodule KilnCMS.Slug.PatternTest do
  use ExUnit.Case, async: true

  alias KilnCMS.Slug.Pattern

  describe "expand/2" do
    test "date + title tokens" do
      context = %{title: "A Guide to the Kiln", date: ~D[2026-07-23]}
      assert Pattern.expand("[yyyy]-[mm]-[title]", context) == "2026-07-guide-kiln"
    end

    test "slash and dot separators normalize to hyphens" do
      context = %{title: "Post", date: ~D[2026-01-05]}
      assert Pattern.expand("[yyyy]/[mm]/[dd].[title]", context) == "2026-01-05-post"
    end

    test "the keyphrase token prefers seo_keywords and falls back to the title" do
      assert Pattern.expand("[focus-keyphrase]", %{title: "Fallback Title"}) == "fallback-title"

      assert Pattern.expand("[focus-keyphrase]", %{
               title: "T",
               seo_keywords: "Ceramic Kilns, other"
             }) == "ceramic-kilns"
    end

    test "the category token uses the category slug and drops out cleanly when absent" do
      assert Pattern.expand("[category]-[title]", %{title: "Post", category_slug: "news"}) ==
               "news-post"

      assert Pattern.expand("[category]-[title]", %{title: "Post"}) == "post"
    end

    test "DateTime dates and literal text work" do
      context = %{title: "X", date: ~U[2026-12-31 23:00:00Z]}
      assert Pattern.expand("archive-[yyyy]-[title]", context) == "archive-2026-x"
    end
  end

  # #804. `[field:<name>]` gives every custom field a slugified scalar for free
  # and expands a map or list to "". A type that wants more — a composite's named
  # parts, or a derived form like the word below — says so through
  # `c:Kiln.FieldType.tokens/1`, and these are the definitions that reach the
  # engine.
  describe "extra definitions from a field type" do
    defp word_token do
      [
        %{
          match: ~r/\Afield:rating\.word\z/,
          resolve: fn _token, ctx -> Map.get(ctx[:custom_fields] || %{}, "rating_word", "") end
        }
      ]
    end

    test "a type-declared token expands" do
      context = %{title: "Kiln", custom_fields: %{"rating_word" => "three"}}

      assert Pattern.expand("[title]-[field:rating.word]", context, word_token()) ==
               "kiln-three"
    end

    test "without them the same token expands empty, and the pattern is invalid" do
      context = %{title: "Kiln", custom_fields: %{"rating_word" => "three"}}

      assert Pattern.expand("[title]-[field:rating.word]", context) == "kiln"
      assert {:error, message} = Pattern.validate("[field:rating.word]")
      assert message =~ "unknown token"
    end

    test "validate accepts them when they are supplied" do
      assert Pattern.validate("[field:rating.word]", extra_definitions: word_token()) == :ok
    end

    # `Kiln.Tokens.expand/3` takes the FIRST matching definition, so a plugin
    # cannot redefine `[title]` out from under a pattern that already relies on
    # it — for every content type that happens to use that field type.
    test "a built-in name cannot be shadowed" do
      shadow = [%{match: "title", resolve: fn _token, _ctx -> "hijacked" end}]

      assert Pattern.expand("[title]", %{title: "Real Title"}, shadow) == "real-title"
    end

    test "they reach alias expansion too" do
      context = %{title: "Kiln", custom_fields: %{"rating_word" => "three"}}

      assert Pattern.expand_path("/rated/[field:rating.word]", context, word_token()) ==
               "/rated/three"
    end
  end

  # The cheap pre-check that keeps a field-definition lookup off the write path
  # for the overwhelming majority of patterns, which use built-ins only.
  describe "unknown_tokens/2" do
    test "is empty for a built-in-only pattern, and for nil" do
      assert Pattern.unknown_tokens(nil, :slug) == []
      assert Pattern.unknown_tokens("[yyyy]-[title]-[field:size]", :slug) == []
    end

    test "names what the built-ins do not cover" do
      assert Pattern.unknown_tokens("[title]-[field:rating.word]", :slug) == ["field:rating.word"]
    end

    # `[slug]` is circular in a slug pattern and legal in an alias — so "unknown"
    # is relative to the usage, and asking with the wrong one would send the
    # write path looking for a field type that owns `[slug]`.
    test "is usage-aware" do
      assert Pattern.unknown_tokens("[slug]", :slug) == ["slug"]
      assert Pattern.unknown_tokens("[slug]", :alias) == []
    end
  end

  describe "validate/1" do
    test "accepts known tokens and nil" do
      assert Pattern.validate(nil) == :ok
      assert Pattern.validate("[yyyy]-[title]") == :ok
      assert Pattern.validate("[category]/[focus-keyphrase]") == :ok
    end

    test "rejects unknown tokens and blank patterns" do
      assert {:error, message} = Pattern.validate("[titel]-[mm]")
      assert message =~ "[titel]"
      assert {:error, _} = Pattern.validate("   ")
    end

    test "rejects the empty-bracket pattern" do
      assert {:error, _} = Pattern.validate("[]")
    end

    test "field tokens are allowed; malformed ones are not" do
      assert Pattern.validate("[field:size]-[title]") == :ok
      assert {:error, _} = Pattern.validate("[field:Bad Name]")
    end

    test "the slug token is alias-only (circular in a slug pattern)" do
      assert {:error, _} = Pattern.validate("[slug]")
      assert Pattern.validate("/kiln/care/[slug]", usage: :alias) == :ok
    end
  end

  describe "field_names/1 (#616)" do
    test "extracts the field names a pattern references, de-duplicated" do
      assert Pattern.field_names("/library/[field:url_key]/[title]") == ["url_key"]
      assert Pattern.field_names("[field:a]-[field:b]-[field:a]") == ["a", "b"]
    end

    test "is empty for a nil or token-free pattern" do
      assert Pattern.field_names(nil) == []
      assert Pattern.field_names("[yyyy]-[title]") == []
    end
  end

  describe "expand_path/2 (alias patterns, #485 follow-up)" do
    test "literal segments plus field tokens" do
      assert Pattern.expand_path("/acupuncture/needle/size/[field:size]", %{
               custom_fields: %{"size" => "14mm"}
             }) == "/acupuncture/needle/size/14mm"
    end

    test "empty segments drop out; an all-empty expansion is nil" do
      assert Pattern.expand_path("/[category]/[title]", %{title: "Post"}) == "/post"
      assert Pattern.expand_path("/[category]", %{}) == nil
    end

    test "the slug token embeds the derived slug" do
      assert Pattern.expand_path("/kiln/care/[slug]", %{slug: "guide-2"}) == "/kiln/care/guide-2"
    end

    test "non-scalar field values expand empty" do
      assert Pattern.expand_path("/x/[field:tags]", %{custom_fields: %{"tags" => ["a", "b"]}}) ==
               "/x"
    end
  end

  describe "Slugs.derive_base/2 (shared entry point)" do
    alias KilnCMS.CMS.Slugs

    test "nil pattern uses the default chain" do
      assert Slugs.derive_base(nil, %{title: "A Guide to the Kiln"}) == "guide-kiln"
      assert Slugs.derive_base(nil, %{title: "T", seo_keywords: "ceramic kiln"}) == "ceramic-kiln"
    end

    test "an empty expansion falls back to the default chain" do
      # [category] with no category would expand to "" — the title still wins.
      assert Slugs.derive_base("[category]", %{title: "Big Story"}) == "big-story"
    end

    test "no usable author text yields no slug, even with date tokens" do
      assert Slugs.derive_base("[yyyy]-[mm]-[title]", %{title: "!!!", date: ~D[2026-07-23]}) ==
               ""
    end

    test "a working pattern expands normally" do
      context = %{title: "Big Story", category_slug: "news", date: ~D[2026-07-23]}
      assert Slugs.derive_base("[category]-[title]", context) == "news-big-story"
    end
  end

  test "validate!/1 raises for the compile-time macro option" do
    assert_raise ArgumentError, ~r/titel/, fn -> Pattern.validate!("[titel]") end
    assert Pattern.validate!("[yyyy]-[title]") == "[yyyy]-[title]"
    assert Pattern.validate!(nil) == nil
  end
end
