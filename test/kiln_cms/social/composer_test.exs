defmodule KilnCMS.Social.ComposerTest do
  @moduledoc """
  Composing an announcement (#497): what survives the character limit, and what
  a document is allowed to put on the operator's timeline.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Social.Composer

  @url "https://example.test/blog/a-post"

  defp post(attrs \\ %{}) do
    struct!(KilnCMS.CMS.Post, Map.merge(%{title: "A title", excerpt: nil, slug: "a-post"}, attrs))
  end

  describe "the default shape" do
    test "is title, blank line, URL" do
      assert Composer.compose(post(), @url, 300) == "A title\n\n#{@url}"
    end

    test "includes the excerpt when it fits" do
      text = Composer.compose(post(%{excerpt: "A short summary."}), @url, 300)

      assert text == "A title\n\nA short summary.\n\n#{@url}"
    end

    test "falls back to the SEO description when there is no excerpt" do
      record = post(%{excerpt: nil, seo_description: "From the SEO field."})

      assert Composer.compose(record, @url, 300) =~ "From the SEO field."
    end

    test "drops the excerpt whole rather than shaving it to a few words" do
      # 250-character title + a 32-character URL leaves 14 characters for an
      # excerpt — below the floor, so it goes entirely rather than as a fragment.
      record = post(%{title: String.duplicate("x", 250), excerpt: "A summary worth reading."})

      text = Composer.compose(record, @url, 300)

      # Three words of trailing context reads as a truncation bug, not a summary.
      refute text =~ "A summary"
      assert text =~ @url
    end
  end

  describe "the limit" do
    test "the URL always survives, whatever the title does" do
      record = post(%{title: String.duplicate("word ", 200)})

      text = Composer.compose(record, @url, 300)

      # An announcement truncated into a link-less sentence is worse than none:
      # it reads as a post someone meant to finish.
      assert String.ends_with?(text, @url)
      assert String.length(text) <= 300
    end

    test "cuts on a grapheme boundary, never mid-character" do
      record = post(%{title: String.duplicate("é😀", 200)})

      text = Composer.compose(record, @url, 300)
      assert String.valid?(text)
    end

    test "the composed text never exceeds the limit" do
      for limit <- [50, 120, 300, 500] do
        record = post(%{title: String.duplicate("long title ", 60), excerpt: "and a summary"})

        assert String.length(Composer.compose(record, @url, limit)) <= limit
      end
    end
  end

  describe "templates" do
    test "interpolate the same tokens the email reaction uses" do
      record = post(%{title: "Ship it", excerpt: "Now."})

      text = Composer.compose(record, @url, 300, "New {{type}}: {{title}} — {{excerpt}} {{url}}")

      assert text == "New post: Ship it — Now. #{@url}"
    end

    test "an absent excerpt renders as nothing, not as the literal token" do
      text = Composer.compose(post(), @url, 300, "{{title}}{{excerpt}} {{url}}")

      refute text =~ "{{excerpt}}"
      assert text == "A title #{@url}"
    end
  end

  describe "what a document cannot do to the timeline" do
    test "control characters are stripped" do
      record = post(%{title: "Title" <> <<0, 7>> <> "control"})

      # Written as bytes rather than as literals in the source: a raw NUL in a
      # test file is the kind of thing an editor silently eats.
      composed = Composer.compose(record, @url, 300)
      refute composed =~ <<0>>
      refute composed =~ <<7>>
      assert composed =~ "Titlecontrol"
    end

    test "runs of blank lines are collapsed" do
      record = post(%{title: "One\n\n\n\n\nTwo"})

      assert Composer.compose(record, @url, 300) =~ "One\n\nTwo"
    end

    test "carriage returns are normalized" do
      record = post(%{title: "One\r\nTwo"})

      refute Composer.compose(record, @url, 300) =~ "\r"
    end
  end
end
