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

  ## Those two flags are not enough on their own (#918)

  They clear the trailer `/Info` and the Catalog's `/Metadata`. They do **not**
  touch per-page `/Metadata` XMP packets or `/PieceInfo` private data — and
  `/PieceInfo` is where Illustrator, InDesign and Acrobat park the author name
  and the authoring filesystem path (`C:\\Users\\jane\\...`). Verified against
  qpdf 12.3.2: after the two flags, a page-level `dc:creator` and a
  `/PieceInfo /Private` string both still grep out of the stored file.

  qpdf has no flag for this, so the strip runs in two passes: dump the object
  dictionaries with `--json-output`, prune `/Metadata` and `/PieceInfo` from
  every object that carries one, and feed the result back through
  `--update-from-json` alongside the two document-level flags.
  `--json-stream-data=none` keeps the intermediate JSON to the dictionaries —
  stream payloads are the bulk of a PDF and nothing here needs them.

  ## Encrypted PDFs are refused, and say so

  qpdf cannot open a user-password-encrypted PDF without the password, so it
  cannot strip one. Such a file is refused with `{:error, :encrypted}` rather
  than the generic `:strip_failed`, because the two mean different things to
  whoever uploaded it: one is "this file is broken", the other is "unlock it
  first". Storing it unstripped is not on the table — see the posture above.
  """

  require Logger

  # How long qpdf may run before it is abandoned. A PDF is a container: a small
  # file can describe a very large amount of work, the same class of problem
  # `ImageProcessor`'s pixel cap and `AVProcessor`'s scan limits address.
  #
  # Unlike ffmpeg, qpdf has no self-imposed CPU limit to hand it. Closing an
  # Erlang port shuts the pipes *without* signalling the child, so the timeout
  # additionally kills the OS process by pid (#918): a `Task.shutdown/2` left an
  # orphan qpdf burning CPU and then writing an unreferenced file into the temp
  # dir minutes after the upload had already been refused, with nothing reaping
  # it. `--decode-level=none` removes the amplification that made that reachable
  # — a 25 MB PDF can hold a FlateDecode stream that inflates to ~25 GB, and
  # qpdf's default `generalized` decode level would expand it.
  @timeout_ms 30_000

  # Keys pruned from EVERY object, not just pages: `/PieceInfo` is legal on any
  # dictionary, and a `/Metadata` stream attached to a Form XObject leaks the
  # same way one attached to a Page does.
  @pruned_keys ["/Metadata", "/PieceInfo"]

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
    strip_to(path, out)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp strip_to(path, out) do
    {update_args, update_path} = object_prune_args(path)

    try do
      case qpdf(base_args() ++ update_args ++ [path, out]) do
        # qpdf exits 3 for warnings it recovered from ("operation succeeded with
        # warnings"), which a slightly malformed but readable PDF routinely
        # triggers. The output is written and correct, so treating it as failure
        # would reject documents every other reader opens fine.
        {_output, code} when code in [0, 3] ->
          {:ok, out}

        {output, code} ->
          File.rm(out)
          classify_failure(path, output, code)
      end
    after
      if update_path, do: File.rm(update_path)
    end
  rescue
    error ->
      Logger.warning("DocumentProcessor.strip_metadata failed for #{path}: #{inspect(error)}")
      {:error, :strip_failed}
  end

  # Encryption is classified from the FAILURE, not probed up front. `qpdf
  # --is-encrypted` also exits 0 for an **owner-password-only** file — the
  # "restrict printing/editing" export that every reader opens with no password
  # at all — and qpdf strips those perfectly well. Pre-checking therefore
  # refused a large class of ordinary documents and told the uploader to remove
  # a password that does not exist. Only a file qpdf could not *open* is
  # `:encrypted`.
  defp classify_failure(path, output, code) do
    if output =~ ~r/invalid password/i do
      Logger.info("Refusing encrypted PDF #{path}: qpdf cannot strip what it cannot open")
      {:error, :encrypted}
    else
      Logger.warning(
        "qpdf strip failed (exit #{code}) for #{path}: #{String.slice(output, 0, 500)}"
      )

      {:error, :strip_failed}
    end
  end

  # The document-level half. `--decode-level=none` keeps qpdf from inflating
  # every stream it copies, which is both the timeout amplification vector and
  # unnecessary work — nothing here inspects stream contents.
  defp base_args,
    do: ["--remove-info", "--remove-metadata", "--decode-level=none"]

  # The per-object half (#918). Returns `{args, temp_path_to_clean_up}`, and
  # `{[], nil}` whenever there is nothing to prune — in which case the
  # document-level strip still runs, which is strictly better than refusing an
  # upload because a metadata *extra* could not be read.
  #
  # The dump goes to a FILE, not stdout. `qpdf/1` merges stderr into stdout so a
  # failure message is never lost, and qpdf emits `WARNING:` lines for any file
  # whose xref it reconstructs — exactly the "damaged but readable" class the
  # `code in [0, 3]` tolerance exists for. Read from stdout, those lines land in
  # front of the JSON, `Jason.decode/1` fails, and the prune is skipped on
  # precisely the files most likely to have been produced by a tool that also
  # left `/PieceInfo` behind.
  # sobelow_skip ["Traversal.FileModule"]
  defp object_prune_args(path) do
    json_path = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-objects.json")

    try do
      with {_out, code} when code in [0, 3] <-
             qpdf(["--json-output=2", "--json-stream-data=none", path, json_path]),
           {:ok, raw} <- File.read(json_path),
           {:ok, decoded} <- Jason.decode(raw),
           {:ok, pruned} when pruned != %{} <- prune_objects(decoded),
           update <- %{"qpdf" => [header(decoded), pruned]},
           update_path <-
             Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-prune.json"),
           :ok <- File.write(update_path, Jason.encode!(update)) do
        {["--update-from-json=" <> update_path], update_path}
      else
        # Distinguished from "nothing to prune" so a silent skip is visible.
        {:ok, empty} when empty == %{} ->
          {[], nil}

        other ->
          Logger.warning(
            "PDF object prune unavailable for #{path} (#{inspect(other)}); " <>
              "document-level strip still applied"
          )

          {[], nil}
      end
    after
      File.rm(json_path)
    end
  end

  defp header(%{"qpdf" => [header | _rest]}), do: header

  # Every `obj:N 0 R` entry carrying a pruned key at any depth, rewritten
  # without it.
  defp prune_objects(%{"qpdf" => [_header, objects]}) when is_map(objects) do
    pruned =
      objects
      |> Enum.flat_map(fn {key, entry} -> prune_entry(key, entry) end)
      |> Map.new()

    {:ok, pruned}
  end

  defp prune_objects(_other), do: :error

  # qpdf JSON v2 has TWO object shapes, and the second one is the one that
  # matters most in practice: a plain object is `%{"value" => dict}`, but a
  # STREAM object is `%{"stream" => %{"dict" => dict}}` — and image and Form
  # XObjects are streams. Those carry the original photo's XMP (photographer,
  # GPS) and Photoshop's/Illustrator's `/PieceInfo`, so matching only `"value"`
  # missed the most common real-world carrier while the moduledoc claimed
  # otherwise.
  defp prune_entry("obj:" <> _rest = key, %{"value" => dict}) when is_map(dict) do
    case prune_dict(dict) do
      ^dict -> []
      cleaned -> [{key, %{"value" => cleaned}}]
    end
  end

  defp prune_entry("obj:" <> _rest = key, %{"stream" => %{"dict" => dict} = stream})
       when is_map(dict) do
    case prune_dict(dict) do
      ^dict -> []
      cleaned -> [{key, %{"stream" => Map.put(stream, "dict", cleaned)}}]
    end
  end

  defp prune_entry(_key, _entry), do: []

  # Recursive: `/Metadata` and `/PieceInfo` are legal on any dictionary, and a
  # direct (inline) annotation or resource dictionary nests one a level down
  # where a top-level `Map.drop/2` never reaches it.
  defp prune_dict(dict) when is_map(dict) do
    dict
    |> Map.drop(@pruned_keys)
    |> Map.new(fn {k, v} -> {k, prune_dict(v)} end)
  end

  defp prune_dict(list) when is_list(list), do: Enum.map(list, &prune_dict/1)
  defp prune_dict(other), do: other

  # `Port.open/2` with `:spawn_executable` execs directly rather than through a
  # shell, so neither the program nor the argument list can be injected into.
  # `args` is fixed flags plus paths this server generated; even a hostile
  # *filename* would arrive as one exec argv entry, not as shell syntax.
  #
  # A port rather than `System.cmd/3` because the timeout has to be able to KILL
  # the child, and only a port hands back its OS pid. Closing the port alone
  # leaves qpdf running (#918).
  # sobelow_skip ["CI.System"]
  defp qpdf(args) do
    case System.find_executable("qpdf") do
      nil ->
        {"qpdf not found", :enoent}

      exe ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, args}
          ])

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _closed -> nil
          end

        collect(port, os_pid, [], System.monotonic_time(:millisecond) + @timeout_ms)
    end
  end

  # `acc` is an iodata LIST, not a binary being appended to. `acc <> chunk` in a
  # receive loop is quadratic — it reallocates the whole accumulated output per
  # chunk — which on a large `--json-output` dump was the difference between
  # tens of megabytes and most of a gigabyte of resident memory, in the
  # LiveView process handling the upload.
  #
  # The deadline is absolute rather than a per-message `after`: qpdf streams its
  # output, so a per-message timeout resets on every chunk and a slow but chatty
  # run could outlive the budget indefinitely.
  defp collect(port, os_pid, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} -> collect(port, os_pid, [acc | chunk], deadline)
      {^port, {:exit_status, code}} -> {IO.iodata_to_binary(acc), code}
    after
      remaining ->
        kill(os_pid)
        close(port)
        drain(port)
        {"qpdf timed out after #{@timeout_ms}ms", :timeout}
    end
  end

  # `Port.close/1` stops delivery but does not purge what the port already sent,
  # and this runs in the LiveView process handling the upload — `MediaLive` has
  # no catch-all `handle_info/2`, so one stray `{port, {:data, _}}` left in the
  # mailbox crashes the editor's media page instead of showing them the
  # refusal. Under the previous `Task`-based design the strays died with the
  # task; a port makes them the caller's problem.
  defp drain(port) do
    receive do
      {^port, _anything} -> drain(port)
    after
      0 -> :ok
    end
  end

  # SIGKILL, because the point is that the process stops now: it is holding CPU
  # on an upload the caller has already given up on, and qpdf has no cleanup
  # worth waiting for. Closing the port does not signal the child.
  # sobelow_skip ["CI.System"]
  defp kill(nil), do: :ok

  defp kill(os_pid) do
    System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp close(port) do
    Port.close(port)
    :ok
  rescue
    # Already closed because the child exited in the race with the timeout.
    ArgumentError -> :ok
  end
end
