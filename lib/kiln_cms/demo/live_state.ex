defmodule KilnCMS.Demo.LiveState do
  @moduledoc """
  Everything a running node holds *outside* the database, brought to a stop
  around a demo restore. See `docs/demo-mode.md`.

  The restore replaces the database in one transaction. The danger is not the
  requests that fail while it runs — those are visitors seeing an error for a
  few seconds on a demo — but state from *before* the restore being written
  *into* the restored database afterwards. Postgres makes that easy: a write
  that blocked on the restore's locks re-resolves the table name when the lock
  is released and lands in the freshly restored table. So each holder of
  pre-reset state is stopped before the restore begins:

    * **Collaborative documents.** A `KilnCMS.Collab.DocServer` keeps a
      document's CRDT state in memory and writes it back when it stops. One
      opened before the reset and stopped after it would write the visitor's
      edits over the golden content. They are stopped *before* (their
      write-back lands in the database about to be replaced), and none may
      start until the reset ends (`KilnCMS.Collab.Crdt.ensure_server/2`
      refuses; the editor falls back to solo editing).
    * **LiveView sessions.** An open editor holds unsaved form state and
      autosaves it. Every user's sockets are evicted
      (`KilnCMS.Accounts.SessionEviction`), and while the reset runs a
      reconnect is refused at mount (`KilnCMSWeb.LiveUserAuth`) and sent to
      sign-in — so no editor exists to autosave during the restore. They are
      evicted again afterwards, when the restored `tokens` table is empty and
      reconnecting means signing in.
    * **Oban.** Queues are paused cluster-wide and running jobs get a grace
      period to finish, so a job that read the old data doesn't write its
      result into the new. Jobs still running after the grace period are
      left alone — killing one mid-write is worse than a stale write the next
      reset removes — and reported.

  And one thing is cleared *after*, because it would otherwise outlive the
  reset it was meant to be bounded by:

    * **Per-account sign-in throttles** (`KilnCMS.Accounts.AccountThrottle`).
      The demo's shared account is one identifier for every visitor, so its
      failure budget is shared too, and anyone can spend it on purpose. The
      reset is the documented "known-good" moment, so it forgets them. Per-IP
      buckets are left: they are about the visitor, not the data, and expire on
      their own.

  The delivery caches are flushed after the restore by `KilnCMS.Demo` itself.

  Node-local steps run on every connected node. A demo is normally a single
  node; this is so a second one doesn't quietly keep its documents open.
  """

  require Logger

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Repo

  @resetting_key {KilnCMS.Demo, :resetting}
  @poll_ms 250

  @type quiesced :: %{
          documents_closed: non_neg_integer(),
          queues_paused?: boolean(),
          jobs_still_running: non_neg_integer(),
          users: MapSet.t(String.t())
        }

  @doc """
  Whether a reset is in progress on this node. Read on every signed-in
  LiveView mount and every collab document start, so it is a
  `:persistent_term` lookup rather than a message to anything.
  """
  @spec resetting?() :: boolean()
  def resetting?, do: :persistent_term.get(@resetting_key, false)

  @doc """
  Stops pre-reset state from reaching the restored database. Returns what it
  did, and the user ids whose sockets `after_restore/1` evicts again.

  `:job_id` is the reset's own Oban job, excluded from the drain — it is the
  one job guaranteed to be running. `:grace_ms` bounds the drain (30s).
  """
  @spec quiesce(keyword()) :: quiesced()
  def quiesce(opts \\ []) do
    documents_closed = on_every_node(:begin_local)
    queues_paused? = pause_queues()
    still_running = drain(opts[:job_id], Keyword.get(opts, :grace_ms, 30_000))

    # Last, immediately before the restore: a socket evicted earlier would have
    # reconnected during the drain.
    users = MapSet.new(user_ids())
    Enum.each(users, &SessionEviction.evict(&1, :demo_reset))

    %{
      documents_closed: documents_closed,
      queues_paused?: queues_paused?,
      jobs_still_running: still_running,
      users: users
    }
  end

  @doc """
  After the restore has committed: evict every socket again — the pre-reset
  users and the restored ones — and close any document that slipped open.

  Returns how many distinct users were evicted across both passes.
  """
  @spec after_restore(MapSet.t(String.t())) :: non_neg_integer()
  def after_restore(users_before) do
    users = MapSet.union(users_before, MapSet.new(user_ids()))
    Enum.each(users, &SessionEviction.evict(&1, :demo_reset))
    on_every_node(:close_local_documents)
    MapSet.size(users)
  end

  @doc """
  Ends the reset: lifts the mount and document gates, forgets the per-account
  throttles, and resumes the queues. Runs whether or not the restore
  succeeded.
  """
  @spec resume() :: :ok
  def resume do
    on_every_node(:end_local)

    try do
      Oban.resume_all_queues(Oban)
    rescue
      error -> Logger.warning("Demo reset couldn't resume Oban queues: #{inspect(error)}")
    catch
      :exit, reason ->
        Logger.warning("Demo reset couldn't resume Oban queues: #{inspect(reason)}")
    end

    :ok
  end

  # -- node-local steps, run through `on_every_node/1` -------------------------

  @doc false
  @spec begin_local() :: non_neg_integer()
  def begin_local do
    :persistent_term.put(@resetting_key, true)
    close_local_documents()
  end

  @doc false
  @spec end_local() :: non_neg_integer()
  def end_local do
    :persistent_term.erase(@resetting_key)
    AccountThrottle.forget_all()
    KilnCMS.Cache.Hosts.clear()
    0
  end

  @doc false
  # `terminate_child`, not a kill: `DocServer` traps exits so its `terminate/2`
  # persists — into the database that is about to be replaced, which is the
  # point of doing this first.
  @spec close_local_documents() :: non_neg_integer()
  def close_local_documents do
    supervisor = KilnCMS.Collab.Crdt.DocSupervisor

    case Process.whereis(supervisor) do
      nil ->
        0

      _pid ->
        supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.count(fn {_, pid, _, _} ->
          is_pid(pid) and DynamicSupervisor.terminate_child(supervisor, pid) == :ok
        end)
    end
  end

  # Sums the integer results from each node. A node that fails to answer is
  # logged, not raised: it is the reset's job to finish and resume the queues.
  defp on_every_node(fun) do
    [node() | Node.list()]
    |> :erpc.multicall(__MODULE__, fun, [], 15_000)
    |> Enum.reduce(0, fn
      {:ok, count}, acc when is_integer(count) ->
        acc + count

      other, acc ->
        Logger.warning("Demo reset step #{fun} failed on a node: #{inspect(other)}")
        acc
    end)
  end

  defp pause_queues do
    Oban.pause_all_queues(Oban) == :ok
  rescue
    error ->
      Logger.warning("Demo reset couldn't pause Oban queues: #{inspect(error)}")
      false
  catch
    :exit, reason ->
      Logger.warning("Demo reset couldn't pause Oban queues: #{inspect(reason)}")
      false
  end

  # Local queues only: `check_all_queues/0` reports this node's producers,
  # which is the whole demo on the single node it normally is.
  defp drain(own_job_id, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    do_drain(own_job_id, deadline)
  end

  defp do_drain(own_job_id, deadline) do
    running = running_jobs(own_job_id)

    cond do
      running == 0 ->
        0

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("Demo reset proceeding with #{running} job(s) still running")
        running

      true ->
        Process.sleep(@poll_ms)
        do_drain(own_job_id, deadline)
    end
  end

  defp running_jobs(own_job_id) do
    Oban.check_all_queues(Oban)
    |> Enum.flat_map(& &1.running)
    |> Enum.count(&(&1 != own_job_id))
  rescue
    _error -> 0
  catch
    :exit, _reason -> 0
  end

  # Text ids straight from the table: this runs on both sides of the restore,
  # and the users on each side are different rows. A list, turned into a
  # MapSet once by the caller — see `KilnCMS.Demo.Blobs.referenced_keys/0` for
  # why no branch here builds one.
  defp user_ids do
    case Repo.query("SELECT id::text FROM users", []) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [id] -> id end)
      {:error, _} -> []
    end
  rescue
    _error -> []
  end
end
