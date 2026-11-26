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
  `verified` as a covering manifest records it and `false` otherwise (nothing is
  hashed or verified on import; a `sha256` is recorded only when the manifest
  or the stamp's checksum sidecar supplies one),
  `succeeded` unless a file is zero bytes (`failed`, "empty artifact").
  `started_at` is the stamp read as UTC; `finished_at` is the newest file's
  mtime. Components are inferred from the files. `keep_days` (#3113) is the
  `BACKUP_KEEP_DAYS` a covering manifest of cron's (`Manifest.cron?/1`)
  recorded, only when that run succeeded (its prune ran), else `nil`;
  `KilnCMS.Backups.Presence` judges older rows by it. A row is never
  rewritten (one narrow exception, #2846, below, never touches `keep_days`),
  so runs imported before #3113 keep `nil`.

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
  the partials. The wait is long because a mislabel is costly (it is
  corrected only once the stamp completes, below), and a late one only
  leaves the stamp out of the history a little longer. A covering manifest
  still wins, and a stamp that has a row (the application's own runs) is never
  looked at. An mtime more than five minutes in the future reads as fresh,
  with a warning: a clock that is off must not turn a live run into a dead
  one. `backup.sh prune` removes the partials only once every file of the
  stamp is four times older than this (`ABANDONED_PARTIAL_MIN`), and the
  application's start step only once the stamp has a row, so the stamp is
  always read before its evidence goes.

  ## An Interrupted row whose stamp finished after all (#2846)

  An old `backup.sh` with no heartbeat, or clocks that disagree badly, can
  get a live run recorded as Interrupted. That row is the one an import may
  rewrite, once: each pass reads the Interrupted rows
  (`Backups.list_interrupted_imports/1`) and looks at those whose stamp is in
  the listing again. One is re-evaluated, through
  `Backups.reevaluate_interrupted_run/3`, only when its stamp now has

    * no `.partial` at all, every listed file still there when stat'ed, and
      its newest file settled (#{10} minutes old, so not in the future);
    * for **every** kind in the row's components (and any kind its files
      add), a finished file: and either a covering manifest that succeeded,
      or a complete set with that kind's checksum sidecar (a dump, a single
      media archive, or parts 1..N). A cron `all` killed during media is not
      turned into "succeeded, db only".

  The new outcome is what importing the stamp now would record, minus
  `started_at`, `keep_days`, `trigger` and the log (the row keeps its own, plus one
  line). The write locks the row and refuses (`StaleRecord`, counted
  nowhere) one that is no longer that Interrupted row, or that retention has
  marked `pruned` anywhere since (`Run.Changes.ReevaluateInterrupted`).
  Nothing is stat'ed while the lock is held. A file retention deletes after
  the stat is marked on the rewritten row by retention's own locked
  `:mark_pruned`. The one window left is a row with no artifacts (only
  partials when it was recorded): a deletion between the stat and the lock
  leaves nothing to mark, so the rewrite records that file as present
  although it is gone (accepted: it takes a prune landing in the
  milliseconds between the two). Re-evaluations count as `reevaluated`,
  their failures as `failed`, and they share the #2417 backoff.

  `kiln-<kind>-<stamp>.sha256` sidecars are not artifacts and never make a run
  by themselves, but are accounted for by their stamp: a well-formed one
  (`Checksum.parse_sidecar/1`) supplies the per-file `sha256` of the imported
  artifact; a malformed or oversized one is ignored with a warning.

  Separate cron entries (`backup.sh db`, then `backup.sh media`) have different
  stamps, so they become two runs.

  ## A stamp whose write keeps failing (#2417)

  The importer runs on every History mount, marker sync, backup end and
  retention pass. A stamp whose insert errors (a constraint the row breaks,
  say) would otherwise be retried, and warned about, every time. So a failed
  write puts the stamp, keyed by `{directory, stamp}`, into a node-local
  backoff: 15 minutes after the first failure, doubling each time, at most
  6 hours. Until then the stamp is `deferred` in the summary: not attempted,
  not logged. Each real attempt that fails logs one warning with the attempt
  number, the redacted cause and the next try, and emits
  `[:kiln_cms, :backups, :import, :failed]`. A success, a row appearing for
  the stamp, or its files going clears its entry; `retry_failed/0` clears
  every entry and imports at once (through `bin/kiln_cms rpc`). The table lives
  in `:persistent_term`, written at most once per call and only when it
  changed, and holds at most #{500} entries (the soonest due are dropped
  first). It is per node and lost on a restart; two concurrent calls may
  each write it, and the later one wins. Each of those only brings a retry
  forward.

  A deferred stamp is safe to leave unrecorded. It has no Run row, so
  retention treats its files as **Unrecorded** (kept until older than the
  floor), exactly as when its write fails, and the application's partial
  sweep removes a stamp's `.partial` files only once the stamp has a row, so
  it keeps them. A deferred stamp never turns `run/1` into `{:error, _}`:
  retention and the partial sweep go ahead only on `{:ok, _}`, and one bad
  stamp must not stop them for every other one. A refused read (a revoked
  grant) is still `{:error, _}` and records no backoff: nothing was
  attempted.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Checksum, Manifest, Redact}

  require Logger

  @settle_ms :timer.minutes(10)
  @interrupted_after_s 3 * 3600
  @future_slack_s 300
  @logged_partials 5
  @max_trigger 64
  @max_sidecar_bytes 4 * 1024 * 1024

  # The import backoff (#2417): `%{{dir, stamp} => %{failures, retry_at,
  # first_error}}`, `retry_at` in Unix milliseconds.
  @failures {__MODULE__, :failures}
  @first_backoff_ms :timer.minutes(15)
  @max_backoff_ms :timer.hours(6)
  @max_failures 500
  @max_cause 300

  @type summary :: %{
          imported: non_neg_integer(),
          pending: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          deferred: non_neg_integer(),
          reevaluated: non_neg_integer()
        }

  @doc """
  Import every backup found on disk that has no run yet.

  Returns `{:ok, summary}` — `imported` rows written (a concurrent call may
  have written the same stamp, in which case the write was a no-op but is still
  counted), `pending` stamps waiting out the settle window, `skipped` stamps
  that cannot be represented (impossible date), `failed` rows whose write
  errored, `deferred` stamps whose write failed before and whose backoff has
  not run out (not attempted, see the moduledoc), `reevaluated` Interrupted
  rows rewritten because their stamp finished after all (#2846) — or
  `{:error, reason}` when the directory cannot be listed or the runs cannot
  be read.
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

  @doc """
  Forget every stamp's import backoff on this node and import at once, as
  `run/0`. For an operator who fixed what made a write fail:
  `bin/kiln_cms rpc 'IO.inspect(KilnCMS.Backups.Importer.retry_failed())'`.
  """
  @spec retry_failed() :: {:ok, summary()} | {:error, term()}
  def retry_failed do
    reset_failures()
    run()
  end

  @doc """
  The error of an imported run recorded as killed (#2478): the one
  `:reevaluate_interrupted` may replace (#2846).
  """
  @spec interrupted_message() :: String.t()
  def interrupted_message, do: KilnCMS.Backups.Run.interrupted_import_error()

  @doc false
  # Empties the backoff table. `KilnCMS.DataCase.setup_sandbox/1` calls it for
  # every synchronous test, so a stamp one test failed on is never deferred in
  # another, whatever order the modules run in.
  @spec reset_failures() :: :ok
  def reset_failures do
    if :persistent_term.get(@failures, nil), do: :persistent_term.erase(@failures)
    :ok
  end

  @doc false
  # Test seams, each defaulting to the real thing: `:list` (`list/1`; a test
  # passes one that changes the directory between the listing and the stat),
  # `:import` (the write, `attrs -> {:ok, _} | {:error, _}`), `:now_ms`
  # (the backoff's clock, Unix milliseconds) and `:reevaluate` (the
  # re-evaluation's write, `(run, attrs) -> {:ok, _} | {:error, _}`).
  @spec run(Path.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def run(dir, opts \\ []) do
    reconcile_stale_runs()
    list = Keyword.get(opts, :list, &list/1)

    with {:ok, names} <- list.(dir),
         {:ok, existing} <- existing_stamps(),
         {:ok, interrupted} <- interrupted_imports() do
      import_new(dir, names, existing, interrupted, opts)
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

  defp interrupted_imports do
    case Backups.list_interrupted_imports(actor: Backups.system(), authorize_with: :error) do
      {:ok, runs} -> {:ok, runs}
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

  defp import_new(dir, listed, existing, interrupted, opts) do
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

    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.os_time(:millisecond) end)
    import = Keyword.get(opts, :import, &Backups.import_run(&1, actor: Backups.system()))
    failures = failures()

    {deferred, due} =
      Enum.split_with(attrs ++ manifest_only, &deferred?(failures, dir, &1.stamp, now_ms))

    results = Enum.map(due, &{&1.stamp, import_one(&1, import)})

    # #2846: the Interrupted rows whose stamp finished after all. Stat'ed
    # and judged one at a time, each written right after its stat.
    reevaluate = Keyword.get(opts, :reevaluate, &reevaluate_run/2)
    context = %{dir: dir, manifest: manifest, covered: covered, sidecars: sidecars, now: now}

    {re_deferred, re_due} =
      interrupted
      |> Enum.filter(&reevaluable?(&1, files, partials))
      |> Enum.split_with(&deferred?(failures, dir, &1.stamp, now_ms))

    re_results =
      for run <- re_due,
          result = reevaluate_one(run, Map.fetch!(files, run.stamp), context, reevaluate),
          result != :skip,
          do: {run.stamp, result}

    # The stamps still waiting for a row (or a re-evaluation): an entry for
    # any other stamp of this directory (now recorded, or its files gone) is
    # dropped.
    live =
      MapSet.new(
        new ++ Enum.map(manifest_only, & &1.stamp) ++ Enum.map(re_due ++ re_deferred, & &1.stamp)
      )

    save_failures(failures, update_failures(failures, dir, live, results ++ re_results, now_ms))

    {:ok,
     %{
       imported: Enum.count(results, &match?({_, :ok}, &1)),
       pending: length(pending),
       skipped: length(invalid),
       failed: Enum.count(results ++ re_results, &match?({_, {:error, _}}, &1)),
       deferred: length(deferred) + length(re_deferred),
       reevaluated: Enum.count(re_results, &match?({_, :ok}, &1))
     }}
  end

  # An Interrupted row worth a stat (#2846): its stamp has finished files in
  # the listing and no `.partial` of any kind.
  defp reevaluable?(run, files, partials),
    do: Map.has_key?(files, run.stamp) and not Map.has_key?(partials, run.stamp)

  # `:skip` (not ready, nothing attempted), `:ok`, `:stale` (the row changed
  # under the lock) or `{:error, cause}`.
  defp reevaluate_one(run, names, context, reevaluate) do
    %{dir: dir, manifest: manifest, covered: covered, sidecars: sidecars, now: now} = context
    entry = dir |> entry(run.stamp, names, []) |> Map.put(:state, :ready)
    manifest = if MapSet.member?(covered, run.stamp), do: manifest

    if length(entry.files) == length(names) and old_enough?(entry.files, now) and
         complete?(entry, run.components, manifest, sidecars) do
      attrs =
        entry
        |> run_attrs(manifest, covered, dir, sidecars, now)
        |> Map.take([:status, :error, :components, :finished_at, :artifacts])

      run |> reevaluate.(attrs) |> reevaluated()
    else
      :skip
    end
  end

  defp reevaluated({:ok, _run}), do: :ok

  defp reevaluated({:error, error}),
    do: if(stale?(error), do: :stale, else: {:error, cause(error)})

  defp reevaluate_run(run, attrs),
    do: Backups.reevaluate_interrupted_run(run, attrs, actor: Backups.system())

  defp stale?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

  defp stale?(_error), do: false

  # Every kind the row names, and any its files add, has a finished file,
  # and either the covering manifest succeeded or that kind's set is complete
  # with its sidecar beside it.
  defp complete?(entry, components, manifest, sidecars) do
    kinds = Enum.uniq(components ++ Enum.map(entry.files, & &1.kind))
    ok? = match?(%Manifest{ok: true}, manifest)

    with_sidecar =
      sidecars |> Map.get(entry.stamp, []) |> MapSet.new(fn {kind, _name} -> kind end)

    kinds != [] and
      Enum.all?(kinds, fn kind ->
        of_kind = Enum.filter(entry.files, &(&1.kind == kind))

        of_kind != [] and
          (ok? or (MapSet.member?(with_sidecar, kind) and set_complete?(kind, of_kind)))
      end)
  end

  # One dump or one single archive; or parts 1..N and nothing else.
  defp set_complete?(_kind, [%{part: nil}]), do: true

  defp set_complete?(:media, files),
    do: Enum.all?(files, &is_integer(&1.part)) and media_problem(files, true) == nil

  defp set_complete?(_kind, _files), do: false

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
    case Artifact.parse_sidecar_name(name) do
      {:ok, %{stamp: stamp, partial?: true}} ->
        {files, add_partial(partials, stamp, sub, name), sidecars}

      {:ok, %{kind: kind, stamp: stamp, partial?: false}} ->
        if Artifact.subdir(kind) == sub,
          do:
            {files, partials, Map.update(sidecars, stamp, [{kind, name}], &[{kind, name} | &1])},
          else: {files, partials, sidecars}

      :error ->
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
  # row is rewritten only if its stamp later completes (#2846).
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
        files |> Enum.map(&artifact_attrs(&1, manifest, digests)) |> Artifact.group_files(),
      keep_days: prune_keep_days(manifest)
    }
  end

  # Cron's window when this run's prune ran (#3113): only a covering manifest
  # of cron's (`Manifest.cron?/1`) that succeeded, since `backup.sh all`
  # prunes as its last step before that manifest; a failed one may have
  # stopped first. A Kiln manifest says nothing about cron's prune.
  defp prune_keep_days(%Manifest{ok: true} = manifest), do: Manifest.cron_keep_days(manifest)
  defp prune_keep_days(_none), do: nil

  defp outcome(true, _manifest, _problem, _empty?), do: {:failed, interrupted_message()}
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

  defp import_one(attrs, import) do
    case import.(attrs) do
      {:ok, _run} -> :ok
      {:error, error} -> {:error, cause(error)}
    end
  end

  # What went wrong, for the log. Redacted: an Ash error's message can quote
  # attributes, and those come from files and a manifest on disk.
  defp cause(error) when is_exception(error),
    do: Redact.text(Exception.message(error), [], @max_cause)

  defp cause(error), do: Redact.text(inspect(error), [], @max_cause)

  defp failures, do: :persistent_term.get(@failures, %{})

  defp deferred?(failures, dir, stamp, now_ms) do
    case failures do
      %{{^dir, ^stamp} => %{retry_at: retry_at}} -> now_ms < retry_at
      _ -> false
    end
  end

  # The table after this call: this directory's entries kept only for `live`
  # stamps, a success cleared, a failure recorded (and warned about), then
  # cut to `@max_failures`.
  defp update_failures(failures, dir, live, results, now_ms) do
    kept =
      Map.reject(failures, fn {{entry_dir, stamp}, _entry} ->
        entry_dir == dir and not MapSet.member?(live, stamp)
      end)

    results
    |> Enum.reduce(kept, fn
      {stamp, result}, acc when result in [:ok, :stale] -> Map.delete(acc, {dir, stamp})
      {stamp, {:error, cause}}, acc -> record_failure(acc, dir, stamp, cause, now_ms)
    end)
    |> cap()
  end

  defp record_failure(failures, dir, stamp, cause, now_ms) do
    previous = Map.get(failures, {dir, stamp}, %{failures: 0, first_error: cause})
    attempt = previous.failures + 1
    retry_at = now_ms + backoff_ms(attempt)
    next = retry_at |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second)

    Logger.warning(
      "Couldn't import backup #{stamp} (attempt #{attempt}): #{cause}. " <>
        "Next try after #{DateTime.to_iso8601(next)}; " <>
        "KilnCMS.Backups.Importer.retry_failed() retries now"
    )

    :telemetry.execute([:kiln_cms, :backups, :import, :failed], %{count: 1}, %{
      stamp: stamp,
      attempt: attempt,
      retry_at: next,
      error: cause
    })

    Map.put(failures, {dir, stamp}, %{
      failures: attempt,
      retry_at: retry_at,
      first_error: previous.first_error
    })
  end

  # 15 min, 30 min, 1 h, 2 h, 4 h, then 6 h.
  defp backoff_ms(attempt),
    do: min(@first_backoff_ms * Integer.pow(2, min(attempt - 1, 10)), @max_backoff_ms)

  # The soonest due go first: losing an entry only brings its retry forward.
  defp cap(failures) when map_size(failures) <= @max_failures, do: failures

  defp cap(failures) do
    failures
    |> Enum.sort_by(fn {_key, %{retry_at: retry_at}} -> retry_at end, :desc)
    |> Enum.take(@max_failures)
    |> Map.new()
  end

  # One write per call, and none when nothing changed: replacing a
  # `:persistent_term` value makes every process on the node scan for the old
  # one.
  defp save_failures(same, same), do: :ok
  defp save_failures(_old, new) when map_size(new) == 0, do: reset_failures()
  defp save_failures(_old, new), do: :persistent_term.put(@failures, new)
end
