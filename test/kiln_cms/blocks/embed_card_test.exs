defmodule KilnCMS.Blocks.EmbedCardTest do
  @moduledoc """
  What an embed block renders once oEmbed metadata is attached (#489), and — the
  part that matters — what it still refuses to render.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks
  alias KilnCMS.Blocks.Embed

  # A *resolved* block: `resolved_url` defaults to the block's own url, which is
  # what `fresh?/1` requires. Pass it explicitly to build a stale one.
  defp embed(attrs) do
    attrs = Map.put_new(attrs, :resolved_url, attrs[:url])
    struct(%Embed{_type: "embed"}, attrs)
  end

  defp web(block), do: block |> Blocks.render(:web) |> IO.iodata_to_binary()

  describe "the framed hosts are unchanged" do
    test "YouTube still renders an iframe, on the canonical player URL" do
      html = web(embed(%{url: "https://www.youtube.com/watch?v=abc123"}))

      assert html =~ ~s(<iframe src="https://www.youtube.com/embed/abc123")
      refute html =~ "kiln-embed-card"
    end

    test "a resolved title becomes the iframe's accessible name" do
      html = web(embed(%{url: "https://vimeo.com/123", title: "A talk"}))

      assert html =~ ~s(title="A talk")
    end

    test "an iframe is never built for a host outside the allowlist" do
      # The card path must not become a second, laxer route to an iframe.
      html = web(embed(%{url: "https://attacker.example/x", title: "T", provider_name: "P"}))

      refute html =~ "<iframe"
      assert html =~ "kiln-embed-card"
    end
  end

  describe "the card" do
    test "renders a link, thumbnail and byline from resolved metadata" do
      html =
        web(
          embed(%{
            url: "https://soundcloud.com/artist/track",
            title: "A track",
            author_name: "Artist",
            provider_name: "SoundCloud",
            thumbnail_url: "https://i1.sndcdn.com/x.jpg"
          })
        )

      assert html =~ ~s(href="https://soundcloud.com/artist/track")
      assert html =~ ~s(<img src="https://i1.sndcdn.com/x.jpg" alt="")
      assert html =~ "A track"
      assert html =~ "SoundCloud · Artist"
      assert html =~ ~s(rel="noopener")
    end

    test "escapes every metadata field" do
      html =
        web(
          embed(%{
            url: "https://soundcloud.com/a/b",
            title: "<script>alert(1)</script>",
            provider_name: "\" onload=\"x"
          })
        )

      refute html =~ "<script>"
      refute html =~ "onload=\"x"
      assert html =~ "&lt;script&gt;"
    end

    test "a javascript: url renders no card at all, and never the scheme" do
      html = web(embed(%{url: "javascript:alert(1)", title: "T"}))

      # `card?/1` requires a URL the link sanitizer vouches for, so this falls
      # through to the bare figure — whose `data-url` is filtered too, because a
      # headless consumer builds its own link from it.
      refute html =~ "javascript:"
      refute html =~ "kiln-embed-card"
      assert html =~ ~s(data-url="")
    end

    test "stale metadata renders no card — the URL changed under it" do
      block =
        embed(%{
          url: "https://soundcloud.com/artist/second",
          resolved_url: "https://soundcloud.com/artist/first",
          title: "FIRST TRACK",
          thumbnail_url: "https://i1.sndcdn.com/first.jpg"
        })

      html = web(block)

      # Ash merges an embedded block by id, so an editorial save that changes
      # only `url` keeps the old title and thumbnail. Without a freshness check
      # the first target's card renders over the second one's href — forever,
      # because a blank-title test would never re-enqueue a resolve either.
      refute html =~ "kiln-embed-card"
      refute html =~ "FIRST TRACK"
      refute html =~ "first.jpg"
      assert html =~ ~s(data-url="https://soundcloud.com/artist/second")

      # …and it does not pollute search or the LLM surface either.
      assert Blocks.search_text(block) == ""
      assert Embed.to_markdown(block) == "<https://soundcloud.com/artist/second>"
    end

    test "falls back to the bare figure when nothing resolved" do
      html = web(embed(%{url: "https://attacker.example/thing"}))

      # Exactly what an embed rendered before #489 — the feature degrades to the
      # old behaviour rather than to an error or an empty card.
      assert html =~ ~s(<figure class="kiln-embed" data-url="https://attacker.example/thing">)
      refute html =~ "kiln-embed-card"
    end
  end

  describe "other surfaces" do
    test ":json carries the metadata and omits what is absent" do
      json = Blocks.render(embed(%{url: "https://x.example/a", title: "T"}), :json)

      assert json["title"] == "T"
      refute Map.has_key?(json, "thumbnail_url")
      refute Map.has_key?(json, "author_name")
    end

    test ":json_ld stays nil — an embed makes no claim about the page" do
      assert Blocks.render(embed(%{url: "https://x.example/a", title: "T"}), :json_ld) == nil
    end

    test "search_text and markdown use the resolved title" do
      block = embed(%{url: "https://x.example/a", title: "A track", author_name: "Artist"})

      assert Blocks.search_text(block) == "A track Artist"
      assert Embed.to_markdown(block) == "[A track](https://x.example/a)"

      # Unresolved: a bare link rather than a link with no text.
      assert Embed.to_markdown(embed(%{url: "https://x.example/a"})) == "<https://x.example/a>"
      assert Embed.to_markdown(embed(%{})) == ""
    end

    test "an unresolved embed contributes nothing to search" do
      assert Blocks.search_text(embed(%{url: "https://x.example/a"})) == ""
    end
  end
end
