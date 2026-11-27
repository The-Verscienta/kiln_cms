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
  `.good` and `.hold`) and `.partial` files are never strays. A file kept after
  its off-site copy was refused, `<name>.refused-<stamp>` in its own kind's
  directory (`Artifact.refused_name/2`, #2484), is a stray aged from the later
  of its mtime and the refusal stamp in its name.

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
  reads a `.hold` as a keep rule. A unit with no data file left, only its
  sidecar, gets no hold.

  ### A held backup deleted outside the app (#2931)

  A host whose `scripts/backup.sh` predates the hold markers ignores them,
  and its cron prune deletes what a schedule keeps. Each sync spots that from
  the `.hold` markers the scan listed, before any is written or removed
  (`held_deleted_candidates/2`): a held unit with no member left at all (the
  v1.9.x script's `remove_unit` deletes the sidecar too), or none but its
  sidecar (v1.8 and older prune with `find` by age, which can leave the
  `.sha256`), whose stamp has no `.work/` directory, whose Run is not
  running, and whose Run doesn't record the app pruning that kind here (the
  app's own deletes, one that stopped part-way included). The scan's held
  stamps are part of the one Run read, so this adds no query. Such a unit's
  `.hold` is stale, and it is reported only once that `.hold` is removed, so
  a marker that can't be removed (a directory, say) is never reported, and a
  removed one is never reported twice. The report is a warning naming up to
  ten units ("and N more"), a `[:kiln_cms, :backups, :hold, :deleted_outside]`
  event (`%{count: n}`, with `scope: :local`), and a notice
  (`KilnCMS.Backups.Notices.held_deleted/2`) that the Backups page and the
  Schedule tab show. A unit the app pruned whose Run could not be marked
  (`Recorder.mark_pruned/2` is best-effort) is reported too.

  ### A stale hold that can't be removed (#3004)

  A `.hold` the plan no longer names whose removal fails (a permission
  error, a busy file, an entry that is not a regular file) keeps its unit
  for this pass of `run/2`: the unit is left out of the deletes, with a
  warning naming it and the reason, and `run/2` lists it in `kept`. The
  prune step turns that into a `:stopped` retention notice and a run log
  line, so a stuck hold doesn't pin disk unseen. Deleting the unit anyway
  would leave a hold naming a unit that is gone; with no Run row to mark
  pruned, the next sync would report the app's own delete as one made
  outside the app. Right before each unit goes, a `.hold` of it still in
  its own directory also keeps it (the backstop for the same case), with a
  warning, and lists it in `kept` too.
  `backup.sh prune` never removes a hold, and keeps every unit that has
  one, so it has no such case.

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
  left alone. The Run read covers the stamps of the `.hold` markers too, so
  when it fails no held unit is reported deleted either; the next sync looks
  again.

  ## What cron can't see

  `backup.sh prune` has no database: rules 1, 2 (except a running Run), 4 and
  9 apply there, and rule 3 only through the last-good marker: a unit with a
  `.good` in its own directory is kept, so cron keeps the newest verified
  backup even when a newer complete set from a failed run exists. Rules 5 to
  8 apply there only through the hold markers. That holds as long as the app
  keeps the markers in step; a host whose copy of `backup.sh` predates a
  marker ignores it. Where a schedule keeps less than `BACKUP_KEEP_DAYS`,
  cron keeps more than the app, never less. Cron never deletes strays or
  markers, except a file kept after a refusal, which it ages as this module
  does. Unlike this module, it does delete `.partial` files: those of a run
  killed outright, once every file of the stamp is 12 hours old (#2478). Here
  a `.partial` is only ever a reason to keep; the start step's sweep removes
  one, once its stamp has a run row.

  ## On an off-site destination (#2220, ADR 0064)

  `run_on_destination/3` prunes one destination, right after a backup
  finished sending to it (`KilnCMS.Backups.Steps`), when its adapter
  `supports/0` both `:list` and `:delete`, and pruning is turned on there:
  a stored destination's `prune`, or, for the env destination
  (`BACKUP_RCLONE_REMOTE`), `BACKUP_RCLONE_REMOTE_PRUNE` (#2950, off by
  default). Only the in-app off-site step prunes the env remote;
  `scripts/backup.sh` never does, so the switch does nothing on a
  cron-only install.

    0. **Location.** Before anything is listed, where the destination writes
       is checked again (`prune_blocker/3`, the rule the Destinations tab's
       badge shows too), since a row was saved before the environment or
       the other rows were what they are now. Nothing is pruned on a stored
       destination that is, contains or is inside `BACKUP_RCLONE_REMOTE`, or
       another stored destination; nor on one whose location can't be told
       (a plugin's kind) or can't be compared with an rclone remote (an S3
       bucket, #2221, or an SFTP server, #2222) while `BACKUP_RCLONE_REMOTE`
       is set, since nothing can show the two apart. The env remote is pruned
       only while every stored destination, enabled or not, has a location
       that can be told, is neither an S3 bucket nor an SFTP server, and does
       not overlap it.
    1. **Inventory.** The destination's `list/1`, through
       `KilnCMS.Backups.Destination.call/4`, grouped into units as `scan/1`
       groups the local disk (`destination_inventory/4`). Only whole backup
       files in their own `db/` or `media/` count; anything else it lists is
       ignored. A unit's age is the later of its newest remote mtime and its
       stamp's own instant, so a copy whose mtime the store reset, or doesn't
       report, is never older than the backup itself.
    2. **Local pins.** The `.keep` markers and the `.work/` directories of
       this host's backup directory are merged in, so a recovery point pins
       the remote copy too, and a backup in flight is never touched. The
       `.good`, `.hold` and `.keep` markers stay local: nothing here uploads,
       lists or reads a marker on the destination.
    3. **The keep rules**, exactly as above (`plan/4`), over the
       destination's own units: its newest verified and newest complete unit
       of each kind are never deleted.
    4. **Ownership.** Of what the rules would delete, only a unit whose Run
       records sending it to THIS destination key (an artifact of that kind,
       or one of its parts, with the key's status `ok`, or `pruned` by an
       earlier pass that stopped part-way) is deleted, and only when that Run
       is an in-app one (`origin: :app`) whose `dir_id` is this backup
       directory's `.kiln-dir-id`, or, on a stored destination, a directory
       the destination adopted for it (`DestinationConfig.owners/2`)
       (`destination_plan/5`). Anything else, such as another installation's
       backup in a shared bucket, a cron-made or imported backup, or a
       backup another backup directory sent (a database restored on another
       server keeps the original server's run history), is left and
       reported. A directory with no `.kiln-dir-id` deletes nothing.
    5. **Delete.** Each unit is re-checked (`recheck/2`; a unit an adopted
       directory sent, also against the destination's row as it is then),
       then deleted one
       file at a time, data before the sidecar. The first delete that fails
       or runs past its bound stops the pass. The files deleted are marked
       `pruned` under that key on their runs (`Recorder.mark_pruned/2`).

  Each `list` and each `delete` call has a bound of its own (10 minutes for
  the listing, 60 seconds for a delete), and the step's deadline when that
  comes first, so one hung call can't use up the whole off-site step
  (#2950). A listing past its bound is a skip, as one that fails is; a
  delete past its bound stops the pass, and the store may still have
  removed that file (the next pass simply no longer lists it).

  It fails closed: a policy that can't be resolved, a local backup directory
  that can't be listed, a destination listing that fails, or a Run read that
  fails deletes nothing and returns `{:error, reason}`.
  """
  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups

  alias KilnCMS.Backups.{
    Artifact,
    Destination,
    DestinationConfig,
    DirId,
    Importer,
    Notices,
    Recorder,
    WorkState
  }

  alias KilnCMS.Backups.Destination.Sftp
  alias KilnCMS.Backups.Destination.Sftp.HostKey
  alias KilnCMS.Backups.Retention.Policy

  require Logger

  @partial_grace_s 3600
  @day 86_400
  @log_units 10

  # The bound on one `list` and on one `delete` of a destination's retention
  # (#2950), each also bounded by the step's deadline. A listing of a large
  # bucket takes minutes; one file's delete, seconds.
  @list_call_ms :timer.minutes(10)
  @delete_call_ms :timer.seconds(60)
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

  @typedoc """
  What `scan/1` found on this host's disk, or `destination_inventory/4` on a
  destination, which also carries the destination's `key`.
  """
  @type inventory :: %{
          required(:units) => %{{String.t(), :db | :media} => unit()},
          required(:markers) => MapSet.t(String.t()),
          required(:work) => MapSet.t(String.t()),
          required(:strays) => [
            %{
              required(:name) => String.t(),
              required(:sub) => String.t(),
              required(:mtime) => integer(),
              optional(:refused_at) => String.t()
            }
          ],
          optional(:held) => MapSet.t({String.t(), :db | :media}),
          optional(:key) => String.t()
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

  @typedoc """
  A unit the plan would delete, kept because its stale `.hold` couldn't be
  removed (#3004): why, as the removal failed.
  """
  @type held_kept :: %{stamp: String.t(), kind: :db | :media, reason: term()}

  @doc """
  How long a `.partial` counts as a live writer's work: younger, and its unit
  is in flight; older, and the start step's partial sweep removes it once
  every file of its stamp is older and the stamp has a run row (#2478).
  """
  @spec partial_grace_s() :: pos_integer()
  def partial_grace_s, do: @partial_grace_s

  @doc """
  Import, plan, sync the last-good and hold markers and delete. Returns `{:ok, %{deleted: names, units: count,
  plan: plan, stopped: nil | reason, kept: kept}}` — `names` are the file
  names removed, already marked `pruned` on their runs; `stopped` is set when
  the deleting itself broke off part-way (what was removed by then is still
  in `names`); `kept` lists the units the plan would delete that were kept
  because their stale `.hold` couldn't be removed (#3004, see "The hold
  markers"), as `%{stamp, kind, reason}` — or `{:error, reason}` when
  retention could not start, with nothing deleted.

  Options:

    * `:policy` - a `Policy` struct, or a 0-arity function returning
      `{:ok, policy} | {:error, reason}`. Defaults to `&Policy.current/0`:
      `BACKUP_KEEP_DAYS` and every schedule's keep rules, read fail-closed.
    * `:now` - posix seconds (default: now).
    * `:dry_run` - plan only; delete nothing and write no marker (default
      `false`).
    * `:under_lease` - a function that runs a 0-arity function only while
      the backup step's lease holds, `{:ok, result}` or
      `{:error, :superseded}` (the prune step's `Chain.while_holding/2`,
      #3041). The marker sync runs inside it.
    * `:discard` - a function that removes a unit's paths under that lease,
      `:ok` or `{:error, reason}` (the prune step's move into the trash,
      ADR 0067). Used instead of deleting each file in place.

  With them, a prune step that lost its lease (canceled, then resumed, on a
  node that missed the Cancel) deletes nothing and writes no marker: the
  pass is `{:error, :superseded}` when the lease was gone before it started,
  and stops with `stopped: :superseded` when it went part-way, keeping what
  it had deleted under the lease in `deleted`.
  """
  @spec run(Path.t(), keyword()) ::
          {:ok,
           %{
             deleted: [String.t()],
             units: non_neg_integer(),
             plan: plan(),
             stopped: term() | nil,
             kept: [held_kept()]
           }}
          | {:error, term()}
  def run(dir \\ Backups.dir(), opts \\ []) do
    case prepare(dir, opts) do
      {:ok, {plan, inventory, runs}} ->
        if Keyword.get(opts, :dry_run, false),
          do: {:ok, %{deleted: [], units: 0, plan: plan, stopped: nil, kept: []}},
          else: execute(dir, {plan, inventory, runs}, opts)

      {:error, reason} ->
        skipped(reason)
    end
  end

  # Everything before the first delete. Any failure here, a raise or an exit
  # included, means nothing was deleted.
  defp prepare(dir, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, _summary} <- import_first(dir),
         {:ok, policy} <- policy(opts),
         {:ok, inventory} <- scan(dir),
         {:ok, runs} <- read_runs(stamps(inventory)) do
      {:ok, {plan(inventory, runs, policy, now), inventory, runs}}
    end
  rescue
    error -> {:error, {:crashed, error.__struct__}}
  catch
    # A call into a process that died, or a query that timed out, exits;
    # retention is then skipped like any other failure to start.
    :exit, _reason -> {:error, {:crashed, :exit}}
  end

  # Whatever was deleted is marked on its runs, even when the deleting stopped
  # part-way. The markers move first: nothing below deletes the newest
  # verified unit, and a cron prune that runs meanwhile sees the new one.
  # A unit whose stale `.hold` the sync couldn't remove is left out of the
  # deletes (#3004): deleting it would leave a hold naming a unit that is
  # gone, which the next sync reports as deleted outside the app.
  defp execute(dir, {plan, inventory, runs}, opts) do
    markers = fn ->
      _ = sync(dir, plan.last_good, opts)
      sync_holds(dir, plan.holds, inventory, runs, opts)
    end

    case under_lease(opts, markers) do
      {:ok, stuck} ->
        {to_delete, kept} = withhold(plan.delete, stuck)

        {deleted, units, stopped, held} =
          delete_entries(
            dir,
            %{plan | delete: to_delete},
            Keyword.take(opts, [:before_unit, :discard])
          )

        Recorder.mark_pruned(deleted)
        if stopped, do: stopped(deleted, stopped)

        {:ok, %{deleted: deleted, units: units, plan: plan, stopped: stopped, kept: kept ++ held}}

      {:error, :superseded} = superseded ->
        Logger.info("Backup retention skipped: the prune step no longer holds the backup lock")
        superseded
    end
  end

  # The plan's deletes without the units whose stale hold is stuck, and those
  # units, each with a warning: a stuck hold must not pin disk unseen.
  defp withhold(delete, stuck) when map_size(stuck) == 0, do: {delete, []}

  defp withhold(delete, stuck) do
    {kept, rest} =
      Enum.split_with(delete, &Map.has_key?(stuck, {&1.stamp, &1.kind}))

    kept =
      for entry <- kept do
        reason = Map.fetch!(stuck, {entry.stamp, entry.kind})

        Logger.warning(
          "Retention kept #{label(entry)}: its stale hold marker " <>
            "#{entry.sub}/#{Artifact.hold_name(entry.stamp)} couldn't be removed " <>
            "(#{hold_reason(reason)}). Remove it by hand so retention can delete the backup"
        )

        %{stamp: entry.stamp, kind: entry.kind, reason: reason}
      end

    {rest, kept}
  end

  # The marker sync, under the step's lease when it has one (#3041), as the
  # finish step's sync is (#3013).
  defp under_lease(opts, fun) do
    case Keyword.get(opts, :under_lease) do
      nil -> {:ok, fun.()}
      under_lease -> under_lease.(fun)
    end
  end

  defp skipped(reason) do
    Logger.error("Backup retention skipped: #{describe(reason)}; nothing was deleted")

    :telemetry.execute([:kiln_cms, :backups, :retention, :skipped], %{count: 1}, %{
      scope: :local,
      reason: reason
    })

    {:error, reason}
  end

  # Not a failure: the step that took over prunes.
  defp stopped(deleted, :superseded) do
    Logger.info(
      "Backup retention removed #{length(deleted)} file(s), then stopped: the prune step " <>
        "no longer holds the backup lock"
    )
  end

  defp stopped(deleted, reason) do
    Logger.error(
      "Backup retention removed #{length(deleted)} file(s), then stopped: #{describe(reason)}"
    )

    :telemetry.execute(
      [:kiln_cms, :backups, :retention, :stopped],
      %{count: 1, deleted: length(deleted)},
      %{scope: :local, reason: reason}
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

  def describe({:list, reason}),
    do: "couldn't list the destination (#{Destination.format_reason(reason)})"

  def describe({:read_destination, reason}),
    do: "couldn't read the destination's settings (#{inspect(reason)})"

  def describe({:delete, name, reason}),
    do: "couldn't delete #{name} (#{Destination.format_reason(reason)})"

  def describe(:env_overlap), do: "it overlaps BACKUP_RCLONE_REMOTE"

  def describe(:env_overlap_unknown),
    do: "can't confirm it doesn't overlap BACKUP_RCLONE_REMOTE"

  def describe(:destination_overlap), do: "it overlaps another backup destination"

  def describe(:destination_overlap_possible),
    do:
      "another S3 backup destination uses a bucket of the same name; the app can't tell " <>
        "whether it is the same store"

  def describe(:destination_unknown),
    do:
      "a stored backup destination's location can't be told, so it can't be shown not to " <>
        "overlap BACKUP_RCLONE_REMOTE"

  def describe(:destination_s3),
    do: "an S3 backup destination can't be compared with BACKUP_RCLONE_REMOTE"

  def describe(:destination_sftp),
    do: "an SFTP backup destination can't be compared with BACKUP_RCLONE_REMOTE"

  def describe(:destination_overlap_possible_sftp),
    do:
      "another SFTP backup destination uses a folder inside or around this one's; the app " <>
        "can't tell whether it is the same server until both trust host keys of the same " <>
        "type that differ, and each has passed a Test since the later of the two was trusted"

  def describe({:dir_id, reason}),
    do: "couldn't read the backup directory's id (#{inspect(reason)})"

  def describe(:not_prunable), do: "Kiln doesn't prune this destination"
  def describe(:unsupported), do: "its adapter can't list and delete files"
  def describe({:crashed, module}), do: "it crashed (#{inspect(module)})"

  def describe({:stale_holds, [%{stamp: stamp, kind: kind, reason: reason}]}),
    do:
      "a stale hold marker it couldn't remove kept #{kind} backup #{stamp} " <>
        "(#{Artifact.subdir(kind)}/#{Artifact.hold_name(stamp)}: #{hold_reason(reason)})"

  def describe({:stale_holds, kept}) when is_list(kept) do
    named =
      kept
      |> Enum.take(@log_units)
      |> Enum.map_join(", ", &"#{&1.kind} backup #{&1.stamp} (#{hold_reason(&1.reason)})")

    more = if length(kept) > @log_units, do: " and #{length(kept) - @log_units} more", else: ""

    "stale hold markers it couldn't remove kept #{length(kept)} backups: #{named}#{more}"
  end

  def describe({:cron_prune, text}) when is_binary(text), do: text
  def describe(:superseded), do: "this backup step no longer holds the backup lock"
  def describe(reason), do: inspect(reason)

  # `config :kiln_cms, KilnCMS.Backups, importer:` swaps the module in tests
  # only, as for the steps' own imports (`KilnCMS.Backups.Steps`).
  defp import_first(dir) do
    importer =
      Keyword.get(Application.get_env(:kiln_cms, KilnCMS.Backups, []), :importer, Importer)

    case importer.run(dir) do
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
        sync_holds(dir, plan(inventory, runs, policy, now).holds, inventory, runs, opts)

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
  # The held units found deleted outside the app are worked out from the
  # scan's holds before any of that, and reported once their `.hold` is gone.
  # Returns the stale holds that couldn't be removed, `%{{stamp, kind} =>
  # reason}`, so a prune keeps their units (#3004).
  defp sync_holds(dir, holds, inventory, runs, opts) do
    create = Keyword.get(opts, :create_marker, &create_marker/1)
    gone = held_deleted_candidates(inventory, runs)

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

    results =
      for kind <- [:db, :media],
          {stamp, result} <- remove_stale_holds(dir, kind, MapSet.new(Map.get(holds, kind, []))),
          do: {{stamp, kind}, result}

    removed = for {unit, :ok} <- results, into: MapSet.new(), do: unit

    gone
    |> Enum.filter(&MapSet.member?(removed, {&1.stamp, &1.kind}))
    |> held_deleted(dir, opts)

    for {unit, {:error, reason}} <- results, into: %{}, do: {unit, reason}
  end

  # The kind's stale `.hold` markers, each with how its removal went: `:ok`
  # (gone now) or `{:error, reason}`. A directory that can't be listed
  # removes and names none; a unit there whose hold is still in place is
  # kept anyway by the check right before its delete (`remove_unless_held/3`).
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_stale_holds(dir, kind, keep) do
    sub = Artifact.subdir(kind)

    case File.ls(Path.join(dir, sub)) do
      {:ok, names} ->
        for name <- names,
            {:ok, stamp} <- [Artifact.parse_hold_name(name)],
            not MapSet.member?(keep, stamp),
            do: {stamp, remove_marker(Path.join([dir, sub, name]), "#{sub}/#{name}", :hold)}

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Couldn't list #{sub}/ to remove old hold markers (#{inspect(reason)})")
        []
    end
  end

  defp hold_reason({:remove, reason}), do: inspect(reason)
  defp hold_reason({:not_regular, type}), do: "a #{type}, not a regular file"
  defp hold_reason({:lstat, reason}), do: "couldn't read it: #{inspect(reason)}"
  defp hold_reason(:still_there), do: "still there right before the delete"
  defp hold_reason(reason), do: inspect(reason)

  @doc false
  # The held units deleted outside the app (#2931), pure: every
  # `{stamp, kind}` the scan found a `.hold` for (`inventory.held`) whose
  # unit has no member left (a v1.9.x `backup.sh`'s `remove_unit` deletes the
  # sidecar too), or none but its sidecar (v1.8 and older prune with `find` by
  # age, which can leave the `.sha256`). Not one whose stamp has a `.work/` directory or whose Run is
  # running (a backup still writing it), nor one whose Run records the app
  # pruning it here (`Recorder.mark_pruned/2`, the artifact or any of its
  # parts: retention's own deletes, a pass that stopped part-way included,
  # since the sidecar goes last). `runs` must cover the held stamps
  # (`stamps/1` includes them). Returned as `[%{stamp, kind}]`, sorted.
  @spec held_deleted_candidates(inventory(), %{String.t() => map()}) :: [
          %{stamp: String.t(), kind: :db | :media}
        ]
  def held_deleted_candidates(inventory, runs) do
    inventory
    |> Map.get(:held, MapSet.new())
    |> Enum.filter(fn {stamp, kind} ->
      run = runs[stamp]

      not has_data?(inventory.units[{stamp, kind}]) and
        not MapSet.member?(inventory.work, stamp) and
        not match?(%{status: :running}, run) and
        not pruned_here?(run, kind)
    end)
    |> Enum.sort()
    |> Enum.map(fn {stamp, kind} -> %{stamp: stamp, kind: kind} end)
  end

  defp has_data?(nil), do: false
  defp has_data?(unit), do: Enum.any?(unit.files, &(&1.role == :data))

  defp pruned_here?(%{artifacts: artifacts}, kind) when is_list(artifacts) do
    Enum.any?(artifacts, fn artifact ->
      artifact.kind == kind and
        (local_pruned?(artifact.destinations) or
           Enum.any?(artifact.parts || [], &local_pruned?(&1["destinations"])))
    end)
  end

  defp pruned_here?(_run, _kind), do: false

  defp local_pruned?(%{} = destinations),
    do: get_in(destinations, ["local", "status"]) == "pruned"

  defp local_pruned?(_none), do: false

  # The report: a warning naming up to ten, a
  # `[:kiln_cms, :backups, :hold, :deleted_outside]` event, and the notice
  # (`notify:`, tests only, standing in for `Notices.held_deleted/2`, which
  # never raises and holds its write until any open lock transaction commits).
  defp held_deleted([], _dir, _opts), do: :ok

  defp held_deleted(units, dir, opts) do
    count = length(units)

    named =
      units |> Enum.take(@log_units) |> Enum.map_join(", ", &"#{&1.kind} backup #{&1.stamp}")

    more = if count > @log_units, do: " and #{count - @log_units} more", else: ""

    Logger.warning(
      "#{count} backup(s) a schedule keeps were deleted outside the app although their " <>
        ".hold markers kept them: #{named}#{more}. The host's scripts/backup.sh is " <>
        "probably older than this release and ignores .hold markers"
    )

    :telemetry.execute([:kiln_cms, :backups, :hold, :deleted_outside], %{count: count}, %{
      dir: dir,
      scope: :local,
      units: units
    })

    notify = Keyword.get(opts, :notify, &Notices.held_deleted/2)
    notify.(dir, units)
    :ok
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
            {:error, {:remove, reason}}
        end

      {:ok, %{type: type}} ->
        Logger.warning("Left #{label} in place: a #{type}, not a regular file")
        removal_failed(which, %{marker: label, reason: {:not_regular, type}})
        {:error, {:not_regular, type}}

      {:error, :enoent} ->
        :ok

      {:error, unreadable} ->
        {:error, {:lstat, unreadable}}
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
      # never a stray; the marker sync manages both. A hold is listed, for
      # the held units deleted outside the app (#2931).
      match?({:ok, _}, Artifact.parse_hold_name(name)) ->
        {:ok, stamp} = Artifact.parse_hold_name(name)
        {:hold, {stamp, if(sub == "db", do: :db, else: :media)}}

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
          :error -> refused_or_none(name)
        end
    end
  end

  defp refused_or_none(name) do
    case Artifact.parse_refused_name(name) do
      {:ok, refused} -> {:refused, refused}
      :error -> :none
    end
  end

  # A file kept after a refusal (#2484) is no unit's member: a stray that
  # ages from its refusal as well as its mtime (`stray_age/2`).
  defp classify_file(dir, sub, name, {:refused, refused}), do: refused(dir, sub, name, refused)

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

  # Only in its own kind's directory, where the backup sets one aside; one
  # anywhere else is a plain stray.
  defp refused(dir, sub, name, %{kind: kind, refused_at: refused_at}) do
    with {:stray, stray} <- stray(dir, sub, name) do
      if Artifact.subdir(kind) == sub,
        do: {:stray, Map.put(stray, :refused_at, refused_at)},
        else: {:stray, stray}
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
    empty = %{units: %{}, partials: %{}, markers: MapSet.new(), held: MapSet.new(), strays: []}

    acc =
      Enum.reduce(classified, empty, fn
        {:marker, stamp}, acc ->
          %{acc | markers: MapSet.put(acc.markers, stamp)}

        {:hold, key}, acc ->
          %{acc | held: MapSet.put(acc.held, key)}

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
      held: acc.held,
      work: work |> Enum.filter(&WorkState.valid_stamp?/1) |> MapSet.new(),
      strays: Enum.sort_by(acc.strays, &{&1.sub, &1.name})
    }
  end

  # The held stamps too, so the one Run read also tells the hold sync which
  # held units the app pruned itself.
  defp stamps(inventory) do
    (Map.keys(inventory.units) ++ MapSet.to_list(Map.get(inventory, :held, MapSet.new())))
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
  end

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
               :schedule_ids,
               :dir_id
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
  # A unit with no data file left (only its sidecar) holds nothing worth a
  # `.hold`: its hold goes, and the sync reports it if the app didn't prune it.
  defp holds(units, runs, policy, counted, now) do
    held =
      for unit <- units,
          has_data?(unit),
          held?(unit, runs[unit.stamp], policy, counted, now),
          do: unit

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

    if expired?(stray_age(stray, now), policy.keep_days, now),
      do: {:delete, Map.put(entry, :reason, {:expired, :stray, policy.keep_days})},
      else: {:keep, Map.put(entry, :reason, :keep_days)}
  end

  # A file kept after a refusal (#2484) ages from the later of its mtime and
  # the refusal its name records: the rename kept the mtime, which says when
  # the file last changed and may be long before it was set aside. A refusal
  # stamp that is no plausible instant (`plausible_stamp?/2`) counts for
  # nothing, so a forged name can't keep the file forever. `backup.sh prune`
  # ages it the same way.
  defp stray_age(%{refused_at: refused_at, mtime: mtime}, now) do
    with true <- plausible_stamp?(refused_at, now),
         {:ok, at} <- Artifact.parse_stamp(refused_at) do
      max(mtime, DateTime.to_unix(at))
    else
      _ -> mtime
    end
  end

  defp stray_age(stray, _now), do: stray.mtime

  ## Destinations (#2220)

  @doc """
  Prune the destination `config`, after a backup sent to it (see "On an
  off-site destination"): a stored one, or the env destination
  (`BACKUP_RCLONE_REMOTE`) when `BACKUP_RCLONE_REMOTE_PRUNE` is on
  (`Backups.rclone_remote_prune?/0`, #2950). `dir` is this host's backup
  directory, for its `.keep` markers, its `.work/` directories and its
  `.kiln-dir-id`, whose backups (and the adopted directories') are the only
  ones a pass deletes.

  Returns `{:ok, %{deleted: names, units: count, unowned: entries,
  other_directory: entries, stopped: nil | reason}}`: the file names
  deleted (already marked `pruned` on their runs), how many units they came
  from, the units the keep rules would have deleted but that are not this
  backup directory's to delete (left alone), those of them an in-app backup
  of another backup directory sent there, and why the deleting broke off,
  if it did. `{:error, reason}`
  when it could not start, with nothing deleted: `{:error, :not_prunable}`
  for the env destination with the switch off (or any key that is neither),
  and `prune_blocker/3`'s reason when that names one (`:unsupported` for an
  adapter that can't list and delete).

  Options:

    * `:policy` and `:now` - as for `run/2`;
    * `:adoptions` - a stored destination's `adoptions`, read again for
      this pass (`DestinationConfig.owners/2`); none by default;
    * `:deadline` - the step's deadline (a
      `System.monotonic_time(:millisecond)` instant). Each `list` and
      `delete` call is bounded by it and by its own limit, whichever comes
      first (`Destination.call_deadline/2`);
    * `:list_call_ms` and `:delete_call_ms` - those limits (default
      #{div(@list_call_ms, 60_000)} minutes for the listing,
      #{div(@delete_call_ms, 1000)} seconds for each delete).
  """
  @spec run_on_destination(Path.t(), Config.t(), keyword()) ::
          {:ok,
           %{
             deleted: [String.t()],
             units: non_neg_integer(),
             unowned: [entry()],
             other_directory: [entry()],
             stopped: term() | nil
           }}
          | {:error, term()}
  def run_on_destination(dir, %Config{} = config, opts \\ []) do
    with {:ok, subject} <- prune_subject(config),
         :ok <- supported(config),
         :ok <- clear_to_prune(subject, config),
         {:ok, {current, owners}} <- owners(dir, subject, opts),
         {:ok, plan} <- prepare_destination(dir, config, owners, opts) do
      execute_destination(dir, config, plan, Keyword.put(opts, :current_dir_id, current))
    end
  end

  # What is pruned: a stored destination as itself, the env destination as
  # `:env` (where it writes is `Destination.env_location/0`), and only while
  # its switch is on. Its key is the one `Destination.env_key/1` gives the
  # remote set now, so a config resolved before the remote changed is not it.
  defp prune_subject(%Config{key: "dest:" <> _} = config), do: {:ok, config}

  defp prune_subject(%Config{id: nil, key: key}) do
    remote = Backups.rclone_remote()

    if is_binary(remote) and remote != "" and key == Destination.env_key(remote) and
         Backups.rclone_remote_prune?(),
       do: {:ok, :env},
       else: {:error, :not_prunable}
  end

  defp prune_subject(%Config{}), do: {:error, :not_prunable}

  defp supported(config) do
    if Destination.supports?(config, [:list, :delete]), do: :ok, else: {:error, :unsupported}
  end

  # Step 0 above. The overlap was refused when the row was created, but
  # `BACKUP_RCLONE_REMOTE` can have changed since, and a plugin's location
  # was never known: retention must not reach files another destination was
  # sent. Every row, disabled ones too: a disabled destination's files are
  # still there. Settings are enough for `Destination.location/1`.
  defp clear_to_prune(subject, config) do
    case Backups.list_backup_destinations(actor: Backups.system(), authorize_with: :error) do
      {:ok, rows} ->
        case prune_blocker(subject_for(subject, config), rows, Destination.env_location()) do
          nil -> :ok
          reason -> {:error, reason}
        end

      {:error, error} ->
        {:error, {:read_destination, error.__struct__}}
    end
  end

  defp subject_for(:env, _config), do: :env
  defp subject_for(%Config{}, config), do: config

  @typedoc """
  Why a destination whose pruning is on is not pruned (`prune_blocker/3`).
  """
  @type prune_blocker ::
          :unsupported
          | :env_overlap
          | :env_overlap_unknown
          | :destination_overlap
          | :destination_overlap_possible
          | :destination_overlap_possible_sftp
          | :destination_unknown
          | :destination_s3
          | :destination_sftp
          | :not_prunable

  @doc """
  Why pruning, where it is turned on, can't run on `subject`, or `nil` when
  it can (#2950). The one rule both retention and the Destinations tab
  apply, so the tab's "Prunes" badge shows only where a pass would prune.
  Pure: the caller reads `rows`, every stored destination (enabled or not;
  anything with `:id`, `:kind` and `:settings`; an SFTP row's `:host_key`,
  `:last_test_ok` and `:last_tested_at` too), and passes
  `Destination.env_location/0` as `env`.

  For a stored destination's `%Config{}`:

    * `:unsupported` - its adapter's `supports/0` lacks `:list` or `:delete`;
    * `:env_overlap` - it is, contains or is inside `BACKUP_RCLONE_REMOTE`;
    * `:env_overlap_unknown` - `BACKUP_RCLONE_REMOTE` is set and where it
      writes can't be told (a plugin's kind) or can't be compared with an
      rclone remote (an S3 bucket, #2221, or an SFTP server, #2222);
    * `:destination_overlap` - it overlaps another stored destination (one
      whose location can't be told overlaps nothing that can);
    * `:destination_overlap_possible` - another stored S3 destination names
      a bucket of the same name, one prefix inside the other, on another
      endpoint host or port: it may be the same bucket under another name
      (`Destination.possible_overlap?/2`, #3088);
    * `:destination_overlap_possible_sftp` - another stored SFTP
      destination's path is inside or around this one's, on any host, port
      or login: it may be the same folder (`Destination.possible_overlap?/2`,
      #2222). Unless both rows prove they are distinct servers (#3200):
      both trust a host key (`Sftp.trusted_key/1`) of the same type, the
      fingerprints differ, and each row's last Test passed
      (`last_test_ok`) after the later of the two `host_key["trusted_at"]`
      instants. A Test connects only to a server offering the row's trusted
      key, so it shows that key is still the server's own, after both keys
      were in place. Every other pair stays blocked: a key not yet trusted,
      keys of different types (one server holds an ed25519 and an RSA key),
      one fingerprint (one server by name and by IP), and a key that hasn't
      been seen since (a disabled row never connects, so a server
      reinstalled with a new key would otherwise look like another
      server; re-trusting one row of a rotated server moves the later
      trust past the other's last Test). The subject's own row in `rows`
      supplies its key and Test; with no row it is never proven. The exact
      `:destination_overlap` (same host, port and login) is never narrowed.

  For `:env`, the env destination, which may share a place with any of them
  unseen:

    * `:not_prunable` - `BACKUP_RCLONE_REMOTE` is unset (`env` is `nil`);
    * `:destination_unknown` - a stored destination's location can't be
      told (a plugin's);
    * `:destination_s3` - a stored destination is an S3 bucket, which the
      remote may name under any name;
    * `:destination_sftp` - a stored destination is an SFTP server, which
      the remote may name under any name;
    * `:destination_overlap` - a stored destination overlaps it.

  Whether pruning is turned on at all (a row's `prune`,
  `BACKUP_RCLONE_REMOTE_PRUNE`) is the caller's to check first.
  """
  @spec prune_blocker(Config.t() | :env, [map()], Destination.location() | nil) ::
          prune_blocker() | nil
  def prune_blocker(:env, _rows, nil), do: :not_prunable

  def prune_blocker(:env, rows, env) when is_list(rows) do
    Enum.find_value(rows, fn row -> env_row_blocker(row_location(row), env) end)
  end

  def prune_blocker(%Config{} = config, rows, env) when is_list(rows) do
    location = Destination.location(config)

    cond do
      not Destination.supports?(config, [:list, :delete]) ->
        :unsupported

      blocker = env_blocker(location, env) ->
        blocker

      overlaps_another?(
        location,
        config.id,
        rows,
        &Destination.overlap?(location, row_location(&1))
      ) ->
        :destination_overlap

      overlaps_another?(location, config.id, rows, fn row ->
        Destination.possible_overlap?(location, row_location(row)) and
            not distinct_servers?(config.id, row, rows)
      end) ->
        possible_overlap(location)

      true ->
        nil
    end
  end

  defp possible_overlap({:sftp, _host, _port, _user, _segments}),
    do: :destination_overlap_possible_sftp

  defp possible_overlap(_location), do: :destination_overlap_possible

  defp row_location(row),
    do: Destination.location(%Config{kind: row.kind, settings: row.settings})

  defp env_row_blocker(:unknown, _env), do: :destination_unknown
  defp env_row_blocker({:s3, _host, _port, _bucket, _prefix}, _env), do: :destination_s3
  defp env_row_blocker({:sftp, _host, _port, _user, _path}, _env), do: :destination_sftp

  defp env_row_blocker(location, env),
    do: if(Destination.overlap?(location, env), do: :destination_overlap)

  defp env_blocker(_location, nil), do: nil
  defp env_blocker(:unknown, _env), do: :env_overlap_unknown

  # An S3 bucket and an rclone remote can't be compared: the remote may name
  # the same bucket under any name (#2221, decided conservative per ADR 0064).
  defp env_blocker({:s3, _host, _port, _bucket, _prefix}, _env), do: :env_overlap_unknown

  # So can an SFTP server's folder, which the remote may reach as any
  # `sftp` remote (#2222).
  defp env_blocker({:sftp, _host, _port, _user, _path}, _env), do: :env_overlap_unknown

  defp env_blocker(location, env),
    do: if(Destination.overlap?(location, env), do: :env_overlap)

  defp overlaps_another?(:unknown, _id, _rows, _overlaps?), do: false

  defp overlaps_another?(_location, id, rows, overlaps?) do
    Enum.any?(rows, &(&1.id != id and overlaps?.(&1)))
  end

  @doc """
  Whether pressing **Test** on the SFTP rows involved would clear
  `config`'s `:destination_overlap_possible_sftp` (#3428), so the
  Destinations tab can say so. Pure, on the same `rows` and `env` as
  `prune_blocker/3`, whose rule it reuses rather than restates.

  True only when `prune_blocker/3` gives `:destination_overlap_possible_sftp`
  and every SFTP row whose path may overlap this one's lacks nothing but
  the Tests (#3200): both rows trust a key of the same type, the
  fingerprints differ, both trust times can be read, and one row or both
  hasn't passed a Test since the later trust. One partner that a Test
  can't clear (no trusted key, keys of different types, one fingerprint)
  makes it false, since the row stays blocked whatever is tested.
  """
  @spec cleared_by_test?(Config.t() | :env, [map()], Destination.location() | nil) ::
          boolean()
  def cleared_by_test?(%Config{} = config, rows, env) when is_list(rows) do
    location = Destination.location(config)

    prune_blocker(config, rows, env) == :destination_overlap_possible_sftp and
      rows
      |> Enum.filter(
        &(&1.id != config.id and Destination.possible_overlap?(location, row_location(&1)))
      )
      |> Enum.all?(&(server_proof(config.id, &1, rows) in [:proven, :untested]))
  end

  def cleared_by_test?(:env, _rows, _env), do: false

  # Two SFTP rows whose paths nest are distinct servers when both trust a
  # key of the same type with different fingerprints, and each passed a
  # Test after the later of the two trusts (#3200). Positive proof only:
  # nothing here infers a key is good from the absence of a refusal.
  defp distinct_servers?(id, other, rows), do: server_proof(id, other, rows) == :proven

  # `:proven` (distinct servers), `:untested` (the keys would prove it, but
  # one row or both hasn't passed a Test since the later trust, #3428), or
  # `:unproven` (no Test can prove it).
  defp server_proof(id, %{kind: "sftp"} = other, rows) do
    with %{kind: "sftp"} = own <- Enum.find(rows, &(&1.id == id)),
         {type, own_fingerprint} <- Sftp.trusted_key(own),
         {^type, other_fingerprint} <- Sftp.trusted_key(other),
         false <- HostKey.same?(own_fingerprint, other_fingerprint),
         %DateTime{} = own_trusted <- trusted_at(own),
         %DateTime{} = other_trusted <- trusted_at(other) do
      later = Enum.max([own_trusted, other_trusted], DateTime)

      if tested_since?(own, later) and tested_since?(other, later),
        do: :proven,
        else: :untested
    else
      _missing_untrusted_or_same -> :unproven
    end
  end

  defp server_proof(_id, _row, _rows), do: :unproven

  defp trusted_at(%{host_key: %{"trusted_at" => at}}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp trusted_at(_row), do: nil

  defp tested_since?(row, instant) do
    case {Map.get(row, :last_test_ok), Map.get(row, :last_tested_at)} do
      {true, %DateTime{} = at} -> DateTime.compare(at, instant) == :gt
      _untested_or_failed -> false
    end
  end

  # Whose units the ownership rule (step 4) accepts: in-app runs of THIS
  # backup directory (`origin: :app` and its `dir_id` this directory's
  # `.kiln-dir-id`), on the env destination (#2950), which cron sends to
  # under the same key, and on a stored one, where a database restored on
  # another server would otherwise find the original server's run history
  # and delete what that server sent. A stored destination adds the
  # directories it adopted for this one (`DestinationConfig.owners/2`). A
  # directory with no id has made no in-app backup, so nothing there is its.
  defp owners(dir, subject, opts) do
    case DirId.current(dir) do
      {:ok, id} -> {:ok, {id, owners_of(subject, id, opts)}}
      {:error, reason} -> {:error, {:dir_id, reason}}
    end
  end

  defp owners_of(:env, id, _opts), do: [id]

  defp owners_of(%Config{}, id, opts),
    do: DestinationConfig.owners(id, Keyword.get(opts, :adoptions, []))

  defp prepare_destination(dir, config, owners, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, policy} <- policy(opts),
         {:ok, local} <- scan(dir),
         {:ok, listing} <- list_destination(config, opts),
         inventory = destination_inventory(config.key, listing, local, now),
         {:ok, runs} <- read_runs(stamps(inventory)) do
      {:ok, destination_plan(inventory, runs, policy, now, owners: owners)}
    end
  rescue
    error -> {:error, {:crashed, error.__struct__}}
  end

  # A hung listing costs this destination's retention, never the whole step
  # (#2950): it is a skip, as any listing that fails is.
  defp list_destination(config, opts) do
    started = System.monotonic_time(:millisecond)
    deadline = Destination.call_deadline(opts[:deadline], list_call_ms(opts))
    result = Destination.call(config, :list, [], deadline: deadline)

    Logger.info(
      "Retention on #{config.key}: the listing took " <>
        "#{System.monotonic_time(:millisecond) - started} ms"
    )

    case result do
      {:ok, listing} when is_list(listing) -> {:ok, listing}
      {:ok, _other} -> {:error, {:list, "the adapter's listing is not a list"}}
      {:error, reason} -> {:error, {:list, reason}}
    end
  end

  defp list_call_ms(opts), do: Keyword.get(opts, :list_call_ms, @list_call_ms)
  defp delete_call_ms(opts), do: Keyword.get(opts, :delete_call_ms, @delete_call_ms)

  @doc """
  The inventory of a destination keyed `key`, from its `list/1` output, with
  `local`'s (`scan/1`'s) `.keep` markers and `.work/` stamps merged in. Pure.

  Only a whole backup file (`Destination.backup_file?/1`) listed in its own
  kind's `db/` or `media/` is a member: anything else is ignored, never a
  stray, since nothing proves it is Kiln's. Every member counts as a regular
  file of its listed size (an unknown size is 0, so such a unit is never
  complete and never takes a newest slot). Its mtime is the later of the
  listed one and the stamp's own instant; with neither, `now`, so a unit
  whose age can't be told never ages out.
  """
  @spec destination_inventory(String.t(), [map()], inventory(), integer()) :: inventory()
  def destination_inventory(key, listing, local, now) do
    units =
      listing
      |> Enum.flat_map(&remote_member(&1, now))
      |> Enum.reduce(%{}, fn {{stamp, kind} = unit_key, file}, acc ->
        unit = Map.get(acc, unit_key, %{stamp: stamp, kind: kind, files: [], partials: []})
        Map.put(acc, unit_key, %{unit | files: [file | unit.files]})
      end)

    %{units: units, markers: local.markers, work: local.work, strays: [], key: key}
  end

  defp remote_member(%{subdir: subdir, name: name} = item, now)
       when is_binary(subdir) and is_binary(name) do
    with true <- Destination.backup_file?(name) and name == Path.basename(name),
         {role, %{kind: kind, stamp: stamp} = parsed} <- parsed(name),
         true <- Artifact.subdir(kind) == subdir do
      [
        {{stamp, kind},
         %{
           name: name,
           role: role,
           part: parsed.part,
           type: :regular,
           size: remote_size(item[:bytes]),
           mtime: remote_age(item[:mtime], stamp, now)
         }}
      ]
    else
      _ -> []
    end
  end

  defp remote_member(_item, _now), do: []

  defp remote_size(bytes) when is_integer(bytes) and bytes >= 0, do: bytes
  defp remote_size(_unknown), do: 0

  # The later of the two, so a tie, or a store that reset the mtime to the
  # upload's, errs toward keeping.
  defp remote_age(mtime, stamp, now) do
    at =
      case Artifact.parse_stamp(stamp) do
        {:ok, at} -> DateTime.to_unix(at)
        :error -> nil
      end

    case Enum.reject([remote_mtime(mtime), at], &is_nil/1) do
      [] -> now
      times -> Enum.max(times)
    end
  end

  defp remote_mtime(%DateTime{} = at), do: DateTime.to_unix(at)
  defp remote_mtime(posix) when is_integer(posix), do: posix
  defp remote_mtime(_unknown), do: nil

  @doc """
  The plan for a destination's inventory (`destination_inventory/4`):
  `plan/4`'s keep rules, then the ownership filter. Pure.

  Returns `%{delete: entries, keep: entries, unowned: entries,
  other_directory: entries}`. `delete` holds only units whose Run is an
  in-app one (`origin: :app`) of a backup directory in `opts[:owners]` and
  records sending them to the inventory's key; `unowned` the units the
  rules would have deleted but that have no such record (they are in `keep`
  too, with the reason `{:not_sent_here, rule_reason}`); `other_directory`
  those of `unowned` whose record is an in-app run of another backup
  directory.

  `opts[:owners]` is the list of backup-directory ids whose runs may make a
  unit deletable. Without it, or with `[]`, nothing is deleted: cron sends
  to the env remote under the same key, and a database restored on another
  server carries the original server's run history.
  """
  @spec destination_plan(inventory(), %{String.t() => map()}, Policy.t(), integer(), keyword()) ::
          %{
            delete: [entry()],
            keep: [entry()],
            unowned: [entry()],
            other_directory: [entry()]
          }
  def destination_plan(%{key: key} = inventory, runs, %Policy{} = policy, now, opts \\ []) do
    plan = plan(inventory, runs, policy, now)
    owners = Keyword.get(opts, :owners) || []

    {owned, unowned} =
      Enum.split_with(plan.delete, &owned?(runs[&1.stamp], &1.kind, key, owners))

    left = Enum.map(unowned, &%{&1 | reason: {:not_sent_here, &1.reason}})

    %{
      delete: owned,
      keep: Enum.sort_by(plan.keep ++ left, &{&1.stamp || "", &1.kind, &1.files}),
      unowned: unowned,
      other_directory: Enum.filter(unowned, &other_directory?(runs[&1.stamp], &1.kind, key))
    }
  end

  @sent_here ["ok", "pruned"]

  defp owned?(%{origin: :app, dir_id: dir_id} = run, kind, key, owners)
       when is_binary(dir_id) and owners != [],
       do: dir_id in owners and sent_here?(run, kind, key)

  defp owned?(_run, _kind, _key, _owners), do: false

  # Left only because another backup directory's in-app backup sent it.
  defp other_directory?(%{origin: :app, dir_id: dir_id} = run, kind, key)
       when is_binary(dir_id),
       do: sent_here?(run, kind, key)

  defp other_directory?(_run, _kind, _key), do: false

  # The Run of the stamp has an artifact of this kind that it recorded sent
  # to `key` (the artifact, or any of its parts), or pruned there by an
  # earlier pass that stopped part-way. Nothing else licenses a delete.
  defp sent_here?(%{artifacts: artifacts}, kind, key) when is_list(artifacts) do
    Enum.any?(artifacts, fn artifact ->
      artifact.kind == kind and
        (recorded_here?(artifact.destinations, key) or
           Enum.any?(artifact.parts || [], &recorded_here?(&1["destinations"], key)))
    end)
  end

  defp sent_here?(_run, _kind, _key), do: false

  defp recorded_here?(%{} = destinations, key),
    do: get_in(destinations, [key, "status"]) in @sent_here

  defp recorded_here?(_none, _key), do: false

  # The deletes, each unit re-checked first (`recheck/2`, and on a stored
  # destination `still_owned/3`), data before the sidecar. The first delete that fails stops the pass: a store refusing
  # one delete (or hanging on it) would only do so again.
  defp execute_destination(dir, config, plan, opts) do
    bounds = {opts[:deadline], delete_call_ms(opts)}
    current = opts[:current_dir_id]

    {deleted, units, stopped} =
      Enum.reduce_while(plan.delete, {[], 0, nil}, fn entry, {deleted, units, nil} ->
        case remove_remote_safely(dir, config, entry, {bounds, current}) do
          {:ok, []} -> {:cont, {deleted, units, nil}}
          {:ok, names} -> {:cont, {[names | deleted], units + 1, nil}}
          {:stop, [], reason} -> {:halt, {deleted, units, reason}}
          {:stop, names, reason} -> {:halt, {[names | deleted], units + 1, reason}}
        end
      end)

    deleted = deleted |> Enum.reverse() |> List.flatten()
    Recorder.mark_pruned(deleted, config.key)

    {:ok,
     %{
       deleted: deleted,
       units: units,
       unowned: plan.unowned,
       other_directory: plan.other_directory,
       stopped: stopped
     }}
  end

  defp remove_remote_safely(dir, config, entry, {bounds, current}) do
    with :ok <- recheck(dir, entry.stamp),
         :ok <- still_owned(config, entry.stamp, current) do
      remove_remote(config, entry, bounds)
    else
      {:skip, why} ->
        Logger.info(
          "Retention on #{config.key} left #{label(entry)} in place: #{why} since it was planned"
        )

        {:ok, []}
    end
  rescue
    error -> {:stop, [], {:crashed, error.__struct__}}
  end

  # A unit another backup directory sent is deleted only while the stored
  # destination still adopts that directory for this one: the row is read
  # again right before each such unit, as `prune` is before the pass, so an
  # adoption removed while a pass runs stops its further deletes. A unit of
  # this directory needs no read of the row. The env remote adopts nothing.
  defp still_owned(%Config{id: id, key: "dest:" <> _}, stamp, current)
       when is_binary(id) and is_binary(current) do
    case Backups.get_run_by_stamp(stamp, actor: Backups.system(), authorize_with: :error) do
      {:ok, %{dir_id: dir_id}} when is_binary(dir_id) and dir_id != current ->
        still_adopted(id, dir_id, current)

      {:ok, _own_or_gone} ->
        :ok

      {:error, _error} ->
        {:skip, :unreadable_run}
    end
  end

  defp still_owned(_config, _stamp, _current), do: :ok

  defp still_adopted(id, dir_id, current) do
    case Backups.get_backup_destination(id, actor: Backups.system(), authorize_with: :error) do
      {:ok, %{adoptions: adoptions}} ->
        if dir_id in DestinationConfig.owners(current, adoptions),
          do: :ok,
          else: {:skip, :no_longer_adopted}

      _gone_or_unreadable ->
        {:skip, :unreadable_destination}
    end
  end

  # Each delete gets its own bound (#2950), worked out right before it. One
  # killed at the bound may still have removed the file: it is not marked
  # pruned, and the next pass no longer lists it.
  defp remove_remote(config, entry, {step_deadline, per_call_ms}) do
    result =
      Enum.reduce_while(entry.files, {:ok, []}, fn name, {:ok, removed} ->
        ref = %{subdir: entry.sub, name: name}
        deadline = Destination.call_deadline(step_deadline, per_call_ms)

        case Destination.call(config, :delete, [ref], deadline: deadline) do
          :ok -> {:cont, {:ok, [name | removed]}}
          {:error, reason} -> {:halt, {:stop, removed, {:delete, name, reason}}}
          other -> {:halt, {:stop, removed, {:delete, name, inspect(other)}}}
        end
      end)

    case result do
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      {:stop, removed, reason} -> {:stop, Enum.reverse(removed), reason}
    end
  end

  ## Delete

  @doc false
  # Deletes a plan's `delete` entries, each unit re-checked first. Returns
  # `{file_names_removed, units_touched, stopped}`: `stopped` is `nil`, or why
  # the deleting broke off (a raise, or `:superseded` when `discard:` says the
  # step lost its lease), with what was removed before it kept.
  # `before_unit:` (tests only) runs ahead of each entry; `discard:` is
  # `run/2`'s. Public for the tests that change the directory between the
  # plan and the delete.
  @spec apply_plan(Path.t(), plan(), keyword()) ::
          {[String.t()], non_neg_integer(), term() | nil}
  def apply_plan(dir, plan, opts \\ []) do
    {deleted, units, stopped, _held} = delete_entries(dir, plan, opts)
    {deleted, units, stopped}
  end

  # `apply_plan/3`, and the units the check right before the delete found a
  # `.hold` on (`remove_unless_held/3`), as `run/2`'s `kept` lists them.
  defp delete_entries(dir, plan, opts) do
    before_unit = Keyword.get(opts, :before_unit, fn _entry -> :ok end)
    discard = Keyword.get(opts, :discard)

    {deleted, units, stopped, held} =
      Enum.reduce_while(plan.delete, {[], 0, nil, []}, fn entry, {deleted, units, nil, held} ->
        case remove_safely(dir, entry, before_unit, discard) do
          {:ok, []} -> {:cont, {deleted, units, nil, held}}
          {:ok, names} -> {:cont, {[names | deleted], units + 1, nil, held}}
          {:held, unit} -> {:cont, {deleted, units, nil, [unit | held]}}
          {:error, reason} -> {:halt, {deleted, units, reason, held}}
        end
      end)

    {deleted |> Enum.reverse() |> List.flatten(), units, stopped, Enum.reverse(held)}
  end

  defp remove_safely(dir, entry, before_unit, discard) do
    before_unit.(entry)

    case remove(dir, entry, discard) do
      {:error, :superseded} = superseded -> superseded
      {:held, _unit} = held -> held
      names -> {:ok, names}
    end
  rescue
    error -> {:error, {:crashed, error.__struct__}}
  end

  defp remove(dir, %{kind: :stray} = entry, discard), do: remove_files(dir, entry, discard)

  defp remove(dir, entry, discard) do
    case recheck(dir, entry.stamp) do
      :ok ->
        remove_unless_held(dir, entry, discard)

      {:skip, why} ->
        Logger.info("Retention left #{label(entry)} in place: #{why} since it was planned")
        []
    end
  end

  # A `.hold` of the unit, in its own directory, still there (#3004): only one
  # whose removal failed can be, since the plan never deletes a unit it
  # holds. `execute/3` leaves those out already; this is the backstop, and
  # its unit is listed in `kept` like theirs.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_unless_held(dir, entry, discard) do
    if present?(Path.join([dir, entry.sub, Artifact.hold_name(entry.stamp)])) do
      Logger.warning(
        "Retention kept #{label(entry)}: its hold marker " <>
          "#{entry.sub}/#{Artifact.hold_name(entry.stamp)} was still there right before " <>
          "the delete. Remove it by hand if no schedule keeps the backup"
      )

      {:held, %{stamp: entry.stamp, kind: entry.kind, reason: :still_there}}
    else
      remove_files(dir, entry, discard)
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
  # With `discard`, the unit's files go through it in that order (#3041),
  # and `{:error, :superseded}` means none went.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_files(dir, entry, nil) do
    entry.files
    |> Enum.reduce_while([], fn name, removed ->
      case File.rm(Path.join([dir, entry.sub, name])) do
        result when result in [:ok, {:error, :enoent}] ->
          {:cont, [name | removed]}

        {:error, reason} ->
          Logger.warning("Retention couldn't remove #{name} (#{inspect(reason)}); kept the rest")
          {:halt, removed}
      end
    end)
    |> Enum.reverse()
    |> removed(entry)
  end

  defp remove_files(dir, entry, discard) do
    case discard.(Enum.map(entry.files, &Path.join([dir, entry.sub, &1]))) do
      :ok ->
        removed(entry.files, entry)

      {:error, :superseded} = superseded ->
        superseded

      # The files before the one that failed were moved aside, then deleted.
      {:error, {:move_aside, name, reason}} ->
        Logger.warning("Retention couldn't remove #{name} (#{inspect(reason)}); kept the rest")
        entry.files |> Enum.take_while(&(&1 != name)) |> removed(entry)

      {:error, reason} ->
        Logger.warning("Retention couldn't remove #{label(entry)} (#{inspect(reason)})")
        []
    end
  end

  defp removed(names, entry) do
    if names != [],
      do: Logger.info("Retention removed #{label(entry)}: #{reason_text(entry.reason)}")

    names
  end

  defp label(%{kind: :stray, files: [name]}) do
    if Artifact.parse_refused_name(name) == :error,
      do: "stray file #{name}",
      else: "refused file #{name}"
  end

  defp label(%{kind: kind, stamp: stamp}), do: "#{kind} backup #{stamp}"

  defp reason_text({:expired, :unrecorded, days}),
    do: "older than #{days} days, with no recorded run"

  defp reason_text({:expired, :schedule, days}),
    do: "older than #{days} days, the keep days of the schedule that made it"

  defp reason_text({:expired, _rule, days}), do: "older than #{days} days"
end
