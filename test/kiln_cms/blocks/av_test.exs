defmodule KilnCMS.Blocks.AVTest do
  @moduledoc """
  The video and audio blocks (#494): the `src` is always built from `media_id`
  alone (never a stored URL — a gated item has none, and a public one can
  become gated later), a pasted `url` is only a fallback and is scheme-
  filtered, and every rendered value is escaped.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks
  alias KilnCMS.Blocks.{Audio, Video}

  defp video(attrs), do: struct(%Video{_type: "video"}, attrs)
  defp audio(attrs), do: struct(%Audio{_type: "audio"}, attrs)
  defp web(block), do: block |> Blocks.render(:web) |> IO.iodata_to_binary()

  describe "an empty (just-inserted) block" do
    test "renders a placeholder rather than a player with no source" do
      assert web(video(%{})) == "<div class=\"kiln-video\"></div>"
      assert web(audio(%{})) == "<div class=\"kiln-audio\"></div>"
    end

    test "the :json surface carries no src either" do
      assert Blocks.render(video(%{}), :json) == %{"_type" => "video"}
      assert Blocks.render(audio(%{}), :json) == %{"_type" => "audio"}
    end

    test "the :json_ld surface is nil, not a nameless VideoObject" do
      assert Blocks.render(video(%{}), :json_ld) == nil
      assert Blocks.render(audio(%{}), :json_ld) == nil
    end
  end

  describe "src resolution" do
    test "a library item always streams through the app route" do
      assert web(video(%{media_id: "abc-123"})) =~ ~s(src="/media/abc-123/stream")
      assert web(audio(%{media_id: "abc-123"})) =~ ~s(src="/media/abc-123/stream")
    end

    test "the stream route wins over a stale pasted url" do
      html = web(video(%{media_id: "abc-123", url: "https://cdn.example.com/old.mp4"}))
      assert html =~ ~s(src="/media/abc-123/stream")
      refute html =~ "cdn.example.com"
    end

    test "a pasted url is used only when there is no library item" do
      assert web(video(%{url: "https://cdn.example.com/clip.mp4"})) =~
               ~s(src="https://cdn.example.com/clip.mp4")
    end

    test "a blank media_id does not count as a library item" do
      assert web(video(%{media_id: "  ", url: "https://cdn.example.com/clip.mp4"})) =~
               "cdn.example.com"
    end

    test "a javascript: url is rejected outright, not rendered" do
      assert web(video(%{url: "javascript:alert(1)"})) == "<div class=\"kiln-video\"></div>"
      assert web(audio(%{url: "javascript:alert(1)"})) == "<div class=\"kiln-audio\"></div>"
    end
  end

  describe "video player attributes" do
    test "always controllable and preloading metadata only" do
      html = web(video(%{media_id: "id"}))
      assert html =~ "controls"
      assert html =~ ~s(preload="metadata")
      assert html =~ "playsinline"
    end

    test "autoplay always implies muted" do
      html = web(video(%{media_id: "id", autoplay: true}))
      assert html =~ "autoplay muted"
    end

    test "no autoplay attribute when the flag is off" do
      refute web(video(%{media_id: "id", autoplay: false})) =~ "autoplay"
    end

    test "loop is emitted only when set" do
      assert web(video(%{media_id: "id", loop: true})) =~ " loop"
      refute web(video(%{media_id: "id", loop: false})) =~ " loop"
    end
  end

  describe "title and caption on the rendered page" do
    test "the title is rendered — the editor offers the field, so it must appear" do
      assert web(video(%{media_id: "v1", title: "Launch talk"})) =~ "Launch talk"
      assert web(audio(%{media_id: "a1", title: "Episode 1"})) =~ "Episode 1"
    end

    test "the caption is rendered as a figcaption" do
      assert web(video(%{media_id: "v1", caption: "A recap"})) =~
               "<figcaption>A recap</figcaption>"
    end

    test "a blank title emits no empty element" do
      refute web(video(%{media_id: "v1", title: "  "})) =~ "kiln-video-title"
      refute web(video(%{media_id: "v1"})) =~ "kiln-video-title"
    end
  end

  describe "poster" do
    test "a poster media item resolves through the stream route too" do
      html = web(video(%{media_id: "v1", poster_media_id: "p1"}))
      assert html =~ ~s(poster="/media/p1/stream")
    end

    test "no poster attribute at all when none is set" do
      refute web(video(%{media_id: "v1"})) =~ "poster="
    end
  end

  describe "captions" do
    test "a caption track renders as a default <track>" do
      html = web(video(%{media_id: "v1", captions_media_id: "c1", captions_lang: "fr"}))
      assert html =~ ~s(<track kind="captions" src="/media/c1/stream")
      assert html =~ ~s(srclang="fr")
      assert html =~ "default/>"
    end

    test "language and label fall back rather than rendering empty attributes" do
      html = web(video(%{media_id: "v1", captions_media_id: "c1"}))
      assert html =~ ~s(srclang="en")
      assert html =~ ~s(label="Captions")
    end

    test "no <track> when no caption track is picked" do
      refute web(video(%{media_id: "v1"})) =~ "<track"
    end
  end

  describe "escaping" do
    test "a caption with markup is escaped, not injected" do
      html = web(video(%{media_id: "v1", caption: "<script>alert('x')</script>"}))
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "a caption label with a quote can't break out of the attribute" do
      html = web(video(%{media_id: "v1", captions_media_id: "c1", captions_label: ~s(a" onx=")}))
      refute html =~ ~s(onx=")
    end

    test "an audio title with markup is escaped" do
      html = web(audio(%{media_id: "a1", title: "<b>hi</b>"}))
      refute html =~ "<b>hi</b>"
      assert html =~ "&lt;b&gt;"
    end
  end

  describe "structured data" do
    test "a titled video fires a VideoObject" do
      block =
        video(%{
          media_id: "v1",
          title: "Launch talk",
          caption: "A recap",
          duration_seconds: 3725.0
        })

      assert %{
               "@type" => "VideoObject",
               "name" => "Launch talk",
               "contentUrl" => "/media/v1/stream",
               "description" => "A recap",
               "duration" => "PT1H2M5S"
             } = Blocks.render(block, :json_ld)
    end

    test "an untitled video fires nothing — name is required by the schema" do
      assert Blocks.render(video(%{media_id: "v1", caption: "no title"}), :json_ld) == nil
    end

    test "a titled audio fires an AudioObject" do
      assert %{"@type" => "AudioObject", "name" => "Episode 1"} =
               Blocks.render(audio(%{media_id: "a1", title: "Episode 1"}), :json_ld)
    end

    test "an externally-hosted poster url is used when no poster item is picked" do
      # `poster_url` has no visible input in the editor, only a hidden one — it
      # arrives through the headless write API, and this is the render that
      # makes it worth carrying.
      html = web(video(%{media_id: "v1", poster_url: "https://cdn.example.com/still.jpg"}))
      assert html =~ ~s(poster="https://cdn.example.com/still.jpg")
    end

    test "a picked poster item wins over an external poster url" do
      html =
        web(
          video(%{
            media_id: "v1",
            poster_media_id: "p1",
            poster_url: "https://cdn.example.com/still.jpg"
          })
        )

      assert html =~ ~s(poster="/media/p1/stream")
      refute html =~ "cdn.example.com"
    end

    test "a javascript: poster url is dropped, not rendered" do
      refute web(video(%{media_id: "v1", poster_url: "javascript:alert(1)"})) =~ "poster="
    end

    test "a poster becomes the thumbnailUrl" do
      block = video(%{media_id: "v1", title: "T", poster_media_id: "p1"})
      assert %{"thumbnailUrl" => "/media/p1/stream"} = Blocks.render(block, :json_ld)
    end

    test "no duration key when the item was never probed" do
      block = video(%{media_id: "v1", title: "T", duration_seconds: nil})
      refute Map.has_key?(Blocks.render(block, :json_ld), "duration")
    end
  end

  describe "the :json delivery surface" do
    test "carries the resolved src and the playback flags" do
      block = video(%{media_id: "v1", title: "T", autoplay: true, loop: false})

      assert %{
               "_type" => "video",
               "src" => "/media/v1/stream",
               "media_id" => "v1",
               "title" => "T",
               "autoplay" => true,
               "loop" => false
             } = Blocks.render(block, :json)
    end

    test "flags are always present as booleans, never absent" do
      json = Blocks.render(video(%{media_id: "v1"}), :json)
      assert json["autoplay"] == false
      assert json["loop"] == false
    end
  end

  describe "text projections" do
    test "search_text is the title and caption" do
      assert Blocks.search_text(video(%{title: "Talk", caption: "Recap"})) == "Talk Recap"
      assert Blocks.search_text(audio(%{title: "Ep 1", caption: nil})) == "Ep 1"
    end

    test "to_markdown links at the stream route" do
      assert Blocks.to_markdown(video(%{media_id: "v1", title: "Talk"})) ==
               "[Talk](/media/v1/stream)"
    end

    test "an untitled item still gets a usable link label" do
      assert Blocks.to_markdown(audio(%{media_id: "a1"})) == "[Audio](/media/a1/stream)"
    end

    test "an empty block falls back to its plain-text projection" do
      assert Blocks.to_markdown(video(%{title: "Orphan"})) == "Orphan"
    end
  end
end
