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

  This hands a user-supplied file to an external binary, so the containment is
  spelled out rather than inherited. Four limits, and they cover different
  failure modes:

    * `-probesize`/`-analyzeduration` — how far ffmpeg may scan before deciding
      what a file is. A few kilobytes can declare an arbitrarily long stream.
    * `-nostdin` — so it can never block waiting for input it will never get.
    * `-timelimit` (`@cpu_seconds`) — a **CPU-second** rlimit, which bounds a
      hostile file that spins.
    * `@wall_clock_ms` — a **wall-clock** deadline, enforced by
      `KilnCMS.ExternalCommand` killing the OS process.

  The last one exists because the fourth failure mode is the common one and the
  first three all miss it (#1100). A `-c copy` remux is I/O-bound, so it burns
  almost no CPU and `-timelimit` essentially never fires; and neither
  `System.cmd/3` nor the calling Oban job's timeout can stop a running ffmpeg,
  because closing an Erlang port shuts the pipes but sends the child no signal.
  Only the OS pid a port hands back can be signalled, which is what
  `ExternalCommand` is for.

  ## Temp disk

  `strip_metadata/2` writes a second full copy of the upload to
  `System.tmp_dir!()` while the source is still there, so peak usage is roughly
  **twice** the file — up to 1 GB for one 500 MB video, and more with concurrent
  uploads. It therefore checks free space before starting and returns
  `{:error, :insufficient_space}` rather than letting ffmpeg fail ENOSPC
  half-written, because under the caller's default configuration that failure
  used to mean *stored unstripped* — the privacy guarantee lapsing precisely
  under disk pressure, when nobody is looking at it (#1100).

  The precheck cannot be the whole answer: concurrent uploads can each pass it
  and then collectively exhaust the disk. So an ENOSPC that happens anyway is
  recognised in ffmpeg's own output and reported as the same
  `:insufficient_space`, which is the reason the caller refuses on.
  """

  require Logger

  import Bitwise, only: [&&&: 2]

  alias KilnCMS.ExternalCommand

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
  # This is the bound ffmpeg imposes on ITSELF, and it is the only one that
  # survives ffmpeg being started some other way. It catches the process that
  # spins: extracting one frame from a web-ready file is a fraction of a second,
  # so two minutes is generous for a 500 MB source on a slow disk and still
  # finite for a hostile one.
  #
  # It does NOT catch the process that stalls, which is the common case — see
  # `@wall_clock_ms` below. It was the only bound here until #1100.
  @cpu_seconds "120"

  # Wall-clock milliseconds any one ffmpeg/ffprobe run may take before it is
  # killed. Distinct from `@cpu_seconds` and *not* redundant with it: a `-c copy`
  # remux is I/O-bound, so it can sit on a stalled disk for hours having burned
  # two seconds of CPU, and the rlimit never fires (#1100).
  #
  # Two minutes, chosen from both ends. A 500 MB remux is a straight read+write,
  # so even at 10 MB/s it finishes inside 100 s — anything past that is not
  # slow, it is stuck. And `strip_metadata/2` runs inline on the LiveView
  # handling the upload, so this is also the longest an editor's media page can
  # be blocked. It sits below `KilnCMS.Media.AVWorker`'s 5-minute Oban timeout
  # deliberately, so a stuck poster job is killed and logged here rather than
  # having the job reaped around a child that keeps running.
  @wall_clock_ms :timer.minutes(2)

  # Free temp space `strip_metadata/2` wants before it starts: the input's size
  # again (the output of a stream copy is the same order as its input), plus a
  # tenth for a remux that grows — a fragmented MP4 comes back with a full
  # `moov` index — plus a fixed floor so a small file on a nearly-full disk is
  # still refused rather than squeaking through on a percentage.
  @space_margin_numerator 11
  @space_margin_denominator 10
  @space_floor_bytes 16_000_000

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
  # than a bare status code — and, below, so the reason can be *classified*.
  #
  # `exe` is always a `System.find_executable/1` result for a literal
  # `"ffprobe"`/`"ffmpeg"` (see below), never anything a caller supplies, and
  # `ExternalCommand` execs directly rather than through a shell — so neither
  # the program nor the argument list can be injected into. `args` carries a
  # server-generated temp path plus fixed flags; even a hostile *filename*
  # would arrive as one exec argv entry, not as shell syntax.
  defp cmd(exe, args) do
    case ExternalCommand.run(exe, args, @wall_clock_ms) do
      {output, 0} ->
        {:ok, output}

      {_output, :timeout} ->
        Logger.warning(
          "#{Path.basename(exe)} exceeded its #{@wall_clock_ms}ms limit and was killed"
        )

        {:error, :timeout}

      {output, status} ->
        Logger.warning("#{Path.basename(exe)} exited #{status}: #{String.slice(output, 0, 500)}")
        {:error, classify_failure(output, status)}
    end
  rescue
    e ->
      Logger.warning("#{Path.basename(exe)} failed: #{inspect(e)}")
      {:error, e}
  end

  # A disk that filled up mid-write has to be told apart from a container ffmpeg
  # cannot remux, because the caller's answer differs: one is transient and
  # retryable and is refused, the other will never succeed and (by default)
  # falls back to storing the file as it arrived. The precheck in
  # `strip_metadata/2` catches most of these before ffmpeg starts, but not
  # concurrent uploads that each pass it and then exhaust the disk together —
  # this is the backstop for that race.
  #
  # ffmpeg's diagnostics are not localized, so matching the message is stable.
  # It reaches us because `-v error` still prints write failures and stderr is
  # folded into the captured output.
  defp classify_failure(output, status) do
    if String.contains?(output, "No space left on device"),
      do: :insufficient_space,
      else: {:exit_status, status}
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

  Returns `{:error, :insufficient_space}` when the temp filesystem has no room
  for the copy, either because the precheck said so or because ffmpeg hit
  ENOSPC anyway. Unlike the two above, the caller refuses that one
  unconditionally — see the "Temp disk" section of this module's docs.

  Returns `{:error, :timeout}` when the remux exceeded `@wall_clock_ms` and the
  process was killed.
  """
  @spec strip_metadata(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def strip_metadata(path, ext) when is_binary(path) and is_binary(ext) do
    cond do
      ext not in @strippable_exts ->
        {:error, :unsupported_ext}

      # Before the space check, not after: on a host with no ffmpeg there is no
      # copy to make room for, and answering "out of disk" would send the
      # operator after the wrong thing entirely.
      is_nil(ffmpeg()) ->
        {:error, :unavailable}

      not enough_temp_space?(path) ->
        {:error, :insufficient_space}

      true ->
        run_strip(ffmpeg(), path, ext)
    end
  end

  # Whether `System.tmp_dir!()` has room for a stripped copy of the file at
  # `path`. Public only so the arithmetic and the threshold can be asserted
  # directly — the alternative is a test that fills a disk.
  @doc false
  @spec enough_temp_space?(Path.t()) :: boolean()
  # sobelow_skip ["Traversal.FileModule"]
  def enough_temp_space?(path) do
    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, available} <- available_bytes(System.tmp_dir!()) do
      available >= required_bytes(size)
    else
      # Fail direction, stated on purpose: when we cannot *measure* free space
      # we proceed rather than refuse. Refusing on an unknown would break A/V
      # upload on every host whose `df` we cannot read — an outage in exchange
      # for a guess — and the ENOSPC classification in `classify_failure/2`
      # still catches the case this was meant to catch, just later.
      _unmeasurable -> true
    end
  end

  @doc false
  @spec required_bytes(non_neg_integer()) :: non_neg_integer()
  def required_bytes(size) when is_integer(size) and size >= 0,
    do: div(size * @space_margin_numerator, @space_margin_denominator) + @space_floor_bytes

  # `df -Pk`: POSIX output, so exactly one line per filesystem (without `-P`,
  # a long device name wraps onto two and the fields shift), in 1024-byte
  # blocks. Available is the fourth field from the left on both GNU and BSD df,
  # which is the pair this has to work on — Linux in production, macOS locally.
  #
  # `dir` is always `System.tmp_dir!()`, never caller input, and `System.cmd/3`
  # execs directly rather than through a shell.
  # sobelow_skip ["CI.System"]
  defp available_bytes(dir) do
    case System.cmd("df", ["-Pk", dir]) do
      {output, 0} -> parse_available(output)
      _nonzero -> :error
    end
  rescue
    # No `df` on this host. Handled the same as unparseable output.
    _error -> :error
  end

  @doc false
  @spec parse_available(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_available(output) do
    with [_header, line | _rest] <- String.split(output, "\n", trim: true),
         [_filesystem, _blocks, _used, available | _rest] <- String.split(line),
         {kbytes, ""} <- Integer.parse(available) do
      {:ok, kbytes * 1024}
    else
      _unparseable -> :error
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
