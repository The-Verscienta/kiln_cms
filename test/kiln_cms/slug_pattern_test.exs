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
