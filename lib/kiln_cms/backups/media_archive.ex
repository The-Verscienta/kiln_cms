defmodule KilnCMS.Backups.MediaArchive do
  @moduledoc """
  Writes the media directory as a set of independent `tar.gz` parts (#2218).

  A deployment's media can be many gigabytes. One archive of it means one
  multi-gigabyte file that has to be written, verified, uploaded and (after a
  failure) rebuilt in one piece. This module splits the **file set** instead:
  every part is a complete, independently valid `tar.gz` holding a disjoint
  subset of the files, so each can be listed, hashed, uploaded and restored on
  its own. (Byte-splitting one gzip stream gives pieces that are none of those.)

  `scripts/backup.sh` mirrors this planner (walk order, exclusion globs, part
  assignment, names, `tar` flags, retry): keep the two in step. Why the script
  re-implements this planner instead of calling it, what the two must agree
  on, and the rule that both change in the same pull request are ADR 0042
  (`docs/decisions/0042-*`).

  ## Planning

  `plan/3` walks the media directory lazily (`File.ls/1` and `File.lstat/2` with
  an explicit stack, never a recursive listing held in memory) and writes
  null-separated `./relative/path` lists, one per part, into a work directory
  (`partNN.list`, mode 0600), followed by `plan.json`, which marks the plan
  complete. A part closes when adding the next file would push the sum of its
  **input** file sizes past the cap, so the cap is a target ceiling, not an
  exact size (gzip makes the archive smaller than its input). A file larger than
  the cap is never split: it becomes a part of its own, flagged `oversize`.

  Regular files and symlinks are archived (a symlink as a symlink). Sockets,
  devices and directories are skipped, so **empty directories and directory
  metadata are not preserved**; restoring recreates directories as it extracts
  files into them.

  Exclusions (`BACKUP_MEDIA_EXCLUDE`) are applied here, in the planner, never by
  tar. A pattern is matched against the path relative to the media directory:
  `*` and `?` stay within one path segment, `**` crosses segments, and a
  pattern with no `/` is matched against the file or directory name at any depth
  (so `*.tmp` means every `.tmp` file). A directory that matches is skipped
  whole.

  The plan is **frozen**: it is written once and `load_plan/2` reads it back, so
  an interrupted run resumes with the same parts. Files created after planning
  are not in the set (the next backup has them).

  ## Archiving

  `archive_part/4` does one part: it drops list entries that no longer exist
  (logged, and counted in the result), runs

      tar -czf <part>.partial --null -C <media_dir> -T <list>

  (only flags GNU tar and bsdtar share), lists the result with `tar -tzf`,
  renames it into place, sets mode 0600 and hashes it with `Checksum`. No
  archive bytes pass through the VM, and the list is read in chunks, so memory
  does not grow with the size of the media directory.

  **The exit code alone is never trusted.** bsdtar exits 1 for every problem and
  GNU tar exits 1 or 2 depending on the kind; neither number says whether a
  file merely vanished mid-run (the app deletes media while a backup runs). A
  part succeeds only if tar exited 0 *and* its archive lists cleanly. Anything
  else removes the `.partial`, re-filters the same list (so files that vanished
  are dropped and counted) and tries once more; a second failure is the part's
  error, with tar's own output. A failed part never leaves a `.partial`, and the
  parts finished before it stay on disk for a resume.

  ## Checksums

  `checksum/3` re-reads every finished part once, in order, checks each digest
  against the one recorded when the part was written, and returns the digest of
  all parts concatenated (what `cat part* | sha256sum` prints) together with the
  `kiln-media-<stamp>.sha256` sidecar it writes (see `Checksum`).
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Checksum, Redact}
  alias KilnCMS.ExternalCommand

  require Logger

  @read_chunk 65_536
  @tail 2000
  @empty_tar :zlib.gzip(<<0::size(10_240 * 8)>>)

  @type part :: %{
          index: pos_integer(),
          list: String.t(),
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          oversize: boolean()
        }

  @type plan :: %{
          stamp: String.t(),
          media_dir: Path.t(),
          work_dir: Path.t(),
          parts: [part()],
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          excluded: non_neg_integer(),
          unreadable_names: non_neg_integer(),
          unreadable_examples: [String.t()],
          part_bytes: pos_integer()
        }

  @type finished :: %{
          index: pos_integer(),
          name: String.t(),
          path: Path.t(),
          bytes: non_neg_integer(),
          sha256: String.t(),
          oversize: boolean(),
          files: non_neg_integer(),
          dropped: non_neg_integer(),
          verified: boolean()
        }

  ## Planning

  @doc """
  Plan the archive of `media_dir`, writing the lists and `plan.json` into
  `work_dir` (created 0700; stale lists of an earlier plan are removed first).

  Options: `:stamp` (required), `:part_bytes` (default `Backups.media_part_bytes/0`),
  `:exclude` (default `Backups.media_exclude/0`).

  The tree is listed with `:file.list_dir_all/1`, which also returns the names
  the VM's file-name encoding cannot decode (raw binaries, e.g. a Latin-1 name
  under a UTF-8 VM); `File.ls/1` would omit those silently. Such a name is
  `lstat`ed and archived byte for byte like any other. One the VM cannot even
  `lstat` is not archivable; it is counted in `:unreadable_names` (with up to
  5 lossy-printed `:unreadable_examples`) and warned about, never dropped
  quietly. `:list_dir` and `:lstat` (functions with the `:file` signatures)
  exist so a test can stand in for a filesystem that refuses such names.

  Always produces at least one part: an empty (or fully excluded) tree is one
  part with no files, archived as a valid empty tarball.
  """
  @spec plan(Path.t(), Path.t(), keyword()) :: {:ok, plan()} | {:error, term()}
  def plan(media_dir, work_dir, opts) do
    stamp = Keyword.fetch!(opts, :stamp)
    cap = Keyword.get_lazy(opts, :part_bytes, &Backups.media_part_bytes/0)
    globs = Keyword.get_lazy(opts, :exclude, &Backups.media_exclude/0)

    fs = %{
      list_dir: opts[:list_dir] || (&:file.list_dir_all/1),
      lstat: opts[:lstat] || (&File.lstat/1)
    }

    with :ok <- media_dir_exists(media_dir),
         :ok <- mkdir_private(work_dir),
         :ok <- clear_plan(work_dir),
         {:ok, state} <- walk(media_dir, work_dir, cap, compile_globs(globs), fs) do
      plan = %{
        stamp: stamp,
        media_dir: media_dir,
        work_dir: work_dir,
        parts: state.parts,
        files: state.files,
        bytes: state.bytes,
        excluded: state.excluded,
        unreadable_names: state.unreadable,
        unreadable_examples: Enum.reverse(state.unreadable_examples),
        part_bytes: cap
      }

      if state.unreadable > 0 do
        Logger.warning(
          "Media backup could not archive #{state.unreadable} file name(s) the file-name " <>
            "encoding cannot represent, e.g. #{Enum.join(plan.unreadable_examples, ", ")}"
        )
      end

      if globs != [] do
        Logger.info(
          "Media backup excludes #{length(globs)} pattern(s): #{state.excluded} entr(ies) left out"
        )
      end

      with :ok <- write_plan(plan), do: {:ok, plan}
    end
  end

  @doc """
  Read back the plan written by `plan/3` from `work_dir`, for `media_dir`.

  `{:error, :no_plan}` when there is no complete plan (planning was interrupted
  before `plan.json` landed, or this is not a work directory), so the caller
  plans afresh; also when a list the plan names has gone missing.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec load_plan(Path.t(), Path.t()) :: {:ok, plan()} | {:error, :no_plan}
  def load_plan(media_dir, work_dir) do
    with {:ok, json} <- File.read(Path.join(work_dir, "plan.json")),
         {:ok, %{"stamp" => stamp, "parts" => [_ | _] = parts} = map} <- Jason.decode(json),
         true <- is_binary(stamp),
         {:ok, parts} <- decode_parts(parts, work_dir) do
      {:ok,
       %{
         stamp: stamp,
         media_dir: media_dir,
         work_dir: work_dir,
         parts: parts,
         files: Enum.sum(Enum.map(parts, & &1.files)),
         bytes: Enum.sum(Enum.map(parts, & &1.bytes)),
         excluded: map["excluded"] || 0,
         unreadable_names: nonneg(map["unreadable_names"]),
         unreadable_examples: examples(map["unreadable_examples"]),
         part_bytes: map["part_bytes"] || Backups.media_part_bytes()
       }}
    else
      _ -> {:error, :no_plan}
    end
  end

  defp nonneg(n) when is_integer(n) and n >= 0, do: n
  defp nonneg(_), do: 0

  defp examples(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp examples(_), do: []

  @doc "`load_plan/2` when a complete plan exists, else `plan/3`."
  @spec plan_or_load(Path.t(), Path.t(), keyword()) :: {:ok, plan()} | {:error, term()}
  def plan_or_load(media_dir, work_dir, opts) do
    case load_plan(media_dir, work_dir) do
      {:ok, plan} -> {:ok, plan}
      {:error, :no_plan} -> plan(media_dir, work_dir, opts)
    end
  end

  @doc "The final file names of a plan's parts, in order."
  @spec names(plan()) :: [String.t()]
  def names(%{stamp: stamp, parts: parts}), do: Artifact.set_names(stamp, length(parts))

  defp decode_parts(parts, work_dir) do
    decoded =
      for {%{"index" => index, "list" => list, "files" => files, "bytes" => bytes} = p, i} <-
            Enum.with_index(parts, 1),
          index == i,
          is_binary(list),
          is_integer(files) and is_integer(bytes) do
        %{index: index, list: list, files: files, bytes: bytes, oversize: p["oversize"] == true}
      end

    if length(decoded) == length(parts) and
         Enum.all?(decoded, &File.regular?(Path.join(work_dir, &1.list))),
       do: {:ok, decoded},
       else: :error
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_plan(plan) do
    path = Path.join(plan.work_dir, "plan.json")

    map = %{
      "version" => 1,
      "stamp" => plan.stamp,
      "part_bytes" => plan.part_bytes,
      "excluded" => plan.excluded,
      "unreadable_names" => plan.unreadable_names,
      "unreadable_examples" => plan.unreadable_examples,
      "parts" =>
        Enum.map(plan.parts, fn p ->
          %{
            "index" => p.index,
            "list" => p.list,
            "files" => p.files,
            "bytes" => p.bytes,
            "oversize" => p.oversize
          }
        end)
    }

    with {:ok, json} <- Jason.encode(map),
         :ok <- File.write(path <> ".partial", json),
         :ok <- File.chmod(path <> ".partial", 0o600),
         do: File.rename(path <> ".partial", path)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp clear_plan(work_dir) do
    for file <-
          Path.wildcard(Path.join(work_dir, "part*.list")) ++ [Path.join(work_dir, "plan.json")],
        do: File.rm(file)

    :ok
  end

  defp media_dir_exists(media_dir) do
    if File.dir?(media_dir), do: :ok, else: {:error, {:missing_media_dir, media_dir}}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp mkdir_private(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  defp list_name(index), do: "part#{pad(index)}.list"
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # The walk. `stack` holds directories still to list (paths relative to the
  # media dir, "" for the root); `state` the open list and the finished parts.
  defp walk(media_dir, work_dir, cap, matcher, fs) do
    state = %{
      work_dir: work_dir,
      cap: cap,
      matcher: matcher,
      fs: fs,
      io: nil,
      index: 0,
      count: 0,
      bytes: 0,
      oversize: false,
      parts: [],
      files: 0,
      excluded: 0,
      unreadable: 0,
      unreadable_examples: []
    }

    try do
      {:ok, finish_walk(walk_dirs([""], media_dir, state))}
    catch
      {:walk_error, reason} -> {:error, reason}
    end
  end

  defp walk_dirs([], _media_dir, state), do: state

  defp walk_dirs([rel | stack], media_dir, state) do
    abs = if rel == "", do: media_dir, else: Path.join(media_dir, rel)

    case state.fs.list_dir.(abs) do
      {:ok, names} ->
        {dirs, state} =
          names
          |> Enum.map(&raw_name/1)
          |> Enum.sort()
          |> Enum.reduce({[], state}, &visit(&1, rel, media_dir, &2))

        # Sorted, so the smallest pops first and the plan is deterministic.
        walk_dirs(Enum.sort(dirs) ++ stack, media_dir, state)

      # Vanished since the parent listed it.
      {:error, :enoent} ->
        walk_dirs(stack, media_dir, state)

      {:error, reason} ->
        close_io(state)
        throw({:walk_error, {:list_dir, abs, reason}})
    end
  end

  # `:file.list_dir_all/1` gives a charlist for a name it decoded and a binary
  # for one it could not; both become the bytes tar will be handed.
  defp raw_name(name) when is_binary(name), do: name
  defp raw_name(name) when is_list(name), do: :unicode.characters_to_binary(name)

  defp visit(name, rel, media_dir, {dirs, state}) do
    child = if rel == "", do: name, else: rel <> "/" <> name

    if excluded?(state.matcher, child, name) do
      {dirs, %{state | excluded: state.excluded + 1}}
    else
      case state.fs.lstat.(Path.join(media_dir, child)) do
        {:ok, %{type: :directory}} ->
          {[child | dirs], state}

        {:ok, %{type: type, size: size}} when type in [:regular, :symlink] ->
          {dirs, add_file(state, child, size)}

        # Vanished since the listing.
        {:error, :enoent} ->
          {dirs, state}

        # A name the VM listed but cannot stat cannot be archived: say so.
        {:error, _reason} ->
          {dirs, note_unreadable(state, child)}

        # Sockets, devices.
        _other ->
          {dirs, state}
      end
    end
  end

  @max_examples 5

  defp note_unreadable(state, child) do
    examples =
      if length(state.unreadable_examples) < @max_examples,
        do: [inspect(String.replace_invalid(child)) | state.unreadable_examples],
        else: state.unreadable_examples

    %{state | unreadable: state.unreadable + 1, unreadable_examples: examples}
  end

  defp add_file(state, rel, size) do
    state =
      cond do
        size > state.cap ->
          state |> close_part() |> open_part(true)

        state.count > 0 and state.bytes + size > state.cap ->
          state |> close_part() |> open_part(false)

        state.io == nil ->
          open_part(state, false)

        true ->
          state
      end

    write!(state.io, ["./", rel, 0])
    state = %{state | count: state.count + 1, bytes: state.bytes + size, files: state.files + 1}

    # An oversize part holds exactly its one file.
    if state.oversize, do: close_part(state), else: state
  end

  # `path` is the work dir plus a generated `partNN.list` name.
  # sobelow_skip ["Traversal.FileModule"]
  defp open_part(state, oversize) do
    index = state.index + 1
    path = Path.join(state.work_dir, list_name(index))

    with {:ok, io} <- :file.open(path, [:write, :raw, :binary, :delayed_write]),
         :ok <- chmod_or_close(path, io) do
      %{state | io: io, index: index, count: 0, bytes: 0, oversize: oversize}
    else
      {:error, reason} ->
        throw({:walk_error, {:write_list, path, reason}})
    end
  end

  # `path` is the generated list file opened just above (see `open_part/2`).
  # sobelow_skip ["Traversal.FileModule"]
  defp chmod_or_close(path, io) do
    with {:error, _} = error <- File.chmod(path, 0o600) do
      :file.close(io)
      error
    end
  end

  defp close_part(%{io: nil} = state), do: state

  defp close_part(state) do
    # A delayed_write handle reports a failed flush (ENOSPC, EIO) on close.
    case :file.close(state.io) do
      :ok -> :ok
      {:error, reason} -> throw({:walk_error, {:write_list, reason}})
    end

    part = %{
      index: state.index,
      list: list_name(state.index),
      files: state.count,
      bytes: state.bytes,
      oversize: state.oversize
    }

    %{state | io: nil, parts: [part | state.parts], count: 0, bytes: 0, oversize: false}
  end

  defp close_io(%{io: nil}), do: :ok
  defp close_io(%{io: io}), do: :file.close(io)

  defp finish_walk(state) do
    state = close_part(state)

    state =
      if state.parts == [] do
        # Nothing to archive: one empty part, so a set always has a member.
        state = open_part(state, false)
        close_part(state)
      else
        state
      end

    %{
      state
      | parts: Enum.reverse(state.parts),
        bytes: Enum.sum(Enum.map(state.parts, & &1.bytes))
    }
  end

  defp write!(io, data) do
    case :file.write(io, data) do
      :ok -> :ok
      {:error, reason} -> throw({:walk_error, {:write_list, reason}})
    end
  end

  ## Exclusion globs

  defp compile_globs(globs) do
    for glob <- globs, is_binary(glob), glob = String.trim(glob), glob != "" do
      {String.contains?(glob, "/"), Regex.compile!("\\A" <> glob_source(glob) <> "\\z", "s")}
    end
  end

  defp excluded?([], _rel, _name), do: false

  defp excluded?(matcher, rel, name) do
    Enum.any?(matcher, fn
      {true, regex} -> Regex.match?(regex, rel)
      {false, regex} -> Regex.match?(regex, name)
    end)
  end

  defp glob_source(glob), do: glob |> String.trim_leading("./") |> glob_source("")
  defp glob_source("", acc), do: acc
  defp glob_source("**/" <> rest, acc), do: glob_source(rest, acc <> "(?:.*/)?")
  defp glob_source("**" <> rest, acc), do: glob_source(rest, acc <> ".*")
  defp glob_source("*" <> rest, acc), do: glob_source(rest, acc <> "[^/]*")
  defp glob_source("?" <> rest, acc), do: glob_source(rest, acc <> "[^/]")

  defp glob_source(<<c::utf8, rest::binary>>, acc),
    do: glob_source(rest, acc <> Regex.escape(<<c::utf8>>))

  defp glob_source(<<c, rest::binary>>, acc),
    do: glob_source(rest, acc <> "\\x" <> Base.encode16(<<c>>))

  ## Archiving

  @doc """
  Archive every part of `plan` into `target_dir` (created 0700), in order.

  `opts` as for `archive_part/4`, plus `:reuse`, a function from a plan part to
  `{:ok, finished}` (an already-landed part to keep, e.g. one a resume has
  verified) or `:build`.

  On failure returns `{:error, reason, finished}` with the parts that did land,
  which stay on disk; no `.partial` is left.
  """
  @spec archive(plan(), Path.t(), keyword()) ::
          {:ok, [finished()]} | {:error, term(), [finished()]}
  def archive(plan, target_dir, opts \\ []) do
    reuse = Keyword.get(opts, :reuse, fn _part -> :build end)

    case mkdir_private(target_dir) do
      :ok -> archive_parts(plan.parts, plan, target_dir, opts, reuse, [])
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp archive_parts([], _plan, _target_dir, _opts, _reuse, done), do: {:ok, Enum.reverse(done)}

  defp archive_parts([part | rest], plan, target_dir, opts, reuse, done) do
    result =
      case reuse.(part) do
        {:ok, finished} -> {:ok, finished}
        :build -> archive_part(plan, part.index, target_dir, opts)
      end

    case result do
      {:ok, finished} -> archive_parts(rest, plan, target_dir, opts, reuse, [finished | done])
      {:error, reason} -> {:error, reason, Enum.reverse(done)}
    end
  end

  @doc """
  Archive part `index` of `plan` into `target_dir`; see the moduledoc.

  Options: `:tar` (executable; default the `tar` on `PATH`).

  The result carries the final `name` (from `Artifact.set_names/2`), its `bytes`
  and `sha256` as measured on disk after the rename, `dropped` (list entries
  that had vanished and were left out) and `verified`: `tar -tzf` passed AND
  the size on disk equals the size hashed AND a digest is recorded.
  """
  @spec archive_part(plan(), pos_integer(), Path.t(), keyword()) ::
          {:ok, finished()} | {:error, term()}
  def archive_part(plan, index, target_dir, opts \\ []) do
    part = Enum.find(plan.parts, &(&1.index == index))
    name = plan |> names() |> Enum.at(index - 1)

    with {:ok, part} <- found(part, index),
         {:ok, tar} <- tar_executable(opts),
         :ok <- mkdir_private(target_dir) do
      final = Path.join(target_dir, name)
      build(plan, part, final, tar, name, 1)
    end
  end

  defp found(nil, index), do: {:error, {:no_such_part, index}}
  defp found(part, _index), do: {:ok, part}

  defp tar_executable(opts) do
    case Keyword.get_lazy(opts, :tar, fn -> System.find_executable("tar") end) do
      nil -> {:error, {:missing_executable, "tar"}}
      exe -> {:ok, exe}
    end
  end

  # Attempt 1; on any failure remove the partial and attempt 2 from a freshly
  # filtered copy of the same list. The second failure is the part's error.
  # Every path is the target dir plus a name from `Artifact.set_names/2`, or a
  # generated file in the work dir; none comes from request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp build(plan, part, final, tar, name, attempt) do
    partial = final <> ".partial"
    filtered = Path.join(plan.work_dir, "part#{pad(part.index)}.run.list")

    result =
      with {:ok, kept, dropped} <- filter_list(plan, part, filtered),
           :ok <- run_archive(tar, plan.media_dir, filtered, partial, kept),
           :ok <- run_tar(tar, ["-tzf", partial]),
           :ok <- File.rename(partial, final),
           :ok <- File.chmod(final, 0o600),
           {:ok, sha256, hashed} <- Checksum.file(final),
           {:ok, %{size: size}} <- File.stat(final) do
        {:ok,
         %{
           index: part.index,
           name: name,
           path: final,
           bytes: hashed,
           sha256: sha256,
           oversize: part.oversize,
           files: kept,
           dropped: dropped,
           verified: size == hashed
         }}
      end

    File.rm(partial)
    File.rm(filtered)

    case result do
      {:ok, finished} ->
        {:ok, finished}

      {:error, reason} when attempt == 1 ->
        File.rm(final)

        Logger.warning(
          "Media archive part #{part.index} failed (#{inspect(reason, limit: 5, printable_limit: 200)}); retrying once from a re-filtered list"
        )

        build(plan, part, final, tar, name, 2)

      {:error, _reason} = error ->
        File.rm(final)
        error
    end
  end

  # `partial` is `<target dir>/<generated part name>.partial`.
  # sobelow_skip ["Traversal.FileModule"]
  defp run_archive(_tar, _media_dir, _filtered, partial, 0) do
    # Every listed file vanished (or the tree is empty): a valid empty tarball,
    # written directly because GNU tar refuses to create an empty archive.
    File.write(partial, @empty_tar)
  end

  defp run_archive(tar, media_dir, filtered, partial, _kept) do
    run_tar(tar, ["-czf", partial, "--null", "-C", media_dir, "-T", filtered])
  end

  # Copy the part's list to `filtered`, dropping entries that no longer exist
  # (lstat, so a dangling symlink is still a file to keep).
  # sobelow_skip ["Traversal.FileModule"]
  defp filter_list(plan, part, filtered) do
    source = Path.join(plan.work_dir, part.list)

    with {:ok, out} <- :file.open(filtered, [:write, :raw, :binary, :delayed_write]) do
      File.chmod(filtered, 0o600)

      try do
        case each_entry(source, {0, 0, :ok}, fn entry, {kept, dropped, status} ->
               if status == :ok and present?(plan.media_dir, entry) do
                 {kept + 1, dropped, :file.write(out, [entry, 0])}
               else
                 {kept, dropped + 1, status}
               end
             end) do
          {:error, _} = error ->
            error

          {kept, dropped, :ok} ->
            if dropped > 0 do
              Logger.warning(
                "Media archive part #{part.index}: #{dropped} listed file(s) vanished since planning and were left out"
              )
            end

            {:ok, kept, dropped}

          {_kept, _dropped, {:error, _} = error} ->
            error
        end
      after
        :file.close(out)
      end
    end
  end

  defp present?(media_dir, <<"./", rel::binary>>),
    do: match?({:ok, _}, File.lstat(Path.join(media_dir, rel)))

  defp present?(_media_dir, _entry), do: false

  # Folds `fun` over the NUL-separated entries of `path`, in chunks.
  defp each_entry(path, acc, fun) do
    case :file.open(path, [:read, :raw, :binary, read_ahead: @read_chunk]) do
      {:ok, io} ->
        try do
          read_entries(io, "", acc, fun)
        after
          :file.close(io)
        end

      {:error, _} = error ->
        error
    end
  end

  defp read_entries(io, rest, acc, fun) do
    case :file.read(io, @read_chunk) do
      {:ok, data} ->
        {complete, [tail]} =
          [rest, data]
          |> IO.iodata_to_binary()
          |> :binary.split(<<0>>, [:global])
          |> Enum.split(-1)

        read_entries(io, tail, Enum.reduce(complete, acc, &fold_entry(&1, &2, fun)), fun)

      :eof ->
        if rest == "", do: acc, else: fun.(rest, acc)

      {:error, _} = error ->
        error
    end
  end

  defp fold_entry("", acc, _fun), do: acc
  defp fold_entry(entry, acc, fun), do: fun.(entry, acc)

  # Runs `tar` with stdout and stderr merged, keeping only the tail of its
  # output (a listing of millions of files must not accumulate in the VM).
  #
  # Closing a port does not stop its OS process, so a caller killed mid-run (an
  # Oban timeout or cancel) would leave `tar -czf` writing `<part>.partial` that
  # a Resume then collides with. `ExternalCommand` kills the OS process when
  # the caller dies before tar exits.
  defp run_tar(tar, args) do
    case ExternalCommand.run(tar, args, :infinity, tail: @tail) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:exit_status, "tar", status, Redact.text(output, [], 500)}}
    end
  end

  ## Checksums

  @doc """
  Re-read the finished parts in order, confirm each digest still matches the
  one recorded when it was written, and write the sidecar into `target_dir`.

  Returns the digest and size of all parts concatenated and the sidecar's file
  name. A part that changed since it was hashed, or a failed sidecar write, is
  an error.
  """
  @spec checksum(plan(), [finished()], Path.t()) ::
          {:ok, %{sha256: String.t(), bytes: non_neg_integer(), sidecar: String.t()}}
          | {:error, term()}
  def checksum(plan, finished, target_dir) do
    paths = Enum.map(finished, & &1.path)

    with {:ok, %{files: files, sha256: sha256, bytes: bytes}} <- Checksum.concat(paths),
         :ok <- same_digests(files, finished),
         sidecar = Artifact.sidecar_name(:media, plan.stamp),
         :ok <-
           Checksum.write_sidecar(
             Path.join(target_dir, sidecar),
             Enum.map(finished, &{&1.name, &1.sha256})
           ) do
      {:ok, %{sha256: sha256, bytes: bytes, sidecar: sidecar}}
    end
  end

  defp same_digests(files, finished) do
    changed =
      for {%{sha256: now}, %{sha256: recorded, name: name}} <- Enum.zip(files, finished),
          now != recorded,
          do: name

    case changed do
      [] -> :ok
      names -> {:error, {:checksum_changed, names}}
    end
  end
end
