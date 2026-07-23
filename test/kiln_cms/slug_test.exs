defmodule KilnCMS.SlugTest do
  use ExUnit.Case, async: true

  alias KilnCMS.Slug

  describe "slugify/1" do
    test "downcases, drops punctuation, hyphenates whitespace" do
      assert Slug.slugify("Hello,  World!") == "hello-world"
    end

    test "transliterates diacritics instead of dropping the letters" do
      assert Slug.slugify("Café Décor") == "cafe-decor"
    end

    test "collapses runs of separators and trims edge hyphens" do
      assert Slug.slugify(" --Already - Slug-like-- ") == "already-slug-like"
    end

    test "non-binary input yields the empty string" do
      assert Slug.slugify(nil) == ""
    end
  end

  describe "derive/1" do
    test "strips stop words from the title" do
      assert Slug.derive("A Guide to the Kiln") == "guide-kiln"
      assert Slug.derive("The Quick Brown Fox and the Lazy Dog") == "quick-brown-fox-lazy-dog"
    end

    test "keeps stop words when stripping would leave nothing" do
      assert Slug.derive("The And") == "the-and"
    end

    test "unsluggable titles yield the empty string" do
      assert Slug.derive("!!!") == ""
      assert Slug.derive(nil) == ""
    end
  end

  describe "focus_keyphrase/1" do
    test "returns the first comma-separated keyphrase, trimmed" do
      assert Slug.focus_keyphrase("ceramic kiln , pottery, firing") == "ceramic kiln"
      assert Slug.focus_keyphrase("solo phrase") == "solo phrase"
    end

    test "blank or nil keywords yield the empty string" do
      assert Slug.focus_keyphrase("   ") == ""
      assert Slug.focus_keyphrase(nil) == ""
    end
  end
end
