defmodule KilnCMS.Backups.Importer do
  @moduledoc """
  Turns backups this application did not record into `KilnCMS.Backups.Run` rows
  (#2217), so the history shows cron-made backups next to app-made ones.

  ## The files are the truth; the manifest only enriches

  `scripts/backup.sh` writes `kiln-db-<stamp>.dump` / `kiln-media-<stamp>.tar.gz`
  under `db/` and `media/`, and a `manifest.json` that describes only the LAST
  run (and only for `all`). So the importer scans the two directories, groups
  files by the stamp in their names, and creates one run per stamp. The manifest
  is consulted for a stamp only when its artifact paths carry that stamp: then
  its trigger, outcome, error, times, `verified` flags and off-site remote are
  used. A failed manifest with no stamped files at all becomes a `failed` run
  keyed by its `"stamp"` (`KilnCMS.Backups.Manifest`), or by the stamp of its
  `started_at` in a manifest without one.

  ## What an imported run is

  `origin: :imported`, trigger `"cron"` unless a manifest says otherwise,
  `verified: false` (nothing is hashed or verified on import; a `sha256` is
  recorded only when the manifest or the stamp's checksum sidecar supplies one),
  `succeeded` unless a file is zero bytes (`failed`, "empty artifact").
  `started_at` is the stamp read as UTC; `finished_at` is the newest file's
  mtime. Components are inferred from the files.

  ## Safe to run at any time

    * **Idempotent.** Existing stamps come from one `select stamp` query and a
      set difference; only new stamps are stat'ed. The write is an upsert that
      does nothing on a conflicting stamp, so a run the application owns (still
      `running`, or finished) or a previous import is never modified, and two
      concurrent calls cannot double-insert.
    * **Settled.** A stamp with no covering manifest and no `.partial` is left
      for a later call until its newest file is at least #{10} minutes old, so
      a cron run still writing is not recorded half-done. A stamp WITH a
      `.partial` (of any kind, a checksum sidecar's or the media marker's
      included) is pending while the newest of all its files, partial or
      finished, in `db/` and `media/`, is younger than
      `interrupted_after_s/0`; after that it is a killed run (#2478, below).
    * **Bounded.** It lists two directories and stats files of new stamps only;
      it never walks the tree or reads a file's contents. A directory with
      thousands of backups costs one listing plus one insert per new stamp.
    * **Total.** A missing directory is "nothing to import"; an unreadable one
      is `{:error, _}`. Nothing raises, so it is safe inside `start_async` and
      at the tail of the worker. A file named like an artifact that is a
      directory or symlink, or a stamp that is not a real instant, is skipped.
    * **Independent** of `BACKUP_ENABLED` and of `pg_dump` being installed.

  Runs as `KilnCMS.Backups.system/0` and fails closed: with the grant revoked it
  reports `{:error, _}` and writes nothing.

  ## Media part sets (#2218)

  The `kiln-media-<stamp>.partNN.tar.gz` files of one stamp are ONE artifact
  (`Artifact.group_files/1`): logical name `kiln-media-<stamp>`, `parts` in
  numeric order, `bytes` summed. A set with a gap (`part03` missing) is imported
  as a `failed` run, "incomplete media set: missing part03", because a restore
  from it would silently lack files; so is a stamp carrying both a legacy single
  archive and parts, and so are parts with no media sidecar, "incomplete media
  set: parts but no sidecar": every part set is written with one, so parts
  without it are what a run killed mid-set leaves (`restore.sh` and
  `backup.sh verify` refuse such a set too). A manifest calling the parts
  verified does not stand in for the sidecar. A legacy single archive without
  a sidecar (from before checksums) imports as before. A `.partNN…partial`
  holds the stamp like any other partial. A set whose run was killed while its
  `.partial` marker was still there is "Interrupted" (above); one whose marker
  went before the stamp was read (the marker sync off, or the node down for
  half a day) shows what is left: parts but no sidecar.

  ## A run killed outright (#2478)

  `kill -9`, the OOM killer or a power cut leaves a cron run's `.partial`
  files behind: no trap runs. `backup.sh` touches every `.partial` of its stamp
  every five minutes for as long as it lives, so a stamp whose newest file is
  three hours old (36 missed touches, and room for clocks that disagree) has
  no writer. It becomes a `failed` run, "Interrupted: the backup stopped
  before it finished and left .partial files behind", with the finished files
  it has as artifacts (none at all when only partials are left), the kinds of
  its finished files and its partials as components, and a log entry naming
  the partials. Such a row is never rewritten, which is
  why the wait is long: a mislabel would be permanent, a late one only leaves
  the stamp out of the history a little longer. A covering manifest still
  wins, and a stamp that has a row (the application's own runs) is never
  looked at. An mtime more than five minutes in the future reads as fresh,
  with a warning: a clock that is off must not turn a live run into a dead
  one. `backup.sh prune` removes the partials only once every file of the
  stamp is four times older than this (`ABANDONED_PARTIAL_MIN`), and the
  application's start step only once the stamp has a row, so the stamp is
  always read before its evidence goes.

  `kiln-<kind>-<stamp>.sha256` sidecars are not artifacts and never make a run
  by themselves, but are accounted for by their stamp: a well-formed one
  (`Checksum.parse_sidecar/1`) supplies the per-file `sha256` of the imported
  artifact; a malformed or oversized one is ignored with a warning.

  Separate cron entries (`backup.sh db`, then `backup.sh media`) have different
  stamps, so they become two runs.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Checksum, Manifest}

  require Logger

  @settle_ms :timer.minutes(10)
  @interrupted_after_s 3 * 3600
  @future_slack_s 300
  @interrupted "Interrupted: the backup stopped before it finished and left .partial files behind"
  @logged_partials 5
  @max_trigger 64
  @max_sidecar_bytes 4 * 1024 * 1024
  @sidecar ~r/\Akiln-(db|media)-(\d{8}-\d{6})\.sha256(\.partial)?\z/

  @type summary :: %{
          imported: non_neg_integer(),
          pending: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc """
  Import every backup found on disk that has no run yet.

  Returns `{:ok, summary}` — `imported` rows written (a concurrent call may
  have written the same stamp, in which case the write was a no-op but is still
  counted), `pending` stamps waiting out the settle window, `skipped` stamps
  that cannot be represented (impossible date), `failed` rows whose write
  errored — or `{:error, reason}` when the directory cannot be listed or the
  runs cannot be read.
  """
  @spec run() :: {:ok, summary()} | {:error, term()}
  def run, do: run(Backups.dir())

  @doc """
  How long, in seconds, a stamp with a `.partial` beside it must have been
  quiet (the newest of all its files, partial or finished) before it is
  recorded as an interrupted run. `scripts/backup.sh` keeps its partials
  fresh far inside this, and prunes them only well after it (#2478).
  """
  @spec interrupted_after_s() :: pos_integer()
  def interrupted_after_s, do: @interrupted_after_s

  @doc false
  # `list` is `list/1` outside tests, which pass one that changes the
  # directory between the listing and the stat.
  @spec run(Path.t(), (Path.t() -> {:ok, [{String.t(), String.t()}]} | {:error, term()})) ::
          {:ok, summary()} | {:error, term()}
  def run(dir, list \\ &list/1) do
    reconcile_stale_runs()

    with {:ok, names} <- list.(dir),
         {:ok, existing} <- existing_stamps() do
      import_new(dir, names, existing)
    end
  rescue
    error ->
      Logger.warning("Backup import crashed: #{Exception.message(error)}")
      {:error, {:crashed, error.__struct__}}
  end

  # Fail stale `running` runs first, so a killed worker's stamp reads as failed
  # rather than running. The sweep raises on a revoked grant; this boundary
  # downgrades that to a warning, and the read below then fails closed.
  defp reconcile_stale_runs do
    Backups.reconcile_stale_runs()
  rescue
    error -> Logger.warning("Couldn't sweep stale backup runs: #{Exception.message(error)}")
  end

  defp existing_stamps do
    case Backups.list_runs(
           query: [select: [:stamp]],
           actor: Backups.system(),
           authorize_with: :error
         ) do
      {:ok, runs} -> {:ok, MapSet.new(runs, & &1.stamp)}
      {:error, error} -> {:error, {:read_runs, error.__struct__}}
    end
  end

  # `%{stamp => [%{kind, name, partial?}]}` from names alone — no stat yet. A
  # missing subdirectory is an empty one (S3 deployments have no `media/`); any
  # other failure aborts, since a half-seen stamp would be recorded wrong forever.
  @doc false
  # The `{sub, name}` entries of `db/` and `media/`, for `classify/1`.
  @spec list(Path.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def list(dir) do
    Enum.reduce_while(["db", "media"], {:ok, []}, fn sub, {:ok, acc} ->
      case File.ls(Path.join(dir, sub)) do
        {:ok, names} ->
          {:cont, {:ok, acc ++ Enum.map(names, &{sub, &1})}}

        {:error, :enoent} ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          Logger.warning("Couldn't list #{sub}/ in the backup directory: #{inspect(reason)}")
          {:halt, {:error, {:ls, sub, reason}}}
      end
    end)
  end

  defp import_new(dir, listed, existing) do
    manifest = Manifest.read(dir)

    {files, partials, sidecars} = classify(listed)

    {valid, invalid} =
      files
      |> Map.keys()
      |> Enum.split_with(&real_stamp?/1)

    for stamp <- invalid,
        do: Logger.warning("Skipping a backup with an impossible stamp: #{stamp}")

    covered = covered_stamps(manifest)
    manifest_only = failed_manifest_attrs(manifest, existing, files)

    # A stamp with only partials is a candidate too (a run killed in its first
    # file), unless the failed manifest already speaks for it. One whose stamp
    # is no real instant is ignored silently: it would warn every slot.
    partial_only =
      for stamp <- Map.keys(partials),
          not Map.has_key?(files, stamp),
          real_stamp?(stamp),
          not Enum.any?(manifest_only, &(&1.stamp == stamp)),
          do: stamp

    new = (valid ++ partial_only) |> Enum.reject(&MapSet.member?(existing, &1)) |> Enum.sort()
    now = System.os_time(:second)

    {ready, pending} =
      new
      |> Enum.map(&entry(dir, &1, Map.get(files, &1, []), Map.get(partials, &1, [])))
      |> Enum.reject(&(&1.files == [] and &1.partials == []))
      |> Enum.map(&Map.put(&1, :state, settle(&1, covered, now)))
      |> Enum.split_with(&(&1.state != :pending))

    warn_future(pending, now)

    attrs = Enum.map(ready, &run_attrs(&1, manifest, covered, dir, sidecars, now))

    results = Enum.map(attrs ++ manifest_only, &import_one/1)

    {:ok,
     %{
       imported: Enum.count(results, &(&1 == :ok)),
       pending: length(pending),
       skipped: length(invalid),
       failed: Enum.count(results, &(&1 == :error))
     }}
  end

  defp real_stamp?(stamp), do: match?({:ok, _}, Artifact.parse_stamp(stamp))

  @doc false
  # `{files, partials, sidecars}` from `list/1`'s entries: artifact names
  # grouped by stamp (`%{stamp => [{kind, name, part}]}`, each in the
  # directory its kind lives in), the `.partial` files of each stamp
  # (`%{stamp => [{sub, name}]}`, of any kind and in either directory: an
  # artifact's, a part's, a checksum sidecar's, the media marker), and the
  # checksum sidecars (`%{stamp => [{kind, name}]}`). The application's
  # partial sweep reads the same grouping, so the two can't disagree on which
  # stamp a file belongs to. A `.partial` named like neither is in none.
  @spec classify([{String.t(), String.t()}]) :: {map(), map(), map()}
  def classify(listed) do
    Enum.reduce(listed, {%{}, %{}, %{}}, fn {sub, name}, {files, partials, sidecars} ->
      case Artifact.parse_file(name) do
        {:ok, %{partial?: false} = parsed} ->
          {add_file(files, sub, parsed, name), partials, sidecars}

        {:ok, %{stamp: stamp, partial?: true}} ->
          {files, add_partial(partials, stamp, sub, name), sidecars}

        :error ->
          classify_sidecar(sub, name, files, partials, sidecars)
      end
    end)
  end

  defp add_partial(partials, stamp, sub, name),
    do: Map.update(partials, stamp, [{sub, name}], &[{sub, name} | &1])

  defp classify_sidecar(sub, name, files, partials, sidecars) do
    case Regex.run(@sidecar, name) do
      [_, _kind, stamp, ".partial"] ->
        {files, add_partial(partials, stamp, sub, name), sidecars}

      [_, kind, stamp] ->
        kind = String.to_existing_atom(kind)

        if Artifact.subdir(kind) == sub,
          do:
            {files, partials, Map.update(sidecars, stamp, [{kind, name}], &[{kind, name} | &1])},
          else: {files, partials, sidecars}

      _ ->
        {files, partials, sidecars}
    end
  end

  # A file only counts in the directory its kind lives in.
  defp add_file(files, sub, %{kind: kind, stamp: stamp, part: part}, name) do
    if Artifact.subdir(kind) == sub,
      do: Map.update(files, stamp, [{kind, name, part}], &[{kind, name, part} | &1]),
      else: files
  end

  # Stat (lstat: a symlink or directory named like an artifact is not one) only
  # the files of a stamp we are about to create. `held?` is whether any
  # `.partial` is named beside the stamp; `partials` are the regular ones,
  # which date it. `vanished?` is whether a listed `.partial` was gone by the
  # time it was stat'ed: a run renaming its partials into place as it
  # finishes, whose stamp can't be judged from this listing.
  defp entry(dir, stamp, names, partial_names) do
    files =
      for {kind, name, part} <- names,
          path = Path.join([dir, Artifact.subdir(kind), name]),
          {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
            [File.lstat(path, time: :posix)] do
        %{kind: kind, name: name, bytes: size, mtime: mtime, part: part}
      end

    stats =
      for {sub, name} <- partial_names,
          do: {name, File.lstat(Path.join([dir, sub, name]), time: :posix)}

    partials =
      for {name, {:ok, %File.Stat{type: :regular, mtime: mtime}}} <- stats do
        %{kind: partial_kind(name), name: name, mtime: mtime}
      end

    %{
      stamp: stamp,
      files: Enum.sort_by(files, &{&1.kind, &1.part || 0}),
      partials: Enum.sort_by(partials, & &1.name),
      held?: partial_names != [],
      vanished?: Enum.any?(stats, &match?({_, {:error, :enoent}}, &1))
    }
  end

  defp partial_kind("kiln-db-" <> _), do: :db
  defp partial_kind("kiln-media-" <> _), do: :media

  # `:ready` (import it), `:interrupted` (import it as a killed run) or
  # `:pending` (look again later). A stamp one of whose partials vanished
  # between the listing and the stat is pending this call: dated by what is
  # left, a run that just finished could be recorded as interrupted, and that
  # row is never rewritten.
  defp settle(%{stamp: stamp} = entry, covered, now) do
    cond do
      MapSet.member?(covered, stamp) -> :ready
      entry.vanished? -> :pending
      not entry.held? -> if old_enough?(entry.files, now), do: :ready, else: :pending
      future?(entry, now) -> :pending
      now - newest(entry) >= @interrupted_after_s -> :interrupted
      true -> :pending
    end
  end

  defp old_enough?(files, now), do: (now - newest_of(files)) * 1000 >= @settle_ms

  # The newest mtime of every file of the stamp, partial or finished.
  defp newest(entry), do: newest_of(entry.files ++ entry.partials)

  defp newest_of(files), do: files |> Enum.map(& &1.mtime) |> Enum.max()

  defp future?(entry, now), do: newest(entry) > now + @future_slack_s

  # Once per call, not per stamp: a skewed clock would otherwise flood the log
  # every slot.
  defp warn_future(pending, now) do
    case Enum.filter(pending, &(&1.held? and future?(&1, now))) do
      [] ->
        :ok

      skewed ->
        Logger.warning(
          "Backup files dated in the future (#{Enum.map_join(skewed, ", ", & &1.stamp)}): " <>
            "kept pending, as if still being written; check the clocks of this node and " <>
            "of the backup directory's file server"
        )
    end
  end

  # The stamps the manifest speaks for: those its artifact paths carry.
  defp covered_stamps(nil), do: MapSet.new()

  defp covered_stamps(%Manifest{} = manifest) do
    manifest.artifacts
    |> Enum.flat_map(fn artifact ->
      case Artifact.parse_file(Path.basename(artifact.path)) do
        {:ok, %{stamp: stamp, partial?: false}} -> [stamp]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp run_attrs(%{stamp: stamp, files: files} = entry, manifest, covered, dir, sidecars, now) do
    {:ok, started_at} = Artifact.parse_stamp(stamp)
    finished_at = entry |> newest() |> DateTime.from_unix!()
    manifest = if MapSet.member?(covered, stamp), do: manifest
    interrupted? = entry.state == :interrupted

    empty? = Enum.any?(files, &(&1.bytes == 0))
    problem = media_problem(files, media_sidecar?(sidecars, stamp))

    {status, error} = outcome(interrupted?, manifest, problem, empty?)

    digests = digests(dir, stamp, sidecars)

    %{
      stamp: stamp,
      trigger: trigger(manifest),
      status: status,
      # The partials' kinds too: a run killed with nothing finished still
      # names what it was backing up. (`Backups.newest_attempt/1` counts an
      # imported failure against every component regardless: a cron `all`
      # killed in its db phase would have done media as well.)
      components: (files ++ entry.partials) |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort(),
      started_at: (manifest && manifest.started_at) || started_at,
      finished_at: (manifest && manifest.finished_at) || finished_at,
      error: error,
      log: [
        %{
          level: :info,
          step: "import",
          message: "Found in the backup directory; this application did not record the run"
        }
        | interrupted_log(interrupted?, entry.partials, now)
      ],
      artifacts:
        files |> Enum.map(&artifact_attrs(&1, manifest, digests)) |> Artifact.group_files()
    }
  end

  defp outcome(true, _manifest, _problem, _empty?), do: {:failed, @interrupted}
  defp outcome(_, %Manifest{ok: false, error: error}, _problem, _empty?), do: {:failed, error}
  defp outcome(_, _manifest, problem, _empty?) when is_binary(problem), do: {:failed, problem}
  defp outcome(_, _manifest, _problem, true), do: {:failed, "empty artifact"}
  defp outcome(_, _manifest, _problem, _empty?), do: {:succeeded, nil}

  defp interrupted_log(false, _partials, _now), do: []

  defp interrupted_log(true, partials, now) do
    named =
      partials
      |> Enum.take(@logged_partials)
      |> Enum.map_join(", ", &"#{&1.name} (#{div(now - &1.mtime, 60)} min old)")

    more = length(partials) - @logged_partials
    more = if more > 0, do: " and #{more} more", else: ""

    [
      %{
        level: :error,
        step: "import",
        message: "No backup has written to this stamp for hours; left behind: #{named}#{more}"
      }
    ]
  end

  # What is wrong with the media files of a stamp, or `nil`: parts that don't
  # run 1..N, a legacy single archive sitting beside parts, or parts with no
  # sidecar. Every part set is written with a sidecar (one part keeps the legacy
  # name), by the app and by `backup.sh` alike, so parts without one are what a
  # run killed mid-set leaves once its `.partial` marker went before the stamp
  # was read (with the marker there it is "Interrupted"); a manifest
  # does not excuse it, since `restore.sh` refuses such a set too. A legacy
  # single archive without one is a pre-checksum backup and stays fine. Part
  # numbers are unique per stamp (one file name each), so there is no duplicate
  # to resolve.
  defp media_problem(files, sidecar?) do
    media = Enum.filter(files, &(&1.kind == :media))
    parts = for %{part: part} <- media, is_integer(part), do: part
    singles = Enum.count(media, &is_nil(&1.part))

    cond do
      parts == [] ->
        nil

      missing = missing_parts(parts) ->
        "incomplete media set: missing " <> Enum.map_join(missing, ", ", &part_label/1)

      singles > 0 ->
        "ambiguous media set: both a single archive and parts"

      not sidecar? ->
        "incomplete media set: parts but no sidecar"

      true ->
        nil
    end
  end

  # Whether the stamp has a media sidecar on disk (well-formed or not: its
  # presence is what tells a finished set from an interrupted one).
  defp media_sidecar?(sidecars, stamp),
    do: sidecars |> Map.get(stamp, []) |> Enum.any?(&match?({:media, _}, &1))

  # The first few absent part numbers below the highest present one, lazily (a
  # file named `part99999999` must not cost a hundred million iterations).
  defp missing_parts(parts) do
    present = MapSet.new(parts)

    case 1..Enum.max(parts)//1
         |> Stream.reject(&MapSet.member?(present, &1))
         |> Enum.take(5) do
      [] -> nil
      missing -> missing
    end
  end

  defp part_label(n), do: "part" <> String.pad_leading(Integer.to_string(n), 2, "0")

  # `%{file_name => sha256}` from the stamp's sidecars. Never raises, never
  # trusts: a sidecar that is not a small regular file, or does not parse
  # strictly, is ignored with a warning.
  # sobelow_skip ["Traversal.FileModule"]
  defp digests(dir, stamp, sidecars) do
    sidecars
    |> Map.get(stamp, [])
    |> Enum.flat_map(&sidecar_digests(dir, &1))
    |> Map.new()
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp sidecar_digests(dir, {kind, name}) do
    path = Path.join([dir, Artifact.subdir(kind), name])

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_sidecar_bytes <-
           File.lstat(path),
         {:ok, entries} <- Checksum.parse_sidecar(path) do
      for {hex, file} <- entries, do: {file, hex}
    else
      _ ->
        Logger.warning("Ignoring an unreadable or malformed checksum sidecar: #{name}")
        []
    end
  end

  # Only a succeeded run's remote vouches for its files (#2218). Before the
  # fix, `backup.sh` named the remote in its failure manifests too, so one
  # on disk from an older script would mark a refused or never-sent file as
  # copied off-site.
  defp offsite(%Manifest{ok: true, offsite: offsite}), do: offsite
  defp offsite(_manifest), do: nil

  defp trigger(%Manifest{trigger: trigger}) when is_binary(trigger),
    do: String.slice(trigger, 0, @max_trigger)

  defp trigger(_none), do: "cron"

  defp artifact_attrs(file, manifest, digests) do
    base = %{
      kind: file.kind,
      name: file.name,
      bytes: file.bytes,
      verified: false,
      destinations: %{"local" => %{"status" => "ok"}}
    }

    attrs =
      with %Manifest{} <- manifest,
           %{} = listed <-
             Enum.find(manifest.artifacts, &(Path.basename(&1.path) == file.name)),
           {:ok, attrs} <- Artifact.from_manifest(listed, offsite(manifest)) do
        %{attrs | bytes: file.bytes}
      else
        _ -> base
      end

    # Recorded, not verified: nothing here hashes the file.
    case {attrs[:sha256], digests[file.name]} do
      {nil, hex} when is_binary(hex) -> Map.put(attrs, :sha256, hex)
      _ -> attrs
    end
  end

  # A failed manifest naming no stamped file: the run has nothing on disk to be
  # found by, so it is keyed by the manifest's own `stamp`, or, in a manifest
  # without one, by the stamp of its start. Never the start when the stamp is
  # there: Kiln's stamp is taken before `started_at` (and may be stepped past a
  # used one), so the start's second can name a run that doesn't exist and
  # this would insert a second, failed copy of the application's run.
  defp failed_manifest_attrs(
         %Manifest{ok: false, started_at: %DateTime{} = at} = m,
         existing,
         files
       ) do
    stamp = m.stamp || Artifact.stamp(at)

    if Enum.any?(m.artifacts, &stamped?/1) or MapSet.member?(existing, stamp) or
         Map.has_key?(files, stamp) do
      []
    else
      [
        %{
          stamp: stamp,
          trigger: trigger(m),
          status: :failed,
          components: [],
          started_at: at,
          finished_at: m.finished_at,
          error: m.error || "The backup failed",
          log: [],
          artifacts: []
        }
      ]
    end
  end

  defp failed_manifest_attrs(_manifest, _existing, _files), do: []

  defp stamped?(artifact),
    do: match?({:ok, %{partial?: false}}, Artifact.parse_file(Path.basename(artifact.path)))

  defp import_one(attrs) do
    case Backups.import_run(attrs, actor: Backups.system()) do
      {:ok, _run} ->
        :ok

      {:error, error} ->
        Logger.warning("Couldn't import backup #{attrs.stamp}: #{error.__struct__}")
        :error
    end
  end
end
