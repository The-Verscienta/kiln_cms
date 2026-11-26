defmodule KilnCMS.Backups.Verify do
  @moduledoc """
  Re-check a recorded backup's files on this host's disk (#2234), for
  `bin/backup verify` and `mix kiln.backup.verify`.

  Read-only. It hashes, lists and compares; it never writes the run, a
  sidecar, a marker or the manifest, and never sets an artifact's
  `verified` (ADR 0033: only the backup that wrote a file vouches for it).

  ## What is checked, per file of each artifact

    1. Its name. Each file name on the row must be a bare backup file name
       of this run's stamp and the artifact's kind, not a `.partial`, with
       part numbers in list order (`Artifact.parse_file/1`). A name that
       isn't is refused as `:unsafe_name` before any path is built from it.
    2. That it is here: a regular file (`lstat`, so a symlink is
       `:not_regular`). An absent file is skipped when the run says why it
       is gone, judged per part: its own `"local"` destination marked
       `"pruned"`, a copy that reached an off-site destination (never
       fetched), or cron's prune by the same judgment the History page makes
       (`KilnCMS.Backups.DiskView`, `:expired` / `:probably_expired`).
       Otherwise it is `:missing`.
    3. Its SHA-256 and size against the row's (`Checksum.concat/1`, one pass);
       for a media set whose every part is here, the set digest too. A row
       with no digest (a cron backup imported without one) is checked against
       the sidecar instead; with neither, the file fails as `:no_digest`.
    4. The sidecar (`kiln-<kind>-<stamp>.sha256`) against the row's digests
       (`Checksum.check_sidecar/2`).
    5. A dump whose digest matched: `pg_restore --list`, so its table of
       contents still reads. A missing `pg_restore` is a failure
       (`:pg_restore_missing`), not a pass.

  `verified` is true only when at least one file was hashed and nothing
  failed: a run whose files are all skipped (pruned, off-site only) is not
  verified here.
  """

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Checksum, Command, DirId, DiskView, Run, WorkState}

  @type result :: :ok | :failed | :skipped

  @type check :: %{
          kind: :db | :media,
          file: String.t(),
          check: :name | :present | :sha256 | :set_sha256 | :sidecar | :pg_restore,
          result: result(),
          code: atom() | nil,
          detail: String.t()
        }

  @type report :: %{
          verified: boolean(),
          hashed: non_neg_integer(),
          failed: non_neg_integer(),
          checks: [check()],
          artifacts: [
            %{
              kind: :db | :media,
              name: String.t(),
              recorded_verified: boolean(),
              result: result()
            }
          ],
          dir_id_mismatch: boolean()
        }

  @doc """
  Verify `run`'s files under the backup directory.

  Options: `:dir` (default `KilnCMS.Backups.dir/0`), `:pg_restore` (the
  executable, default `"pg_restore"`), `:now`, `:cron_prunes` (as
  `KilnCMS.Backups.DiskView.read/4` takes it, default `nil`) and
  `:in_flight` (what the backup lock holds, default
  `KilnCMS.Backups.in_flight/0`).

  `{:ok, report}`, or `{:error, reason}`: `:in_progress` (the run is still
  running, or the lock holds its stamp) or `:invalid_stamp`.
  """
  @spec run(Run.t(), keyword()) :: {:ok, report()} | {:error, :in_progress | :invalid_stamp}
  def run(%Run{} = run, opts \\ []) do
    dir = Keyword.get_lazy(opts, :dir, &Backups.dir/0)

    with :ok <- valid_stamp(run),
         :ok <- not_in_progress(run, opts) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      view = DiskView.read(dir, [run], now, cron_prunes: Keyword.get(opts, :cron_prunes))
      presence = Map.get(view.presence, run.id, %{artifacts: []})
      mismatch? = dir_id_mismatch?(run, dir)

      ctx = %{
        dir: dir,
        run: run,
        pg_restore: Keyword.get(opts, :pg_restore, "pg_restore"),
        mismatch?: mismatch?
      }

      judged =
        run.artifacts
        |> Enum.with_index()
        |> Enum.map(fn {artifact, index} ->
          state = presence.artifacts |> Enum.at(index, %{}) |> Map.get(:state)
          {artifact, artifact(artifact, state, ctx)}
        end)

      {:ok, report(judged, mismatch?)}
    end
  end

  defp valid_stamp(%Run{stamp: stamp}),
    do: if(WorkState.valid_stamp?(stamp), do: :ok, else: {:error, :invalid_stamp})

  defp not_in_progress(%Run{status: :running}, _opts), do: {:error, :in_progress}

  defp not_in_progress(%Run{stamp: stamp}, opts) do
    case Keyword.get_lazy(opts, :in_flight, &Backups.in_flight/0) do
      %{stamp: ^stamp} -> {:error, :in_progress}
      _other -> :ok
    end
  end

  defp dir_id_mismatch?(%Run{dir_id: nil}, _dir), do: false

  defp dir_id_mismatch?(%Run{dir_id: dir_id}, dir) do
    case DirId.current(dir) do
      {:ok, ^dir_id} -> false
      _other -> true
    end
  end

  defp report(judged, mismatch?) do
    checks = Enum.flat_map(judged, fn {_artifact, checks} -> checks end)
    failed = Enum.count(checks, &(&1.result == :failed))
    hashed = Enum.count(checks, &(&1.check == :sha256 and &1.result == :ok))

    %{
      verified: failed == 0 and hashed > 0,
      hashed: hashed,
      failed: failed,
      checks: checks,
      artifacts:
        Enum.map(judged, fn {artifact, checks} ->
          %{
            kind: artifact.kind,
            name: artifact.name,
            recorded_verified: artifact.verified == true,
            result: overall(checks)
          }
        end),
      dir_id_mismatch: mismatch?
    }
  end

  defp overall(checks) do
    cond do
      Enum.any?(checks, &(&1.result == :failed)) -> :failed
      Enum.any?(checks, &(&1.check == :sha256 and &1.result == :ok)) -> :ok
      true -> :skipped
    end
  end

  ## One artifact

  defp artifact(%Artifact{} = artifact, state, ctx) do
    case files(artifact, ctx.run.stamp) do
      {:ok, files} -> check_files(artifact, files, state, ctx)
      {:error, detail} -> [check(artifact, artifact.name, :name, :failed, :unsafe_name, detail)]
    end
  end

  # `[%{name, sha256, bytes, destinations}]` in order, once every name on the
  # row is a bare file name of this run's stamp and this artifact's kind, not
  # a `.partial`, with part numbers in list order. Only names that pass are
  # ever joined to a path.
  defp files(%Artifact{parts: [_ | _] = parts} = artifact, stamp) do
    total = length(parts)

    parts
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {part, index}, {:ok, acc} ->
      name = if is_map(part), do: field(part, "name")

      case safe_name(name, stamp, artifact.kind, index, total) do
        :ok -> {:cont, {:ok, [part_file(part, name, artifact) | acc]}}
        {:error, _detail} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp files(%Artifact{} = artifact, stamp) do
    with :ok <- safe_name(artifact.name, stamp, artifact.kind, nil, 1) do
      {:ok,
       [
         %{
           name: artifact.name,
           sha256: digest(artifact.sha256),
           bytes: artifact.bytes,
           destinations: artifact.destinations
         }
       ]}
    end
  end

  defp part_file(part, name, artifact) do
    %{
      name: name,
      sha256: digest(field(part, "sha256")),
      bytes: field(part, "bytes"),
      destinations: field(part, "destinations") || artifact.destinations
    }
  end

  # A part map's field, string-keyed as stored, atom-keyed as built in code.
  defp field(part, "name"), do: part["name"] || part[:name]
  defp field(part, "sha256"), do: part["sha256"] || part[:sha256]
  defp field(part, "bytes"), do: part["bytes"] || part[:bytes]
  defp field(part, "destinations"), do: part["destinations"] || part[:destinations]

  defp safe_name(name, stamp, kind, index, total) when is_binary(name) do
    with true <- Path.basename(name) == name,
         {:ok, %{stamp: ^stamp, kind: ^kind, partial?: false, part: part}} <-
           Artifact.parse_file(name),
         true <- part_in_order?(part, index, total) do
      :ok
    else
      _ -> {:error, "#{inspect(name)} is not a file name of this backup; nothing was read"}
    end
  end

  defp safe_name(name, _stamp, _kind, _index, _total),
    do: {:error, "a file of this backup has no usable name (#{inspect(name)}); nothing was read"}

  # A single file has no part number; a set's parts count 1..n in list order,
  # and a set of one may keep the legacy single-file name.
  defp part_in_order?(nil, nil, 1), do: true
  defp part_in_order?(nil, 1, 1), do: true
  defp part_in_order?(part, index, _total) when is_integer(index), do: part == index
  defp part_in_order?(_part, _index, _total), do: false

  defp digest(hex) when is_binary(hex) do
    if hex =~ ~r/\A[0-9a-fA-F]{64}\z/, do: String.downcase(hex)
  end

  defp digest(_other), do: nil

  defp check_files(artifact, files, state, ctx) do
    sub = Path.join(ctx.dir, Artifact.subdir(artifact.kind))
    {here, absent_checks} = locate(artifact, files, state, sub, ctx)

    if here == [] do
      absent_checks
    else
      expected = expected_digests(artifact, files, sub)
      {hashed, _set_sha256} = hashing = hash(artifact, here, expected, sub)

      absent_checks ++
        hashed ++
        set_check(artifact, files, here, hashing) ++
        sidecar_check(artifact, files, expected, sub) ++
        pg_restore_check(artifact, here, hashed, sub, ctx)
    end
  end

  # The files that are here (regular, by `lstat`), and a check for each one
  # that isn't.
  # sobelow_skip ["Traversal.FileModule"]
  defp locate(artifact, files, state, sub, ctx) do
    Enum.reduce(files, {[], []}, fn file, {here, checks} ->
      case File.lstat(Path.join(sub, file.name)) do
        {:ok, %File.Stat{type: :regular}} ->
          {[file | here], checks}

        {:ok, %File.Stat{type: type}} ->
          detail = "#{file.name} is a #{type}, not a regular file"
          {here, [check(artifact, file.name, :present, :failed, :not_regular, detail) | checks]}

        {:error, :enoent} ->
          {here, [absent(artifact, file, state, ctx) | checks]}

        {:error, reason} ->
          detail = "couldn't read #{file.name} (#{inspect(reason)})"
          {here, [check(artifact, file.name, :present, :failed, :unreadable, detail) | checks]}
      end
    end)
    |> then(fn {here, checks} -> {Enum.reverse(here), Enum.reverse(checks)} end)
  end

  # Why an absent file is gone, per part: its own `"local"` marker, an
  # off-site copy, or cron's prune as the History page judges it.
  defp absent(artifact, file, state, ctx) do
    cond do
      local_status(file.destinations) == "pruned" ->
        skipped(artifact, file, :pruned, "pruned here by retention")

      off_site?(file.destinations) ->
        skipped(artifact, file, :off_site_only, "off-site only (not fetched)")

      state in [:expired, :probably_expired] ->
        skipped(artifact, file, state, "removed by the cron prune (#{state})")

      ctx.mismatch? ->
        detail =
          "#{file.name} is missing: this run's files are in another node's backup " <>
            "directory (#{ctx.run.dir_id})"

        check(artifact, file.name, :present, :failed, :missing, detail)

      true ->
        check(artifact, file.name, :present, :failed, :missing, "#{file.name} is missing")
    end
  end

  defp skipped(artifact, file, code, detail),
    do: check(artifact, file.name, :present, :skipped, code, detail)

  defp local_status(%{"local" => %{"status" => status}}), do: status
  defp local_status(_destinations), do: nil

  defp off_site?(destinations) when is_map(destinations) do
    Enum.any?(destinations, fn
      {"local", _local} -> false
      {key, %{"status" => "ok"}} when is_binary(key) -> true
      _other -> false
    end)
  end

  defp off_site?(_destinations), do: false

  # `{:recorded, %{name => hex}}` when the row has every file's digest, else
  # the sidecar's (`{:sidecar, ...}`), else `:none`.
  defp expected_digests(artifact, files, sub) do
    if Enum.all?(files, &is_binary(&1.sha256)) do
      {:recorded, Map.new(files, &{&1.name, &1.sha256})}
    else
      case read_sidecar(artifact, sub) do
        {:ok, entries} -> {:sidecar, Map.new(entries, fn {hex, name} -> {name, hex} end)}
        _none -> :none
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_sidecar(artifact, sub) do
    path = sidecar_path(artifact, sub)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> Checksum.parse_sidecar(path)
      {:ok, _other} -> {:error, :not_regular}
      {:error, _} = error -> error
    end
  end

  defp sidecar_path(artifact, sub) do
    stamp = artifact_stamp(artifact)
    Path.join(sub, Artifact.sidecar_name(artifact.kind, stamp))
  end

  # The stamp a validated file name carries (every file of an artifact has
  # the run's stamp, `files/2` checked).
  defp artifact_stamp(artifact) do
    [name | _] = Artifact.files(artifact)
    {:ok, %{stamp: stamp}} = Artifact.parse_file(name)
    stamp
  end

  defp hash(artifact, here, expected, sub) do
    paths = Enum.map(here, &Path.join(sub, &1.name))

    case Checksum.concat(paths) do
      {:ok, %{files: hashed, sha256: set_sha256}} ->
        checks =
          here
          |> Enum.zip(hashed)
          |> Enum.map(fn {file, found} -> compare(artifact, file, found, expected) end)

        {checks, set_sha256}

      {:error, reason} ->
        checks =
          for file <- here do
            detail = "couldn't hash #{file.name} (#{inspect(reason)})"
            check(artifact, file.name, :sha256, :failed, :unreadable, detail)
          end

        {checks, nil}
    end
  end

  defp compare(artifact, file, _found, :none) do
    detail = "#{file.name} has no digest on record and no sidecar: nothing to check it against"
    check(artifact, file.name, :sha256, :failed, :no_digest, detail)
  end

  defp compare(artifact, file, found, {source, digests}) do
    case Map.get(digests, file.name) do
      nil ->
        detail = "#{file.name} is not in the sidecar, and the run has no digest for it"
        check(artifact, file.name, :sha256, :failed, :no_digest, detail)

      hex ->
        bytes_ok? = source == :sidecar or not is_integer(file.bytes) or file.bytes == found.bytes

        if Plug.Crypto.secure_compare(found.sha256, hex) and bytes_ok? do
          check(artifact, file.name, :sha256, :ok, nil, matched(source))
        else
          detail =
            "#{file.name} changed: expected sha256 #{hex}#{bytes(file.bytes, source)}, " <>
              "found #{found.sha256} (#{found.bytes} bytes)"

          check(artifact, file.name, :sha256, :failed, :changed, detail)
        end
    end
  end

  defp matched(:recorded), do: "matches the digest the backup recorded"
  defp matched(:sidecar), do: "matches the sidecar (the run recorded no digest)"

  defp bytes(bytes, :recorded) when is_integer(bytes), do: " (#{bytes} bytes)"
  defp bytes(_bytes, _source), do: ""

  # A media set's own digest, the parts' bytes in order (what `concat/1`
  # folded while it hashed them), once every part is here and each matched.
  defp set_check(%Artifact{parts: [_ | _]} = artifact, files, here, {hashed, set_sha256}) do
    expected = digest(artifact.sha256)

    cond do
      length(here) != length(files) or Enum.any?(hashed, &(&1.result != :ok)) ->
        []

      is_nil(expected) or is_nil(set_sha256) ->
        []

      Plug.Crypto.secure_compare(set_sha256, expected) ->
        [
          check(
            artifact,
            artifact.name,
            :set_sha256,
            :ok,
            nil,
            "the parts in order match the set's digest"
          )
        ]

      true ->
        detail =
          "the parts in order hash to #{set_sha256}, not the set's recorded #{expected}"

        [check(artifact, artifact.name, :set_sha256, :failed, :changed, detail)]
    end
  end

  defp set_check(_artifact, _files, _here, _hashed), do: []

  defp sidecar_check(_artifact, _files, :none, _sub), do: []
  defp sidecar_check(_artifact, _files, {:sidecar, _digests}, _sub), do: []

  # sobelow_skip ["Traversal.FileModule"]
  defp sidecar_check(artifact, files, {:recorded, digests}, sub) do
    path = sidecar_path(artifact, sub)
    name = Path.basename(path)
    entries = Enum.map(files, &{&1.name, Map.fetch!(digests, &1.name)})

    case Checksum.check_sidecar(path, entries) do
      :ok ->
        [check(artifact, name, :sidecar, :ok, nil, "lists the recorded digests")]

      {:error, :enoent} ->
        [check(artifact, name, :sidecar, :failed, :sidecar_missing, "#{name} is missing")]

      {:error, :sidecar_changed} ->
        detail = "#{name} no longer lists the digests the backup recorded"
        [check(artifact, name, :sidecar, :failed, :sidecar_changed, detail)]

      {:error, :malformed} ->
        [check(artifact, name, :sidecar, :failed, :sidecar_malformed, "#{name} can't be read")]

      {:error, :not_regular} ->
        detail = "#{name} is not a regular file"
        [check(artifact, name, :sidecar, :failed, :not_regular, detail)]

      {:error, reason} ->
        detail = "couldn't read #{name} (#{inspect(reason)})"
        [check(artifact, name, :sidecar, :failed, :unreadable, detail)]
    end
  end

  # Only a dump whose digest matched: listing a changed one proves nothing.
  defp pg_restore_check(%Artifact{kind: :db} = artifact, [file], [%{result: :ok}], sub, ctx) do
    case Command.cmd(ctx.pg_restore, ["--list", Path.join(sub, file.name)]) do
      :ok ->
        [check(artifact, file.name, :pg_restore, :ok, nil, "pg_restore --list reads it")]

      {:error, {_exe, :enoent}} ->
        detail =
          "the digest matched, but pg_restore is not installed here, so the dump's " <>
            "table of contents was not listed"

        [check(artifact, file.name, :pg_restore, :failed, :pg_restore_missing, detail)]

      {:error, {:exit_status, _exe, status, output}} ->
        detail = "pg_restore --list exited #{inspect(status)}: #{output}"
        [check(artifact, file.name, :pg_restore, :failed, :pg_restore_list, detail)]
    end
  end

  defp pg_restore_check(_artifact, _here, _hashed, _sub, _ctx), do: []

  defp check(artifact, file, check, result, code, detail),
    do: %{
      kind: artifact.kind,
      file: file,
      check: check,
      result: result,
      code: code,
      detail: detail
    }
end
