defmodule KilnCMS.Backups.DirQueues do
  @moduledoc """
  One Oban queue per backup directory (#2845): `backup_dir_<dir_id>`, run
  with concurrency one by every node whose `<BACKUP_DIR>/.kiln-dir-id` is
  that id. A job that must run where a directory's files are (a backup step
  after `start`, a resume's `start`, a per-directory last-good marker sync)
  goes to that queue, so only a node that has the files fetches it, rather
  than snoozing on every node that hasn't (ADR 0040's affinity snooze, kept
  as the fallback below).

  ## Which nodes run a directory's queue

  Each node's heartbeat (`KilnCMS.Backups.Heartbeat`) starts the queue of
  the directory it reports, on this node only (`reconcile/4`). Oban doesn't
  persist a queue started at runtime, so a restarted node starts it again on
  its first tick. A queue is never stopped: a stopped queue's running job is
  orphaned once Oban's shutdown grace period runs out. It is paused instead
  (a running job finishes, no new one is fetched):

    * at once when the directory's id read succeeds with another id (the
      directory was replaced);
    * after 180 s of reads that give no id (`Chain.stale_after_s/0`): a hung
      or missing directory;

  and resumed when the id comes back. A paused queue costs nothing. Each
  tick checks the queues it paused and pauses again one that runs (a pause
  signal lost while Oban's notifier was down, or a later
  `Oban.resume_all_queues/1`). The heartbeat resumes only a queue it paused
  itself: one paused by anything else (an operator, the demo reset's
  `Oban.pause_all_queues/1`) is left paused and not advertised, so its jobs
  keep the snooze in `backup_steps` until it runs again.

  ## Who may route a job there (the capability)

  A node advertises the queue in its beat (`KilnCMS.Backups.NodeBeat`'s
  `dir_queue` and `dir_queue_boot_id`) only once it has checked that the
  queue runs here and is not paused; the next beat publishes it. A job is
  routed into `backup_dir_<id>` only when a node that beat within 180 s
  reports `id` as its directory, advertises that queue, and wrote the
  advertisement in its current boot (`routable?/1`). Otherwise it stays in
  `backup_steps` (or `default` for the marker sync) on the bounded affinity
  snooze, as before #2845: a node from before #2845 (mixed-version window,
  rollback), a queue that didn't start (Oban's notifier is down), or no node
  with the directory at all. A queue that hasn't started three ticks after
  the first try logs one warning and emits `:start_failed`.

  Routing happens in two places: a step inserted by `Chain.advance/3` goes
  straight to the queue, and a job fetched from `backup_steps` (or `default`)
  by a node without its directory is moved in place (`move/2`: same job id,
  no attempt spent) and snoozed for 0 s. A reclaimed step and every `start`
  are inserted into `backup_steps` and routed on fetch.

  ## Jobs left in a queue no node runs

  `Chain.sweep_stranded/0` and `MarkerSyncWorker.sweep_stranded/0` look at
  jobs that have waited in a directory queue (`status/1`):

    1. a live node reports the directory but none advertises its queue,
       for 5 minutes: moved back to `backup_steps` (a backup step), or
       canceled (a marker sync);
    2. no live node reports the directory, for 30 minutes: a backup step is
       interrupted and the lock released, a resume's start goes back to
       `backup_steps`, a marker sync is canceled;
    3. otherwise left alone.

  ## Telemetry

  `[:kiln_cms, :backups, :dir_queue, :started | :paused | :resumed |
  :start_failed]` with `%{count: 1}` and `%{queue: name, node: node}` (`:paused`
  also `reason: :changed | :gone`); `[:kiln_cms, :backups, :dir_queue,
  :routed]` with `%{queue: name, from: queue, worker: worker}`.

  ## Configuration

  `config :kiln_cms, KilnCMS.Backups, dir_queues?:` turns all of it off
  (`false`: every job stays in `backup_steps` on the snooze); it defaults to
  the heartbeat's own switch. `dir_queue_control:` is the module that talks
  to Oban (tests only).
  """
  import Ecto.Query

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, DirId}
  alias KilnCMS.Repo

  require Logger

  @prefix "backup_dir_"
  @start_ticks 3
  @move_back_after_s 300
  @stranded_after_s 1_800
  @waiting_states ["available", "scheduled", "retryable"]

  @typedoc """
  What the heartbeat remembers about this node's directory queues. `queues`:
  `:active` (running, as far as it knows), `:paused` (paused by this
  heartbeat, so it may resume it) or `:held` (found paused by something
  else, which it never resumes).
  """
  @type state :: %{
          advertised: String.t() | nil,
          absent_since: integer() | nil,
          queues: %{String.t() => :active | :paused | :held},
          pending: %{String.t() => pos_integer()},
          start_failed: MapSet.t()
        }

  @typedoc "How a directory stands for routing (`status/1`)."
  @type status :: :advertised | :reported | :none

  @doc "The queue of backup directory `dir_id`, nil for anything that is not a directory id."
  @spec name(term()) :: String.t() | nil
  def name(dir_id), do: if(DirId.valid?(dir_id), do: @prefix <> dir_id)

  @doc "The directory id a queue is named for, nil for any other queue."
  @spec dir_id(term()) :: String.t() | nil
  def dir_id(@prefix <> id = _queue), do: if(DirId.valid?(id), do: id)
  def dir_id(_queue), do: nil

  @doc "Whether `queue` is a directory's queue."
  @spec dir_queue?(term()) :: boolean()
  def dir_queue?(queue), do: dir_id(queue) != nil

  @doc """
  Whether jobs are routed to directory queues and the heartbeat runs them:
  `config :kiln_cms, KilnCMS.Backups, dir_queues?:`, by default the
  heartbeat's own switch (`Chain.heartbeat?/0`).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Keyword.fetch(backups_env(), :dir_queues?) do
      {:ok, enabled?} -> enabled? == true
      :error -> Chain.heartbeat?()
    end
  end

  @doc "Seconds a job waits in a queue no live node advertises before it is moved back."
  @spec move_back_after_s() :: pos_integer()
  def move_back_after_s, do: @move_back_after_s

  @doc "Seconds a job waits for a directory no live node reports before it is stranded."
  @spec stranded_after_s() :: pos_integer()
  def stranded_after_s, do: @stranded_after_s

  ## Routing

  @doc """
  Whether a job pinned to `dir_id` may be put in its queue: a node whose beat
  is under 180 s old (the database's clock) reports `dir_id` and advertises
  its queue, in this boot. Fails closed: beats that can't be read are no.
  """
  @spec routable?(term()) :: boolean()
  def routable?(dir_id) do
    name(dir_id) != nil and status(dir_id) == {:ok, :advertised}
  end

  @doc """
  How directory `dir_id` stands, from the beats of the last 180 s:
  `:advertised` (`routable?/1`), `:reported` (a live node reports it, as its
  current id or the last one it read, but none advertises its queue) or
  `:none`. `{:error, reason}` when the beats can't be read.
  """
  @spec status(String.t()) :: {:ok, status()} | {:error, term()}
  def status(dir_id) do
    with {:ok, beats} <- Backups.live_beats(Chain.stale_after_s()) do
      {:ok, status_in(beats, dir_id)}
    end
  end

  @doc """
  `status/1` of every directory in `dir_ids`, from one read of the beats.
  """
  @spec statuses([String.t()]) :: {:ok, %{String.t() => status()}} | {:error, term()}
  def statuses(dir_ids) do
    with {:ok, beats} <- Backups.live_beats(Chain.stale_after_s()) do
      {:ok, Map.new(dir_ids, &{&1, status_in(beats, &1)})}
    end
  end

  defp status_in(beats, dir_id) do
    cond do
      Enum.any?(beats, &advertises?(&1, dir_id)) -> :advertised
      Enum.any?(beats, &(dir_id in [&1.dir_id, &1.last_dir_id])) -> :reported
      true -> :none
    end
  end

  # A beat from before #2845's columns, or written by an earlier boot under
  # the same node name (a node from before #2845 doesn't touch them), is no
  # claim.
  defp advertises?(beat, dir_id) do
    beat.dir_id == dir_id and Map.get(beat, :dir_queue) == dir_id and
      Map.get(beat, :dir_queue_boot_id) == beat.boot_id
  end

  @doc """
  Move `job`, which this process is executing, to `queue`: the same row, so
  the same job id, and its attempt is not spent when the caller then returns
  `{:snooze, 0}`. `:gone` when the row is no longer this execution's (it was
  canceled, or rescued and fetched again meanwhile).
  """
  @spec move(Oban.Job.t(), String.t()) :: :ok | :gone
  def move(%Oban.Job{id: id, attempted_at: %DateTime{} = at} = job, queue)
      when is_integer(id) and is_binary(queue) do
    query =
      from(j in Oban.Job,
        where: j.id == ^id and j.state == "executing" and j.attempted_at == ^at
      )

    case Repo.update_all(query, set: [queue: queue]) do
      {1, _} ->
        :telemetry.execute([:kiln_cms, :backups, :dir_queue, :routed], %{count: 1}, %{
          queue: queue,
          from: job.queue,
          worker: job.worker
        })

        :ok

      {0, _} ->
        :gone
    end
  end

  def move(%Oban.Job{}, _queue), do: :gone

  @doc """
  Whether a job this process fetched should be moved to `dir_id`'s queue
  (`move/2`): routing is on, the job is stored, it sits in a queue that is
  not that directory's, and the directory is `routable?/1`.
  """
  @spec route?(Oban.Job.t(), term()) :: boolean()
  def route?(%Oban.Job{id: id, attempted_at: at, queue: queue}, dir_id) do
    is_integer(id) and at != nil and enabled?() and not dir_queue?(queue) and
      routable?(dir_id)
  end

  @doc """
  Jobs of `worker` (its full module name) waiting in a directory queue for at
  least `move_back_after_s/0`, by the database's clock: `%{id, queue,
  dir_id, state, waited_s}`. What the stranded sweeps start from.
  """
  @spec waiting(String.t()) :: [map()]
  def waiting(worker) do
    Repo.all(
      from(j in Oban.Job,
        where:
          j.worker == ^worker and like(j.queue, ^"backup\\_dir\\_%") and
            j.state in @waiting_states and
            j.scheduled_at < fragment("now() - make_interval(secs => ?)", ^@move_back_after_s),
        order_by: j.id,
        select: %{
          id: j.id,
          queue: j.queue,
          state: j.state,
          waited_s: fragment("extract(epoch FROM now() - ?)::float8", j.scheduled_at)
        }
      )
    )
    |> Enum.map(&Map.put(&1, :dir_id, dir_id(&1.queue)))
    |> Enum.reject(&is_nil(&1.dir_id))
  end

  @doc """
  What the stranded sweeps do with a job that has waited `waited_s` in the
  queue of a directory standing at `status`: `:move_back`, `:stranded` or
  `:leave` (see "Jobs left in a queue no node runs").
  """
  @spec verdict(status(), number()) :: :move_back | :stranded | :leave
  def verdict(:reported, waited_s) when waited_s >= @move_back_after_s, do: :move_back
  def verdict(:none, waited_s) when waited_s >= @stranded_after_s, do: :stranded
  def verdict(_status, _waited_s), do: :leave

  @doc """
  Put job `id` back in `backup_steps`, available now, when it still waits in
  `queue`. Inside the lock transaction for a backup step. `:ok` or `:gone`.
  """
  @spec move_back(integer(), String.t()) :: :ok | :gone
  def move_back(id, queue) do
    # Due now by the database's clock, like every time the sweeps compare.
    query =
      from(j in Oban.Job,
        where: j.id == ^id and j.queue == ^queue and j.state in @waiting_states,
        update: [
          set: [queue: "backup_steps", state: "available", scheduled_at: fragment("now()")]
        ]
      )

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> :gone
    end
  end

  ## The heartbeat's part

  @doc "A heartbeat's directory-queue state, before its first tick."
  @spec new_state() :: state()
  def new_state do
    %{advertised: nil, absent_since: nil, queues: %{}, pending: %{}, start_failed: MapSet.new()}
  end

  @doc """
  `new_state/0` with the directory queues already running on this node (a
  heartbeat restarted while Oban kept running), so their pausing is still
  this heartbeat's to do. One found paused is `:held`: nothing says this
  heartbeat paused it, so it is not resumed. Never raises.
  """
  @spec seeded_state() :: state()
  def seeded_state do
    queues =
      for {queue, status} <- control().running(), dir_queue?(queue), into: %{} do
        {queue, if(status == :paused, do: :held, else: :active)}
      end

    %{new_state() | queues: queues}
  catch
    _kind, _reason -> new_state()
  end

  @doc """
  One heartbeat's turn, after a successful beat that reported `dir_id` (nil
  when the read gave none): start that directory's queue (or resume it, when
  this heartbeat paused it), pause any other (at once for another id, after
  180 s without one, and again whenever one it paused runs), and work out
  what the next beat advertises. `now_ms` is monotonic. Returns the new
  state.
  """
  @spec reconcile(state(), String.t() | nil, integer(), String.t()) :: state()
  def reconcile(state, dir_id, now_ms, node) do
    case name(dir_id) do
      nil -> absent(state, now_ms, node)
      queue -> present(state, dir_id, queue, node)
    end
  end

  defp present(state, dir_id, queue, node) do
    others = state.queues |> Map.keys() |> List.delete(queue)
    state = pause_running(%{state | absent_since: nil}, others, node, :changed)

    {state, record, running?} = ensure_running(state, queue, node)

    %{
      state
      | advertised: if(running?, do: dir_id),
        queues: Map.put(state.queues, queue, record)
    }
  end

  # The current queue: what `queues` records for it, and whether it runs
  # (only then is it advertised).
  defp ensure_running(state, queue, node) do
    control = control()

    case {control.check(queue), Map.get(state.queues, queue)} do
      {:running, _record} ->
        {started(state, queue, node), :active, true}

      {:paused, :paused} ->
        :ok = control.resume(queue)
        emit(:resumed, queue, node)
        Logger.info("Backup directory queue #{queue}: resumed on this node")
        recheck(state, queue, node, :paused)

      {:paused, _record} ->
        {state, :held, false}

      {:stopped, _record} ->
        :ok = control.start(queue)
        state = %{state | pending: Map.update(state.pending, queue, 1, &(&1 + 1))}
        recheck(state, queue, node, :active)
    end
  end

  # Oban starts, pauses and resumes a queue through its notifier, so the
  # answer may only show on the next tick; the advertisement waits for it.
  # `waiting` is what to record until it does: a resume not taken yet is
  # still this heartbeat's pause.
  defp recheck(state, queue, node, waiting) do
    case control().check(queue) do
      :running -> {started(state, queue, node), :active, true}
      _other -> {start_not_taken(state, queue, node), waiting, false}
    end
  end

  defp started(%{pending: pending} = state, queue, node) when is_map_key(pending, queue) do
    emit(:started, queue, node)
    Logger.info("Backup directory queue #{queue}: running on this node")

    %{
      state
      | pending: Map.delete(pending, queue),
        start_failed: MapSet.delete(state.start_failed, queue)
    }
  end

  defp started(state, _queue, _node), do: state

  defp start_not_taken(state, queue, node) do
    tries = Map.get(state.pending, queue, 0)

    if tries >= @start_ticks and not MapSet.member?(state.start_failed, queue) do
      emit(:start_failed, queue, node)

      Logger.warning(
        "Backup directory queue #{queue} hasn't started on this node after #{tries} tries " <>
          "(is Oban's notifier working?). This node doesn't advertise it, so jobs for its " <>
          "backup directory stay in backup_steps and snooze until a node with the " <>
          "directory picks them up."
      )

      %{state | start_failed: MapSet.put(state.start_failed, queue)}
    else
      state
    end
  end

  # No id: inside the window only the queues this heartbeat already paused
  # are checked (and paused again if they run); past it, every one.
  defp absent(state, now_ms, node) do
    since = state.absent_since || now_ms
    state = %{state | absent_since: since, advertised: nil}

    queues =
      if now_ms - since >= Chain.stale_after_s() * 1000,
        do: Map.keys(state.queues),
        else: for({queue, :paused} <- state.queues, do: queue)

    pause_running(state, queues, node, :gone)
  end

  # Each of `queues` that runs is paused, whatever was recorded: a pause
  # that didn't take, or a queue resumed by something else since. One paused
  # by something else is `:held`; one that no longer runs here is forgotten.
  defp pause_running(state, queues, node, reason) do
    Enum.reduce(queues, state, fn queue, acc ->
      case {control().check(queue), Map.get(acc.queues, queue)} do
        {:running, _record} -> pause(acc, queue, node, reason)
        {:paused, :paused} -> acc
        {:paused, _record} -> %{acc | queues: Map.put(acc.queues, queue, :held)}
        {:stopped, _record} -> %{acc | queues: Map.delete(acc.queues, queue)}
      end
    end)
  end

  defp pause(state, queue, node, reason) do
    :ok = control().pause(queue)
    emit(:paused, queue, node, %{reason: reason})

    Logger.info(
      "Backup directory queue #{queue}: paused on this node, " <>
        if(reason == :changed,
          do: "whose backup directory now has another id",
          else: "whose backup directory has given no id for #{Chain.stale_after_s()} s"
        )
    )

    %{state | queues: Map.put(state.queues, queue, :paused)}
  end

  defp emit(event, queue, node, metadata \\ %{}) do
    :telemetry.execute(
      [:kiln_cms, :backups, :dir_queue, event],
      %{count: 1},
      Map.merge(%{queue: queue, node: node}, metadata)
    )
  end

  @doc false
  # `config :kiln_cms, KilnCMS.Backups, dir_queue_control:` (tests only).
  @spec control() :: module()
  def control, do: Keyword.get(backups_env(), :dir_queue_control, __MODULE__.ObanControl)

  defp backups_env, do: Application.get_env(:kiln_cms, KilnCMS.Backups, [])

  defmodule Control do
    @moduledoc false
    # How `DirQueues` drives this node's Oban queues.

    @callback check(String.t()) :: :running | :paused | :stopped
    @callback start(String.t()) :: :ok
    @callback pause(String.t()) :: :ok
    @callback resume(String.t()) :: :ok
    @callback running() :: [{String.t(), :running | :paused}]
  end

  defmodule ObanControl do
    @moduledoc false
    # The real one: this node's Oban, `local_only`. `check/1` reads the local
    # queue registry (one call to the queue's producer, which exits when it
    # is busy or gone: no answer is "stopped"); the others are signals
    # through Oban's notifier, which may not arrive (`DirQueues.reconcile/4`
    # checks again on the next tick).
    @behaviour KilnCMS.Backups.DirQueues.Control

    @impl true
    def check(queue) do
      case Oban.check_queue(queue: queue) do
        %{paused: true} -> :paused
        %{} -> :running
        nil -> :stopped
      end
    catch
      :exit, _reason -> :stopped
    end

    @impl true
    def start(queue) do
      Oban.start_queue(queue: queue, limit: 1, local_only: true)
      :ok
    end

    # Both raise `ArgumentError` when the queue doesn't run here: then there
    # is nothing to pause or resume.
    @impl true
    def pause(queue) do
      Oban.pause_queue(queue: queue, local_only: true)
      :ok
    rescue
      ArgumentError -> :ok
    end

    @impl true
    def resume(queue) do
      Oban.resume_queue(queue: queue, local_only: true)
      :ok
    rescue
      ArgumentError -> :ok
    end

    # Only when the heartbeat starts (`DirQueues.seeded_state/0`), never in a
    # tick: it asks every queue's producer.
    @impl true
    def running do
      for %{queue: queue} = check <- Oban.check_all_queues(),
          do: {queue, if(check[:paused], do: :paused, else: :running)}
    end
  end
end
