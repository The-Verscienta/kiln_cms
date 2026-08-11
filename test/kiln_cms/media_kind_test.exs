defmodule KilnCMS.MediaKindTest do
  @moduledoc """
  Content-type classification (#494). The `:document` bucket used to be
  spelled "not an image", and the regression this guards is that A/V does not
  silently fall back into it.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.MediaKind

  describe "of/1" do
    test "images" do
      for ct <- ~w(image/jpeg image/png image/webp image/gif) do
        assert MediaKind.of(ct) == :image
      end
    end

    test "a MISSING content_type is an image; a blank string is not" do
      # nil: every row predating #481 was an image, and seed data still creates
      # rows without one. "" is a real stored value that names nothing, so it
      # takes the `:document` fallback like any other unrecognized type — which
      # is also what the SQL twin (`document_filter/0`) does with it.
      assert MediaKind.of(nil) == :image
      assert MediaKind.of("") == :document
    end

    test "classification is case-insensitive, matching the ilike-based SQL filters" do
      # `content_type` is editor-writable through the API. If `of/1` were
      # case-sensitive, a row set to "VIDEO/MP4" would be a video to the
      # picker's `ilike` query and a document to every Elixir caller — no
      # AVWorker job, wrong badge, and /stream serving it as a download.
      assert MediaKind.of("VIDEO/MP4") == :video
      assert MediaKind.of("Audio/MPEG") == :audio
      assert MediaKind.of("IMAGE/PNG") == :image
      assert MediaKind.of("Text/VTT") == :captions
    end

    test "video and audio" do
      assert MediaKind.of("video/mp4") == :video
      assert MediaKind.of("video/webm") == :video
      assert MediaKind.of("audio/mpeg") == :audio
      assert MediaKind.of("audio/mp4") == :audio
    end

    test "a WebVTT track is its own kind, not a document" do
      assert MediaKind.of("text/vtt") == :captions
    end

    test "everything else is a document" do
      assert MediaKind.of("application/pdf") == :document
      assert MediaKind.of("application/zip") == :document
    end
  end

  describe "inline_streamable?/1" do
    test "accepts exactly the types the A/V validator produces" do
      for ct <- MediaKind.inline_streamable_types(), do: assert(MediaKind.inline_streamable?(ct))
    end

    test "rejects anything that would be dangerous to echo into an inline response" do
      # `content_type` is in MediaItem's default_accept, so an editor with API
      # access can set it to anything — the allowlist is what stops that
      # string reaching a Content-Type header on a non-attachment response.
      for ct <- ["text/html", "image/svg+xml", "application/javascript", "text/plain"] do
        refute MediaKind.inline_streamable?(ct)
      end
    end

    test "is exact-match, never a prefix match" do
      refute MediaKind.inline_streamable?("video/quicktime")
      refute MediaKind.inline_streamable?("video/mp4; charset=utf-8")
      refute MediaKind.inline_streamable?(nil)
    end

    test "a document is playable by nothing and served as an attachment" do
      refute MediaKind.inline_streamable?("application/pdf")
    end
  end

  describe "humanize_duration/1" do
    test "formats under an hour as m:ss" do
      assert MediaKind.humanize_duration(0) == "0:00"
      assert MediaKind.humanize_duration(9.4) == "0:09"
      assert MediaKind.humanize_duration(75) == "1:15"
      assert MediaKind.humanize_duration(599) == "9:59"
    end

    test "formats an hour and over as h:mm:ss" do
      assert MediaKind.humanize_duration(3600) == "1:00:00"
      assert MediaKind.humanize_duration(3725) == "1:02:05"
    end

    test "an unprobed item shows nothing rather than 0:00" do
      assert MediaKind.humanize_duration(nil) == nil
      assert MediaKind.humanize_duration(-1) == nil
    end
  end
end
