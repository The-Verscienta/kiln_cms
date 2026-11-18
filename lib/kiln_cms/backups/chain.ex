defmodule KilnCMS.Backups.Chain do
  @moduledoc """
  The cluster-wide backup lock's algorithms (#2218): who may start a backup,
  which step job may run, and what happens to a chain whose node stopped.

  A backup is a chain of `KilnCMS.Backups.StepWorker` jobs (start, dump, plan,
  archive per part, checksum, prune, offsite, finish). One chain holds the
  backup pipeline at a time, recorded on the singleton `KilnCMS.Backups.Lock`
  row; at most one request waits behind it, and later requests of the same kind
  fold into that one (`request/1`).

  ## One transaction, one lock

  Every decision runs in `with_lock/1`: a transaction that first takes
  `pg_advisory_xact_lock` on one fixed key, then ensures and reads the row. The
  lock writes and the `Oban.insert/2` or cancel they decide on commit together,
  so a step job exists exactly when the row names it. **No Run write happens
  inside it**: a Run write is best-effort and may fail, and a failed statement
  would abort the transaction that inserts the next step. Run writes happen
  before (a step's progress) or after the commit (bookkeeping here).

  The advisory lock is the guarantee, not the row. Today the `:ensure` upsert
  that follows it also row-locks the singleton (AshPostgres renders it as
  `ON CONFLICT ... DO UPDATE`), so two lock transactions would queue on the
  row even without it; but that is how AshPostgres happens to render an
  upsert with nothing to update, not something this module controls, and a
  transaction that takes the advisory lock without touching the row (a
  maintenance query, a future caller) must still keep every decision out.
  `chain_race_test.exs` pins it: a transaction holding only the advisory key
  (`lock_key/0`) holds a request back.

  One other write does happen inside it: a scheduled request's window claims
  (part of #2219; `request/1`'s `:claim`), so a window is claimed exactly when
  the backup it asked for is started, queued or folded. A claim that matches
  zero rows (the window taken by another node) is a returned error, not a
  failed statement, and rolls the whole transaction back.

  Every Lock write passes `actor: Backups.system()` explicitly.

  ## Fencing

  A step presents what `begin_step/1` gave it (`epoch`, its job id) to
  `advance/3`, `mark_finishing/1` and `release/1`. A step whose job was
  reclaimed, canceled or otherwise superseded meanwhile gets
  `{:error, :superseded}` and its results are discarded.

  Work that must not outlive the lease runs inside `while_holding/2`, and is
  kept to what cannot be done outside it. A step writes the contents of its
  files (`state.json`, the dump, a media part, a checksum sidecar, a manifest)
  outside the lock, under temporary names of its own
  (`KilnCMS.Backups.Artifact.partial_name/2`, tagged with its job and attempt,
  #2818, #2819), and only the rename into place runs under the lease
  (`fenced_rename/3`). A superseded step's rename is refused, so its files never
  replace the chain's that took over, and its temporary file is its alone to
  remove. A step that must delete something of the chain's (a work directory, a
  stale plan's media) moves it aside into a trash directory on its own file
  system with one fenced rename and deletes it after the lock is released
  (`fenced/2`). The finish step's
  marker sync (#3013) still runs under the lease, so a superseded finish writes
  no `.good` or `.hold` marker and leaves them to the step that took over.

  Renames and that marker sync are file-system calls inside the lock
  transaction: a backup directory that stalls between a step's write and its
  rename still holds Cancel, new requests and the sweep back until their query
  times out. What moved out is the writing of contents, which is where a
  stalled mount usually hangs. A resume's start checks its lease after it reads the
  run and before it re-opens it (#2816), and the re-open is pinned to that
  read (`KilnCMS.Backups.Run.Changes.Resume`), so a resume canceled before it
  started (`Run`'s `:cancel_resume`, which releases the lock in its own
  transaction) never has its run re-opened.

  A step taken back from a stopped node keeps `phase: :finishing` when it had
  it (#3012): the replacement is past the point of no return too, so a Cancel
  stays refused until it completes.

  ## A node that stopped

  `reclaim_stale/0` frees the lock from a step whose node stopped beating (or
  restarted) and requeues the step with the attempts it has left;
  `reap/0` releases a lock whose step job finished without moving the chain on
  (killed by its timeout, discarded, canceled, deleted). Both run before every
  request and on every heartbeat tick.

  ## What a backup covers (#2219)

  A request may name its components (`:db`, `:media`; nil is everything). The
  start job's args carry them (`"components"`, with `"scheduled"` and
  `"schedule_ids"`), and the start step writes what it settled on into the
  chain's `state.json`. From there on **`state.json` is the only record of the
  holder's components**: later steps, and `in_flight/0`, read them there. They
  are never on the Lock row, whose `:hold` and `:clear` an older node runs
  without knowing such columns.

  A queued request's are on the row (`waiting_components`, ...), and count only
  while their scope is that request's (`waiting_scope/1`). A fresh request that
  folds into a queued fresh one widens it to the union of the two; folding into
  a queued request whose scope is not valid makes it cover everything. A
  queued resume records its run's components, and only a resume of the same
  stamp folds into it (#2540): a fresh request and a resume never fold into
  each other (`request/1`), so neither widens nor narrows the other. A resume
  queued by a node from before #2219 covers everything.
  """
  import Ecto.Query

  alias KilnCMS.AfterCommit
  alias KilnCMS.Backups

  alias KilnCMS.Backups.{
    Artifact,
    DirId,
    DirQueues,
    Heartbeat,
    Importer,
    Lock,
    Markers,
    Recorder,
    Retention,
    Steps,
    StepWorker,
    WorkState
  }

  alias KilnCMS.Backups.Run.Changes.Normalize
  alias KilnCMS.Repo

  require Logger

  @lock_key "kiln:backups:lock"

  # A node is stale when its last beat (the database's clock) is older than
  # this, or when it has no beat and its job was attempted this long ago.
  @stale_after_s 180

  @type lease :: %{
          chain: String.t(),
          epoch: integer(),
          job_id: integer(),
          attempt: pos_integer() | nil,
          step: String.t(),
          part: pos_integer() | nil,
          stamp: String.t() | nil,
          dir_id: String.t() | nil,
          trigger: String.t() | nil,
          resume: String.t() | nil
        }

  @doc "Seconds without a beat after which a node's step is reclaimed."
  @spec stale_after_s() :: pos_integer()
  def stale_after_s, do: @stale_after_s

  @doc false
  # The advisory lock's key, for the race test that holds it on its own.
  @spec lock_key() :: String.t()
  def lock_key, do: @lock_key

  ## The lock transaction

  @doc """
  Run `fun.(row)` inside the lock transaction. `fun` returns `{:ok, value}` to
  commit or `{:error, reason}` to roll back; the result is the same tuple.
  """
  @spec with_lock((Lock.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_lock(fun) do
    Repo.transaction(fn ->
      case fun.(locked_row()) do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Take the advisory lock in the CURRENT transaction and return the lock row
  (created if missing). For a caller already inside a transaction of its own
  (the Run `:cancel` action); everyone else uses `with_lock/1`.

  The advisory lock is taken first and is what serializes; the row lock the
  `:ensure` upsert also takes is incidental (see "One transaction, one lock").
  """
  @spec locked_row() :: Lock.t()
  def locked_row do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [@lock_key])
    _ = Backups.ensure_backup_lock!(%{}, write_opts())
    Backups.backup_lock!(actor: Backups.system())
  end

  ## Requests

  @doc """
  Start a backup, queue it behind the running chain, or fold it into the queued
  one. `attrs`: `:trigger`, `:resume` (a stamp, already validated) and
  `:requested_by` (a user id or nil).

  `{:ok, %{status: :started | :queued | :folded, chain: chain | nil}}`, where
  `chain` is the new chain for `:started` and the running one otherwise; or
  `{:error, reason}`: `availability/0`'s reason, a resume refusal
  (`Backups.resumable_run/2`), `:in_flight` when the stamp to resume is the
  one the running chain holds, or `{:queue_busy, :backup | {:resume, stamp}}`
  (the queued request's kind) when the queued request is not like this one.

  ## Like folds only into like (#2540)

  A request folds into the queued one only when that one does the same work: a
  fresh backup into a queued fresh backup, a resume into a queued resume of the
  same stamp. Anything else is refused and leaves the queue as it was, because
  folding would drop it: a fresh backup folded into a queued resume never takes
  its own (the resume backs up the old stamp), and a resume folded into a
  queued fresh backup (or another stamp's resume) never resumes. The caller
  asks again once the queue clears; the scheduler's claim rolls back with the
  refusal and it asks again on a later tick, so a scheduled backup is never
  folded into a Resume.

  ## Claiming a schedule's window (part of #2219)

  `:claim` is a function of the outcome (`:started`, `:queued` or
  `:folded`) returning `:ok` or `{:error, reason}`, run inside the lock
  transaction only after the decision succeeded. An error rolls everything
  back, the decision's Lock write and `Oban.insert/2` included, and is the
  result. A refused decision (`{:queue_busy, _}`, #2540) never runs it, so
  nothing is claimed. `:scheduled` and `:schedule_ids` say what the schedules
  asked for (`KilnCMS.Backups.Lock.Actions.RequestScheduled`).
  """
  @spec request(map()) :: {:ok, map()} | {:error, term()}
  def request(attrs) do
    trigger = Normalize.trigger(Map.get(attrs, :trigger) || "manual")
    resume = Map.get(attrs, :resume)

    req = %{
      trigger: trigger,
      resume: resume,
      by: Map.get(attrs, :requested_by),
      components: Map.get(attrs, :components),
      scheduled: Map.get(attrs, :scheduled) || [],
      schedule_ids: Map.get(attrs, :schedule_ids) || [],
      claim: Map.get(attrs, :claim)
    }

    with :ok <- Backups.availability(),
         {:ok, resume_components} <- precheck_resume(resume) do
      req = Map.put(req, :resume_components, resume_components)

      # Best-effort housekeeping first, each in its own transaction: a holder
      # that is gone must not make this request queue behind it forever.
      # Reclaim judges a node by its heartbeat rows: with the heartbeat off
      # there are none, and every step older than the stale window would look
      # dead. Reap needs no beat (it reads only the holder's job state).
      _ = if heartbeat?(), do: reclaim_stale()
      _ = reap()
      _ = if heartbeat?(), do: sweep_stranded()

      result = with_lock(&decide_and_claim(&1, req))

      with {:ok, %{status: :folded}} <- result, do: announce_fold(req)
      result
    end
  end

  defp decide_and_claim(row, req) do
    with {:ok, %{status: status} = decided} <- decide(row, req),
         :ok <- run_claim(req.claim, status),
         do: {:ok, decided}
  end

  # Inside the lock transaction. The claim stops at its first error and
  # returns it; nothing here rescues and carries on, because a failed
  # statement aborts the PostgreSQL transaction and every statement after it.
  defp run_claim(nil, _status), do: :ok
  defp run_claim(claim, status) when is_function(claim, 1), do: claim.(status)

  defp precheck_resume(nil), do: {:ok, nil}

  # The run's components travel with the queued resume (#2219), so a fresh
  # request can tell whether the resume covers it.
  defp precheck_resume(stamp) do
    with {:ok, run} <- Backups.resumable_run(stamp) do
      {:ok, if(run.components == [], do: nil, else: run.components)}
    end
  end

  defp decide(%{chain_id: nil} = row, req) do
    chain = Ash.UUID.generate()

    with {:ok, job} <- insert_step(start_args(chain, req, 0, nil)) do
      hold!(row, chain, req.trigger, req.resume, job.id)
      {:ok, %{status: :started, chain: chain}}
    end
  end

  defp decide(row, req) do
    cond do
      req.resume != nil and req.resume in [row.stamp, row.resume_stamp] ->
        {:error, :in_flight}

      is_nil(row.waiting_requested_at) ->
        write!(&Backups.queue_backup_request!/3, row, %{
          waiting_trigger: req.trigger,
          waiting_resume_stamp: req.resume,
          waiting_requested_by: req.by,
          waiting_components: if(req.resume, do: req.resume_components, else: req.components),
          waiting_scheduled: req.scheduled,
          waiting_schedule_ids: req.schedule_ids
        })

        {:ok, %{status: :queued, chain: row.chain_id}}

      row.waiting_resume_stamp == req.resume ->
        write!(&Backups.fold_backup_request!/3, row, fold_fields(row, req))
        {:ok, %{status: :folded, chain: row.chain_id}}

      true ->
        {:error, {:queue_busy, queued_kind(row)}}
    end
  end

  # What the queued request is, for a request that may not fold into it.
  defp queued_kind(%{waiting_resume_stamp: nil}), do: :backup
  defp queued_kind(%{waiting_resume_stamp: stamp}), do: {:resume, stamp}

  # What the queued request covers once `req` folds into it. Only like folds
  # into like (#2540): a queued resume takes only a resume of its own stamp and
  # keeps its run's components; a fresh request folding into a queued fresh
  # one widens it, and one whose scope is not valid covers everything
  # (`waiting_scope/1`).
  defp fold_fields(%{waiting_resume_stamp: stamp} = row, req) when is_binary(stamp) do
    case waiting_scope(row) do
      %{valid?: true} = scope ->
        %{
          waiting_components: scope.components,
          waiting_scheduled: Enum.uniq(scope.scheduled ++ req.scheduled),
          waiting_schedule_ids: Enum.uniq(scope.schedule_ids ++ req.schedule_ids)
        }

      %{valid?: false} ->
        %{
          waiting_components: nil,
          waiting_scheduled: req.scheduled,
          waiting_schedule_ids: req.schedule_ids
        }
    end
  end

  defp fold_fields(row, req) do
    fields =
      case waiting_scope(row) do
        %{valid?: true} = scope ->
          %{
            waiting_components: widen(scope.components, req.components),
            waiting_scheduled: Enum.uniq(scope.scheduled ++ req.scheduled),
            waiting_schedule_ids: Enum.uniq(scope.schedule_ids ++ req.schedule_ids)
          }

        %{valid?: false} ->
          %{
            waiting_components: nil,
            waiting_scheduled: req.scheduled,
            waiting_schedule_ids: req.schedule_ids
          }
      end

    Map.merge(fields, fold_trigger(row, req))
  end

  # A request that is not a schedule's wins the trigger of the fold it joins
  # (#2219): retention gives a schedule's own runs the schedule's keep rules,
  # and only a run whose trigger is `"schedule"` counts as one, so a manual
  # backup folded into a scheduled request (or a scheduled request folded into
  # a manual one, which keeps the queued trigger) is never aged out as the
  # schedule's.
  defp fold_trigger(%{waiting_trigger: "schedule"}, %{trigger: trigger})
       when trigger != "schedule",
       do: %{waiting_trigger: trigger}

  defp fold_trigger(_row, _req), do: %{}

  defp widen(nil, _other), do: nil
  defp widen(_one, nil), do: nil
  defp widen(one, other), do: Enum.filter(Lock.components(), &(&1 in one or &1 in other))

  @doc """
  What the queued request on `row` covers (#2219): `components` (nil is
  everything), `scheduled`, `schedule_ids`, and whether the row's fields for
  them are `valid?`. They count only while `waiting_scope_at` equals
  `waiting_requested_at` and `waiting_scope_folds` equals `waiting_folds`: a
  node from before #2219 that queued or folded a request wrote neither, and
  then the request covers everything.
  """
  @spec waiting_scope(Lock.t()) :: %{
          valid?: boolean(),
          components: [atom()] | nil,
          scheduled: [atom()],
          schedule_ids: [String.t()]
        }
  def waiting_scope(row) do
    valid? =
      match?(%DateTime{}, row.waiting_scope_at) and
        match?(%DateTime{}, row.waiting_requested_at) and
        DateTime.compare(row.waiting_scope_at, row.waiting_requested_at) == :eq and
        row.waiting_scope_folds == row.waiting_folds

    if valid? do
      %{
        valid?: true,
        components: row.waiting_components,
        scheduled: row.waiting_scheduled || [],
        schedule_ids: row.waiting_schedule_ids || []
      }
    else
      %{valid?: false, components: nil, scheduled: [], schedule_ids: []}
    end
  end

  defp announce_fold(req) do
    what = if req.resume, do: "a resume of #{req.resume}", else: "a backup (#{req.trigger})"

    Logger.info(
      "Backup request folded: #{what} was asked for while one runs and another is queued; " <>
        "the queued backup covers it"
    )

    :telemetry.execute([:kiln_cms, :backups, :request, :folded], %{count: 1}, %{
      trigger: req.trigger,
      resume: req.resume,
      components: req.components
    })
  end

  ## Steps

  @doc """
  A step job claims the lock. Its chain, step, part and job id must be what the
  row names, else `{:error, :superseded}`. The start step also settles the
  chain's stamp here, once: a retried start reads it back, so it keeps the same
  stamp.

  The start step's backup directory is this node's, every attempt afresh: it
  is bound to the chain (the row's `dir_id`) only when start hands over to
  `dump` (`advance/3`), with its `state.json` written, so a start that failed
  before that and is retried on a node with another `BACKUP_DIR` writes its
  files there and binds that one. The chain's files are never split.

  The directory's id is read before the lock is taken (#2818): reading a file
  on a stalled mount must not hold the lock. Only a directory with no id yet
  (the first start on it) has one created, inside the lock and only once the
  job is known to be current, so a superseded start never creates it. A
  directory whose id can't be read fails the start, again only once it is
  known to be current.

  A fresh stamp steps past one already in use: by a Run, by a work directory,
  or by any file in this node's `db/` or `media/` (#2477), which is how a
  `scripts/backup.sh` run that has no Run yet shows. Those directories are
  listed before the lock too.
  """
  @spec begin_step(Oban.Job.t()) :: {:ok, lease()} | {:error, term()}
  def begin_step(%Oban.Job{id: id, args: args} = job) do
    {dir_id, on_disk} =
      if args["step"] == "start",
        do: {DirId.current(), stamps_on_disk()},
        else: {:not_start, MapSet.new()}

    with_lock(fn row ->
      if current?(row, args, id),
        do: claim_step(row, job, {dir_id, on_disk}),
        else: {:error, :superseded}
    end)
  end

  defp claim_step(row, %Oban.Job{id: job_id, attempt: attempt, args: %{"step" => step}}, found) do
    with {:ok, fields, dir_id} <- start_fields(row, step, found) do
      fields =
        Map.merge(fields, %{
          executing_boot_id: Backups.boot_id(),
          executing_job_id: job_id,
          executing_attempt: attempt
        })

      row = write!(&Backups.mark_backup_lock_executing!/3, row, fields)
      {:ok, %{lease(row, job_id) | dir_id: dir_id, attempt: attempt}}
    end
  end

  defp current?(row, args, job_id) do
    row.chain_id != nil and row.chain_id == args["chain"] and
      to_string(row.step) == args["step"] and row.part == args["part"] and
      row.step_job_id == job_id
  end

  defp start_fields(row, "start", {dir_id, on_disk}) do
    with {:ok, dir_id} <- start_dir_id(dir_id) do
      {:ok, %{stamp: row.stamp || row.resume_stamp || fresh_stamp(on_disk)}, dir_id}
    end
  end

  defp start_fields(row, _step, _found), do: {:ok, %{}, row.dir_id}

  # The id read before the lock (`begin_step/1`). A directory without one is
  # given one here, the only file this transaction may write: the first start
  # on a fresh backup directory.
  defp start_dir_id({:ok, dir_id}), do: {:ok, dir_id}
  defp start_dir_id({:error, :enoent}), do: DirId.local()
  defp start_dir_id({:error, _} = error), do: error

  # Two chains a second apart would share a stamp, and so a Run and file names:
  # step forward past any stamp already used. So would this chain and a cron
  # run of `scripts/backup.sh` started in the same second (#2477): its files
  # have no Run until the Importer reads them, so a stamp with files on disk
  # or a cron run's claim (`on_disk`, `stamps_on_disk/0`) is used too. The
  # script steps past the app's stamps the same way: the start step makes
  # `.work/<stamp>` before anything else (`Steps`), and the script looks for
  # it before and after it claims a stamp. A cron run and a start that look
  # within the same few milliseconds can still pick one stamp
  # (docs/backups.md).
  defp fresh_stamp(on_disk, at \\ DateTime.utc_now(), tries \\ 60) do
    stamp = Artifact.stamp(at)

    if tries > 0 and stamp_taken?(stamp, on_disk),
      do: fresh_stamp(on_disk, DateTime.add(at, 1, :second), tries - 1),
      else: stamp
  end

  defp stamp_taken?(stamp, on_disk) do
    MapSet.member?(on_disk, stamp) or
      match?({:ok, %{}}, Backups.get_run_by_stamp(stamp, actor: Backups.system())) or
      File.exists?(Backups.work_dir(stamp))
  end

  # The stamps any file in this node's `db/` or `media/` carries
  # (`Artifact.name_stamp/1`), and those a running `backup.sh` claims
  # (`.claims/<stamp>`, made before its first file). A directory that can't
  # be listed (not created yet, say) adds none: the start step fails on it
  # later if it matters.
  # sobelow_skip ["Traversal.FileModule"]
  defp stamps_on_disk do
    dir = Backups.dir()

    files =
      for kind <- Artifact.kinds(),
          {:ok, names} <- [File.ls(Path.join(dir, Artifact.subdir(kind)))],
          name <- names,
          {:ok, stamp} <- [Artifact.name_stamp(name)],
          do: stamp

    claims =
      case File.ls(Path.join(dir, ".claims")) do
        {:ok, names} -> Enum.filter(names, &WorkState.valid_stamp?/1)
        {:error, _} -> []
      end

    MapSet.new(files ++ claims)
  end

  defp lease(row, job_id) do
    %{
      chain: row.chain_id,
      epoch: row.epoch,
      job_id: job_id,
      attempt: nil,
      step: to_string(row.step),
      part: row.part,
      stamp: row.stamp,
      dir_id: row.dir_id,
      trigger: row.trigger,
      resume: row.resume_stamp
    }
  end

  @doc """
  Move the chain on to `step` (`part` for an archive step): insert its job and
  point the lock at it, in one transaction. `{:error, :superseded}` when the
  lease is no longer the holder's; nothing is inserted then.

  The job goes to the queue of the chain's backup directory when a live node
  advertises it (`KilnCMS.Backups.DirQueues.routable?/1`, #2845), else to
  `backup_steps`, where a node without the directory moves it there when it
  fetches it. The beats are read before the lock is taken, so a read never
  holds it.
  """
  @spec advance(lease(), String.t(), pos_integer() | nil) :: :ok | {:error, term()}
  def advance(lease, step, part \\ nil) do
    opts = step_queue(lease.dir_id)

    result =
      with_lock(fn row ->
        if holds?(row, lease),
          do: move_to(row, lease, step, part, opts),
          else: {:error, :superseded}
      end)

    with {:ok, _job} <- result, do: :ok
  end

  defp step_queue(dir_id) do
    if DirQueues.enabled?() and DirQueues.routable?(dir_id),
      do: [queue: DirQueues.name(dir_id)],
      else: []
  end

  defp move_to(row, lease, step, part, opts) do
    with {:ok, job} <- insert_step(step_args(lease, step, part), opts) do
      fields = %{step: step, part: part, step_job_id: job.id}

      # The start step's hand-over binds the chain to its backup directory
      # (`begin_step/1`); every later step carries the bound one in its lease.
      fields = if lease.step == "start", do: Map.put(fields, :dir_id, lease.dir_id), else: fields

      write!(&Backups.move_backup_lock!/3, row, fields)
      {:ok, job}
    end
  end

  @doc "Past the point of no return: Cancel is refused from here."
  @spec mark_finishing(lease()) :: :ok | {:error, term()}
  def mark_finishing(lease) do
    result =
      with_lock(fn row ->
        if holds?(row, lease),
          do: {:ok, write!(&Backups.mark_backup_lock_finishing!/3, row, %{})},
          else: {:error, :superseded}
      end)

    with {:ok, _row} <- result, do: :ok
  end

  @doc """
  The chain is done (succeeded, failed terminally, refused): free the lock and
  start the waiting request, if any. `{:ok, promoted_chain | nil}`.
  """
  @spec release(lease()) :: {:ok, String.t() | nil} | {:error, term()}
  def release(lease) do
    with_lock(fn row ->
      if holds?(row, lease), do: release_in_txn(row), else: {:error, :superseded}
    end)
  end

  @doc """
  Give up a resume whose start `job` found no node with the run's files
  (#2539; `StepWorker`): when `job` is still the lock's start job, free the
  lock and promote the waiting request, then, after the commit, say on the
  run why (`Steps.resume_refused/3`). Returns what the job returns:
  `{:cancel, reason}`, or `{:cancel, :superseded}` when the lock has moved on.
  """
  @spec abandon_start(Oban.Job.t(), term()) :: {:cancel, term()} | {:error, term()}
  def abandon_start(%Oban.Job{id: id, args: args}, reason) do
    result =
      with_lock(fn row ->
        if current?(row, args, id), do: release_resume(row), else: {:error, :superseded}
      end)

    case result do
      {:ok, stamp} when is_binary(stamp) ->
        Steps.resume_refused(stamp, args["chain"], reason)
        {:cancel, reason}

      {:ok, nil} ->
        {:cancel, reason}

      {:error, :superseded} ->
        {:cancel, :superseded}

      {:error, error} ->
        Logger.warning("Couldn't give up the backup resume: #{inspect(error, limit: 5)}")
        {:error, error}
    end
  end

  defp release_resume(row) do
    with {:ok, _promoted} <- release_in_txn(row), do: {:ok, row.resume_stamp}
  end

  @doc """
  Run `fun` under the lock, only while `lease` still holds it. A Cancel takes
  the same advisory lock, so a cancel that commits first makes this skip `fun`
  (`{:error, :superseded}`), and a cancel that comes after waits for `fun`.
  Keep `fun` short: it holds the lock transaction.
  """
  @spec while_holding(map(), (-> term())) :: {:ok, term()} | {:error, term()}
  def while_holding(lease, fun) do
    with_lock(fn row ->
      if holds?(row, lease), do: {:ok, fun.()}, else: {:error, :superseded}
    end)
  end

  @doc """
  `while_holding/2` for a file-system call that answers `:ok` or
  `{:error, reason}`: `:ok`, the call's own `{:error, reason}`, or
  `{:error, :superseded}` when the lease no longer holds the lock (the call
  was not made). Keep `fun` to one rename, or a few: it holds the lock
  transaction.
  """
  @spec fenced(map(), (-> :ok | {:error, term()})) :: :ok | {:error, term()}
  def fenced(lease, fun) do
    case while_holding(lease, fun) do
      {:ok, :ok} -> :ok
      {:ok, {:error, _} = error} -> error
      {:error, _} = error -> error
    end
  end

  @doc """
  Rename `from` to `to` only while `lease` holds the lock (`fenced/2`): how a
  step puts a file it wrote under a temporary name of its own into place
  (#2819). A superseded step's rename is refused with `{:error, :superseded}`
  and leaves `to` as it was.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec fenced_rename(map(), Path.t(), Path.t()) :: :ok | {:error, term()}
  def fenced_rename(lease, from, to), do: fenced(lease, fn -> File.rename(from, to) end)

  defp holds?(row, lease) do
    row.chain_id == lease.chain and row.epoch == lease.epoch and row.step_job_id == lease.job_id
  end

  @doc """
  Inside a lock transaction: cancel every step job of `chain`, in whichever
  queue (`backup_steps` or a directory's, #2845), by worker and args
  (`Oban.cancel_all_jobs/1`; an executing one is killed once the transaction
  commits). For the person's Cancel (`Run.Changes.Cancel`, and a resume
  canceled before it started, `Run.Changes.CancelResume`), which then releases
  the lock with `release_in_txn/1`.
  """
  @spec cancel_chain_jobs(String.t()) :: :ok
  def cancel_chain_jobs(chain) when is_binary(chain) do
    worker = inspect(StepWorker)
    contains = %{"chain" => chain}

    # `@>` so the args' GIN index serves it.
    query =
      from(j in Oban.Job,
        where: j.worker == ^worker and fragment("? @> ?", j.args, type(^contains, :map))
      )

    {:ok, _canceled} = Oban.cancel_all_jobs(query)
    :ok
  end

  @doc """
  Inside a lock transaction: clear the holder and promote the waiting request
  to a new chain. `{:ok, promoted_chain | nil}`, or `{:error, reason}` when the
  promoted start job can't be inserted (the caller rolls back).
  """
  @spec release_in_txn(Lock.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def release_in_txn(row) do
    row = write!(&Backups.clear_backup_lock!/3, row, %{})

    case row.waiting_requested_at do
      nil ->
        {:ok, nil}

      requested_at ->
        chain = Ash.UUID.generate()
        scope = waiting_scope(row)

        req = %{
          trigger: row.waiting_trigger || "manual",
          resume: row.waiting_resume_stamp,
          components: scope.components,
          scheduled: scope.scheduled,
          schedule_ids: scope.schedule_ids
        }

        args = start_args(chain, req, row.waiting_folds, requested_at)

        with {:ok, job} <- insert_step(args) do
          hold!(row, chain, req.trigger, req.resume, job.id)
          {:ok, chain}
        end
    end
  end

  defp hold!(row, chain, trigger, resume, job_id) do
    write!(&Backups.hold_backup_lock!/3, row, %{
      chain_id: chain,
      trigger: trigger,
      resume_stamp: resume,
      step: :start,
      part: nil,
      step_job_id: job_id
    })
  end

  # Every Lock write: as the `:backups` system actor, explicitly, and inside the
  # lock transaction, so its notifications (the Lock has no notifiers) are
  # returned rather than reported as missed.
  defp write!(fun, row, params) do
    {row, _notifications} = fun.(row, params, write_opts())
    row
  end

  defp write_opts, do: [actor: Backups.system(), return_notifications?: true]

  # `"components"` nil is everything. A node from before #2219 ignores the
  # three keys, and backs up everything.
  defp start_args(chain, req, folded, requested_at) do
    %{
      "chain" => chain,
      "step" => "start",
      "part" => nil,
      "trigger" => req.trigger,
      "resume" => req.resume,
      "components" => req.components && Enum.map(req.components, &Atom.to_string/1),
      "scheduled" => Enum.map(req.scheduled, &to_string/1),
      "schedule_ids" => req.schedule_ids,
      "folded" => folded,
      "requested_at" => requested_at && DateTime.to_iso8601(requested_at)
    }
  end

  defp step_args(lease, step, part) do
    %{
      "chain" => lease.chain,
      "step" => step,
      "part" => part,
      "stamp" => lease.stamp,
      "dir" => lease.dir_id,
      "trigger" => lease.trigger,
      "resume" => lease.resume
    }
  end

  # A conflict means a job for this chain+step+part already exists: storing its
  # id (or none) would point the lock at a job this chain did not decide on.
  defp insert_step(args, opts \\ []) do
    case args |> StepWorker.new(opts) |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: false, id: id} = job} when is_integer(id) -> {:ok, job}
      {:ok, %Oban.Job{}} -> {:error, :step_conflict}
      {:error, _} = error -> error
    end
  end

  ## The last-good marker (#2554)

  @doc """
  Bring the `.good` markers in `dir` in step with its newest verified backups,
  and the `.hold` markers with what the schedules' keep rules hold
  (`Retention.sync_last_good/2`), for a deployment whose backups come from host
  cron, where no chain ever runs to do it. What `MarkerSyncWorker` runs.

  The importer runs first, outside the lock: it writes Run rows, and no Run
  write happens inside the lock transaction (see the moduledoc). Then, under
  the lock and only while no chain holds it, the scan, the Run read and the
  marker writes. While this holds the advisory lock no request can start a
  chain (`request/1` waits for it), so a sync and an in-app backup never move
  the markers at the same time. While a chain holds the lock this writes
  nothing and returns `:busy`: that chain syncs the markers itself when it
  succeeds or prunes.

  The critical section is local work: listing `db/`, `media/` and `.work/`,
  an `lstat` per file, one Run query, and creating or removing marker files.
  Nothing bounds how long a stalled filesystem keeps it there; the
  transaction's timeout applies to its queries, not to the file calls.

  A held backup the sync finds deleted outside the app (#2931, see
  `Retention`'s "The hold markers") is logged and counted under the lock, and
  its notice is written once the lock transaction commits
  (`KilnCMS.AfterCommit.deferring/1`), so a failed notice write can't abort
  it.

  `{:ok, %{db: stamp | nil, media: stamp | nil}}`, `:busy`, or
  `{:error, reason}` with no marker written or removed (logged, with a
  `[:kiln_cms, :backups, :last_good, :failed]` event). Never raises.
  """
  @spec sync_last_good(Path.t(), keyword()) ::
          {:ok, %{db: String.t() | nil, media: String.t() | nil}} | :busy | {:error, term()}
  def sync_last_good(dir \\ Backups.dir(), opts \\ []) do
    opts = Keyword.put(opts, :import, false)

    result =
      with {:ok, _summary} <- import_for_sync(dir) do
        # The held-deleted notice (#2931) is written after COMMIT, so a failed
        # write can't abort the lock transaction.
        AfterCommit.deferring(fn -> with_lock(&sync_unless_held(&1, dir, opts)) end)
      end

    case result do
      {:ok, :busy} -> :busy
      {:ok, last_good} -> synced(dir, last_good)
      # `Retention.sync_last_good/2` reported its own failure; the rollback
      # only undoes the lock row's ensure.
      {:error, {:retention, reason}} -> {:error, reason}
      {:error, reason} -> Retention.sync_failed(reason)
    end
  rescue
    error -> Retention.sync_failed({:crashed, error.__struct__})
  catch
    # The lock wait or a query timing out exits; a periodic job must log it
    # and try again next time, not crash.
    kind, _reason -> Retention.sync_failed({:crashed, kind})
  end

  defp sync_unless_held(%{chain_id: nil}, dir, opts), do: locked_sync(dir, opts)
  defp sync_unless_held(_held, _dir, _opts), do: {:ok, :busy}

  defp locked_sync(dir, opts) do
    case Retention.sync_last_good(dir, opts) do
      {:ok, last_good} -> {:ok, last_good}
      {:error, reason} -> {:error, {:retention, reason}}
    end
  end

  defp import_for_sync(dir) do
    case Importer.run(dir) do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, {:import, reason}}
    end
  end

  # `held`: how many `.hold` markers the directory has once the sync is done
  # (#2219), counted from the disk.
  defp synced(dir, last_good) do
    markers = Markers.read(dir)

    :telemetry.execute([:kiln_cms, :backups, :last_good, :synced], %{count: 1}, %{
      dir: dir,
      db: last_good.db,
      media: last_good.media,
      held: Enum.sum(for {_kind, stamps} <- markers.hold, do: MapSet.size(stamps))
    })

    {:ok, last_good}
  end

  ## Reclaim and reap

  @doc false
  # `config :kiln_cms, KilnCMS.Backups, heartbeat?:` (default true; the test
  # build turns it off and drives `reclaim_stale/0` directly).
  @spec heartbeat?() :: boolean()
  def heartbeat? do
    Keyword.get(Application.get_env(:kiln_cms, KilnCMS.Backups, []), :heartbeat?, true)
  end

  @doc """
  Free the lock from a step whose node stopped (D9). The holder's step job must
  be `executing`; its node (`attempted_by`) is stale when its `NodeBeat` is
  older than #{@stale_after_s} s by the database's clock (or it has none and the
  job was attempted that long ago), or, when the job's current attempt claimed
  the lock (`executing_job_id` and `executing_attempt`), the beat's boot id is
  not the one that claimed it.

  The old job is canceled first, so a zombie that wakes up can neither ack it
  nor move the chain on (its epoch is gone). With attempts left the step is
  requeued under a new job with the remaining budget, same stamp; with none the
  run fails as interrupted (a finish that had in fact finished is completed
  instead, `Steps.interrupt_finish/4`) and the waiting request is promoted.

  Returns `{:ok, :none | {:requeued, info} | {:interrupted, info}}`.
  """
  @spec reclaim_stale() :: {:ok, term()} | {:error, term()}
  def reclaim_stale do
    result =
      with_lock(fn row ->
        with %{chain_id: chain, step_job_id: job_id} when is_binary(chain) and is_integer(job_id) <-
               row,
             %Oban.Job{state: "executing"} = job <- lock_job(job_id),
             {:stale, node} <- stale(row, job) do
          reclaim(row, job, node)
        else
          _ -> {:ok, :none}
        end
      end)

    after_reclaim(result)
  rescue
    error ->
      Logger.warning("Backup lock reclaim failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp lock_job(id), do: Repo.one(from(j in Oban.Job, where: j.id == ^id, lock: "FOR UPDATE"))

  defp stale(row, job) do
    node = List.first(job.attempted_by || [])
    %{rows: [[now]]} = Repo.query!("SELECT now()")
    cutoff = DateTime.add(now, -@stale_after_s, :second)

    beat =
      node && Backups.get_node_beat!(node, actor: Backups.system(), authorize_with: :error)

    if stale?(row, job, beat, cutoff), do: {:stale, node}, else: :alive
  end

  # A beat from a different boot than the one that claimed the current attempt
  # of the current step means the node restarted; otherwise the beat (or, with
  # none, the attempt) is old. A later attempt of the same job, fetched by
  # another node (or this one after a redeploy) and not yet claimed, is not
  # evidence: the boot id on the row is the earlier attempt's.
  defp stale?(row, job, %{} = beat, cutoff) do
    restarted? =
      row.executing_job_id == row.step_job_id and row.executing_attempt == job.attempt and
        beat.boot_id != row.executing_boot_id

    restarted? or before?(beat.beat_at, cutoff)
  end

  defp stale?(_row, job, nil, cutoff), do: before?(job.attempted_at, cutoff)

  defp before?(%DateTime{} = at, cutoff), do: DateTime.compare(at, cutoff) == :lt
  defp before?(_at, _cutoff), do: false

  defp reclaim(row, job, node) do
    :ok = Oban.cancel_job(job.id)
    info = info(row, node)
    remaining = job.max_attempts - job.attempt

    if remaining > 0 do
      # A fresh `meta`: the replacement is a new attempt, with its own
      # affinity snoozes (`StepWorker`).
      with {:ok, replacement} <- insert_step(job.args, max_attempts: remaining) do
        move_to_replacement(row, replacement)
        {:ok, {:requeued, Map.put(info, :job_id, replacement.id)}}
      end
    else
      with {:ok, promoted} <- release_in_txn(row) do
        {:ok, {:interrupted, Map.put(info, :promoted, promoted)}}
      end
    end
  end

  # `:move` resets the phase to `:running`. A finishing step stays past the
  # point of no return (#3012): until its replacement runs `mark_finishing/1`
  # again, a Cancel would otherwise be accepted for a backup whose manifest
  # may already say ok.
  defp move_to_replacement(row, replacement) do
    moved =
      write!(&Backups.move_backup_lock!/3, row, %{
        step: row.step,
        part: row.part,
        step_job_id: replacement.id
      })

    if row.phase == :finishing,
      do: write!(&Backups.mark_backup_lock_finishing!/3, moved, %{})
  end

  defp info(row, node) do
    %{
      chain: row.chain_id,
      stamp: row.stamp,
      dir_id: row.dir_id,
      step: row.step,
      part: row.part,
      node: node,
      resume: row.resume_stamp
    }
  end

  defp after_reclaim({:ok, {:requeued, info}} = result) do
    Logger.warning(
      "Backup step #{info.step} of #{info.stamp || "a starting backup"} was on node " <>
        "#{info.node}, which stopped responding: requeued (job #{info.job_id})"
    )

    reclaimed_event(info, :requeued)
    result
  end

  defp after_reclaim({:ok, {:interrupted, info}} = result) do
    if interrupt(info, "Interrupted: node #{info.node} stopped responding") != :finished do
      Logger.error(
        "Backup step #{info.step} of #{info.stamp || "a starting backup"} was on node " <>
          "#{info.node}, which stopped responding, and has no attempts left: the backup failed"
      )
    end

    reclaimed_event(info, :interrupted)
    result
  end

  defp after_reclaim(result), do: result

  defp reclaimed_event(info, outcome) do
    :telemetry.execute([:kiln_cms, :backups, :lock, :reclaimed], %{count: 1}, %{
      chain: info.chain,
      stamp: info.stamp,
      step: info.step,
      node: info.node,
      outcome: outcome
    })
  end

  @doc """
  Release a lock whose step job is gone (completed, discarded or canceled
  without moving the chain on, or deleted): a step killed by its timeout, a
  job discarded by Lifeline, a linked exit. The run fails as interrupted (a
  finish that had in fact finished is completed instead,
  `Steps.interrupt_finish/4`) and the waiting request is promoted. `{:ok, :none | {:orphaned, info}}`.
  """
  @spec reap() :: {:ok, term()} | {:error, term()}
  def reap do
    result =
      with_lock(fn row ->
        if row.chain_id != nil and orphaned?(row.step_job_id),
          do: release_orphan(row),
          else: {:ok, :none}
      end)

    with {:ok, {:orphaned, info}} <- result,
         outcome when outcome != :finished <-
           interrupt(info, "Interrupted: the backup's step job ended without finishing its step") do
      Logger.error(
        "Backup step #{info.step} of #{info.stamp || "a starting backup"} ended without " <>
          "finishing its step: the backup failed and the lock was released"
      )
    end

    result
  rescue
    error ->
      Logger.warning("Backup lock reap failed: #{Exception.message(error)}")
      {:error, error}
  end

  @doc """
  Deal with the backup steps left waiting in a backup directory's queue
  that no node runs (#2845; `KilnCMS.Backups.DirQueues`, "Jobs left in a
  queue no node runs"). For each `StepWorker` job that has waited there:

    * a live node (180 s) reports the directory but none advertises its
      queue, for #{DirQueues.move_back_after_s()} s: the holder's job goes
      back to `backup_steps` (same id, available), where it snoozes as before
      #2845 until that node picks it up;
    * no live node reports the directory, for #{DirQueues.stranded_after_s()} s:
      a pinned step is interrupted (its job canceled, the lock released, the
      waiting request promoted, the run failed with a message that says
      why); a resume's start goes back to `backup_steps`, where its
      lost-directory fallback decides (`StepWorker`);
    * otherwise it is left: a node runs the queue, or will soon.

  A job that is not the lock's (superseded, so it would cancel itself when
  run) is canceled in either of the first two cases. The beats are read
  before the lock is taken; beats that can't be read leave everything, with
  a warning. `{:ok, :none | {:interrupted | :returned | :moved_back, info}}`
  for the holder's job.
  """
  @spec sweep_stranded() :: {:ok, term()} | {:error, term()}
  def sweep_stranded do
    case DirQueues.waiting(inspect(StepWorker)) do
      [] -> {:ok, :none}
      waiting -> sweep_waiting(waiting)
    end
  rescue
    error ->
      Logger.warning("Backup stranded-step sweep failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp sweep_waiting(waiting) do
    case waiting |> Enum.map(& &1.dir_id) |> Enum.uniq() |> DirQueues.statuses() do
      {:ok, statuses} ->
        acts =
          for job <- waiting,
              verdict = DirQueues.verdict(statuses[job.dir_id], job.waited_s),
              verdict != :leave,
              do: {job, verdict}

        if acts == [], do: {:ok, :none}, else: sweep_acts(acts)

      {:error, error} ->
        Logger.warning(
          "Backup stranded-step sweep skipped: couldn't read the node heartbeats " <>
            "(#{describe(error)})"
        )

        {:ok, :none}
    end
  end

  defp sweep_acts(acts) do
    result =
      with_lock(fn row ->
        Enum.reduce_while(acts, {:ok, :none}, &sweep_step(row, &1, &2))
      end)

    after_sweep(result)
  end

  # The holder's outcome is the result; a stray's is `:none`.
  defp sweep_step(row, {job, verdict}, {:ok, acc}) do
    case sweep_one(row, job, verdict) do
      {:ok, :none} -> {:cont, {:ok, acc}}
      {:ok, outcome} -> {:cont, {:ok, outcome}}
      {:error, _} = error -> {:halt, error}
    end
  end

  # Under the lock: the holder's job is acted on only while it still waits
  # in that queue (`DirQueues.move_back/2` and the cancel match on both).
  defp sweep_one(%{step_job_id: id} = row, %{id: id} = job, :move_back) do
    moved_back(row, job, :moved_back)
  end

  defp sweep_one(%{step_job_id: id, step: :start} = row, %{id: id} = job, :stranded) do
    moved_back(row, job, :returned)
  end

  defp sweep_one(%{step_job_id: id} = row, %{id: id} = job, :stranded) do
    if still_waiting?(id, job.queue) do
      :ok = Oban.cancel_job(id)

      with {:ok, promoted} <- release_in_txn(row) do
        info = info(row, nil) |> Map.put(:queue, job.queue) |> Map.put(:promoted, promoted)
        {:ok, {:interrupted, info}}
      end
    else
      {:ok, :none}
    end
  end

  # Not the lock's job: superseded, whatever the verdict.
  defp sweep_one(_row, job, _verdict) do
    if still_waiting?(job.id, job.queue) do
      :ok = Oban.cancel_job(job.id)

      Logger.warning(
        "Backup step job #{job.id} was left in #{job.queue} after its backup moved on: canceled"
      )
    end

    {:ok, :none}
  end

  defp moved_back(row, job, outcome) do
    case DirQueues.move_back(job.id, job.queue) do
      :ok -> {:ok, {outcome, Map.put(info(row, nil), :queue, job.queue)}}
      :gone -> {:ok, :none}
    end
  end

  defp still_waiting?(id, queue) do
    Repo.exists?(
      from(j in Oban.Job,
        where:
          j.id == ^id and j.queue == ^queue and
            j.state in ["available", "scheduled", "retryable"]
      )
    )
  end

  defp after_sweep({:ok, {:interrupted, info}} = result) do
    dir = DirQueues.dir_id(info.queue)

    message =
      "Interrupted: no server with its backup directory (id #{dir}) picked up the " <>
        "#{info.step} step for #{div(DirQueues.stranded_after_s(), 60)} minutes"

    if interrupt(info, message) != :finished do
      Logger.error(
        "Backup step #{info.step} of #{info.stamp || "a starting backup"} waited " <>
          "#{div(DirQueues.stranded_after_s(), 60)} minutes for a server with its backup " <>
          "directory (id #{dir}), and none is running: the backup failed and the lock was " <>
          "released"
      )
    end

    stranded_event(info, :interrupted)
    result
  end

  defp after_sweep({:ok, {outcome, info}} = result) when outcome in [:returned, :moved_back] do
    dir = DirQueues.dir_id(info.queue)

    why =
      if outcome == :returned,
        do: "no server with its backup directory (id #{dir}) is running",
        else: "the servers with its backup directory (id #{dir}) don't run its queue"

    Logger.warning(
      "Backup step #{info.step} of #{info.stamp || "a starting backup"} moved back to " <>
        "backup_steps: #{why}"
    )

    stranded_event(info, outcome)
    result
  end

  defp after_sweep(result), do: result

  defp stranded_event(info, outcome) do
    :telemetry.execute([:kiln_cms, :backups, :lock, :stranded], %{count: 1}, %{
      chain: info.chain,
      stamp: info.stamp,
      step: info.step,
      queue: info.queue,
      outcome: outcome
    })
  end

  defp describe(error) when is_exception(error), do: Exception.message(error)
  defp describe(error), do: inspect(error, limit: 5)

  defp release_orphan(row) do
    info = info(row, nil)

    with {:ok, promoted} <- release_in_txn(row) do
      {:ok, {:orphaned, Map.put(info, :promoted, promoted)}}
    end
  end

  defp orphaned?(nil), do: true

  defp orphaned?(job_id) do
    case Repo.one(from(j in Oban.Job, where: j.id == ^job_id, select: j.state)) do
      nil -> true
      state -> state in ["completed", "discarded", "cancelled"]
    end
  end

  # After the commit: the Run, and the failure manifest when the files are here.
  # `:finished` when the step was a finish that had in fact finished (#2419):
  # it is completed, not failed (`Steps.interrupt_finish/4`).
  #
  # A resume chain (#2539) whose start never re-opened the run (discarded or
  # killed before it claimed the lock, or before the re-open) has no run of its
  # own to fail: the run still names the chain it last ran under. It gets the
  # refusal note instead of nothing.
  defp interrupt(%{step: :finish, stamp: stamp} = info, message) when is_binary(stamp) do
    Steps.interrupt_finish(stamp, info.chain, info.dir_id, message)
  rescue
    error ->
      Logger.warning("Couldn't record the interrupted backup: #{Exception.message(error)}")
      :ok
  end

  defp interrupt(%{resume: stamp} = info, message) when is_binary(stamp) do
    if Recorder.from_run(stamp, info.chain).run,
      do: Steps.interrupt(stamp, info.chain, info.dir_id, message),
      else: Steps.resume_refused(stamp, info.chain, {:interrupted, message})
  rescue
    error ->
      Logger.warning("Couldn't record the interrupted backup: #{Exception.message(error)}")
      :ok
  end

  defp interrupt(%{stamp: nil}, _message), do: :ok

  defp interrupt(info, message) do
    Steps.interrupt(info.stamp, info.chain, info.dir_id, message)
  rescue
    error ->
      Logger.warning("Couldn't record the interrupted backup: #{Exception.message(error)}")
      :ok
  end

  @doc "The lock as `Backups.in_flight/1` reports it; see there."
  @spec in_flight(keyword()) :: map() | nil
  def in_flight(opts \\ []) do
    case Backups.backup_lock(actor: Backups.system()) do
      {:ok, %{chain_id: chain} = row} when is_binary(chain) ->
        in_flight = held(row)

        if Keyword.get(opts, :details, false),
          do: Map.put(in_flight, :waiting_for, waiting_for(row)),
          else: in_flight

      _ ->
        nil
    end
  end

  defp held(row) do
    {destinations_total, destination_label} = destination_progress(row)

    %{
      chain: row.chain_id,
      stamp: row.stamp || row.resume_stamp,
      resume: row.resume_stamp,
      trigger: row.trigger,
      step: row.step,
      part: row.part,
      parts_total: parts_total(row),
      destinations_total: destinations_total,
      destination_label: destination_label,
      components: holder_components(row),
      phase: row.phase,
      acquired_at: row.acquired_at,
      waiting:
        row.waiting_requested_at &&
          %{
            trigger: row.waiting_trigger,
            resume: row.waiting_resume_stamp,
            components: waiting_scope(row).components,
            requested_at: row.waiting_requested_at,
            folds: row.waiting_folds
          }
    }
  end

  # What a resume's start is waiting for before it re-opens its run (#2816),
  # from its job: `:files_server` while it snoozes for the server that has the
  # run's files (`StepWorker`'s pinned affinity; a retryable attempt only
  # when that is what failed it) or waits in that directory's queue (#2845),
  # `:cancel_settle` while it runs inside the settle window of the run's
  # Cancel (`Steps`), else nil. Only for the
  # Backups page (`in_flight/1`'s `details: true`): two more reads, which the
  # `Backups.await/2` poll doesn't need.
  defp waiting_for(%{step: :start, resume_stamp: stamp, step_job_id: id})
       when is_binary(stamp) and is_integer(id) do
    query =
      from(j in Oban.Job, where: j.id == ^id, select: map(j, [:state, :meta, :errors, :queue]))

    case Repo.one(query) do
      %{state: state} = job when state in ["available", "scheduled", "retryable"] ->
        # Parked in its directory's queue (#2845), it waits for a server with
        # the files by being there.
        if DirQueues.dir_queue?(job.queue) or snoozed_for_files?(job), do: :files_server

      %{state: "executing"} ->
        if canceled_recently?(stamp), do: :cancel_settle

      _other ->
        nil
    end
  end

  defp waiting_for(_row), do: nil

  # `meta["snoozed"]` counts across all attempts; this attempt's snoozes are
  # those since `meta["affinity_base"]` (`StepWorker.snoozes_this_attempt/1`).
  # An attempt that failed with `:backup_dir_elsewhere` was rebased before it
  # failed, so its retry (retryable, then available) says so through its last
  # error instead. Snoozes of an earlier attempt that got past the check, then
  # failed or was retried for another reason, count for nothing.
  defp snoozed_for_files?(%{meta: meta, errors: errors}) do
    (meta["snoozed"] || 0) - (meta["affinity_base"] || 0) > 0 or last_error_elsewhere?(errors)
  end

  defp last_error_elsewhere?(errors) do
    case List.last(errors || []) do
      %{"error" => error} when is_binary(error) -> error =~ "backup_dir_elsewhere"
      _ -> false
    end
  end

  defp canceled_recently?(stamp) do
    case Backups.get_run_by_stamp(stamp, actor: Backups.system()) do
      {:ok, %{status: :canceled, finished_at: %DateTime{} = at}} ->
        DateTime.diff(DateTime.utc_now(), at, :millisecond) < Heartbeat.settled_after_ms()

      _ ->
        false
    end
  end

  # How many media parts the archive step works through: the frozen plan's
  # count in `state.json`, readable only on a node that has the chain's backup
  # directory. Nil elsewhere, and before the plan step.
  defp parts_total(%{step: :archive, stamp: stamp, dir_id: dir_id}) when is_binary(stamp) do
    with {:ok, ^dir_id} <- DirId.current(),
         {:ok, %{"parts_total" => total}} when is_integer(total) <-
           WorkState.read(Backups.work_dir(stamp)) do
      total
    else
      _ -> nil
    end
  end

  defp parts_total(_row), do: nil

  # Which destination the `offsite` step sends to (#2220): `{n, label}`, the
  # number of destinations the start froze in `state.json` and the redacted
  # label of the one `part` names, readable only on a node that has the
  # chain's backup directory. `{nil, nil}` elsewhere, and for the no-op
  # `offsite` of a backup without destinations.
  defp destination_progress(%{step: :offsite, part: part, stamp: stamp, dir_id: dir_id})
       when is_integer(part) and is_binary(stamp) do
    with {:ok, ^dir_id} <- DirId.current(),
         {:ok, %{"destinations" => list}} when is_list(list) <-
           WorkState.read(Backups.work_dir(stamp)),
         %{"label" => label} when is_binary(label) <- Enum.at(list, part - 1) do
      {length(list), label}
    else
      _ -> {nil, nil}
    end
  end

  defp destination_progress(_row), do: {nil, nil}

  # The holder's components, from its `state.json` (their only record; see the
  # moduledoc): readable only on a node that has the chain's backup directory,
  # once the start step has handed over. Nil elsewhere.
  defp holder_components(%{stamp: stamp, dir_id: dir_id})
       when is_binary(stamp) and is_binary(dir_id) do
    with {:ok, ^dir_id} <- DirId.current(),
         {:ok, %{"components" => names}} when is_list(names) <-
           WorkState.read(Backups.work_dir(stamp)) do
      Enum.filter(Lock.components(), &(Atom.to_string(&1) in names))
    else
      _ -> nil
    end
  end

  defp holder_components(_row), do: nil

  @doc "The stamp the lock holds (or is about to: a resume not yet begun), or nil."
  @spec held_stamp() :: String.t() | nil
  def held_stamp do
    case fetch_held_stamp() do
      {:ok, stamp} -> stamp
      {:error, _} -> nil
    end
  end

  @doc """
  `held_stamp/0` for a caller that must tell "none held" (`{:ok, nil}`) from
  "the lock could not be read" (`{:error, reason}`).
  """
  @spec fetch_held_stamp() :: {:ok, String.t() | nil} | {:error, term()}
  def fetch_held_stamp do
    case Backups.backup_lock(actor: Backups.system(), authorize_with: :error) do
      {:ok, %{chain_id: chain} = row} when is_binary(chain) ->
        {:ok, row.stamp || row.resume_stamp}

      {:ok, _free_or_missing} ->
        {:ok, nil}

      {:error, _} = error ->
        error
    end
  end
end
