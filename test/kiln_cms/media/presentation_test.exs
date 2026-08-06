defmodule KilnCMS.Media.PresentationTest do
  @moduledoc """
  `KilnCMS.Media.Presentation` — the two rules delivery depends on: a `srcset`
  carries one encoding and never a crop, and `<picture>` sources carry the
  alternates in most-efficient-first order (#473).
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Media.Presentation

  defp item(variants, extra \\ %{}) do
    Map.merge(
      %{url: "/uploads/orig.jpg", width: 1600, variants: variants, focal_x: 0.5, focal_y: 0.5},
      extra
    )
  end

  defp variant(url, width, content_type \\ nil) do
    base = %{"url" => url, "width" => width, "height" => div(width, 2)}
    if content_type, do: Map.put(base, "content_type", content_type), else: base
  end

  describe "srcset/1" do
    test "carries the source-format variants and the original, widest last" do
      srcset =
        item(%{
          "thumb" => variant("/uploads/t.jpg", 400, "image/jpeg"),
          "medium" => variant("/uploads/m.jpg", 1024, "image/jpeg")
        })
        |> Presentation.srcset()

      assert srcset =~ "/uploads/t.jpg 400w"
      assert srcset =~ "/uploads/m.jpg 1024w"
      assert srcset =~ "/uploads/orig.jpg 1600w"
    end

    # A browser picks from a `srcset` on width alone. Mixing encodings there
    # would hand a WebP-less client a WebP, and offer two entries at the same
    # width for it to choose between arbitrarily.
    test "never mixes encodings — alternates stay out" do
      srcset =
        item(%{
          "thumb" => variant("/uploads/t.jpg", 400, "image/jpeg"),
          "thumb.webp" => variant("/uploads/t.webp", 400, "image/webp")
        })
        |> Presentation.srcset()

      assert srcset =~ "/uploads/t.jpg 400w"
      refute srcset =~ "t.webp"
    end

    # `card` is a different picture, not a smaller one.
    test "excludes crops — including their alternate encodings" do
      srcset =
        item(%{
          "thumb" => variant("/uploads/t.jpg", 400, "image/jpeg"),
          "card" => variant("/uploads/c.jpg", 800, "image/jpeg"),
          "card.webp" => variant("/uploads/c.webp", 800, "image/webp")
        })
        |> Presentation.srcset()

      assert srcset =~ "/uploads/t.jpg 400w"
      refute srcset =~ "/uploads/c.jpg"
      refute srcset =~ "/uploads/c.webp"
    end

    test "a video poster frame is excluded too" do
      srcset =
        item(%{"poster" => variant("/uploads/p.jpg", 1280, "image/jpeg")}, %{width: nil})
        |> Presentation.srcset()

      assert srcset == nil
    end

    test "an unsafe url poisons nothing" do
      srcset =
        item(%{"thumb" => variant("javascript:alert(1)", 400, "image/jpeg")}, %{width: nil})
        |> Presentation.srcset()

      assert srcset == nil
    end
  end

  describe "sources/1" do
    test "one entry per alternate encoding, most efficient first" do
      sources =
        item(%{
          "thumb" => variant("/uploads/t.jpg", 400, "image/jpeg"),
          "thumb.webp" => variant("/uploads/t.webp", 400, "image/webp"),
          "medium.webp" => variant("/uploads/m.webp", 1024, "image/webp"),
          "thumb.avif" => variant("/uploads/t.avif", 400, "image/avif")
        })
        |> Presentation.sources()

      # A browser takes the FIRST type it supports and stops looking, so AVIF
      # has to precede WebP or it is never chosen.
      assert [%{type: "image/avif"}, %{type: "image/webp"} = webp] = sources
      assert webp.srcset =~ "/uploads/t.webp 400w"
      assert webp.srcset =~ "/uploads/m.webp 1024w"
    end

    test "excludes crops, like srcset does" do
      [%{srcset: srcset}] =
        item(%{
          "thumb.webp" => variant("/uploads/t.webp", 400, "image/webp"),
          "card.webp" => variant("/uploads/c.webp", 800, "image/webp")
        })
        |> Presentation.sources()

      assert srcset =~ "/uploads/t.webp"
      refute srcset =~ "/uploads/c.webp"
    end

    # An upload processed before #473 has no `content_type` on its variants;
    # the caller then renders a plain `<img>` and nothing is lost.
    test "empty for an item with no alternates" do
      assert Presentation.sources(item(%{"thumb" => variant("/uploads/t.jpg", 400)})) == []
      assert Presentation.sources(item(nil)) == []
    end

    # A WebP *upload*'s variants are written once under the bare label and carry
    # `image/webp`. Matching on content type alone would emit a `<source>`
    # listing the very files the `<img>` fallback already has, minus the
    # original — strictly worse than no `<picture>` at all.
    test "a WebP source item gets no <source> — its variants are the fallback" do
      sources =
        item(%{
          "thumb" => variant("/uploads/t.webp", 400, "image/webp"),
          "medium" => variant("/uploads/m.webp", 1024, "image/webp")
        })
        |> Presentation.sources()

      assert sources == []
    end

    # Without a full-size entry the `<source>` tops out at the largest
    # downscale, and a matching `<source>` replaces the `<img>`'s srcset
    # outright — so the original becomes unreachable.
    test "the full-size alternate carries the original's width" do
      [%{srcset: srcset}] =
        item(%{
          "thumb.webp" => variant("/uploads/t.webp", 400, "image/webp"),
          "full.webp" => variant("/uploads/f.webp", 1600, "image/webp")
        })
        |> Presentation.sources()

      assert srcset =~ "/uploads/f.webp 1600w"
    end
  end
end
