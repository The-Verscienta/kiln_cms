defmodule Kiln.Advisory.Checks.LinkTextTest do
  @moduledoc """
  Link text that doesn't say where it goes (#495).

  The interesting half of this check is what it stays QUIET about: an advisory
  that flags a perfectly good link is one authors learn to dismiss, and then it
  isn't flagging the bad ones either.
  """
  use ExUnit.Case, async: true

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Checks.LinkText
  alias Kiln.Advisory.Context

  defp check(links) do
    body = %Body{links: links}
    LinkText.check(%Context{body: body})
  end

  defp link(text, href \\ "/somewhere", index \\ 0),
    do: %{text: text, href: href, index: index}

  defp codes(outcomes) do
    outcomes |> List.wrap() |> Enum.filter(&is_struct/1) |> Enum.map(& &1.code)
  end

  test "a document with no links has nothing to judge" do
    assert LinkText.check(%Context{body: %Body{}}) == :n_a
  end

  describe "descriptive link text passes" do
    test "ordinary informative labels" do
      outcomes =
        check([
          link("our refund policy"),
          link("the 2024 annual report"),
          link("Contact the support team")
        ])

      assert codes(outcomes) == []
    end

    test "a phrase that CONTAINS an uninformative one is fine" do
      # The match is on the whole text, never a substring — otherwise every one
      # of these, which are good links, would be flagged.
      outcomes =
        check([
          link("learn more about invoicing"),
          link("read more of Ada's essays"),
          link("click here to see why we don't say click here")
        ])

      assert codes(outcomes) == []
    end

    test "a single word that happens to be a domain-like product name" do
      assert codes(check([link("Elixir")])) == []
    end
  end

  describe "uninformative text" do
    test "the classic offenders" do
      for text <- ["click here", "Click here", "read more", "here", "Learn more", "this link"] do
        assert :link_text_uninformative in codes(check([link(text)])),
               "expected #{inspect(text)} to be flagged"
      end
    end

    test "trailing punctuation doesn't hide it" do
      assert :link_text_uninformative in codes(check([link("Click here!")]))
      assert :link_text_uninformative in codes(check([link("read more…")]))
    end

    test "it is a warning, not an error — context can make it defensible" do
      [finding] = check([link("read more")]) |> List.wrap() |> Enum.filter(&is_struct/1)
      assert finding.severity == :warning
    end

    test "the finding names one example and counts the rest" do
      [finding] =
        [link("click here", "/a", 1), link("read more", "/b", 4), link("here", "/c", 4)]
        |> check()
        |> List.wrap()
        |> Enum.filter(&is_struct/1)

      assert finding.args.count == 3
      assert finding.args.example == "click here"
      # De-duplicated: two findings in one block is one jump target.
      assert finding.args.indexes == [1, 4]
    end
  end

  describe "empty link text" do
    test "is an error — there is nothing to click and nothing to announce" do
      [finding] = check([link("")]) |> List.wrap() |> Enum.filter(&is_struct/1)

      assert finding.code == :link_text_empty
      assert finding.severity == :error
    end

    test "whitespace-only counts as empty" do
      assert :link_text_empty in codes(check([link("   ")]))
    end
  end

  describe "a bare URL as the label" do
    test "schemes, www hosts, same-origin paths, and dotted hosts WITH a path" do
      for text <- [
            "https://example.com/a/long/path",
            "http://example.com",
            "www.example.com",
            "example.com/blog",
            "/blog/a-post"
          ] do
        assert :link_text_bare_url in codes(check([link(text)])),
               "expected #{inspect(text)} to be flagged"
      end
    end

    test "a sentence containing a URL is not a bare URL" do
      assert codes(check([link("read it at example.com")])) == []
    end

    test "a dotted token with no path is NOT treated as a URL" do
      # These were all false positives while a bare dotted token counted, and
      # they are exactly the words technical writing links on.
      for text <- ["Node.js", "asp.net", "annual-report.pdf", "Ph.D", "v2.11.5"] do
        refute :link_text_bare_url in codes(check([link(text)])),
               "expected #{inspect(text)} NOT to be flagged"
      end
    end

    test "ordinary phrases are not URLs" do
      assert :link_text_bare_url not in codes(check([link("the report")]))
      assert :link_text_bare_url not in codes(check([link("Read the docs")]))
      assert :link_text_bare_url not in codes(check([link("Yes. No")]))
    end
  end

  test "a pathological label can't be used to wedge the editor" do
    # `fold/1`'s trailing-punctuation strip is quadratic, and this check runs
    # on every keystroke AND on opening a document. Without the length guard a
    # 32 KB punctuation label took seconds; the bound must hold regardless of
    # what an author (or an API client) puts in a link.
    payload = String.duplicate("!", 40_000) <> "a"

    {microseconds, _outcomes} = :timer.tc(fn -> check([link(payload)]) end)

    assert microseconds < 100_000,
           "checking a #{byte_size(payload)}-byte label took #{microseconds}us"
  end

  test "all three findings can fire at once, one per kind" do
    outcomes =
      check([
        link(""),
        link("click here"),
        link("https://example.com/x")
      ])

    assert Enum.sort(codes(outcomes)) == [
             :link_text_bare_url,
             :link_text_empty,
             :link_text_uninformative
           ]
  end

  test "it reports into both panels — descriptive links are an SEO signal too" do
    assert :accessibility in LinkText.lenses()
    assert :seo in LinkText.lenses()
  end
end
