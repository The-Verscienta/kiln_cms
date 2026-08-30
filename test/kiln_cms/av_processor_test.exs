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

  # #820. The strip is a privacy control, and the only thing that can show a
  # privacy control works is the output of the tool it shells out to — the
  # same argument `DocumentProcessorTest` makes for qpdf. Tagged `:ffmpeg` and
  # excluded where the binaries are missing, so a host without them reports a
  # skip rather than a green run that asserted nothing.
  #
  # Every assertion here corresponds to a defect the first cut actually had:
  # global-only metadata clearing, default stream selection silently dropping
  # the second audio track, and a faststart file coming back with `moov` at
  # the end.
  @moduletag :tmp_dir
  describe "strip_metadata/2 (#820)" do
    @describetag :ffmpeg

    defp source_with_metadata(dir) do
      path = Path.join(dir, "source.mp4")

      {_out, 0} =
        System.cmd(
          System.find_executable("ffmpeg"),
          ["-v", "error", "-y"] ++
            ["-f", "lavfi", "-i", "testsrc=size=64x64:rate=5:duration=1"] ++
            ["-f", "lavfi", "-i", "sine=frequency=440:duration=1"] ++
            ["-f", "lavfi", "-i", "sine=frequency=880:duration=1"] ++
            ["-map", "0:v", "-map", "1:a", "-map", "2:a"] ++
            ["-metadata", "location=+40.7128-074.0060/"] ++
            ["-metadata", "com.apple.quicktime.model=iPhone 15 Pro"] ++
            ["-metadata:s:a:0", "title=Original English"] ++
            ["-movflags", "+faststart"] ++
            ["-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", path],
          stderr_to_stdout: true
        )

      path
    end

    defp ffprobe_json(path, args) do
      {out, 0} =
        System.cmd(
          System.find_executable("ffprobe"),
          ["-v", "error", "-of", "json"] ++ args ++ [path],
          stderr_to_stdout: true
        )

      Jason.decode!(out)
    end

    test "removes global and per-stream metadata", %{tmp_dir: dir} do
      src = source_with_metadata(dir)

      # The fixture is only meaningful if ffmpeg actually wrote the tags.
      before = ffprobe_json(src, ["-show_entries", "format_tags"])
      assert before["format"]["tags"] != nil

      assert {:ok, out} = AVProcessor.strip_metadata(src, ".mp4")
      on_exit(fn -> File.rm(out) end)

      after_tags = ffprobe_json(out, ["-show_entries", "format_tags"])
      tags = after_tags["format"]["tags"] || %{}

      refute Map.has_key?(tags, "location")
      refute Map.has_key?(tags, "com.apple.quicktime.model")

      # Per-stream tags are where a phone writes its per-track wall-clock
      # `creation_time`. This asserts the outcome, not which flag delivers it.
      streams = ffprobe_json(out, ["-show_entries", "stream_tags"])["streams"]

      for stream <- streams do
        stream_tags = stream["tags"] || %{}
        refute Map.has_key?(stream_tags, "title")
        refute Map.has_key?(stream_tags, "creation_time")
      end
    end

    test "keeps every audio track — default stream selection would drop one", %{tmp_dir: dir} do
      src = source_with_metadata(dir)
      assert length(audio_streams(src)) == 2

      assert {:ok, out} = AVProcessor.strip_metadata(src, ".mp4")
      on_exit(fn -> File.rm(out) end)

      assert length(audio_streams(out)) == 2,
             "the second audio track was dropped — the remux needs an explicit -map"
    end

    defp audio_streams(path) do
      ffprobe_json(path, ["-select_streams", "a", "-show_entries", "stream=index"])["streams"] ||
        []
    end

    test "the stripped MP4 is still faststart", %{tmp_dir: dir} do
      src = source_with_metadata(dir)
      assert {:ok, out} = AVProcessor.strip_metadata(src, ".mp4")
      on_exit(fn -> File.rm(out) end)

      # `moov` before `mdat` is what lets a player start on the first range
      # request instead of seeking to the tail of a 500 MB object first.
      data = File.read!(out)

      # Destructured on purpose: `:binary.match/2` returns `:nomatch`, and an
      # atom sorts before any tuple in Erlang term order — so a bare
      # `match(a) < match(b)` would pass vacuously on an output that has no
      # `moov` at all, which is precisely the regression this pins.
      {moov, _} = :binary.match(data, "moov")
      {mdat, _} = :binary.match(data, "mdat")
      assert moov < mdat
    end

    test "an extension it does not know is refused, not interpolated into a path" do
      assert {:error, :unsupported_ext} =
               AVProcessor.strip_metadata("/tmp/x", "/../../etc/passwd")
    end
  end

  # #1100 moved probe/poster off `System.cmd/3` and onto the port runner that
  # can enforce a wall-clock deadline. Nothing pinned either of them SUCCEEDING
  # before — the only coverage was that a garbage file errors, which a runner
  # returning nothing at all would also satisfy. So the output ffprobe actually
  # produces, and the fact that it still parses as JSON once stderr is folded
  # into it, are pinned here.
  describe "probe/poster with ffmpeg" do
    @describetag :ffmpeg

    test "probe/1 reads duration and dimensions back", %{tmp_dir: dir} do
      assert {:ok, probed} = AVProcessor.probe(source_with_metadata(dir))

      assert probed.width == 64
      assert probed.height == 64
      assert probed.video?
      assert_in_delta probed.duration, 1.0, 0.3
    end

    test "poster/2 writes a real JPEG", %{tmp_dir: dir} do
      assert {:ok, out} = AVProcessor.poster(source_with_metadata(dir), 1.0)
      on_exit(fn -> File.rm(out) end)

      # SOI marker — that it is a JPEG, not merely a non-empty file.
      assert <<0xFF, 0xD8, _rest::binary>> = File.read!(out)
    end
  end

  # #1100. The strip writes a second full copy of the upload to the temp
  # filesystem, so a 500 MB video needs a gigabyte there. When that runs out,
  # ffmpeg fails ENOSPC and the caller's default configuration used to store the
  # file UNSTRIPPED — the privacy guarantee lapsing exactly under disk pressure,
  # which is when nobody is watching. These pin the precheck that refuses first.
  describe "temp-space precheck (#1100)" do
    # A file whose `stat` size is larger than any disk this will ever run on,
    # without writing the bytes: the header goes at offset 0 and a single byte
    # goes at the far end, leaving a hole in between. 8 TB is comfortably above
    # any CI runner's free space and comfortably below ext4's 16 TiB file cap.
    @sparse_size 8_000_000_000_000

    defp huge_sparse_mp4(dir) do
      path = Path.join(dir, "huge.mp4")

      {:ok, fd} = :file.open(path, [:write, :binary])
      :ok = :file.write(fd, <<0, 0, 0, 24>> <> "ftyp" <> "isom" <> String.duplicate("\0", 64))
      :ok = :file.pwrite(fd, @sparse_size, <<0>>)
      :ok = :file.close(fd)

      # Deleted eagerly (as `IngestTest`'s twin of this fixture already does)
      # because ExUnit only clears a `:tmp_dir` at the START of that test's
      # next run — without this, the hole outlives the suite as a file whose
      # stat size is 8 TB, and anything that later walks the tree without
      # minding sparseness (rsync, a backup, `du --apparent-size`) reads it
      # as 8 TB of real zeros.
      on_exit(fn -> File.rm(path) end)

      # If the filesystem did not give us a sparse file of the size we asked
      # for, every assertion below would be measuring the wrong thing.
      assert File.stat!(path).size == @sparse_size + 1

      path
    end

    test "a file that cannot fit its own copy is refused", %{tmp_dir: dir} do
      refute AVProcessor.enough_temp_space?(huge_sparse_mp4(dir))
    end

    test "an ordinary upload is not", %{tmp_dir: dir} do
      path = Path.join(dir, "small.mp4")
      File.write!(path, String.duplicate("x", 1_000))

      assert AVProcessor.enough_temp_space?(path)
    end

    test "an unmeasurable path proceeds rather than refusing" do
      # Fail direction, on purpose: refusing when free space cannot be read
      # would break A/V upload on every host whose `df` we cannot parse. The
      # ENOSPC classification is the backstop for what this lets through.
      assert AVProcessor.enough_temp_space?("/nonexistent/#{System.unique_integer()}")
    end

    test "the requirement is the file again, with headroom" do
      # More than the input, because the copy is the same order of magnitude
      # and a remux can grow — a fragmented MP4 comes back with a full `moov`.
      assert AVProcessor.required_bytes(500_000_000) > 500_000_000

      # And a floor, so a small file on a nearly-full disk is still refused
      # rather than squeaking through on a percentage of almost nothing.
      assert AVProcessor.required_bytes(0) >= 16_000_000
    end

    test "parses GNU df" do
      output = """
      Filesystem     1K-blocks      Used Available Use% Mounted on
      /dev/root       74244772  12285036  61943352  17% /
      """

      assert AVProcessor.parse_available(output) == {:ok, 61_943_352 * 1024}
    end

    test "parses BSD/macOS df" do
      output = """
      Filesystem   1024-blocks      Used Available Capacity  Mounted on
      /dev/disk3s5   971298980 367330784 561974572    40%    /System/Volumes/Data
      """

      assert AVProcessor.parse_available(output) == {:ok, 561_974_572 * 1024}
    end

    test "refuses to guess at output it does not understand" do
      assert :error = AVProcessor.parse_available("")
      assert :error = AVProcessor.parse_available("df: /nope: No such file or directory\n")
      assert :error = AVProcessor.parse_available("Filesystem Size\n/dev/root 74244772\n")
    end

    @tag :ffmpeg
    test "strip_metadata/2 reports it, without starting ffmpeg", %{tmp_dir: dir} do
      assert {:error, :insufficient_space} =
               AVProcessor.strip_metadata(huge_sparse_mp4(dir), ".mp4")
    end
  end
end
