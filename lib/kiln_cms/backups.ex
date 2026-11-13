defmodule KilnCMS.Backups do
  @moduledoc """
  In-app backups (#484): what the last one was, and running a new one.

  Kiln's backups have always been `scripts/backup.sh` on cron — solid for a
  self-hoster with shell access, and completely invisible to everyone else.
  Two ecosystems say that isn't enough (Akeeba is Joomla's most-installed
  extension outright, UpdraftPlus is top-10 on WordPress), and the thing they
  are really selling is not a novel dump format. It is *knowing*.

  So the shape here is visibility first:

    * `status/0` reads a **manifest** written by whichever path last ran, so
      the console can say when the last backup was, how big it was, and
      whether it verified — including for a cron run this application never
      saw. Since #2219 it says so per component (database, media), from the
      run history and the manifest together.
    * `request/2` asks for one, from the app: a chain of Oban jobs, one per
      step, behind a cluster-wide lock (#2218; `KilnCMS.Backups.Chain`).

  ## Starting a backup

  Every entry point goes through `request/2` with an actor: the Backups page's
  "Back up now" and "Resume" buttons (as the platform admin), a legacy
  `KilnCMS.Backups.Worker` job and the console's `Worker.run/3` (as
  `system/0`), and a future scheduler, which must call
  `request(trigger: "schedule")` as `system/0`. A request while a backup runs
  queues behind it; at most one waits, and later requests of the same kind fold
  into that one (a different kind is refused: `KilnCMS.Backups.Chain.request/1`).
  `scripts/backup.sh` runs outside the application and does not take the lock.

  A request may cover only some components (#2219):
  `request([components: [:db]], actor)` backs up the database alone. A
  request folding into a queued one widens it to both requests' components.

  ## The shell scripts stay canonical

  `scripts/backup.sh` and `scripts/restore.sh` remain the documented ops path,
  and this module produces the same format: the same
  `pg_dump --format=custom --no-owner --no-privileges` dump named
  `kiln-db-<stamp>.dump`, media archives named `kiln-media-<stamp>.tar.gz`
  under the same `db/` and `media/` directories, the same
  `.partial`-then-rename discipline, the same `pg_restore --list` verification.
  Media too (#2218): a library bigger than one part is written, by this module
  (`KilnCMS.Backups.MediaArchive`) and by `backup.sh` alike, as independent
  `kiln-media-<stamp>.partNN.tar.gz` parts, with the same membership, names,
  sidecar and manifest entries. Both are read by `scripts/restore.sh` and by
  this module.

  That constraint is why `run/1` shells out to `pg_dump` rather than
  implementing a dump in Elixir. A hand-rolled logical export would be a
  second format with a second restore procedure, and the restore path is
  exactly where a backup system earns its keep.

  ## Restore is not here

  Deliberately. In-app restore is where Akeeba-class complexity and risk live:
  it means taking the application down, replacing the database underneath a
  running BEAM, and having a credible answer when it fails halfway. The
  documented drill in `docs/backups.md` is the supported path.
  """

  use Ash.Domain

  alias KilnCMS.Backups.{Chain, Heartbeat, Lock, Manifest, Refused, Run, StepWorker, WorkState}

  require Ash.Query
  require Logger

  resources do
    resource KilnCMS.Backups.Run do
      # Every write but `cancel_run` is the `:backups` system actor's
      # (`system/0`): the worker, the importer, retention and
      # `reconcile_stale_runs/0`. The history page reads `run_history` and
      # calls `cancel_run` as a platform admin.
      define :start_run, action: :start
      define :skip_run, action: :skip
      define :record_run_progress, action: :record_progress
      define :finish_run, action: :finish
      define :fail_run, action: :fail
      define :resume_run, action: :resume
      define :note_run_resume_refused, action: :note_resume_refused, args: [:reason]
      define :import_run, action: :import
      define :list_runs, action: :read
      define :run_history, action: :history
      define :get_run, action: :read, get_by: [:id]
      define :get_run_by_stamp, action: :by_stamp, args: [:stamp], not_found_error?: false
      define :list_running_runs, action: :running
      define :mark_run_pruned, action: :mark_pruned
      define :cancel_run, action: :cancel
    end

    resource KilnCMS.Backups.Lock do
      # `request_backup` is every entry point that starts a backup; the
      # platform admin reads `backup_lock` for the in-flight strip. The rest
      # are the step chain's, as `system/0`, inside the lock transaction.
      define :request_backup, action: :request
      define :backup_lock, action: :read, get?: true, not_found_error?: false
      define :ensure_backup_lock, action: :ensure
      define :hold_backup_lock, action: :hold
      define :move_backup_lock, action: :move
      define :mark_backup_lock_executing, action: :mark_executing
      define :mark_backup_lock_finishing, action: :finishing
      define :clear_backup_lock, action: :clear
      define :queue_backup_request, action: :queue_waiting
      define :fold_backup_request, action: :fold
      define :reclaim_stale_backups, action: :reclaim_stale
    end

    resource KilnCMS.Backups.NodeBeat do
      # The heartbeat's, as `system/0`.
      define :beat_node, action: :beat
      define :list_node_beats, action: :read
      define :get_node_beat, action: :read, get_by: [:node], not_found_error?: false
      define :prune_node_beats, action: :prune, require_reference?: false
    end
  end

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor the backup pipeline runs as (#2217): the worker that records a run,
  the importer that turns cron-made backups into rows, and
  `reconcile_stale_runs/0`.

  A `KilnCMS.SystemActor` labelled `:backups`, admitted by name on
  `KilnCMS.Backups.Run` for exactly the actions those callers use (see
  `docs/policy-matrix.md`, "The system actor") rather than `authorize?: false`.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:backups)
      actor -> actor
    end
  end

  @doc false
  # Test seam, as `KilnCMS.Billing.with_actor/2`: run `fun` with `system/0`
  # answering `actor` in this process, so a test can take the grant away and
  # prove the importer and the stale sweep fail CLOSED. Process-local; nothing
  # on a request path calls it.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun) do
    previous = Process.get(@actor_override, :unset)
    Process.put(@actor_override, actor)

    try do
      fun.()
    after
      if previous == :unset,
        do: Process.delete(@actor_override),
        else: Process.put(@actor_override, previous)
    end
  end

  @boot_id_key {__MODULE__, :boot_id}

  @doc """
  This boot of this node: a random id set once when the application starts
  (`init_boot_id/0`). A step job stamps it on the lock when it begins, so a
  node that restarted under the same name is told apart from one still running
  the step (`KilnCMS.Backups.Chain.reclaim_stale/0`).
  """
  @spec boot_id() :: String.t()
  def boot_id do
    case :persistent_term.get(@boot_id_key, nil) do
      nil -> init_boot_id()
      id -> id
    end
  end

  @doc false
  # Called from `KilnCMS.Application.start/2`, before any job can run.
  @spec init_boot_id() :: String.t()
  def init_boot_id do
    id = Ash.UUID.generate()
    :persistent_term.put(@boot_id_key, id)
    id
  end

  # How long past the worker's own timeout a `running` run may sit before it is
  # presumed dead: slack for a slow final write, and for a node whose clock
  # lags the one that started the run.
  @stale_grace_minutes 15

  @doc """
  Fail every `running` run that can no longer be running (#2217), and return how
  many.

  **Time-based, not Oban-state-based**: a run is stale when nothing has touched
  it for longer than a step's timeout (`StepWorker.timeout/1`) plus
  #{@stale_grace_minutes} minutes before `now`, whatever Oban says (see
  `run_stale?/2`). The job was killed or the node stopped; the run says so. The
  run the backup lock holds is never touched: its chain is alive, however long
  a step takes, until the lock says otherwise.

  Reads and writes as `system/0` and fails closed: a revoked grant raises
  instead of reporting "nothing stale". Callers on a request or job tail wrap it.
  """
  @spec reconcile_stale_runs(DateTime.t()) :: non_neg_integer()
  def reconcile_stale_runs(now \\ DateTime.utc_now()) do
    held = Chain.held_stamp()

    # One stale row failing to update must not strand the rest as `running`.
    for run <- list_running_runs!(actor: system(), authorize_with: :error),
        run.stamp != held,
        run_stale?(run, now),
        match?(
          {:ok, _},
          fail_run(
            run,
            %{error: "Interrupted: the job was killed or the node stopped"},
            actor: system()
          )
        ) do
      run
    end
    |> length()
  end

  @doc """
  Whether a `running` run has shown no sign of life for longer than the worker's
  timeout plus grace.

  Measured from the LATER of `started_at` and `updated_at`. A resumed run keeps
  the original attempt's `started_at` (possibly days old) and every progress
  write bumps `updated_at`, so going by `started_at` alone would fail a resumed
  run that is working, seconds after it began.
  """
  @spec run_stale?(Run.t(), DateTime.t()) :: boolean()
  def run_stale?(%Run{} = run, now \\ DateTime.utc_now()) do
    %{stale: cutoff} = resume_cutoffs(now)

    # No timestamp at all (a bare struct) is not evidence of anything: not stale.
    case Enum.filter([run.started_at, run.updated_at], &match?(%DateTime{}, &1)) do
      [] -> false
      times -> DateTime.compare(Enum.max(times, DateTime), cutoff) == :lt
    end
  end

  # How long a `running` run may go without a write before it counts as
  # stale: the worker's timeout plus grace.
  @doc false
  @spec stale_after_ms() :: pos_integer()
  def stale_after_ms do
    StepWorker.timeout(nil) + :timer.minutes(@stale_grace_minutes)
  end

  # The instants a resume is judged against, one definition for the early
  # check (`run_resumable?/2`) and the `:resume` action's UPDATE filter:
  # `stale`, before which a `running` run's last write makes it stale, and
  # `canceled`, before which a Cancel has settled (`Heartbeat.settled_after_ms/0`).
  @doc false
  @spec resume_cutoffs(DateTime.t()) :: %{stale: DateTime.t(), canceled: DateTime.t()}
  def resume_cutoffs(%DateTime{} = now) do
    %{
      stale: DateTime.add(now, -stale_after_ms(), :millisecond),
      canceled: DateTime.add(now, -Heartbeat.settled_after_ms(), :millisecond)
    }
  end

  @doc """
  Whether `run` is one a resume may re-open (#2218): an in-app run that `failed`
  or was `canceled`, or one that is `running` and `run_stale?/2`. Succeeded, skipped and imported
  runs, and a `running` one that is still being written to, are not.
  """
  @spec run_resumable?(Run.t(), DateTime.t()) :: boolean()
  def run_resumable?(run, now \\ DateTime.utc_now())

  def run_resumable?(%Run{origin: :app, status: :failed}, _now), do: true
  def run_resumable?(%Run{origin: :app, status: :canceled}, _now), do: true
  def run_resumable?(%Run{origin: :app, status: :running} = run, now), do: run_stale?(run, now)
  def run_resumable?(_run, _now), do: false

  @doc """
  The run a resume of `stamp` would re-open, or why there is none (#2218).

  Order matters and is the point: the stamp is checked against
  `\\A\\d{8}-\\d{6}\\z` BEFORE a path is built or a row is read, then a run for
  that stamp must exist and be resumable (`run_resumable?/2`), and only then is
  the filesystem consulted for `.work/<stamp>/state.json`. Every refusal is an
  `{:error, reason}`; nothing falls back to a fresh backup.

  Reasons: `:invalid_stamp`, `:in_flight` (the running backup is that stamp's,
  or a resume of it is about to start), `:no_such_run`,
  `{:not_resumable, status}` (a succeeded run, or one still running),
  `{:canceled_recently, seconds}` (#2538: canceled less than
  `Heartbeat.settled_after_ms/0` ago, so a step on a node that lost the
  database may still be stopping; `seconds` is how long is left, rounded up),
  `:no_state`.

  `lock: false` skips the `:in_flight` check: for the resume's own start step,
  which holds the lock on that stamp.
  """
  @spec resumable_run(term(), DateTime.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def resumable_run(stamp, now \\ DateTime.utc_now(), opts \\ []) do
    with :ok <- check_stamp(stamp),
         :ok <- check_not_held(stamp, Keyword.get(opts, :lock, true)),
         {:ok, run} <- fetch_run(stamp),
         :ok <- check_resumable(run, now),
         :ok <- check_settled(run, now),
         :ok <- check_state(stamp) do
      {:ok, run}
    end
  end

  defp check_stamp(stamp),
    do: if(WorkState.valid_stamp?(stamp), do: :ok, else: {:error, :invalid_stamp})

  defp check_not_held(_stamp, false), do: :ok

  defp check_not_held(stamp, true),
    do: if(Chain.held_stamp() == stamp, do: {:error, :in_flight}, else: :ok)

  defp fetch_run(stamp) do
    case get_run_by_stamp(stamp, actor: system()) do
      {:ok, %Run{} = run} -> {:ok, run}
      {:ok, nil} -> {:error, :no_such_run}
      {:error, _} = error -> error
    end
  end

  defp check_resumable(run, now),
    do: if(run_resumable?(run, now), do: :ok, else: {:error, {:not_resumable, run.status}})

  # A Cancel reaches the step's node through Oban's notifier, which a node cut
  # off from the database misses; that node stops the step itself, by its
  # heartbeat, within `Heartbeat.settled_after_ms/0` (#2538). A resume before
  # then could share the step's files with it. A nil `finished_at` (a row
  # canceled before it was recorded) is not evidence of a recent Cancel.
  defp check_settled(%Run{status: :canceled, finished_at: %DateTime{} = at}, now) do
    %{canceled: cutoff} = resume_cutoffs(now)

    case DateTime.diff(at, cutoff, :millisecond) do
      left when left > 0 -> {:error, {:canceled_recently, ceil(left / 1000)}}
      _settled -> :ok
    end
  end

  defp check_settled(_run, _now), do: :ok

  defp check_state(stamp),
    do: if(work_state?(stamp), do: :ok, else: {:error, :no_state})

  @doc """
  Whether `<dir>/.work/<stamp>/state.json` exists - the files a resume would
  build on. `false` for a stamp that is not a real stamp.
  """
  @spec work_state?(term()) :: boolean()
  def work_state?(stamp) do
    WorkState.valid_stamp?(stamp) and stamp |> work_dir() |> WorkState.exists?()
  end

  @doc false
  # The backup directory a resume of `stamp` must run in (#2539): the run's
  # `dir_id`, nil when the run has none (imported, from before #2539) or
  # doesn't exist. Fails closed on a refused read, so the caller can tell
  # "unpinned" from "unknown".
  @spec resume_dir_id(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def resume_dir_id(stamp) do
    case get_run_by_stamp(stamp, actor: system(), authorize_with: :error) do
      {:ok, %Run{dir_id: dir_id}} -> {:ok, dir_id}
      {:ok, nil} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  @doc "The work directory of a (valid) stamp. Raises for any other."
  @spec work_dir(String.t()) :: Path.t()
  def work_dir(stamp), do: WorkState.path(dir(), stamp)

  @type component :: :db | :media

  @type component_status :: %{
          last_good: %{at: DateTime.t(), stamp: String.t() | nil, source: :run | :manifest} | nil,
          last_attempt:
            %{at: DateTime.t(), ok?: boolean(), stamp: String.t() | nil, source: :run | :manifest}
            | nil,
          failed?: boolean(),
          stale?: boolean(),
          never?: boolean(),
          stale_after_hours: pos_integer(),
          stale_source: {:env, String.t()}
        }

  @type status :: %{
          configured?: boolean(),
          available?: boolean(),
          manifest: Manifest.t() | nil,
          stale?: boolean(),
          failed?: boolean(),
          expected: [component()],
          components: %{optional(component()) => component_status()},
          source: :runs | :manifest,
          reason: atom() | nil,
          rclone_missing?: boolean()
        }

  @doc """
  Where backups are written. Mirrors `scripts/backup.sh`'s `BACKUP_DIR`,
  including its default, so both paths land in the same place without an
  operator configuring anything twice.
  """
  @spec dir() :: Path.t()
  def dir, do: config(:dir, "/var/backups/kiln")

  @doc """
  The uploads root to archive, or `nil`.

  `nil` is the correct answer on an S3 deployment: the bucket is backed up
  provider-side, and tarring a directory that doesn't hold the media would
  produce an archive that looks like a backup and isn't. Mirrors the script's
  `MEDIA_DIR`, which is unset for the same reason.
  """
  @spec media_dir() :: Path.t() | nil
  def media_dir, do: config(:media_dir, nil)

  @doc """
  What a backup here covers (#2219): the database, and the media when there is
  a `media_dir/0` to archive.
  """
  @spec expected_components() :: [component()]
  def expected_components, do: if(media_dir(), do: [:db, :media], else: [:db])

  @doc """
  The rclone remote to copy each backup to, or `nil` — the script's
  `BACKUP_RCLONE_REMOTE`.

  Not optional in spirit: a backup that only exists on the machine being
  backed up is not a backup of that machine. It is `nil`-able only because
  plenty of deployments handle off-siting outside Kiln entirely.
  """
  @spec rclone_remote() :: String.t() | nil
  def rclone_remote, do: config(:rclone_remote, nil)

  @doc """
  Local retention in days — the script's `BACKUP_KEEP_DAYS`. A backup older
  than this may be deleted unless a keep rule holds it (the newest verified and
  newest complete backup of each component, a recovery point, one in flight);
  see `KilnCMS.Backups.Retention`.
  """
  @spec keep_days() :: pos_integer()
  def keep_days, do: config(:keep_days, 14)

  @doc """
  How old the newest backup may be before the console calls it stale.

  Deliberately longer than a daily cadence: a warning that fires because a
  nightly job ran at 03:20 instead of 03:17 is one an admin learns to ignore.
  """
  @spec stale_after_hours() :: pos_integer()
  def stale_after_hours, do: config(:stale_after_hours, 36)

  @doc """
  The target ceiling, in **bytes**, on the input size of one media part
  (`BACKUP_MEDIA_PART_MB`, default 400 MB; #2218). `scripts/backup.sh` reads
  the same variable the same way.

  Bytes internally so tests can use a few KiB. A target, not an exact size: a
  part closes when the next file would push it over, and one file larger than
  the cap becomes its own oversize part.
  """
  @spec media_part_bytes() :: pos_integer()
  def media_part_bytes, do: config(:media_part_bytes, 400 * 1_048_576)

  @doc """
  Glob patterns (relative to `media_dir/0`) the media archive leaves out
  (`BACKUP_MEDIA_EXCLUDE`; #2218). `[]` — the default — excludes nothing.
  `scripts/backup.sh` reads the same variable and applies the same globs.
  """
  @spec media_exclude() :: [String.t()]
  def media_exclude, do: config(:media_exclude, [])

  @doc """
  Whether running a backup **from the app** is possible here.

  Three things have to be true, and they fail independently, so the reason is
  returned rather than a bare boolean — "backups are off" and "pg_dump isn't
  installed in this image" need completely different responses from an admin.
  """
  @spec availability() :: :ok | {:error, atom()}
  def availability do
    cond do
      not config(:enabled, true) -> {:error, :disabled}
      is_nil(database_url()) -> {:error, :no_database_url}
      is_nil(System.find_executable("pg_dump")) -> {:error, :no_pg_dump}
      is_nil(System.find_executable("pg_restore")) -> {:error, :no_pg_restore}
      true -> :ok
    end
  end

  @doc """
  Everything the console needs to render the backup panel.

  Never raises and never returns `nil` for the whole thing: an unreadable or
  absent manifest is a *state* worth showing ("no backup has ever run here"),
  not an error page.

  ## Per component (#2219)

  A backup may cover only the database or only the media, so the manifest (the
  LAST backup) can't say how each is doing: a database-only run would hide the
  media's state. `components` has one entry per `expected_components/0`:

    * `last_good`: the newest succeeded run that covered it and has a verified
      artifact of that kind, or the manifest when it is newer (or the only
      source); `nil` when there is none.
    * `last_attempt`: the newest run that covered it and succeeded or failed,
      or the manifest, whichever is newer. A failed manifest that doesn't say
      what it covered counts against every component, and so does a failed
      imported (cron) run or one that names no component: those list only
      the kinds of the files they left.
    * `failed?` (the last attempt failed), `stale?` (no last good, or older
      than `stale_after_hours`), `never?` (no attempt at all),
      `stale_after_hours` and where that came from (`stale_source`).

  `stale?` and `failed?` at the top are any component's. The runs are read as
  `system/0`, a few rows per component; when that read fails, the status comes
  from the manifest alone (`source: :manifest`) rather than raising or
  calling anything healthy.
  """
  @spec status() :: status()
  def status do
    availability = availability()
    manifest = Manifest.read(dir())
    expected = expected_components()
    {source, runs} = status_runs(expected)
    components = Map.new(expected, &{&1, component_status(&1, Map.get(runs, &1), manifest)})

    %{
      configured?: not match?({:error, :disabled}, availability),
      available?: availability == :ok,
      # NOT `with({:error, r} <- availability, do: r)` — `with` returns the
      # non-matching value, so a healthy deployment would report its reason as
      # `:ok` and the panel would render "ok" as though it were a fault.
      reason: reason(availability),
      manifest: manifest,
      expected: expected,
      components: components,
      source: source,
      stale?: Enum.any?(components, fn {_c, cs} -> cs.stale? end),
      failed?: Enum.any?(components, fn {_c, cs} -> cs.failed? end),
      rclone_missing?: rclone_missing?()
    }
  end

  # The run history's say on each component: `{:runs, %{c => %{good, attempt}}}`,
  # or `{:manifest, %{}}` when it can't be read.
  defp status_runs(expected) do
    Enum.reduce_while(expected, {:runs, %{}}, fn component, {:runs, acc} ->
      with {:ok, good} <- newest_good_run(component),
           {:ok, attempt} <- newest_attempt(component) do
        {:cont, {:runs, Map.put(acc, component, %{good: good, attempt: attempt})}}
      else
        {:error, error} ->
          history_unreadable(error)
          {:halt, {:manifest, %{}}}
      end
    end)
  end

  @history_warned {__MODULE__, :history_warned_at}
  @history_warn_every_ms :timer.minutes(15)

  # Every occurrence is a telemetry event; the warning is logged at most once
  # per 15 minutes, since the Backups page asks every few seconds while a
  # backup runs.
  defp history_unreadable(error) do
    :telemetry.execute([:kiln_cms, :backups, :status, :history_unreadable], %{count: 1}, %{
      error: error.__struct__
    })

    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get(@history_warned, nil)

    if is_nil(last) or now - last >= @history_warn_every_ms do
      :persistent_term.put(@history_warned, now)

      Logger.warning(
        "Backup status from the manifest alone: the run history could not be read " <>
          "(#{inspect(error.__struct__)})"
      )
    end

    :ok
  end

  # A succeeded run's artifact can be missing for a component it named (a
  # media directory gone mid-way), so a few rows are read, not one.
  defp newest_good_run(component) do
    with {:ok, runs} <- read_status_runs(component, [:succeeded], 5) do
      {:ok, Enum.find(runs, &good_artifact?(&1, component))}
    end
  end

  # A failed run that doesn't say what it covered counts against every
  # component, as a failed manifest does: an imported (cron) run lists only
  # the kinds of the files it left, or none at all.
  defp newest_attempt(component) do
    name = Atom.to_string(component)

    query =
      Ash.Query.filter(
        Run,
        (status in [:succeeded, :failed] and fragment("? = ANY(?)", ^name, components)) or
          (status == :failed and
             (origin == :imported or fragment("cardinality(?) = 0", components)))
      )

    with {:ok, runs} <- read_status_runs(query, 1), do: {:ok, List.first(runs)}
  end

  defp read_status_runs(component, statuses, limit) do
    name = Atom.to_string(component)

    Run
    |> Ash.Query.filter(status in ^statuses and fragment("? = ANY(?)", ^name, components))
    |> read_status_runs(limit)
  end

  defp read_status_runs(query, limit) do
    query =
      query
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(limit)
      |> Ash.Query.select([
        :stamp,
        :status,
        :origin,
        :components,
        :artifacts,
        :started_at,
        :finished_at
      ])

    list_runs(query: query, actor: system(), authorize_with: :error)
  end

  defp good_artifact?(run, component) do
    Enum.any?(run.artifacts, fn artifact ->
      artifact.kind == component and artifact.verified and
        get_in(artifact.destinations, ["local", "status"]) != "pruned"
    end)
  end

  defp component_status(component, runs, manifest) do
    name = Atom.to_string(component)
    runs = runs || %{good: nil, attempt: nil}

    last_good = newer(run_point(runs.good), manifest_good(manifest, name))
    last_attempt = newer(run_point(runs.attempt), manifest_attempt(manifest, name))
    hours = stale_after_hours()

    %{
      last_good: last_good && Map.delete(last_good, :ok?),
      last_attempt: last_attempt,
      failed?: last_attempt != nil and not last_attempt.ok?,
      stale?: last_good == nil or DateTime.diff(DateTime.utc_now(), last_good.at, :hour) >= hours,
      never?: last_good == nil and last_attempt == nil,
      stale_after_hours: hours,
      stale_source: {:env, "BACKUP_STALE_AFTER_HOURS"}
    }
  end

  defp run_point(nil), do: nil

  defp run_point(run) do
    %{
      at: run.finished_at || run.started_at,
      ok?: run.status == :succeeded,
      stamp: run.stamp,
      source: :run
    }
  end

  # An ok manifest vouches for a component it covered with a verified file of
  # that kind.
  defp manifest_good(%Manifest{ok: true, finished_at: %DateTime{} = at} = manifest, name) do
    covered? =
      name in Manifest.components(manifest) and
        Enum.any?(manifest.artifacts, &(&1.kind == name and &1.verified))

    if covered?, do: %{at: at, ok?: true, stamp: nil, source: :manifest}
  end

  defp manifest_good(_manifest, _name), do: nil

  # A failed manifest that doesn't say what it covered (cron's, or one with no
  # artifacts) counts against every component: failing closed.
  defp manifest_attempt(%Manifest{finished_at: %DateTime{} = at} = manifest, name) do
    covered =
      case {manifest.ok, manifest.components} do
        {false, nil} -> [name]
        _ -> Manifest.components(manifest)
      end

    if name in covered, do: %{at: at, ok?: manifest.ok, stamp: nil, source: :manifest}
  end

  defp manifest_attempt(_manifest, _name), do: nil

  # The later of two points; on a tie (the manifest of the run itself) the
  # run's, which carries its stamp.
  defp newer(nil, other), do: other
  defp newer(one, nil), do: one

  defp newer(run, manifest) do
    if DateTime.compare(manifest.at, run.at) == :gt, do: manifest, else: run
  end

  @doc """
  Whether `rclone_remote/0` is set but this image has no `rclone` (#2218).

  The official image ships rclone, so this is a custom image without it. A
  backup taken from the app then fails at its off-site step (#2482), which the
  panel says ahead of time. Not a reason to refuse to start one: its local
  files are kept and can be resumed once rclone is installed.
  """
  @spec rclone_missing?() :: boolean()
  def rclone_missing?,
    do: is_binary(rclone_remote()) and is_nil(System.find_executable("rclone"))

  defp reason({:error, reason}), do: reason
  defp reason(_ok), do: nil

  @doc """
  Whether the newest backup is older than `stale_after_hours/0`.

  A missing manifest is **stale**, not fine. "Nothing has ever run" is the
  most alarming state this can be in, and defaulting it to green is how a
  deployment goes a year without a backup and nobody notices.
  """
  @spec stale?(Manifest.t() | nil) :: boolean()
  def stale?(nil), do: true

  def stale?(%Manifest{finished_at: nil}), do: true

  def stale?(%Manifest{finished_at: finished_at}) do
    DateTime.diff(DateTime.utc_now(), finished_at, :hour) >= stale_after_hours()
  end

  @doc """
  Ask for a backup, as `actor` (#2218). The one entry point: see the moduledoc.

  From a release console, as the backup system actor, then waiting for it:

      {:ok, %{status: :started, chain: chain}} =
        KilnCMS.Backups.request([trigger: "console"], KilnCMS.Backups.system())

      KilnCMS.Backups.await(chain)
      #=> :ok

  Options: `:trigger` (default `"manual"`), `:resume`, a stamp whose failed,
  interrupted or canceled backup to continue, and `:components` (#2219), what a
  fresh backup covers: `[:db]`, `[:media]` or both (absent or nil:
  everything). A `:resume` that is present is always a resume: a malformed one
  is refused (`:invalid_stamp`), never a fresh backup. `:components` is refused
  as `:invalid_components` unless it is a non-empty list of distinct
  components, as `:components_with_resume` beside a `:resume` (a resume backs
  up what its run did), and as `:no_media_dir` when it names `:media` on a
  deployment with no media directory.

    * `{:ok, %{status: :started, chain: chain}}`: it is running.
    * `{:ok, %{status: :queued, chain: running}}`: it starts when the running
      chain finishes.
    * `{:ok, %{status: :folded, chain: running}}`: one of the same kind is
      already queued (a fresh backup, or a resume of the same stamp); that one
      covers this request (logged).
    * `{:error, {:queue_busy, queued}}`: one of another kind is queued
      (`queued` is `:backup` or `{:resume, stamp}`). Nothing changed; ask again
      once the queue clears (#2540).
    * `{:error, reason}`: `availability/0`'s reason, a resume refusal
      (`resumable_run/2`: `:invalid_stamp`, `:in_flight`, `:no_such_run`,
      `{:not_resumable, status}`, `{:canceled_recently, seconds}`,
      `:no_state`), a `:components` refusal, or
      `:forbidden` for an actor the policy refuses (only a platform admin and
      `system/0` may ask).
  """
  @spec request(keyword(), term()) :: {:ok, map()} | {:error, term()}
  def request(opts \\ [], actor) do
    input = %{trigger: to_string(Keyword.get(opts, :trigger, "manual"))}

    with {:ok, input} <- put_resume(input, opts),
         {:ok, input} <- put_components(input, opts) do
      case request_backup(input, actor: actor) do
        {:ok, result} -> {:ok, result}
        {:error, error} -> {:error, refusal(error)}
      end
    end
  end

  defp put_resume(input, opts) do
    if Keyword.has_key?(opts, :resume) do
      resume = Keyword.get(opts, :resume)

      if WorkState.valid_stamp?(resume),
        do: {:ok, Map.put(input, :resume, resume)},
        else: {:error, :invalid_stamp}
    else
      {:ok, input}
    end
  end

  # nil (or absent) is everything. Atoms or their names; the action refuses a
  # repeat, and the rest (`Lock.Actions.Request`).
  defp put_components(input, opts) do
    case Keyword.get(opts, :components) do
      nil ->
        {:ok, input}

      list when is_list(list) and list != [] ->
        components = Enum.map(list, &component/1)

        if Enum.all?(components, &(&1 in Lock.components())) and
             Enum.uniq(components) == components,
           do: {:ok, Map.put(input, :components, components)},
           else: {:error, :invalid_components}

      _other ->
        {:error, :invalid_components}
    end
  end

  defp component(name) when is_atom(name), do: name

  defp component(name) when is_binary(name),
    do: Enum.find(Lock.components(), :unknown, &(Atom.to_string(&1) == name))

  defp component(_other), do: :unknown

  defp refusal(%Ash.Error.Forbidden{}), do: :forbidden

  defp refusal(%{errors: errors} = error) do
    case Enum.find(errors, &match?(%Refused{}, &1)) do
      %Refused{reason: reason} -> reason
      nil -> error
    end
  end

  defp refusal(error), do: error

  @doc """
  Enqueue a backup as `system/0` (deprecated: use `request/2` with the actor
  asking). Same options and results as `request/2`; before #2218 it returned
  the `Oban.Job`.
  """
  @spec enqueue(keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue(opts \\ []), do: request(opts, system())

  @doc """
  What the backup lock holds right now, or `nil` when no backup runs: the chain,
  its stamp, trigger, step and part, `parts_total` (the archive step's part
  count, when this node has the chain's backup directory; else nil),
  `components` (#2219; what the backup covers, from its `state.json` when this
  node has the chain's backup directory; else nil), phase (`:running`, or
  `:finishing` once Cancel is refused), when it took the lock, and the queued
  request (`%{trigger, resume, components, requested_at, folds}`, where nil
  `components` is everything) or `nil`.
  """
  @spec in_flight() :: map() | nil
  def in_flight, do: Chain.in_flight()

  @doc """
  Wait for the chain `chain` to settle: `:ok` when its run succeeded, else
  `{:error, reason}` (the run's error, `:canceled`, `{:skipped, error}`,
  `:no_run` when it ended without one, or `:timeout`). Polls the database, so it
  works from any node. Options: `:timeout` (ms, default 3 hours), `:interval`
  (ms, default 2 s).
  """
  @spec await(String.t(), keyword()) :: :ok | {:error, term()}
  def await(chain, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.hours(3))
    interval = Keyword.get(opts, :interval, 2_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(chain, interval, deadline)
  end

  defp poll(chain, interval, deadline) do
    case settled(chain) do
      :running ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(interval)
          poll(chain, interval, deadline)
        end

      outcome ->
        outcome
    end
  end

  defp settled(chain) do
    held? = match?(%{chain: ^chain}, in_flight())

    case list_runs(query: [filter: [chain_id: chain]], actor: system()) do
      {:ok, [%Run{status: :running} | _]} -> :running
      {:ok, _} when held? -> :running
      {:ok, [%Run{status: :succeeded} | _]} -> :ok
      {:ok, [%Run{status: :canceled} | _]} -> {:error, :canceled}
      {:ok, [%Run{status: :skipped, error: error} | _]} -> {:error, {:skipped, error}}
      {:ok, [%Run{error: error} | _]} -> {:error, error}
      {:ok, []} -> {:error, :no_run}
      {:error, _} = error -> error
    end
  end

  @doc """
  The connection string this deployment backs up. `nil` when none can be
  determined, which `availability/0` reports rather than guessing.

  Three sources, in order of trustworthiness:

    1. an explicit `:database_url` config (the escape hatch for anything the
       other two get wrong);
    2. `DATABASE_URL` from the environment — what production actually sets,
       and the *original* string, complete with its query parameters;
    3. a URL rebuilt from `KilnCMS.Repo.config/0`.

  The environment is consulted before the Repo deliberately.
  Ecto's repo supervisor **pops** `:url` and merges the parsed fields back, so
  `Repo.config/0` never contains it — the original string is simply not
  recoverable from there, and rebuilding one is lossy: it drops the query
  string (`?sslmode=require`) and has to re-encode a password Ecto already
  decoded. Rebuilding is the fallback, not the plan.
  """
  @spec database_url() :: String.t() | nil
  def database_url do
    presence(config(:database_url)) || matching_env_url() || repo_url()
  end

  # `DATABASE_URL` is preferred over a rebuild — but ONLY when it describes the
  # database this application is actually connected to.
  #
  # In production the two are the same string (`runtime.exs` sets the Repo's
  # `url:` from it), and the env var is the better source: it is the original,
  # complete with the query parameters a rebuild drops. Elsewhere they can
  # disagree — `config/test.exs` configures discrete fields while a stale
  # `DATABASE_URL` lingers in the shell — and backing up whatever that stale
  # value points at, rather than the database being served, is the worst
  # possible way to be wrong about a backup.
  defp matching_env_url do
    with url when is_binary(url) <- presence(System.get_env("DATABASE_URL")),
         %URI{path: "/" <> database} <- URI.parse(url),
         ^database <- to_string(KilnCMS.Repo.config()[:database]) do
      url
    else
      _ -> nil
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp repo_url do
    config = KilnCMS.Repo.config()

    with database when is_binary(database) <- Keyword.get(config, :database),
         host when is_binary(host) <- Keyword.get(config, :hostname) do
      "postgres://#{userinfo(config)}#{host}:#{Keyword.get(config, :port, 5432)}/#{database}"
    else
      # No hostname means a unix-socket repo, which has no TCP URL to build —
      # and inventing `localhost` would point `pg_dump` at a different server
      # that may not exist, or none. An honest `nil`: `availability/0` reports
      # `:no_database_url` and the operator sets `BACKUP_DATABASE_URL`.
      #
      # A missing USERNAME is fine by contrast — `userinfo/1` omits it and
      # libpq falls back to `PGUSER`/the current user, which is exactly what a
      # peer-auth deployment wants.
      _ -> nil
    end
  end

  # Percent-encoding, NOT form encoding. `URI.encode_www_form/1` turns a space
  # into `+`, which libpq reads literally — so a password containing a space
  # authenticates as `p+ss` and every backup fails on a deployment that is
  # otherwise working perfectly.
  defp userinfo(config) do
    case Keyword.get(config, :username) do
      username when is_binary(username) ->
        case Keyword.get(config, :password) do
          password when is_binary(password) -> "#{encode(username)}:#{encode(password)}@"
          _ -> "#{encode(username)}@"
        end

      _ ->
        ""
    end
  end

  defp encode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp config(key, default \\ nil) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
