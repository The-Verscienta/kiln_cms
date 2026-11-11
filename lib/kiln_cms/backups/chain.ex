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

  Every Lock write passes `actor: Backups.system()` explicitly.

  ## Fencing

  A step presents what `begin_step/1` gave it (`epoch`, its job id) to
  `advance/3`, `mark_finishing/1` and `release/1`. A step whose job was
  reclaimed, canceled or otherwise superseded meanwhile gets
  `{:error, :superseded}` and its results are discarded.

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

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, DirId, Lock, Steps, StepWorker, WorkState}
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
  asks again once the queue clears; a scheduler (#2219, not yet built) must
  roll its window back and retry on a later tick, so a scheduled backup is
  never folded into a Resume.
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
      schedule_ids: Map.get(attrs, :schedule_ids) || []
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

      result = with_lock(fn row -> decide(row, req) end)

      with {:ok, %{status: :folded}} <- result, do: announce_fold(req)
      result
    end
  end

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
  end

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
  """
  @spec begin_step(Oban.Job.t()) :: {:ok, lease()} | {:error, term()}
  def begin_step(%Oban.Job{id: id, args: args} = job) do
    with_lock(fn row ->
      if current?(row, args, id),
        do: claim_step(row, job),
        else: {:error, :superseded}
    end)
  end

  defp claim_step(row, %Oban.Job{id: job_id, attempt: attempt, args: %{"step" => step}}) do
    with {:ok, fields, dir_id} <- start_fields(row, step) do
      fields =
        Map.merge(fields, %{
          executing_boot_id: Backups.boot_id(),
          executing_job_id: job_id,
          executing_attempt: attempt
        })

      row = write!(&Backups.mark_backup_lock_executing!/3, row, fields)
      {:ok, %{lease(row, job_id) | dir_id: dir_id}}
    end
  end

  defp current?(row, args, job_id) do
    row.chain_id != nil and row.chain_id == args["chain"] and
      to_string(row.step) == args["step"] and row.part == args["part"] and
      row.step_job_id == job_id
  end

  defp start_fields(row, "start") do
    with {:ok, dir_id} <- DirId.local() do
      {:ok, %{stamp: row.stamp || row.resume_stamp || fresh_stamp()}, dir_id}
    end
  end

  defp start_fields(row, _step), do: {:ok, %{}, row.dir_id}

  # Two chains a second apart would share a stamp, and so a Run and file names:
  # step forward past any stamp already used.
  defp fresh_stamp(at \\ DateTime.utc_now(), tries \\ 60) do
    stamp = Artifact.stamp(at)

    if tries > 0 and stamp_taken?(stamp),
      do: fresh_stamp(DateTime.add(at, 1, :second), tries - 1),
      else: stamp
  end

  defp stamp_taken?(stamp) do
    match?({:ok, %{}}, Backups.get_run_by_stamp(stamp, actor: Backups.system())) or
      File.exists?(Backups.work_dir(stamp))
  end

  defp lease(row, job_id) do
    %{
      chain: row.chain_id,
      epoch: row.epoch,
      job_id: job_id,
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
  """
  @spec advance(lease(), String.t(), pos_integer() | nil) :: :ok | {:error, term()}
  def advance(lease, step, part \\ nil) do
    result =
      with_lock(fn row ->
        if holds?(row, lease),
          do: move_to(row, lease, step, part),
          else: {:error, :superseded}
      end)

    with {:ok, _job} <- result, do: :ok
  end

  defp move_to(row, lease, step, part) do
    with {:ok, job} <- insert_step(step_args(lease, step, part)) do
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

  defp holds?(row, lease) do
    row.chain_id == lease.chain and row.epoch == lease.epoch and row.step_job_id == lease.job_id
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
  run fails as interrupted and the waiting request is promoted.

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
        write!(&Backups.move_backup_lock!/3, row, %{
          step: row.step,
          part: row.part,
          step_job_id: replacement.id
        })

        {:ok, {:requeued, Map.put(info, :job_id, replacement.id)}}
      end
    else
      with {:ok, promoted} <- release_in_txn(row) do
        {:ok, {:interrupted, Map.put(info, :promoted, promoted)}}
      end
    end
  end

  defp info(row, node) do
    %{
      chain: row.chain_id,
      stamp: row.stamp,
      dir_id: row.dir_id,
      step: row.step,
      part: row.part,
      node: node
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
    Logger.error(
      "Backup step #{info.step} of #{info.stamp || "a starting backup"} was on node " <>
        "#{info.node}, which stopped responding, and has no attempts left: the backup failed"
    )

    interrupt(info, "Interrupted: node #{info.node} stopped responding")
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
  job discarded by Lifeline, a linked exit. The run fails as interrupted and
  the waiting request is promoted. `{:ok, :none | {:orphaned, info}}`.
  """
  @spec reap() :: {:ok, term()} | {:error, term()}
  def reap do
    result =
      with_lock(fn row ->
        if row.chain_id != nil and orphaned?(row.step_job_id),
          do: release_orphan(row),
          else: {:ok, :none}
      end)

    with {:ok, {:orphaned, info}} <- result do
      Logger.error(
        "Backup step #{info.step} of #{info.stamp || "a starting backup"} ended without " <>
          "finishing its step: the backup failed and the lock was released"
      )

      interrupt(info, "Interrupted: the backup's step job ended without finishing its step")
    end

    result
  rescue
    error ->
      Logger.warning("Backup lock reap failed: #{Exception.message(error)}")
      {:error, error}
  end

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
  defp interrupt(%{stamp: nil}, _message), do: :ok

  defp interrupt(info, message) do
    Steps.interrupt(info.stamp, info.chain, info.dir_id, message)
  rescue
    error ->
      Logger.warning("Couldn't record the interrupted backup: #{Exception.message(error)}")
      :ok
  end

  @doc "The lock as `Backups.in_flight/0` reports it; see there."
  @spec in_flight() :: map() | nil
  def in_flight do
    case Backups.backup_lock(actor: Backups.system()) do
      {:ok, %{chain_id: chain} = row} when is_binary(chain) ->
        %{
          chain: chain,
          stamp: row.stamp || row.resume_stamp,
          trigger: row.trigger,
          step: row.step,
          part: row.part,
          parts_total: parts_total(row),
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

      _ ->
        nil
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
