defmodule KilnCMS.AVProcessor do
  @moduledoc """
  Byte-validates a video/audio upload and — when ffmpeg is installed — probes
  it for duration/dimensions and extracts a poster frame (#494).

  The third member of the upload-validator family, alongside
  `KilnCMS.ImageProcessor` (raster images) and `KilnCMS.DocumentProcessor`
  (PDFs). Same posture as both: deny-by-default, and the format is decided by
  **magic bytes**, never the client-supplied filename or MIME type.

  ## Formats

  Web-ready containers only, matching what `<video>`/`<audio>` can play
  without a transcode: MP4/M4A (ISO-BMFF `ftyp`), WebM (EBML with a `webm`
  DocType — Matroska is rejected), and MP3. Plus WebVTT caption tracks, which
  are not themselves playable media but are uploaded through the same library
  and belong to the same `<video>` element.

  There is **no transcoding**: Kiln stores what it is given. An operator who
  uploads a 4K ProRes master gets a rejection, not a two-hour job — see
  `docs/media-pipeline.md` for the "upload web-ready H.264/AAC" expectation.

  ## ffmpeg is optional

  `probe/1` and `poster/2` shell out to `ffprobe`/`ffmpeg`. Neither is a
  dependency of this application: when the binaries are absent every function
  here returns `{:error, :unavailable}` and the caller
  (`KilnCMS.Media.AVWorker`) degrades to storing the upload with no duration,
  no dimensions and no poster — the editor can still pick a poster image by
  hand. This is why `available?/0` exists and why nothing in the upload path
  is allowed to depend on a probe succeeding.

  ## Bounding a foreign program

  This is the only place in the codebase that hands a user-supplied file to an
  external binary, so the containment is spelled out rather than inherited.
  Neither `System.cmd/3` nor the calling Oban job's timeout can stop a running
  ffmpeg — closing an Erlang port shuts the pipes but signals nothing — so the
  limits have to be ones ffmpeg imposes on itself: `-timelimit` (CPU seconds),
  `-probesize`/`-analyzeduration` (how far it may scan before deciding what a
  file is), and `-nostdin` so it can never block waiting for input. See
  `@scan_limits` and `@cpu_seconds`.
  """

  require Logger

  import Bitwise, only: [&&&: 2]

  # Bytes read from the head of an upload for signature matching. Large enough
  # to cover an EBML header's DocType (which is not at a fixed offset) with
  # room to spare, small enough that a hostile file can't make this expensive.
  @header_bytes 512

  # How far ffmpeg/ffprobe may read before deciding what a file contains.
  #
  # `ImageProcessor` has a decompression-bomb guard (`max_pixels`) because a
  # small file can describe an enormous amount of work; a container is the
  # same problem in a different shape — a few kilobytes can declare an
  # arbitrarily long stream, and without a bound the scan is unbounded. These
  # are ffmpeg's own limits for exactly that, and 16 MB / 10 s is far more than
  # any web-ready file needs to identify itself.
  @scan_limits ["-probesize", "16777216", "-analyzeduration", "10000000"]

  # CPU-seconds ffmpeg may burn before it exits on its own (`setrlimit`).
  #
  # This is the ONLY bound that actually reaches the external process. Neither
  # `System.cmd/3` nor the Oban job timeout can kill it: closing an Erlang port
  # shuts the pipes but sends the OS child no signal, so an ffmpeg spinning on
  # CPU without writing output survives both. Extracting one frame from a
  # web-ready file is a fraction of a second; two minutes is generous for a
  # 500 MB source on a slow disk and still finite for a hostile one.
  @cpu_seconds "120"

  # The containers `strip_metadata/2` knows how to remux. Anything else is
  # refused rather than guessed at — `ext` is interpolated into the output
  # path, so an allowlist is also what keeps that path a path.
  @strippable_exts [".mp4", ".m4a", ".webm", ".mp3"]

  # Per-stream metadata is named explicitly rather than left to the plain
  # `-map_metadata -1`. Reading ffmpeg's source, the bare form appears to set
  # the per-stream and per-chapter "manual" flags too, which would make these
  # redundant — but "appears to, in the version we read" is not what a privacy
  # control should rest on, and stating each one costs nothing. That is where
  # an iPhone's per-track `creation_time` (local wall-clock) and `handler_name`
  # live.
  #
  # `-fflags +bitexact` is doing distinct work: it zeroes the `mdhd`/`tkhd`
  # creation times and suppresses the `encoder` tag ffmpeg would otherwise
  # stamp in, which leaks the server's build. On a stream copy it touches
  # neither timestamps nor the bitstreams.
  @strip_metadata_args [
    "-map_metadata",
    "-1",
    "-map_metadata:s:v",
    "-1",
    "-map_metadata:s:a",
    "-1",
    "-map_metadata:s:s",
    "-1",
    "-map_chapters",
    "-1",
    "-fflags",
    "+bitexact"
  ]

  # Without an explicit `-map`, ffmpeg applies *default stream selection* and
  # keeps one best video, audio and subtitle stream — so a lecture with an
  # English and a Spanish track would silently lose one, permanently, since the
  # original is deleted straight after. `?` makes each optional so a container
  # missing that type isn't an error.
  #
  # Deliberately absent: `0:d` and `0:t`. Data and attachment streams are
  # exactly where GoPro GPMF and Apple `mebx` timed telemetry — GPS tracks —
  # ride along, so dropping them IS the strip. `-dn` says so explicitly rather
  # than leaving it to the absence of a flag.
  @keep_streams_args ["-map", "0:v?", "-map", "0:a?", "-map", "0:s?", "-dn"]

  # ISO-BMFF major brands (bytes 8..11, immediately after the `ftyp` box tag).
  # Deny-by-default, like `ImageProcessor`'s libvips-loader allowlist: a `ftyp`
  # alone is not enough, because QuickTime (`qt  `), 3GPP and the various
  # HEIF/AVIF image brands share it and none of them is a web-ready MP4.
  @mp4_video_brands ~w(isom iso2 iso4 iso5 iso6 avc1 mp41 mp42 dash mmp4)
  @mp4_audio_brands ["M4A ", "M4B "]
  # `M4V ` and `M4VP` carry a trailing space / suffix that `~w` can't express.
  @mp4_video_brands_padded ["M4V ", "M4VP"]

  @doc """
  Returns `{:ok, %{ext:, content_type:, kind:}}` when `path`'s leading bytes
  match a supported A/V container or a WebVTT track. `kind` is `:video`,
  `:audio` or `:captions` — the caller needs it to pick a size cap and decide
  whether the item is worth probing.

  Rejects everything else with `{:error, :unsupported_format}`, including a
  file that merely has a `.mp4` extension.
  """
  # `path` is a LiveView upload's own server-generated temp file, never user
  # input — the traversal warning is a false positive (same reasoning as
  # `DocumentProcessor.validate_upload/1`).
  # sobelow_skip ["Traversal.FileModule"]
  @spec validate_upload(Path.t()) ::
          {:ok, %{ext: String.t(), content_type: String.t(), kind: :video | :audio | :captions}}
          | {:error, term()}
  def validate_upload(path) when is_binary(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @header_bytes)) do
      {:ok, header} when is_binary(header) -> classify(header)
      _ -> {:error, :unsupported_format}
    end
  end

  # WebVTT first: it is the only text format here, so its signature can't
  # collide with the binary ones below.
  defp classify(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: classify(rest)

  defp classify(<<"WEBVTT", rest::binary>>) do
    # The spec requires the signature be followed by end-of-file, a newline,
    # a space or a tab — without that check, a file starting `WEBVTTsomething`
    # would be accepted as a caption track it isn't.
    case rest do
      "" -> ok(".vtt", "text/vtt", :captions)
      <<c, _::binary>> when c in [?\n, ?\r, ?\s, ?\t] -> ok(".vtt", "text/vtt", :captions)
      _ -> {:error, :unsupported_format}
    end
  end

  # EBML. The container is only WebM if its DocType says so — a Matroska
  # (`.mkv`) file has an identical magic number and no browser plays it.
  defp classify(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>> = header) do
    case :binary.match(header, "webm") do
      {_pos, _len} -> ok(".webm", "video/webm", :video)
      :nomatch -> {:error, :unsupported_format}
    end
  end

  # ISO base media file format: a `ftyp` box tag at offset 4, then the brand.
  defp classify(<<_size::binary-size(4), "ftyp", brand::binary-size(4), _::binary>>) do
    cond do
      brand in @mp4_audio_brands -> ok(".m4a", "audio/mp4", :audio)
      brand in @mp4_video_brands -> ok(".mp4", "video/mp4", :video)
      brand in @mp4_video_brands_padded -> ok(".mp4", "video/mp4", :video)
      true -> {:error, :unsupported_format}
    end
  end

  # MP3 with an ID3v2 tag.
  defp classify(<<"ID3", _::binary>>), do: ok(".mp3", "audio/mpeg", :audio)

  # Bare MPEG audio: an 11-bit frame sync. Deliberately last — `0xFF` leads
  # plenty of unrelated formats, so every stricter signature gets first refusal.
  defp classify(<<0xFF, b, _::binary>>) when (b &&& 0xE0) == 0xE0,
    do: ok(".mp3", "audio/mpeg", :audio)

  defp classify(_), do: {:error, :unsupported_format}

  defp ok(ext, content_type, kind), do: {:ok, %{ext: ext, content_type: content_type, kind: kind}}

  @doc """
  The `variants` map label a generated poster frame is stored under.

  Exposed rather than hardcoded at the two call sites for the same reason
  `ImageProcessor.cropped_labels/0` is: `KilnCMS.Media.Presentation` must
  keep this label out of an image `srcset` (a poster is a still of a *video*,
  not an alternate rendering of the item), and that exclusion should not
  depend on somebody remembering the string.
  """
  @spec poster_label() :: String.t()
  def poster_label, do: "poster"

  @doc "Whether ffprobe/ffmpeg are installed, i.e. whether `probe/1` and `poster/2` can do anything."
  @spec available?() :: boolean()
  def available?, do: not is_nil(ffprobe()) and not is_nil(ffmpeg())

  @doc """
  Reads duration and (for video) intrinsic dimensions out of the file at
  `path` via ffprobe.

  `duration` is in seconds and may be `nil` for a stream ffprobe can't measure;
  `width`/`height` are `nil` for audio-only input. Returns
  `{:error, :unavailable}` when ffprobe isn't installed — the caller must treat
  that as "no metadata", not as a failed upload.
  """
  @spec probe(Path.t()) ::
          {:ok,
           %{
             duration: float() | nil,
             width: pos_integer() | nil,
             height: pos_integer() | nil,
             video?: boolean()
           }}
          | {:error, term()}
  def probe(path) when is_binary(path) do
    case ffprobe() do
      nil ->
        {:error, :unavailable}

      exe ->
        args =
          [
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_entries",
            "format=duration:stream=width,height,codec_type"
          ] ++ @scan_limits ++ [path]

        case cmd(exe, args) do
          {:ok, json} -> parse_probe(json)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_probe(json) do
    case Jason.decode(json) do
      {:ok, %{} = decoded} ->
        streams = Map.get(decoded, "streams", [])
        video = Enum.find(streams, &(Map.get(&1, "codec_type") == "video"))

        {:ok,
         %{
           duration: decoded |> Map.get("format", %{}) |> Map.get("duration") |> to_duration(),
           width: video && positive_integer(Map.get(video, "width")),
           height: video && positive_integer(Map.get(video, "height")),
           video?: not is_nil(video)
         }}

      _ ->
        {:error, :unparseable}
    end
  end

  # ffprobe reports duration as a *string* ("12.480000"), and reports "N/A" for
  # streams it can't measure.
  defp to_duration(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, _rest} when seconds > 0 -> Float.round(seconds, 3)
      _ -> nil
    end
  end

  defp to_duration(value) when is_number(value) and value > 0, do: Float.round(value / 1, 3)
  defp to_duration(_), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil

  @doc """
  Extracts a single frame from the video at `path` as a JPEG in the temp dir,
  returning `{:ok, tmp_path}`; the caller owns the temp file.

  `duration` (seconds, or `nil`) only picks the seek point: one second in for
  anything longer than two seconds, the very first frame otherwise — a
  three-frame clip has no "one second in", and many videos open on a black or
  blank frame, which makes a useless poster.

  `{:error, :unavailable}` when ffmpeg isn't installed.
  """
  # `out` is server-built (System.tmp_dir! + a UUID), never user input — the
  # File.rm traversal warning is a false positive (same as
  # `ImageProcessor.strip_metadata/2`).
  # sobelow_skip ["Traversal.FileModule"]
  @spec poster(Path.t(), float() | nil) :: {:ok, Path.t()} | {:error, term()}
  def poster(path, duration \\ nil) when is_binary(path) do
    case ffmpeg() do
      nil ->
        {:error, :unavailable}

      exe ->
        out = Path.join(System.tmp_dir!(), "kiln-poster-#{Ecto.UUID.generate()}.jpg")

        args =
          [
            "-v",
            "error",
            # Never read stdin. ffmpeg does by default, and a job with no
            # terminal attached can block on it forever.
            "-nostdin",
            "-timelimit",
            @cpu_seconds
          ] ++
            @scan_limits ++
            [
              # Before `-i`: ffmpeg seeks the container rather than decoding up
              # to the timestamp, which is the difference between instant and
              # minutes on a long file.
              "-ss",
              seek_point(duration),
              "-i",
              path,
              "-frames:v",
              "1",
              "-f",
              "image2",
              "-y",
              out
            ]

        case cmd(exe, args) do
          {:ok, _output} -> poster_result(out)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ffmpeg can exit 0 having written nothing (e.g. an audio-only file with no
  # video stream to take a frame from), so success is "there is a non-empty
  # JPEG on disk", not "the exit status was zero".
  # sobelow_skip ["Traversal.FileModule"]
  defp poster_result(out) do
    case File.stat(out) do
      {:ok, %{size: size}} when size > 0 ->
        {:ok, out}

      _ ->
        File.rm(out)
        {:error, :no_frame}
    end
  end

  defp seek_point(duration) when is_number(duration) and duration > 2.0, do: "1"
  defp seek_point(_duration), do: "0"

  # ffmpeg's exit status is the only success signal; stderr is folded into the
  # captured output so a failure can be logged with its actual reason rather
  # than a bare status code.
  #
  # `exe` is always a `System.find_executable/1` result for a literal
  # `"ffprobe"`/`"ffmpeg"` (see below), never anything a caller supplies, and
  # `System.cmd/3` execs directly rather than through a shell — so neither the
  # program nor the argument list can be injected into. `args` carries a
  # server-generated temp path plus fixed flags; even a hostile *filename*
  # would arrive as one exec argv entry, not as shell syntax.
  # sobelow_skip ["CI.System"]
  defp cmd(exe, args) do
    case System.cmd(exe, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        Logger.warning("#{Path.basename(exe)} exited #{status}: #{String.slice(output, 0, 500)}")
        {:error, {:exit_status, status}}
    end
  rescue
    e ->
      Logger.warning("#{Path.basename(exe)} failed: #{inspect(e)}")
      {:error, e}
  end

  # Resolved per call rather than at compile time: the binaries are a *system*
  # dependency, so a deployment can gain them (a new base image, an operator
  # `apt install ffmpeg`) without this application being rebuilt.
  defp ffprobe, do: System.find_executable("ffprobe")

  @doc """
  A copy of `path` with its container metadata removed (#820).

  `-map_metadata -1 -c copy` — a **stream copy**, so no re-encode: the audio and
  video bitstreams are written through untouched and only the container's
  metadata atoms are dropped. Cheap enough to run on every upload.

  What this is removing, on a file type where phone-recorded footage is the
  common case rather than the exception:

    * `©xyz` GPS coordinates, which iOS writes on every recording
    * `com.apple.quicktime.model` / `.software` — device and OS version
    * creation-date atoms, often in local wall-clock
    * the original filename, in some encoders' `©nam`
    * editing-application metadata from the export

  Returns `{:error, :unavailable}` when ffmpeg is not installed. **That is a
  real hole, not a formality** — ffmpeg is an optional dependency here, so on a
  host without it an A/V upload is stored exactly as it arrived. The caller
  decides what to do about that; see `KilnCMS.Media.Ingest`, which fails closed
  when the operator has asked it to.
  """
  @spec strip_metadata(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def strip_metadata(path, ext) when is_binary(path) and is_binary(ext) do
    cond do
      ext not in @strippable_exts -> {:error, :unsupported_ext}
      is_nil(ffmpeg()) -> {:error, :unavailable}
      true -> run_strip(ffmpeg(), path, ext)
    end
  end

  # `out` is this function's own generated temp path: a UUID under tmp_dir with
  # an extension already checked against `@strippable_exts`, never caller input.
  # sobelow_skip ["Traversal.FileModule"]
  defp run_strip(exe, path, ext) do
    out = Path.join(System.tmp_dir!(), "kiln-avstrip-#{Ecto.UUID.generate()}#{ext}")

    args =
      ["-v", "error", "-nostdin", "-timelimit", @cpu_seconds] ++
        @scan_limits ++
        ["-i", path] ++
        @strip_metadata_args ++
        @keep_streams_args ++
        faststart_args(ext) ++
        [
          # Copy the streams rather than re-encoding: this is a remux.
          "-c",
          "copy",
          "-y",
          out
        ]

    case cmd(exe, args) do
      {:ok, _output} ->
        strip_result(out)

      {:error, reason} ->
        File.rm(out)
        {:error, reason}
    end
  end

  # `+faststart` is a private option of the mov/mp4 muxer, so passing it to the
  # matroska or mp3 muxer is a hard error, not a no-op.
  defp faststart_args(ext) when ext in [".mp4", ".m4a"], do: ["-movflags", "+faststart"]
  defp faststart_args(_ext), do: []

  # sobelow_skip ["Traversal.FileModule"]
  defp strip_result(out) do
    case File.stat(out) do
      {:ok, %{size: size}} when size > 0 ->
        {:ok, out}

      _ ->
        File.rm(out)
        {:error, :strip_failed}
    end
  end

  defp ffmpeg, do: System.find_executable("ffmpeg")
end
