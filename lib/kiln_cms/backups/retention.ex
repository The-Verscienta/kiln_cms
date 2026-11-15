defmodule KilnCMS.Backups.Retention do
  @moduledoc """
  Which local backups to delete, and deleting them (#2219). Replaces the
  worker's age-only prune; `scripts/backup.sh prune` applies the same rules
  wherever it can see what they need (see "What cron can't see").

  ## The unit is one component of one stamp

  `{stamp, :db}` is the dump and its sidecar; `{stamp, :media}` is the single
  archive or the parts, and the media sidecar. Each unit is aged by its own
  newest regular file (never a `.partial`, never a symlink or directory) and
  deleted whole: data files first, the sidecar last, so a unit that stops
  half-way still has its checksums. The database and the media of one stamp
  are kept or deleted independently.

  ## Keep rules, in order

  For each unit the first rule that holds decides:

    1. **Recovery point.** A `kiln-<stamp>.keep` entry in `db/` or `media/`
       (`Artifact.keep_name/1`) pins every component of that stamp. Only its
       presence counts; nothing here reads, writes or deletes a `.keep`, and a
       marker never ages as a stray.
    2. **In flight.** The stamp's Run is `running`, `.work/<stamp>` exists, or
       a `.partial` of that unit is younger than `partial_grace_s/0`.
    3. **Newest verified.** The newest unit of its kind that is complete on
       disk and belongs to a `succeeded` Run whose artifact of that kind is
       verified (an app run) or present (an imported run, whose `verified`
       is only what a covering `manifest.json` said, so it is not consulted).
       Never deleted.
    4. **Newest complete.** The newest unit of its kind that is complete on
       disk, whatever its Run says (`complete?/1`). `backup.sh prune` keeps the
       same one, so the two prunes together can never empty a component.
    5. **Keep count.** A schedule with a `keep_count` of N holds, per kind it
       backs up, its own newest N, and the newest N of its own and the
       cron-made ones together ("keep more"), however old
       (`{:keep_count, schedule_ids}`). Only good units count: complete, of a
       run as in rule 3, not in flight, of a plausible stamp and not a
       recovery point.
    6. **Unrecorded.** No Run row, a `skipped` one, or one with no artifact of
       this kind: kept until older than the floor (below).
    7. **A schedule's own age.** A schedule's own unit is kept until older
       than the longest `keep_days` of the live schedules it was made for
       (`:schedule`), which may be shorter than `BACKUP_KEEP_DAYS`.
    8. **Imported and orphaned.** A cron-made unit, or a schedule's own unit
       whose schedules no longer back that kind up (deleted or edited), is
       kept until older than the floor (`:schedule_floor` when the floor is
       above `keep_days`).
    9. **Age.** Everything else is kept until older than `keep_days`.

  The **floor** of a kind is the longest of `keep_days` and the `keep_days`
  of every schedule backing that kind up: no backup a schedule did not make
  ages out sooner than one it did. A schedule's own unit is one whose Run is
  an app run of trigger `"schedule"` that backed this kind up
  (`scheduled_components`) for a live schedule covering it (`schedule_ids`).
  A run that also carried a manual or console request (its trigger is then
  not `"schedule"`, `KilnCMS.Backups.Chain`'s fold) is never counted and ages
  at no less than `keep_days`, or the longest `keep_days` of its schedules
  if that is longer. A rule that gives `keep_days` itself is plain age, so
  without keep fields the plan is the one `Policy.legacy/1` gives. The
  schedules come from `Policy.current/0`, paused ones included.

  Rules 3 and 4 choose among units that are not in flight (so the run doing
  the pruning never takes the slot from the last finished backup) and whose
  stamp is plausible (`plausible_stamp?/2`), so a misnamed or future-dated
  file can't hold the slot forever.

  "Older than `keep_days`" is `find -mtime +keep_days`: an age of at least
  `keep_days + 1` whole days. A `kiln-*` file in `db/` or `media/` that is no
  unit's member (a "stray") ages alone under `keep_days`; markers (`.keep`,
  `.good` and `.hold`) and `.partial` files are never strays.

  ## The last-good marker

  `kiln-<stamp>.good` (`Artifact.good_name/1`) in `db/` or `media/` names the
  newest verified unit of that kind (rule 3), for `backup.sh prune`, which has
  no run history to find it by. This module writes it and is the only thing
  that removes it, at three moments: `sync_last_good/2` after a run succeeds,
  `run/2` before its first delete (never on a dry run), and
  `sync_last_good/2` again from `KilnCMS.Backups.Chain.sync_last_good/2`,
  which `KilnCMS.Backups.MarkerSyncWorker` runs every 15 minutes for
  deployments that back up with cron only (#2554). Per kind, the new marker
  is written first and the other `.good` entries of that directory are
  removed only once
  it is there, so a failed write (a warning and a
  `[:kiln_cms, :backups, :last_good, :failed]` event) leaves the old marker
  pinning the previous backup. A kind with no verified unit keeps whatever
  marker it has. Only regular files are removed; anything else of that name
  is left and logged.

  The app never reads a `.good` as a keep rule: it works out rule 3 itself,
  so a stale marker pins nothing here, and its unit ages like any other.

  ## The hold markers

  `kiln-<stamp>.hold` (`Artifact.hold_name/1`) in `db/` or `media/` names a
  unit the schedules' keep rules hold: every unit a keep count holds (rule 5)
  and every unit kept by rules 6 to 8 on a `keep_days` other than
  `BACKUP_KEEP_DAYS`, whatever rules 1 to 4 say of it today (a recovery
  point included). `backup.sh prune` keeps a unit with a `.hold` in its own
  directory, as it does one with a `.good`; it has no schedules to work them
  out from. The holds are synced wherever the `.good` markers are, in the
  same order: every hold the plan names is written first, and only then is a
  `.hold` it no longer names removed (regular files only; a failure is a
  warning and a `[:kiln_cms, :backups, :hold, :failed]` event). In
  `sync_last_good/2` the `.good` markers don't depend on the policy: when the
  schedules can't be read the `.good` markers still move and every hold is
  left as it is, with the same warning and event. Like `.good`, the app never
  reads a `.hold` as a keep rule.

  ## Fail closed, loudly

  Nothing is deleted unless the importer ran (`Importer.run/1`, first, so a
  cron-made backup is classified from its row), the policy resolved and
  validated (the schedules read as the `:backups` system actor with
  `authorize_with: :error`; a refused read is
  `{:policy, {:read_schedules, _}}`, never "no schedules"),
  `db/`, `media/` and `.work/` were listed, and the Run rows were
  read with `authorize_with: :error`. Any of these failing returns
  `{:error, reason}` after a `Logger.error` and a
  `[:kiln_cms, :backups, :retention, :skipped]` telemetry event. Right before
  each unit goes, `.work/<stamp>`, the stamp's markers and its Run are checked
  again; a unit that is now in flight, pinned, or whose Run can't be read is
  left alone.

  ## What cron can't see

  `backup.sh prune` has no database: rules 1, 2 (except a running Run), 4 and
  9 apply there, and rule 3 only through the last-good marker: a unit with a
  `.good` in its own directory is kept, so cron keeps the newest verified
  backup even when a newer complete set from a failed run exists. Rules 5 to
  8 apply there only through the hold markers. That holds as long as the app
  keeps the markers in step; a host whose copy of `backup.sh` predates a
  marker ignores it. Where a schedule keeps less than `BACKUP_KEEP_DAYS`,
  cron keeps more than the app, never less. Cron never deletes strays or
  markers. Unlike this module, it does delete `.partial` files: those of a run
  killed outright, once every file of the stamp is 12 hours old (#2478). Here
  a `.partial` is only ever a reason to keep; the start step's sweep removes
  one, once its stamp has a run row.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Importer, Recorder, WorkState}
  alias KilnCMS.Backups.Retention.Policy

  require Logger

  @partial_grace_s 3600
  @day 86_400
  @subs ["db", "media"]

  @typedoc "One regular-or-not final file of a unit, as `scan/1` saw it."
  @type member :: %{
          name: String.t(),
          role: :data | :sidecar,
          part: pos_integer() | nil,
          type: atom(),
          size: non_neg_integer(),
          mtime: integer()
        }

  @type unit :: %{
          stamp: String.t(),
          kind: :db | :media,
          files: [member()],
          partials: [integer()]
        }

  @type inventory :: %{
          units: %{{String.t(), :db | :media} => unit()},
          markers: MapSet.t(String.t()),
          work: MapSet.t(String.t()),
          strays: [%{name: String.t(), sub: String.t(), mtime: integer()}]
        }

  @type entry :: %{
          stamp: String.t() | nil,
          kind: :db | :media | :stray,
          sub: String.t(),
          files: [String.t()],
          reason: term()
        }

  @typedoc """
  The plan. `last_good` is the newest verified stamp of each kind (rule 3),
  or `nil`: what the `.good` markers should name. `holds` are the stamps of
  each kind the schedules' keep rules hold (see "The hold markers"): what the
  `.hold` markers should name.
  """
  @type plan :: %{
          delete: [entry()],
          keep: [entry()],
          last_good: %{db: String.t() | nil, media: String.t() | nil},
          holds: %{db: [String.t()], media: [String.t()]}
        }

  @doc """
  How long a `.partial` counts as a live writer's work: younger, and its unit
  is in flight; older, and the start step's partial sweep removes it once
  every file of its stamp is older and the stamp has a run row (#2478).
  """
  @spec partial_grace_s() :: pos_integer()
  def partial_grace_s, do: @partial_grace_s

  @doc """
  Import, plan, sync the last-good and hold markers and delete. Returns `{:ok, %{deleted: names, units: count,
  plan: plan, stopped: nil | reason}}` — `names` are the file names removed,
  already marked `pruned` on their runs; `stopped` is set when the deleting
  itself broke off part-way (what was removed by then is still in `names`) —
  or `{:error, reason}` when retention could not start, with nothing deleted.

  Options:

    * `:policy` - a `Policy` struct, or a 0-arity function returning
      `{:ok, policy} | {:error, reason}`. Defaults to `&Policy.current/0`:
      `BACKUP_KEEP_DAYS` and every schedule's keep rules, read fail-closed.
    * `:now` - posix seconds (default: now).
    * `:dry_run` - plan only; delete nothing and write no marker (default
      `false`).
  """
  @spec run(Path.t(), keyword()) ::
          {:ok,
           %{
             deleted: [String.t()],
             units: non_neg_integer(),
             plan: plan(),
             stopped: term() | nil
           }}
          | {:error, term()}
  def run(dir \\ Backups.dir(), opts \\ []) do
    case prepare(dir, opts) do
      {:ok, plan} ->
        if Keyword.get(opts, :dry_run, false),
          do: {:ok, %{deleted: [], units: 0, plan: plan, stopped: nil}},
          else: execute(dir, plan, opts)

      {:error, reason} ->
        skipped(reason)
    end
  end

  # Everything before the first delete. Any failure here, a raise included,
  # means nothing was deleted.
  defp prepare(dir, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, _summary} <- import_first(dir),
         {:ok, policy} <- policy(opts),
         {:ok, inventory} <- scan(dir),
         {:ok, runs} <- read_runs(stamps(inventory)) do
      {:ok, plan(inventory, runs, policy, now)}
    end
  rescue
    error -> {:error, {:crashed, error.__struct__}}
  end

  # Whatever was deleted is marked on its runs, even when the deleting stopped
  # part-way. The markers move first: nothing below deletes the newest
  # verified unit, and a cron prune that runs meanwhile sees the new one.
  defp execute(dir, plan, opts) do
    _ = sync(dir, plan.last_good, opts)
    _ = sync_holds(dir, plan.holds, opts)
    {deleted, units, stopped} = apply_plan(dir, plan, Keyword.take(opts, [:before_unit]))
    Recorder.mark_pruned(deleted)
    if stopped, do: stopped(deleted, stopped)
    {:ok, %{deleted: deleted, units: units, plan: plan, stopped: stopped}}
  end

  defp skipped(reason) do
    Logger.error("Backup retention skipped: #{describe(reason)}; nothing was deleted")

    :telemetry.execute([:kiln_cms, :backups, :retention, :skipped], %{count: 1}, %{reason: reason})

    {:error, reason}
  end

  defp stopped(deleted, reason) do
    Logger.error(
      "Backup retention removed #{length(deleted)} file(s), then stopped: #{describe(reason)}"
    )

    :telemetry.execute(
      [:kiln_cms, :backups, :retention, :stopped],
      %{count: 1, deleted: length(deleted)},
      %{reason: reason}
    )
  end

  @doc "An operator-facing account of why retention was skipped or stopped."
  @spec describe(term()) :: String.t()
  def describe({:import, reason}),
    do: "couldn't import cron-made backups into the backup history (#{inspect(reason)})"

  def describe({:read_runs, reason}),
    do: "couldn't read the backup history (#{inspect(reason)})"

  def describe({:policy, :invalid_policy}),
    do:
      "the retention policy is invalid (BACKUP_KEEP_DAYS must be a whole number of days, 1 or more)"

  def describe({:policy, {:read_schedules, reason}}),
    do: "couldn't read the backup schedules (#{inspect(reason)})"

  def describe({:policy, reason}),
    do: "couldn't resolve the retention policy (#{inspect(reason)})"

  def describe({:ls, sub, reason}),
    do: "couldn't list #{sub}/ in the backup directory (#{inspect(reason)})"

  def describe({:lstat, name, reason}), do: "couldn't read #{name} (#{inspect(reason)})"
  def describe({:crashed, module}), do: "it crashed (#{inspect(module)})"
  def describe(reason), do: inspect(reason)

  defp import_first(dir) do
    case Importer.run(dir) do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, {:import, reason}}
    end
  end

  defp policy(opts) do
    resolved =
      case Keyword.get(opts, :policy, &Policy.current/0) do
        fun when is_function(fun, 0) -> fun.()
        policy -> {:ok, policy}
      end

    with {:ok, policy} <- resolved,
         {:ok, policy} <- Policy.validate(policy) do
      {:ok, policy}
    else
      {:error, reason} -> {:error, {:policy, reason}}
      other -> {:error, {:policy, {:unexpected, other}}}
    end
  end

  ## The last-good marker

  @doc """
  Bring the `.good` markers in `dir` in step with the newest verified unit of
  each kind, and the `.hold` markers with what the schedules hold (see "The
  hold markers"), deleting no backup: the importer, the scan and the Run read of
  `run/2`, then the marker sync it does before its deletes. Called right
  after a run succeeds, so the marker names that run before any later run can
  fail and leave a newer complete set behind.

  Returns `{:ok, %{db: stamp | nil, media: stamp | nil}}` (what the markers
  should name; a failed write is logged and reported by telemetry, not here),
  or `{:error, reason}` with no marker written or removed when any step
  before the sync fails.

  Call it only while holding the backup lock (as the chain's `succeed` and
  `prune` steps do, and `Chain.sync_last_good/2`): two syncs racing on
  different stamps can each remove the other's marker.

  Options:

    * `:policy` - as for `run/2`; only the holds use it.
    * `:import` - run the importer first (default `true`). `false` is for a
      caller that already ran it outside a transaction
      (`Chain.sync_last_good/2`), since the importer writes Run rows.
    * `:now` - posix seconds (default: now).
  """
  @spec sync_last_good(Path.t(), keyword()) ::
          {:ok, %{db: String.t() | nil, media: String.t() | nil}} | {:error, term()}
  def sync_last_good(dir \\ Backups.dir(), opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    result =
      try do
        with {:ok, _summary} <- maybe_import(dir, Keyword.get(opts, :import, true)),
             {:ok, inventory} <- scan(dir),
             {:ok, runs} <- read_runs(stamps(inventory)) do
          {_units, newest} = newest_slots(inventory, runs, now)
          last_good = last_good(newest)
          _ = sync(dir, last_good, opts)
          _ = sync_holds_with_policy(dir, inventory, runs, now, opts)
          {:ok, last_good}
        end
      rescue
        error -> {:error, {:crashed, error.__struct__}}
      catch
        # An exit (a DB call timing out) or a throw must not escape either:
        # the caller releases the backup lock after this returns.
        kind, _reason -> {:error, {:crashed, kind}}
      end

    with {:error, reason} <- result, do: sync_failed(reason)
  end

  @doc false
  # A sync that wrote and removed nothing: the warning and the
  # `[:kiln_cms, :backups, :last_good, :failed]` event. Also for
  # `Chain.sync_last_good/2`, whose import and lock come before this module.
  @spec sync_failed(term()) :: {:error, term()}
  def sync_failed(reason) do
    Logger.warning("Backup last-good marker not updated: #{describe(reason)}")
    marker_failed(%{reason: reason})
    {:error, reason}
  end

  # The holds need the policy; the `.good` markers don't, and were synced
  # already. A policy that can't be resolved leaves every hold where it is
  # (a hold too many keeps a backup a while longer; one too few lets cron
  # delete what a schedule keeps).
  defp sync_holds_with_policy(dir, inventory, runs, now, opts) do
    case policy(opts) do
      {:ok, policy} ->
        sync_holds(dir, plan(inventory, runs, policy, now).holds, opts)

      {:error, reason} ->
        Logger.warning("Backup hold markers not updated: #{describe(reason)}")
        hold_failed(%{reason: reason})
        {:error, reason}
    end
  end

  defp maybe_import(dir, true), do: import_first(dir)
  defp maybe_import(_dir, false), do: {:ok, :skipped}

  defp last_good(newest) do
    Map.new([:db, :media], fn kind -> {kind, get_in(newest, [kind, :verified])} end)
  end

  # Per kind with a verified unit: write its marker, and only once it is
  # there remove the kind's other markers. A kind with none keeps its marker.
  # `create_marker:` (tests only) stands in for creating the file, so a test
  # can fail the write without also failing the removes.
  defp sync(dir, last_good, opts) do
    create = Keyword.get(opts, :create_marker, &create_marker/1)

    for {kind, stamp} <- last_good, is_binary(stamp), into: %{} do
      sub = Artifact.subdir(kind)
      name = Artifact.good_name(stamp)

      case ensure_marker(dir, sub, name, create) do
        :ok ->
          remove_other_markers(dir, sub, name)
          {kind, :ok}

        {:error, reason} ->
          Logger.warning(
            "Backup last-good marker #{sub}/#{name} couldn't be written " <>
              "(#{inspect(reason)}); the previous marker stays"
          )

          marker_failed(%{kind: kind, stamp: stamp, reason: reason})
          {kind, {:error, reason}}
      end
    end
  end

  defp marker_failed(metadata),
    do: :telemetry.execute([:kiln_cms, :backups, :last_good, :failed], %{count: 1}, metadata)

  defp hold_failed(metadata),
    do: :telemetry.execute([:kiln_cms, :backups, :hold, :failed], %{count: 1}, metadata)

  ## The hold markers

  # Every hold the plan names is written first, in both directories; only
  # then is a `.hold` it doesn't name removed. A failed write is logged and
  # reported (`[:kiln_cms, :backups, :hold, :failed]`) and stops nothing else.
  defp sync_holds(dir, holds, opts) do
    create = Keyword.get(opts, :create_marker, &create_marker/1)

    for kind <- [:db, :media], stamp <- Map.get(holds, kind, []) do
      sub = Artifact.subdir(kind)
      name = Artifact.hold_name(stamp)

      with {:error, reason} <- ensure_marker(dir, sub, name, create) do
        Logger.warning(
          "Backup hold marker #{sub}/#{name} couldn't be written (#{inspect(reason)}); " <>
            "backup.sh prune may delete that backup"
        )

        hold_failed(%{kind: kind, stamp: stamp, reason: reason})
      end
    end

    for kind <- [:db, :media] do
      keep = holds |> Map.get(kind, []) |> MapSet.new(&Artifact.hold_name/1)
      remove_stale_holds(dir, Artifact.subdir(kind), keep)
    end

    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_stale_holds(dir, sub, keep) do
    case File.ls(Path.join(dir, sub)) do
      {:ok, names} ->
        for name <- names,
            not MapSet.member?(keep, name),
            match?({:ok, _}, Artifact.parse_hold_name(name)) do
          remove_marker(Path.join([dir, sub, name]), "#{sub}/#{name}", :hold)
        end

        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Couldn't list #{sub}/ to remove old hold markers (#{inspect(reason)})")
        :ok
    end
  end

  # An entry of that name already there, whatever it is, counts: `backup.sh`
  # reads the listing, not the entry.
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_marker(dir, sub, name, create) do
    path = Path.join([dir, sub, name])

    case File.lstat(path) do
      {:ok, _stat} -> :ok
      {:error, :enoent} -> create.(path)
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp create_marker(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        File.close(io)
        File.chmod(path, 0o600)

      {:error, :eexist} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_other_markers(dir, sub, keep) do
    case File.ls(Path.join(dir, sub)) do
      {:ok, names} ->
        for name <- names, name != keep, match?({:ok, _}, Artifact.parse_good_name(name)) do
          remove_marker(Path.join([dir, sub, name]), "#{sub}/#{name}", :last_good)
        end

        :ok

      {:error, reason} ->
        Logger.warning(
          "Couldn't list #{sub}/ to remove old last-good markers (#{inspect(reason)})"
        )

        :ok
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_marker(path, label, which) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        case File.rm(path) do
          result when result in [:ok, {:error, :enoent}] ->
            :ok

          {:error, reason} ->
            # A marker left behind pins its unit for `backup.sh prune` for
            # good, so it surfaces in telemetry, not only in the log.
            Logger.warning(
              "Couldn't remove old #{marker_label(which)} #{label} (#{inspect(reason)})"
            )

            removal_failed(which, %{marker: label, reason: {:remove, reason}})
        end

      {:ok, %{type: type}} ->
        Logger.warning("Left #{label} in place: a #{type}, not a regular file")
        removal_failed(which, %{marker: label, reason: {:not_regular, type}})

      {:error, _gone_or_unreadable} ->
        :ok
    end
  end

  defp marker_label(:last_good), do: "last-good marker"
  defp marker_label(:hold), do: "hold marker"

  defp removal_failed(:last_good, metadata), do: marker_failed(metadata)
  defp removal_failed(:hold, metadata), do: hold_failed(metadata)

  ## Scan

  @doc """
  What is on disk: the units of `db/` and `media/` (with each member's
  `lstat`), the stamps pinned by a marker, the stamps with a `.work/<stamp>`
  directory, and the strays. A missing directory is an empty one; any other
  listing or `lstat` error is `{:error, _}`.
  """
  @spec scan(Path.t()) :: {:ok, inventory()} | {:error, term()}
  # sobelow_skip ["Traversal.FileModule"]
  def scan(dir) do
    with {:ok, db} <- ls(dir, "db"),
         {:ok, media} <- ls(dir, "media"),
         {:ok, work} <- ls(dir, ".work"),
         listed = Enum.map(db, &{"db", &1}) ++ Enum.map(media, &{"media", &1}),
         {:ok, classified} <- classify_all(dir, listed) do
      {:ok, inventory(classified, work)}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ls(dir, sub) do
    case File.ls(Path.join(dir, sub)) do
      {:ok, names} -> {:ok, names}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:ls, sub, reason}}
    end
  end

  defp classify_all(dir, listed) do
    Enum.reduce_while(listed, {:ok, []}, fn {sub, name}, {:ok, acc} ->
      case classify(dir, sub, name) do
        {:error, _} = error -> {:halt, error}
        :ignore -> {:cont, {:ok, acc}}
        item -> {:cont, {:ok, [item | acc]}}
      end
    end)
  end

  defp classify(dir, sub, name) do
    cond do
      match?({:ok, _}, Artifact.parse_keep_name(name)) ->
        {:ok, stamp} = Artifact.parse_keep_name(name)
        {:marker, stamp}

      # A marker-shaped name with a bad stamp pins nothing, and is not a stray.
      String.ends_with?(name, ".keep") ->
        :ignore

      # A last-good or hold marker is never a keep rule here (the plan works
      # out the newest verified unit and the schedules' holds itself) and
      # never a stray; the marker sync manages both.
      String.starts_with?(name, "kiln-") and
          (String.ends_with?(name, ".good") or String.ends_with?(name, ".hold")) ->
        :ignore

      true ->
        classify_file(dir, sub, name, parsed(name))
    end
  end

  defp parsed(name) do
    case Artifact.parse_file(name) do
      {:ok, parsed} ->
        {:data, parsed}

      :error ->
        case Artifact.parse_sidecar_name(name) do
          {:ok, parsed} -> {:sidecar, Map.put(parsed, :part, nil)}
          :error -> :none
        end
    end
  end

  defp classify_file(dir, sub, name, {role, %{kind: kind} = parsed}) do
    home? = Artifact.subdir(kind) == sub

    cond do
      parsed.partial? and home? -> partial(dir, sub, name, kind, parsed.stamp)
      parsed.partial? -> :ignore
      home? -> member(dir, sub, name, kind, parsed, role)
      true -> stray(dir, sub, name)
    end
  end

  defp classify_file(dir, sub, name, :none) do
    if String.starts_with?(name, "kiln-") and not String.ends_with?(name, ".partial"),
      do: stray(dir, sub, name),
      else: :ignore
  end

  defp partial(dir, sub, name, kind, stamp) do
    with {:ok, stat} <- lstat(dir, sub, name), do: {:partial, {stamp, kind}, stat.mtime}
  end

  defp member(dir, sub, name, kind, parsed, role) do
    with {:ok, stat} <- lstat(dir, sub, name) do
      {:member, {parsed.stamp, kind},
       %{
         name: name,
         role: role,
         part: parsed.part,
         type: stat.type,
         size: stat.size,
         mtime: stat.mtime
       }}
    end
  end

  defp stray(dir, sub, name) do
    with {:ok, stat} <- lstat(dir, sub, name) do
      if stat.type == :regular,
        do: {:stray, %{name: name, sub: sub, mtime: stat.mtime}},
        else: :ignore
    end
  end

  # A file that vanished between the listing and the stat (a partial renamed
  # into place, a concurrent prune) is simply not there.
  # sobelow_skip ["Traversal.FileModule"]
  defp lstat(dir, sub, name) do
    case File.lstat(Path.join([dir, sub, name]), time: :posix) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> :ignore
      {:error, reason} -> {:error, {:lstat, name, reason}}
    end
  end

  defp inventory(classified, work) do
    empty = %{units: %{}, partials: %{}, markers: MapSet.new(), strays: []}

    acc =
      Enum.reduce(classified, empty, fn
        {:marker, stamp}, acc ->
          %{acc | markers: MapSet.put(acc.markers, stamp)}

        {:stray, stray}, acc ->
          %{acc | strays: [stray | acc.strays]}

        {:partial, key, mtime}, acc ->
          %{acc | partials: Map.update(acc.partials, key, [mtime], &[mtime | &1])}

        {:member, {stamp, kind} = key, file}, acc ->
          unit = Map.get(acc.units, key, %{stamp: stamp, kind: kind, files: [], partials: []})
          %{acc | units: Map.put(acc.units, key, %{unit | files: [file | unit.files]})}
      end)

    units =
      Map.new(acc.units, fn {key, unit} ->
        {key, %{unit | partials: Map.get(acc.partials, key, [])}}
      end)

    %{
      units: units,
      markers: acc.markers,
      work: work |> Enum.filter(&WorkState.valid_stamp?/1) |> MapSet.new(),
      strays: Enum.sort_by(acc.strays, &{&1.sub, &1.name})
    }
  end

  defp stamps(inventory),
    do: inventory.units |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  ## Runs

  @doc false
  # The rows the plan needs, keyed by stamp. Fails closed: a refused or failed
  # read is `{:error, _}`, never an empty history.
  @spec read_runs([String.t()]) :: {:ok, %{String.t() => struct()}} | {:error, term()}
  def read_runs(stamps) do
    case Backups.list_runs(
           query: [
             filter: [stamp: [in: stamps]],
             select: [
               :stamp,
               :status,
               :origin,
               :trigger,
               :artifacts,
               :components,
               :scheduled_components,
               :schedule_ids
             ]
           ],
           actor: Backups.system(),
           authorize_with: :error
         ) do
      {:ok, runs} -> {:ok, Map.new(runs, &{&1.stamp, &1})}
      {:error, error} -> {:error, {:read_runs, error.__struct__}}
    end
  end

  ## Plan

  @doc """
  The plan for an inventory, pure: `%{delete: entries, keep: entries,
  last_good: %{db: stamp | nil, media: stamp | nil}}`, each entry naming its
  unit (or stray), its regular files in deletion order and the reason;
  `last_good` is the newest verified stamp of each kind (rule 3); `holds`
  the stamps of each kind the `.hold` markers should name. `runs` maps stamp
  to Run (or anything with `status`, `origin` and `artifacts`, and
  `trigger`, `scheduled_components` and `schedule_ids` for the schedules'
  rules); `now` is posix seconds.
  """
  @spec plan(inventory(), %{String.t() => map()}, Policy.t(), integer()) :: plan()
  def plan(inventory, runs, %Policy{} = policy, now) do
    {units, newest} = newest_slots(inventory, runs, now)
    counted = keep_count_holds(units, runs, inventory, policy, now)

    entries =
      Enum.map(units, &decide(&1, runs[&1.stamp], newest, inventory, policy, counted, now)) ++
        Enum.map(inventory.strays, &decide_stray(&1, policy, now))

    {delete, keep} = Enum.split_with(entries, &(elem(&1, 0) == :delete))

    %{
      delete: entries(delete),
      keep: entries(keep),
      last_good: last_good(newest),
      holds: holds(units, runs, policy, counted, now)
    }
  end

  defp newest_slots(inventory, runs, now) do
    units = inventory.units |> Map.values() |> Enum.filter(&deletable?/1)

    candidates =
      Enum.filter(units, fn unit ->
        plausible_stamp?(unit.stamp, now) and
          not in_flight?(unit, runs[unit.stamp], inventory, now)
      end)

    {units, newest(units, candidates, runs)}
  end

  defp entries(tagged),
    do: tagged |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(&{&1.stamp || "", &1.kind, &1.files})

  # Only regular files are ever deleted (or aged); a unit of nothing else has
  # nothing to decide.
  defp deletable?(unit), do: regular(unit) != []

  defp regular(unit), do: Enum.filter(unit.files, &(&1.type == :regular))

  # `%{kind => %{verified: stamp | nil, complete: stamp | nil}}`, for every
  # kind among `units`, chosen among `candidates` only: a unit in flight (the
  # worker's own run, a cron run still writing) must not take the slot from the
  # last finished backup, and neither may a stamp that is no real instant or
  # lies in the future, which would hold it forever. Stamps sort as instants,
  # so the largest is the newest.
  defp newest(units, candidates, runs) do
    by_kind = Enum.group_by(candidates, & &1.kind)

    units
    |> Enum.map(& &1.kind)
    |> Enum.uniq()
    |> Map.new(fn kind ->
      complete = by_kind |> Map.get(kind, []) |> Enum.filter(&complete?/1)

      {kind,
       %{
         verified: complete |> Enum.filter(&good?(&1, runs[&1.stamp])) |> max_stamp(),
         complete: max_stamp(complete)
       }}
    end)
  end

  @future_slack_s 86_400

  @doc """
  Whether a stamp may hold the newest-verified or newest-complete slot: a real
  instant (`Artifact.parse_stamp/1`) no later than a day after `now`. Units of
  any other stamp are still kept or aged like the rest; they just never
  protect themselves by being "newest". `scripts/backup.sh` (`plausible_stamp`)
  applies the same test.
  """
  @spec plausible_stamp?(String.t(), integer()) :: boolean()
  def plausible_stamp?(stamp, now) do
    case Artifact.parse_stamp(stamp) do
      {:ok, at} -> DateTime.to_unix(at) <= now + @future_slack_s
      :error -> false
    end
  end

  defp max_stamp([]), do: nil
  defp max_stamp(units), do: units |> Enum.map(& &1.stamp) |> Enum.max()

  @doc """
  Whether a unit is whole on disk, judged by its final files only (a
  `.partial` beside it is not looked at here). Every file below must be a
  regular, non-empty file; symlinks and directories don't count.

    * `:db` - the dump.
    * `:media` - the single archive and no parts; or parts `01..N` with no gap,
      no single archive beside them, and the media sidecar.

  `scripts/backup.sh` (`unit_complete`) applies the same definition.
  """
  @spec complete?(unit()) :: boolean()
  def complete?(%{kind: :db, files: files}),
    do: Enum.any?(files, &(&1.role == :data and solid?(&1)))

  def complete?(%{kind: :media, files: files}) do
    data = Enum.filter(files, &(&1.role == :data))
    {parts, single} = Enum.split_with(data, &is_integer(&1.part))

    case {parts, single} do
      {[], [archive]} ->
        solid?(archive)

      {[_ | _], []} ->
        numbers = parts |> Enum.map(& &1.part) |> Enum.sort()

        numbers == Enum.to_list(1..length(numbers)) and Enum.all?(parts, &solid?/1) and
          Enum.any?(files, &(&1.role == :sidecar and solid?(&1)))

      _ ->
        false
    end
  end

  defp solid?(file), do: file.type == :regular and file.size > 0

  # A succeeded run whose artifact of this kind is verified (the app's own) or
  # merely present (imported: its `verified` is copied from a covering
  # manifest, if any, so it is not consulted). The unit must be complete.
  defp good?(_unit, nil), do: false

  defp good?(%{kind: kind}, %{status: :succeeded, origin: origin, artifacts: artifacts}) do
    Enum.any?(artifacts, fn artifact ->
      artifact.kind == kind and (origin == :imported or artifact.verified == true)
    end)
  end

  defp good?(_unit, _run), do: false

  defp decide(unit, run, newest, inventory, policy, counted, now) do
    %{stamp: stamp, kind: kind} = unit
    newest = Map.fetch!(newest, kind)

    cond do
      MapSet.member?(inventory.markers, stamp) ->
        {:keep, entry(unit, :recovery_point)}

      in_flight?(unit, run, inventory, now) ->
        {:keep, entry(unit, :in_flight)}

      stamp == newest.verified ->
        {:keep, entry(unit, :newest_verified)}

      stamp == newest.complete ->
        {:keep, entry(unit, :newest_complete)}

      Map.has_key?(counted, {stamp, kind}) ->
        {:keep, entry(unit, {:keep_count, Map.fetch!(counted, {stamp, kind})})}

      true ->
        {rule, days, _held?} = age_rule(unit, run, policy)
        age(unit, days, now, rule)
    end
  end

  ## Schedules (#2219)

  # Whose unit this is, for the schedules' keep rules:
  #
  #   * `:unrecorded` - no Run row, a skipped one, or none of this kind.
  #   * `:cron` - imported (whatever its trigger), or a schedule's own run
  #     whose schedules no longer back this kind up (deleted, or edited). Such
  #     units fill every covering schedule's keep count ("keep more") and age
  #     at the floor.
  #   * `{:own, rules}` - an app run of trigger `"schedule"` that backed this
  #     kind up for these live schedules. Counted toward their keep count, and
  #     aged at their longest `keep_days`, which may be below `keep_days`.
  #   * `{:linked, rules}` - an app run that backed this kind up for these
  #     schedules but whose trigger is not theirs (a manual request folded in):
  #     never counted, aged at no less than `keep_days`.
  #   * `:plain` - anything else (manual, console, a kind no schedule asked
  #     for): `keep_days`, never counted.
  defp category(run, kind, policy) do
    cond do
      unrecorded?(run, kind) -> :unrecorded
      Map.get(run, :origin) == :imported -> :cron
      kind not in (Map.get(run, :scheduled_components) || []) -> :plain
      Map.get(run, :trigger) == "schedule" -> owned(run, kind, policy, {:own, :cron})
      true -> owned(run, kind, policy, {:linked, :plain})
    end
  end

  defp owned(run, kind, policy, {tag, none}) do
    ids = Map.get(run, :schedule_ids) || []

    case Enum.filter(policy.schedules, &(&1.id in ids and kind in &1.kinds)) do
      [] -> none
      rules -> {tag, rules}
    end
  end

  # `{reason, days, held?}`: the age rule a unit falls to once rules 1 to 5
  # pass it by, and whether a `.hold` should name it while it is kept. A rule
  # that gives `keep_days` itself is plain age, so a policy whose schedules
  # set no keep field plans exactly as `Policy.legacy/1` does.
  defp age_rule(unit, run, policy) do
    keep_days = policy.keep_days

    case category(run, unit.kind, policy) do
      :unrecorded ->
        days = floor_days(policy, unit.kind)
        {:unrecorded, days, days > keep_days}

      :plain ->
        {:keep_days, keep_days, false}

      {:own, rules} ->
        case rules |> Enum.map(& &1.keep_days) |> Enum.max() do
          ^keep_days -> {:keep_days, keep_days, false}
          days -> {:schedule, days, true}
        end

      {:linked, rules} ->
        raised([keep_days | Enum.map(rules, & &1.keep_days)], keep_days)

      :cron ->
        raised([floor_days(policy, unit.kind)], keep_days)
    end
  end

  defp raised(days, keep_days) do
    case Enum.max(days) do
      ^keep_days -> {:keep_days, keep_days, false}
      days -> {:schedule_floor, days, true}
    end
  end

  # No unit of a kind a schedule backs up ages out sooner than that
  # schedule's own backups, unless it is one of them.
  defp floor_days(policy, kind) do
    Enum.max([policy.keep_days | for(r <- policy.schedules, kind in r.kinds, do: r.keep_days)])
  end

  # `%{{stamp, kind} => [schedule_id]}`: every unit some schedule's keep count
  # holds. For a schedule keeping N of a kind: its own newest N, and the
  # newest N of its own and the cron-made ones together ("keep more"). Only
  # good units count (complete, from a succeeded run, verified or imported),
  # not in flight, of a plausible stamp, and not a recovery point.
  defp keep_count_holds(units, runs, inventory, policy, now) do
    eligible =
      units
      |> Enum.filter(fn unit ->
        run = runs[unit.stamp]

        not MapSet.member?(inventory.markers, unit.stamp) and
          plausible_stamp?(unit.stamp, now) and not in_flight?(unit, run, inventory, now) and
          complete?(unit) and good?(unit, run)
      end)
      |> Enum.map(&{&1, category(runs[&1.stamp], &1.kind, policy)})

    for %{keep_count: n, id: id} = rule <- policy.schedules,
        is_integer(n),
        kind <- rule.kinds,
        unit <- counted(eligible, id, kind, n),
        reduce: %{} do
      acc -> Map.update(acc, {unit.stamp, kind}, [id], &Enum.uniq([id | &1]))
    end
    |> Map.new(fn {key, ids} -> {key, Enum.sort(ids)} end)
  end

  defp counted(eligible, id, kind, n) do
    of_kind = for {%{kind: ^kind} = unit, category} <- eligible, do: {unit, category}

    own = for {unit, {:own, rules}} <- of_kind, Enum.any?(rules, &(&1.id == id)), do: unit
    cron = for {unit, :cron} <- of_kind, do: unit

    Enum.uniq(newest_n(own, n) ++ newest_n(own ++ cron, n))
  end

  defp newest_n(units, n), do: units |> Enum.sort_by(& &1.stamp, :desc) |> Enum.take(n)

  # The `.hold` set: every unit a keep count holds, and every unit kept by a
  # schedule's age rule (its own `keep_days`, or a floor raised above
  # `keep_days`), whatever rules 1 to 4 say of it today and whatever the
  # host's `BACKUP_KEEP_DAYS` is.
  defp holds(units, runs, policy, counted, now) do
    held =
      for unit <- units, held?(unit, runs[unit.stamp], policy, counted, now), do: unit

    Map.new([:db, :media], fn kind ->
      {kind, for(%{kind: ^kind, stamp: stamp} <- held, do: stamp) |> Enum.uniq() |> Enum.sort()}
    end)
  end

  defp held?(unit, run, policy, counted, now) do
    Map.has_key?(counted, {unit.stamp, unit.kind}) or
      case age_rule(unit, run, policy) do
        {_rule, days, true} -> not expired?(newest_mtime(unit), days, now)
        {_rule, _days, false} -> false
      end
  end

  defp age(unit, days, now, rule) do
    if expired?(newest_mtime(unit), days, now),
      do: {:delete, entry(unit, {:expired, rule, days})},
      else: {:keep, entry(unit, rule)}
  end

  defp newest_mtime(unit), do: unit |> regular() |> Enum.map(& &1.mtime) |> Enum.max()

  defp in_flight?(unit, run, inventory, now) do
    match?(%{status: :running}, run) or MapSet.member?(inventory.work, unit.stamp) or
      Enum.any?(unit.partials, &(&1 >= now - @partial_grace_s))
  end

  defp unrecorded?(nil, _kind), do: true
  defp unrecorded?(%{status: :skipped}, _kind), do: true

  defp unrecorded?(%{artifacts: artifacts}, kind),
    do: not Enum.any?(artifacts, &(&1.kind == kind))

  @doc """
  `find -mtime +days`: whole days of age strictly greater than `days`, i.e. at
  least `days + 1` days old.
  """
  @spec expired?(integer(), pos_integer(), integer()) :: boolean()
  def expired?(mtime, days, now), do: mtime < now - (days + 1) * @day

  # Data before the sidecar, parts in order.
  defp entry(unit, reason) do
    files =
      unit
      |> regular()
      |> Enum.sort_by(&{&1.role == :sidecar, &1.part || 0, &1.name})
      |> Enum.map(& &1.name)

    %{
      stamp: unit.stamp,
      kind: unit.kind,
      sub: Artifact.subdir(unit.kind),
      files: files,
      reason: reason
    }
  end

  defp decide_stray(stray, policy, now) do
    entry = %{stamp: nil, kind: :stray, sub: stray.sub, files: [stray.name]}

    if expired?(stray.mtime, policy.keep_days, now),
      do: {:delete, Map.put(entry, :reason, {:expired, :stray, policy.keep_days})},
      else: {:keep, Map.put(entry, :reason, :keep_days)}
  end

  ## Delete

  @doc false
  # Deletes a plan's `delete` entries, each unit re-checked first. Returns
  # `{file_names_removed, units_touched, stopped}`: `stopped` is `nil`, or why
  # the deleting broke off (a raise), with what was removed before it kept.
  # `before_unit:` (tests only) runs ahead of each entry. Public for the tests
  # that change the directory between the plan and the delete.
  @spec apply_plan(Path.t(), plan(), keyword()) ::
          {[String.t()], non_neg_integer(), term() | nil}
  def apply_plan(dir, plan, opts \\ []) do
    before_unit = Keyword.get(opts, :before_unit, fn _entry -> :ok end)

    {deleted, units, stopped} =
      Enum.reduce_while(plan.delete, {[], 0, nil}, fn entry, {deleted, units, nil} ->
        case remove_safely(dir, entry, before_unit) do
          {:ok, []} -> {:cont, {deleted, units, nil}}
          {:ok, names} -> {:cont, {[names | deleted], units + 1, nil}}
          {:error, reason} -> {:halt, {deleted, units, reason}}
        end
      end)

    {deleted |> Enum.reverse() |> List.flatten(), units, stopped}
  end

  defp remove_safely(dir, entry, before_unit) do
    before_unit.(entry)
    {:ok, remove(dir, entry)}
  rescue
    error -> {:error, {:crashed, error.__struct__}}
  end

  defp remove(dir, %{kind: :stray} = entry), do: remove_files(dir, entry)

  defp remove(dir, entry) do
    case recheck(dir, entry.stamp) do
      :ok ->
        remove_files(dir, entry)

      {:skip, why} ->
        Logger.info("Retention left #{label(entry)} in place: #{why} since it was planned")
        []
    end
  end

  @doc false
  # The last look before a unit goes: `:ok`, or `{:skip, why}` when the stamp
  # gained a work directory or a marker, its Run is running, or its Run can't
  # be read (or anything about the stamp can't be seen: keep).
  @spec recheck(Path.t(), String.t()) :: :ok | {:skip, atom()}
  def recheck(dir, stamp) do
    cond do
      present?(Path.join([dir, ".work", stamp])) ->
        {:skip, :in_flight}

      Enum.any?(@subs, &present?(Path.join([dir, &1, Artifact.keep_name(stamp)]))) ->
        {:skip, :recovery_point}

      true ->
        case Backups.get_run_by_stamp(stamp, actor: Backups.system(), authorize_with: :error) do
          {:ok, %{status: :running}} -> {:skip, :in_flight}
          {:ok, _run_or_nil} -> :ok
          {:error, _} -> {:skip, :unreadable_run}
        end
    end
  end

  # Anything but "definitely not there" counts as there.
  # sobelow_skip ["Traversal.FileModule"]
  defp present?(path), do: File.lstat(path) != {:error, :enoent}

  # Stops at the first file that can't be removed (the sidecar is last, so a
  # unit cut short keeps its checksums); one already gone counts as removed.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_files(dir, entry) do
    removed =
      Enum.reduce_while(entry.files, [], fn name, removed ->
        case File.rm(Path.join([dir, entry.sub, name])) do
          result when result in [:ok, {:error, :enoent}] ->
            {:cont, [name | removed]}

          {:error, reason} ->
            Logger.warning(
              "Retention couldn't remove #{name} (#{inspect(reason)}); kept the rest"
            )

            {:halt, removed}
        end
      end)
      |> Enum.reverse()

    if removed != [],
      do: Logger.info("Retention removed #{label(entry)}: #{reason_text(entry.reason)}")

    removed
  end

  defp label(%{kind: :stray, files: [name]}), do: "stray file #{name}"
  defp label(%{kind: kind, stamp: stamp}), do: "#{kind} backup #{stamp}"

  defp reason_text({:expired, :unrecorded, days}),
    do: "older than #{days} days, with no recorded run"

  defp reason_text({:expired, :schedule, days}),
    do: "older than #{days} days, the keep days of the schedule that made it"

  defp reason_text({:expired, _rule, days}), do: "older than #{days} days"
end
