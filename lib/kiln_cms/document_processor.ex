defmodule KilnCMS.DocumentProcessor do
  @moduledoc """
  Byte-validates a non-image document upload (#481) — the `KilnCMS.ImageProcessor`
  analogue for the document library, deny-by-default and magic-byte-sniffed
  (never the client-supplied filename/MIME).

  PDF was v1. #808 added the rest of what an editor actually has lying
  around: `.docx`/`.xlsx`/`.pptx` (OOXML — a zip with an internal
  `[Content_Types].xml` and a format-specific part), legacy `.doc`/`.xls`/
  `.ppt` (OLE2 compound files), and plain `.zip`. Every one of those is
  still recognized from its **bytes**, never the claimed filename/MIME — see
  `classify_zip/1` and `classify_ole/1`.

  ## Zip is a container, not a format (#808)

  A `.docx`/`.xlsx`/`.pptx`/`.zip` upload is, at the byte level, an
  attacker-controlled archive whose *declared* central-directory metadata
  (entry count, compressed/uncompressed size per entry) this module reads to
  decide whether to accept the file — and reading that metadata is itself a
  decompression bomb's classic amplification point: a tiny compressed blob
  can declare an enormous uncompressed size, or millions of entries, without
  the reader ever inflating a single byte. `zip_bomb?/1` rejects on exactly
  that declared metadata (`@max_zip_uncompressed_bytes`,
  `@max_zip_compression_ratio`, `@max_zip_entries` below), via
  `:zip.list_dir/1` — which reads only the central directory, the same
  region a real decompressor consults before it allocates anything. Nothing
  in this module ever calls a function that inflates archive content; that
  is the one line it does not cross.

  ## Office formats are not stripped (yet)

  `strip_metadata/1` still only knows PDF — it shells out to qpdf, which
  cannot open a zip or an OLE2 file at all. `KilnCMS.Media.Ingest` only
  routes a `.pdf` document through it; every other document kind (office or
  zip) is stored as uploaded, same posture as A/V before #820 landed.
  A metadata strip for OOXML/OLE2 is a real gap (both formats carry author
  names and, for OLE2, the authoring machine's path) but a different tool
  and a different issue — not assumed away here, just not yet built.

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

  alias KilnCMS.ExternalCommand

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

  # How many header bytes are enough to recognize PDF, OOXML/plain-zip, and
  # OLE2 by their leading signature. All three signatures live in the first
  # handful of bytes; 1024 leaves headroom without reading anything close to
  # the whole file for the (common) case of a signature this module rejects
  # outright.
  @header_bytes 1024

  # OLE2 stream names live in the compound file's directory sector, which for
  # a small document is well within the first few KB — this module does not
  # parse the FAT to find it exactly (that is real parsing, not sniffing, and
  # nothing else here does that either). 8 KB is generous for the documents
  # this library actually holds and still bounded/cheap to read.
  @ole_probe_bytes 8192

  # A zip's declared uncompressed TOTAL, read from the central directory
  # alone. 500 MB is far past any legitimate document bundle this library
  # holds (`KilnCMS.Media.Ingest`'s own cap on the file as STORED is 25 MB —
  # see `@max_document_size` there) while still well short of what a bomb
  # needs to be a problem for whatever eventually reads this metadata.
  @max_zip_uncompressed_bytes 500_000_000

  # A genuine document — mostly XML/text, plus whatever already-compressed
  # images it embeds — does not approach this. A bomb built from a repeating
  # byte reaches 1000:1 or more from a file of a few KB; 100:1 is comfortably
  # above anything real and comfortably below anything designed to amplify.
  @max_zip_compression_ratio 100

  # An OOXML package is dozens to a few hundred parts; a legitimate plain-zip
  # upload to a document library is not meaningfully different. Past this,
  # the central directory itself — which `zip_entries/1` reads in full to
  # answer this question — is doing the amplifying, independent of any one
  # entry's declared size.
  @max_zip_entries 10_000

  # OOXML packages (docx/xlsx/pptx) all carry this at the archive root; it is
  # what distinguishes "a zip that happens to be an Office document" from
  # any other zip. The three main-part paths below are what distinguish
  # *which* Office document — a macro-enabled variant (.docm/.xlsm/.pptm)
  # carries the same paths and is classified the same as its non-macro
  # sibling, which is fine: nothing here executes content, it only stores and
  # serves bytes.
  @ooxml_marker "[Content_Types].xml"
  @ooxml_parts %{
    "word/document.xml" =>
      {".docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
    "xl/workbook.xml" =>
      {".xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
    "ppt/presentation.xml" =>
      {".pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"}
  }

  # Legacy OLE2 offers no equivalent of `[Content_Types].xml` — the signature
  # alone is shared by Word/Excel/PowerPoint (and by unrelated formats this
  # module does not accept, like .msi/.msg). What distinguishes them is the
  # name of the stream each application writes at the document's root,
  # searched for here as the raw UTF-16LE bytes the compound file directory
  # stores them as. A signature match with none of these present is refused
  # rather than guessed at — the same deny-by-default posture as everything
  # else in this module.
  @ole_streams %{
    "WordDocument" => {".doc", "application/msword"},
    "PowerPoint Document" => {".ppt", "application/vnd.ms-powerpoint"},
    "Workbook" => {".xls", "application/vnd.ms-excel"},
    # Excel's pre-BIFF8 (95 and earlier) stream name — rare, kept for the
    # same reason the OOXML side keeps macro-enabled variants: a file that is
    # genuinely one of the three formats this module means to accept
    # shouldn't be refused because it's an older dialect of it.
    "Book" => {".xls", "application/vnd.ms-excel"}
  }

  @doc """
  Returns `{:ok, %{ext: ext, content_type: content_type}}` when `path` starts
  with a recognized document magic byte signature — PDF, OOXML
  (docx/xlsx/pptx), legacy OLE2 (doc/xls/ppt), or a plain zip. Rejects
  anything else — including a file that merely has a matching extension —
  with `{:error, :unsupported_format}`, and a zip/OOXML file whose declared
  central-directory metadata looks like a decompression bomb with
  `{:error, :zip_bomb}` (see the moduledoc).
  """
  # `path` is a LiveView upload's own server-generated temp file, never user
  # input — the traversal warning is a false positive (same reasoning as
  # ImageProcessor's temp-file reads/writes).
  # sobelow_skip ["Traversal.FileModule"]
  @spec validate_upload(Path.t()) ::
          {:ok, %{ext: String.t(), content_type: String.t()}} | {:error, term()}
  def validate_upload(path) when is_binary(path) do
    case read_prefix(path, @header_bytes) do
      {:ok, header} -> classify_by_signature(header, path)
      :error -> {:error, :unsupported_format}
    end
  end

  defp classify_by_signature(<<"%PDF-", _rest::binary>>, _path),
    do: {:ok, %{ext: ".pdf", content_type: "application/pdf"}}

  defp classify_by_signature(
         <<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, _rest::binary>>,
         path
       ),
       do: classify_ole(path)

  defp classify_by_signature(<<0x50, 0x4B, 0x03, 0x04, _rest::binary>>, path),
    do: classify_zip(path)

  defp classify_by_signature(_header, _path), do: {:error, :unsupported_format}

  # ── OOXML / plain zip (#808) ────────────────────────────────────────────

  # `:zip.list_dir/1` reads only the central directory (a fixed-size record
  # per entry, near the end of the file) — never the entries' own compressed
  # data. That is true whether the file is 1 KB or 1 GB, which is what makes
  # it safe to call before any size cap has been applied to `path`.
  defp classify_zip(path) do
    case zip_entries(path) do
      {:ok, entries} ->
        if zip_bomb?(entries), do: {:error, :zip_bomb}, else: classify_zip_entries(entries)

      {:error, _reason} ->
        {:error, :unsupported_format}
    end
  end

  # `path` is a server-generated temp file, never user input — same false
  # positive as `validate_upload/1`'s own read.
  # sobelow_skip ["Traversal.FileModule"]
  defp zip_entries(path) do
    case :zip.list_dir(String.to_charlist(path)) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # A file that merely starts with the zip signature but is otherwise
    # garbage can make the zip module raise rather than return an error
    # tuple (a malformed length field read as an offset, for instance).
    # "We could not establish this is a zip" is the same answer either way.
    _error -> {:error, :unreadable}
  end

  # Declared metadata only — see the moduledoc. `file_info` is the bare
  # Erlang `:file.file_info()` record (not an Elixir struct), so its
  # uncompressed `size` is read positionally rather than by field name.
  defp zip_bomb?(entries) do
    totals =
      Enum.reduce(entries, %{count: 0, uncompressed: 0, compressed: 0}, fn
        {:zip_file, _name, file_info, _comment, _offset, comp_size}, acc ->
          %{
            count: acc.count + 1,
            uncompressed: acc.uncompressed + elem(file_info, 1),
            compressed: acc.compressed + comp_size
          }

        # `:zip.list_dir/1` may lead with a `:zip_comment` record — not a
        # file, nothing to total.
        _other, acc ->
          acc
      end)

    cond do
      totals.count > @max_zip_entries -> true
      totals.uncompressed > @max_zip_uncompressed_bytes -> true
      # Nonzero declared content compressing to nothing isn't achievable by
      # any real method (stored data can't shrink, and deflate has overhead)
      # — flagged the same as an absurd ratio rather than divided by zero.
      totals.compressed == 0 -> totals.uncompressed > 0
      totals.uncompressed / totals.compressed > @max_zip_compression_ratio -> true
      true -> false
    end
  end

  defp classify_zip_entries(entries) do
    names = for {:zip_file, name, _fi, _c, _o, _cs} <- entries, do: to_string(name)

    if @ooxml_marker in names,
      do: classify_ooxml_parts(names),
      else: {:ok, %{ext: ".zip", content_type: "application/zip"}}
  end

  defp classify_ooxml_parts(names) do
    @ooxml_parts
    |> Enum.find(fn {part, _fmt} -> part in names end)
    |> case do
      {_part, {ext, content_type}} -> {:ok, %{ext: ext, content_type: content_type}}
      # Carries `[Content_Types].xml` but none of the three main parts this
      # module knows how to name — some other OOXML-family format (Visio,
      # OneNote, …). Deny-by-default: not one of the formats #808 asked for.
      nil -> {:error, :unsupported_format}
    end
  end

  # ── Legacy OLE2 (#808) ──────────────────────────────────────────────────

  defp classify_ole(path) do
    case read_prefix(path, @ole_probe_bytes) do
      {:ok, probe} -> classify_ole_probe(probe)
      :error -> {:error, :unsupported_format}
    end
  end

  defp classify_ole_probe(probe) do
    @ole_streams
    |> Enum.find(fn {stream, _fmt} -> :binary.match(probe, utf16le(stream)) != :nomatch end)
    |> case do
      {_stream, {ext, content_type}} -> {:ok, %{ext: ext, content_type: content_type}}
      nil -> {:error, :unsupported_format}
    end
  end

  defp utf16le(ascii), do: for(<<byte <- ascii>>, into: <<>>, do: <<byte::little-16>>)

  # `path` is a server-generated temp file, never user input — same false
  # positive as `validate_upload/1`'s own read.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_prefix(path, bytes) do
    case File.open(path, [:read, :binary], &IO.binread(&1, bytes)) do
      {:ok, data} when is_binary(data) -> {:ok, data}
      _ -> :error
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

  # `KilnCMS.ExternalCommand`, not `System.cmd/3`, because the timeout has to be
  # able to KILL the child, and only a port hands back its OS pid — closing the
  # port alone leaves qpdf running (#918). That runner used to live here; #1100
  # moved it out when the A/V path needed the identical containment, and its
  # moduledoc carries the reasoning that was in these comments.
  defp qpdf(args) do
    case System.find_executable("qpdf") do
      nil -> {"qpdf not found", :enoent}
      exe -> ExternalCommand.run(exe, args, @timeout_ms)
    end
  end
end
