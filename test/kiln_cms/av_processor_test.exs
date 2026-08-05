defmodule KilnCMS.AVProcessorTest do
  @moduledoc """
  Byte-sniffed A/V validation (#494) — never trusts the filename/MIME a client
  claims, only the actual bytes, same posture as `ImageProcessor` and
  `DocumentProcessor`.

  The probe/poster functions are only exercised where ffmpeg is actually
  installed; everywhere else the assertion is the one that matters more
  operationally — that its absence is a clean `{:error, :unavailable}` and not
  a crash.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.AVProcessor

  defp tmp_file(contents) do
    path = Path.join(System.tmp_dir!(), "avproc_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end

  # A minimal ISO-BMFF head: 4 size bytes, the `ftyp` tag, then the brand.
  defp ftyp(brand), do: tmp_file(<<0, 0, 0, 0x20>> <> "ftyp" <> brand <> "\0\0\0\0rest")

  describe "MP4 / M4A (ISO base media)" do
    test "accepts a common video brand" do
      assert {:ok, %{ext: ".mp4", content_type: "video/mp4", kind: :video}} =
               AVProcessor.validate_upload(ftyp("isom"))
    end

    test "accepts the other video brands" do
      for brand <- ~w(iso2 avc1 mp41 mp42 dash) do
        assert {:ok, %{kind: :video}} = AVProcessor.validate_upload(ftyp(brand))
      end
    end

    test "an M4A brand is audio, not video" do
      assert {:ok, %{ext: ".m4a", content_type: "audio/mp4", kind: :audio}} =
               AVProcessor.validate_upload(ftyp("M4A "))
    end

    test "rejects a QuickTime .mov, which shares the ftyp box" do
      assert {:error, :unsupported_format} = AVProcessor.validate_upload(ftyp("qt  "))
    end

    test "rejects a HEIF image brand, which also shares the ftyp box" do
      assert {:error, :unsupported_format} = AVProcessor.validate_upload(ftyp("heic"))
    end
  end

  describe "WebM" do
    test "accepts an EBML header whose DocType says webm" do
      path = tmp_file(<<0x1A, 0x45, 0xDF, 0xA3>> <> <<1, 2, 3, 4>> <> "webm" <> "rest")

      assert {:ok, %{ext: ".webm", content_type: "video/webm", kind: :video}} =
               AVProcessor.validate_upload(path)
    end

    test "rejects a Matroska file, which has the identical magic number" do
      path = tmp_file(<<0x1A, 0x45, 0xDF, 0xA3>> <> <<1, 2, 3, 4>> <> "matroska" <> "rest")
      assert {:error, :unsupported_format} = AVProcessor.validate_upload(path)
    end
  end

  describe "MP3" do
    test "accepts an ID3v2-tagged file" do
      path = tmp_file("ID3" <> <<3, 0, 0, 0, 0, 0, 0>> <> "rest")

      assert {:ok, %{ext: ".mp3", content_type: "audio/mpeg", kind: :audio}} =
               AVProcessor.validate_upload(path)
    end

    test "accepts a bare MPEG frame sync" do
      path = tmp_file(<<0xFF, 0xFB, 0x90, 0x00>> <> "rest")

      assert {:ok, %{content_type: "audio/mpeg", kind: :audio}} =
               AVProcessor.validate_upload(path)
    end

    test "does not mistake a JPEG for MPEG audio (both start 0xFF)" do
      path = tmp_file(<<0xFF, 0xD8, 0xFF, 0xE0, "jfif header">>)
      assert {:error, :unsupported_format} = AVProcessor.validate_upload(path)
    end
  end

  describe "WebVTT" do
    test "accepts a track file" do
      path = tmp_file("WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nHello.\n")

      assert {:ok, %{ext: ".vtt", content_type: "text/vtt", kind: :captions}} =
               AVProcessor.validate_upload(path)
    end

    test "accepts one with a UTF-8 BOM, which real authoring tools emit" do
      path = tmp_file(<<0xEF, 0xBB, 0xBF>> <> "WEBVTT\n\nrest")
      assert {:ok, %{kind: :captions}} = AVProcessor.validate_upload(path)
    end

    test "rejects a file that merely starts with the letters WEBVTT" do
      # The spec requires EOF/newline/space/tab after the signature — without
      # that check `WEBVTTMalware...` would be accepted as a caption track.
      path = tmp_file("WEBVTTNOTREALLY\n")
      assert {:error, :unsupported_format} = AVProcessor.validate_upload(path)
    end
  end

  describe "rejection" do
    test "rejects a PDF (that is DocumentProcessor's job)" do
      path = tmp_file("%PDF-1.7\nrest")
      assert {:error, :unsupported_format} = AVProcessor.validate_upload(path)
    end

    test "rejects a plain text file" do
      assert {:error, :unsupported_format} = AVProcessor.validate_upload(tmp_file("just text"))
    end

    test "rejects an empty file" do
      assert {:error, :unsupported_format} = AVProcessor.validate_upload(tmp_file(""))
    end

    test "errors gracefully for a nonexistent path" do
      assert {:error, :unsupported_format} =
               AVProcessor.validate_upload("/nonexistent/#{System.unique_integer()}")
    end
  end

  describe "probe/poster without ffmpeg" do
    @tag :tmp_dir
    test "a file ffprobe can't read (or no ffprobe at all) is an error, never a crash", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "garbage.mp4")
      File.write!(path, "not actually a video")

      assert {:error, _reason} = AVProcessor.probe(path)
      assert {:error, _reason} = AVProcessor.poster(path, nil)
    end

    test "available?/0 answers without raising either way" do
      assert is_boolean(AVProcessor.available?())
    end
  end

  test "poster_label/0 is the variants key the rest of the pipeline excludes" do
    assert AVProcessor.poster_label() == "poster"
    assert AVProcessor.poster_label() in KilnCMS.Media.Presentation.excluded_labels()
  end
end
