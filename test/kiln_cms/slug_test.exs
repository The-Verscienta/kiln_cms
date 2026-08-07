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

  describe "random_suffix/0 (#834)" do
    test "is slug-safe — it gets concatenated straight into a slug" do
      # `[a-z2-7]` is base32's lower-cased alphabet. The point of choosing it
      # over base64 is that `+`, `/` and `=` are not slug characters, and a
      # suffix that has to be sanitized afterwards is a suffix that can collide
      # after sanitizing. The leading digit is what keeps an 8-letter word from
      # matching — see `random_suffix/0`.
      for _ <- 1..200 do
        assert Slug.random_suffix() =~ ~r/^[2-7][a-z2-7]{7}$/
      end
    end

    test "survives the round trip through slugify/1 unchanged" do
      # The property above, stated as the thing that actually matters.
      suffix = Slug.random_suffix()
      assert Slug.slugify("untitled-#{suffix}") == "untitled-#{suffix}"
    end

    test "the scaffold detector accepts what the generator actually produces" do
      # The anti-drift assertion, and the reason `random_suffix?/1` is public.
      # `KilnCMS.CMS.Slugs.underived?/2` decides whether a title edit may
      # replace a draft's slug, and it recognised the scaffold by
      # `untitled-<digits>` — which silently stops matching the moment the
      # suffix stops being a counter. The symptom is mild and baffling (typing
      # a title no longer updates a new draft's slug) and lives in a different
      # module from the change that causes it.
      for _ <- 1..100 do
        suffix = Slug.random_suffix()

        assert Slug.random_suffix?(suffix)
        assert KilnCMS.CMS.Slugs.underived?("untitled-#{suffix}", "guide-kiln")
      end
    end

    test "drafts created before the change are still recognised as scaffolds" do
      # `untitled-<digits>` rows do not migrate. Recognising only the new shape
      # would strand every existing draft with a slug a title edit can no longer
      # replace — the same bug, aimed backwards.
      assert KilnCMS.CMS.Slugs.underived?("untitled-1", "guide-kiln")
      assert KilnCMS.CMS.Slugs.underived?("untitled-40213", "guide-kiln")
    end

    test "an author's own slug is not mistaken for a scaffold" do
      refute Slug.random_suffix?("kiln")
      refute Slug.random_suffix?("abcdefgh1")
      # `1`, `0`, `8` and `9` are outside base32's alphabet.
      refute Slug.random_suffix?("2bcdefg1")
      # An 8-letter word: the false positive a plain base32 suffix allowed, and
      # the reason the generated shape leads with a digit.
      refute Slug.random_suffix?("thoughts")
      refute KilnCMS.CMS.Slugs.underived?("untitled-thoughts", "guide-kiln")
      refute KilnCMS.CMS.Slugs.underived?("my-real-slug", "guide-kiln")
    end

    test "does not repeat" do
      # Not a uniqueness proof — it cannot be — but it does catch the failure
      # this replaced: a source that hands back the same low values again.
      # `System.unique_integer/1` would pass this *within* one VM and fail the
      # moment the VM restarted, which is exactly why the regression needs the
      # comment in `random_suffix/0` more than it needs this assertion.
      suffixes = for _ <- 1..1_000, do: Slug.random_suffix()

      assert suffixes |> Enum.uniq() |> length() == 1_000
    end
  end
end
