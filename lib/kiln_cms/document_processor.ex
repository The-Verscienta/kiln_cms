defmodule KilnCMS.DocumentProcessor do
  @moduledoc """
  Byte-validates a non-image document upload (#481) — the `KilnCMS.ImageProcessor`
  analogue for the document library, deny-by-default and magic-byte-sniffed
  (never the client-supplied filename/MIME).

  PDF only for v1: `@allowed_formats` is a single-entry map so the shape
  matches `ImageProcessor.validate_upload/1`'s and stays trivial to extend
  when office-doc/zip support lands (tracked separately, out of scope here).

  `strip_metadata/1` removes the `/Info` dictionary and the XMP metadata stream
  before the blob is stored (#807), the document-library counterpart to
  `ImageProcessor`'s EXIF stripping.

  ## qpdf is required, not optional

  Stripping shells out to `qpdf`. That is a different posture from
  `KilnCMS.AVProcessor`, which degrades to "no duration, no poster" when ffmpeg
  is missing, and the difference is what the absence costs: a missing ffmpeg
  loses *enrichment*, a missing qpdf loses a *privacy guarantee*. A control that
  silently does not apply is worse than no control, because the operator
  believes it did — so `strip_metadata/1` answers `{:error, :unavailable}` and
  the upload is refused rather than stored unstripped.

  `available?/0` therefore checks a **capability**, not a binary: qpdf gained
  `--remove-info`/`--remove-metadata` in 11.10, and Debian bookworm's 11.3.0
  would pass a `System.find_executable/1` check while being unable to strip
  anything. The release image runs Debian trixie for exactly this reason.

  ## Why qpdf and not exiftool

  `exiftool -all=` on a PDF writes an **incremental update** that marks the
  metadata deleted and leaves the original bytes in the file, recoverable by
  anyone who reads it with a parser rather than a viewer. It looks like it
  worked. qpdf rewrites the document, so removal is removal.

  `--remove-info --remove-metadata` is surgical: outlines, forms, attachments
  and page content survive. The `qpdf --empty --pages in.pdf 1-z -- out.pdf`
  idiom also strips metadata, but by rebuilding the file from its pages, which
  silently discards bookmarks — measured, not assumed.
  """

  require Logger

  # How long qpdf may run before it is abandoned. A PDF is a container: a small
  # file can describe a very large amount of work, the same class of problem
  # `ImageProcessor`'s pixel cap and `AVProcessor`'s scan limits address.
  #
  # Unlike ffmpeg, qpdf has no self-imposed CPU limit to hand it, and closing an
  # Erlang port shuts the pipes without signalling the child — so this timeout
  # bounds *our* wait, and a runaway qpdf is reaped by the container rather than
  # by us. Acceptable because the process is per-upload and short-lived; the
  # alternative is holding a LiveView upload open indefinitely.
  @timeout_ms 30_000

  # Canonical {extension, content_type} per magic-byte signature this module
  # recognizes. Deny-by-default: anything else is rejected, same posture as
  # ImageProcessor's `@allowed_formats`.
  @allowed_formats %{
    "%PDF-" => {".pdf", "application/pdf"}
  }

  @doc """
  Returns `{:ok, %{ext: ".pdf", content_type: "application/pdf"}}` when `path`
  starts with a recognized document magic byte signature. Rejects anything
  else — including a file that merely has a `.pdf` extension — with
  `{:error, :unsupported_format}`.
  """
  # `path` is a LiveView upload's own server-generated temp file, never user
  # input — the traversal warning is a false positive (same reasoning as
  # ImageProcessor's temp-file reads/writes).
  # sobelow_skip ["Traversal.FileModule"]
  @spec validate_upload(Path.t()) ::
          {:ok, %{ext: String.t(), content_type: String.t()}} | {:error, term()}
  def validate_upload(path) when is_binary(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 1024)) do
      {:ok, header} when is_binary(header) -> match_signature(header)
      _ -> {:error, :unsupported_format}
    end
  end

  defp match_signature(header) do
    @allowed_formats
    |> Enum.find(fn {sig, _fmt} -> String.starts_with?(header, sig) end)
    |> case do
      {_sig, {ext, content_type}} -> {:ok, %{ext: ext, content_type: content_type}}
      nil -> {:error, :unsupported_format}
    end
  end

  @doc """
  Whether a qpdf **capable of stripping** is installed.

  Not `System.find_executable("qpdf") != nil`: the options this uses arrived in
  qpdf 11.10, and an older qpdf on the host would answer that check and then
  fail every strip. Asking qpdf what it supports is the only honest question.

  Memoized in `:persistent_term` — it shells out, it cannot change while the VM
  runs, and it is on the upload path.
  """
  @spec available?() :: boolean()
  def available? do
    case :persistent_term.get({__MODULE__, :available?}, :unknown) do
      :unknown ->
        result = probe_qpdf()
        :persistent_term.put({__MODULE__, :available?}, result)
        result

      cached ->
        cached
    end
  end

  @doc false
  # Tests toggle the cached answer to exercise the unavailable path without
  # uninstalling qpdf.
  def reset_available_cache, do: :persistent_term.erase({__MODULE__, :available?})

  # `System.cmd/3` execs directly rather than through a shell, and the only
  # input here is a `PATH` lookup — same reasoning as `AVProcessor.cmd/2`.
  # sobelow_skip ["CI.System"]
  defp probe_qpdf do
    with path when is_binary(path) <- System.find_executable("qpdf"),
         {help, 0} <- System.cmd(path, ["--help=all"], stderr_to_stdout: true) do
      String.contains?(help, "--remove-info") and String.contains?(help, "--remove-metadata")
    else
      _no_capable_qpdf -> false
    end
  rescue
    # A binary that exists but cannot be executed raises rather than returning a
    # non-zero exit. "We could not establish that stripping works" is the same
    # answer as "it does not".
    _error -> false
  end

  @doc """
  Rewrites the PDF at `path` without its `/Info` dictionary or XMP metadata,
  returning `{:ok, stripped_path}` — a NEW temp file, leaving the input alone
  (same contract as `KilnCMS.ImageProcessor.strip_metadata/2`).

  `{:error, :unavailable}` when no capable qpdf is installed. Callers must
  treat that as a failed upload, not as "store it as it came" — see the
  moduledoc.
  """
  # `path` is a LiveView upload's own server-generated temp file, and the
  # destination is one we generate — same false positive as `validate_upload/1`.
  # sobelow_skip ["Traversal.FileModule"]
  @spec strip_metadata(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def strip_metadata(path) when is_binary(path) do
    if available?() do
      run_qpdf(path)
    else
      {:error, :unavailable}
    end
  end

  # `out` is a path this function generates from a fresh UUID under the system
  # temp dir — the traversal warning on the `File.rm` below is the same false
  # positive the rest of the media pipeline carries.
  # sobelow_skip ["Traversal.FileModule"]
  defp run_qpdf(path) do
    out = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-stripped.pdf")

    case qpdf(["--remove-info", "--remove-metadata", path, out]) do
      # qpdf exits 3 for warnings it recovered from ("operation succeeded with
      # warnings"), which a slightly malformed but readable PDF routinely
      # triggers. The output is written and correct, so treating it as failure
      # would reject documents every other reader opens fine.
      {_output, code} when code in [0, 3] ->
        {:ok, out}

      {output, code} ->
        File.rm(out)

        Logger.warning(
          "qpdf strip failed (exit #{code}) for #{path}: #{String.slice(output, 0, 500)}"
        )

        {:error, :strip_failed}
    end
  rescue
    error ->
      Logger.warning("DocumentProcessor.strip_metadata failed for #{path}: #{inspect(error)}")
      {:error, :strip_failed}
  end

  # `System.cmd/3` execs directly rather than through a shell, so neither the
  # program nor the argument list can be injected into. `args` is fixed flags
  # plus two paths this server generated; even a hostile *filename* would
  # arrive as one exec argv entry, not as shell syntax. Same as
  # `AVProcessor.cmd/2`, which is the other place a user file meets a binary.
  # sobelow_skip ["CI.System"]
  defp qpdf(args) do
    task =
      Task.async(fn ->
        System.cmd(System.find_executable("qpdf"), args, stderr_to_stdout: true)
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timed_out -> {"qpdf timed out after #{@timeout_ms}ms", :timeout}
    end
  end
end
