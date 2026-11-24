defmodule KilnCMS.Collab.Crdt.DocServer do
  @moduledoc """
  The authoritative Yjs document for one collaborative editing session
  (`KilnCMS.Collab.Crdt`). Holds a `Yex.Doc`, applies binary updates from
  clients (CRDT merge — order-independent, conflict-free), and serves the full
  state to each joiner so late arrivals converge immediately.

  Attached clients (channel processes) are monitored; when the last one
  leaves, the server lingers for an idle grace period — an editor refresh
  reattaches to the same live doc — then stops.

  **Durability:** the doc state survives restarts. It is lazy-restored from
  `collab_doc_states` on first use, checkpointed while dirty, and persisted on
  shutdown (exits are trapped so idle stops *and* supervisor shutdowns during
  a deploy both flush). A hard kill loses at most one checkpoint interval of
  CRDT history — and even then the *content* is safe: the editor's autosave
  path persists converged HTML independently. Rows unused for 30 days are
  pruned opportunistically. Persistence is config-gated
  (`config :kiln_cms, KilnCMS.Collab.Crdt, persist?: false` — off in tests).

  A stored state that will not decode is not applied and not overwritten: the
  row is moved aside under `corrupt:<key>:<unix_ms>:<random>` (pruned with
  the rest after 30 days) and logged at error, and the room starts empty. The
  record's blocks are untouched — an empty fragment never materializes — and
  the first client to join seeds the room from the record (#2756).
  """
  use GenServer, restart: :transient

  alias KilnCMS.Repo

  require Logger

  # How long an abandoned doc lingers before shutdown (covers reloads).
  @idle_shutdown :timer.minutes(10)
  # How often a dirty doc is flushed to the database.
  @checkpoint_after :timer.seconds(15)
  # Doc states untouched this long are pruned on the next restore.
  @prune_after_days 30

  # Started as `{doc_key, org_id}`: the key identifies the doc (and its stored
  # state row), the org is the tenant the joining channel authorized it under,
  # carried so the checkpoint writes back to the right site (#655).
  def start_link({doc_key, _org_id} = arg) do
    GenServer.start_link(__MODULE__, arg, name: via(doc_key))
  end

  defp via(doc_key), do: {:via, Registry, {KilnCMS.Collab.Crdt.Registry, doc_key}}

  @doc """
  Attach the calling process (a channel) as a client. Returns
  `{full_state_update, client_count}` — the count includes the caller, so `1`
  means "you're first" (the client uses that to decide whether to seed the
  doc from the stored HTML; a restored doc already has content, so no
  double-seeding).
  """
  @spec attach(pid()) :: {binary(), pos_integer()}
  def attach(server), do: GenServer.call(server, :attach)

  @doc "Apply one binary Yjs update from a client."
  @spec apply_update(pid(), binary()) :: :ok | {:error, term()}
  def apply_update(server, update) when is_binary(update),
    do: GenServer.call(server, {:apply_update, update})

  @doc """
  `record`'s blocks with this room's converged prose merged in, without writing.

  Runs inside the server so the `Yex.Doc` is read by the process that owns it.
  """
  @spec converged_blocks(GenServer.server(), struct()) :: [map()]
  def converged_blocks(server, record),
    do: GenServer.call(server, {:converged_blocks, record})

  @doc "The whole doc encoded as a single Yjs update."
  @spec state_update(pid()) :: binary()
  def state_update(server), do: GenServer.call(server, :state_update)

  @impl true
  def init({doc_key, org_id}) do
    # So terminate/2 runs (and persists) on supervisor shutdown too.
    Process.flag(:trap_exit, true)

    state = %{
      doc: Yex.Doc.new(),
      clients: MapSet.new(),
      doc_key: doc_key,
      org_id: org_id,
      # Lazy restore on first use — not in init — so a supervised start never
      # blocks on the database (and tests own the connection by then).
      restored?: not persist?(),
      dirty?: false,
      # Updates since the last server-side materialization (spike §8).
      materialize_dirty?: false
    }

    {:ok, state, @idle_shutdown}
  end

  @impl true
  def handle_call(:attach, {pid, _tag}, state) do
    state = maybe_restore(state)
    Process.monitor(pid)
    clients = MapSet.put(state.clients, pid)
    {:ok, full} = Yex.encode_state_as_update(state.doc)
    {:reply, {full, MapSet.size(clients)}, %{state | clients: clients}, @idle_shutdown}
  end

  def handle_call({:apply_update, update}, _from, state) do
    state = maybe_restore(state)

    case Yex.apply_update(state.doc, update) do
      :ok -> {:reply, :ok, mark_dirty(state), @idle_shutdown}
      {:error, reason} -> {:reply, {:error, reason}, state, @idle_shutdown}
    end
  end

  def handle_call({:converged_blocks, record}, _from, state) do
    state = maybe_restore(state)

    {:reply, KilnCMS.Collab.Crdt.Checkpoint.materialize_blocks(record, state.doc), state,
     @idle_shutdown}
  end

  def handle_call(:state_update, _from, state) do
    state = maybe_restore(state)
    {:ok, full} = Yex.encode_state_as_update(state.doc)
    {:reply, full, state, @idle_shutdown}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | clients: MapSet.delete(state.clients, pid)}

    # The last editor is gone — the client persister can no longer save, so
    # the server materializes the converged text into the record itself
    # (spike §8). Never runs while editors are present: they own persistence.
    state =
      if MapSet.size(state.clients) == 0,
        do: materialize(state),
        else: state

    {:noreply, state, @idle_shutdown}
  end

  def handle_info(:checkpoint, state) do
    {:noreply, persist(state), @idle_shutdown}
  end

  # Fires only after @idle_shutdown with no messages at all; stop when nobody
  # is attached (a lone idle client's heartbeats don't reach us, but its
  # channel process is alive — so presence, not traffic, is the signal).
  def handle_info(:timeout, %{clients: clients} = state) do
    if MapSet.size(clients) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state, @idle_shutdown}
    end
  end

  # Trapped exits from linked processes (none expected — clients are
  # monitored, not linked) — treat like any other noise.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state, @idle_shutdown}

  @impl true
  def terminate(_reason, state) do
    state = persist(state)
    # A shutdown mid-session (deploy) also flushes prose to the record — the
    # attached clients' LiveViews are going down with this node anyway.
    materialize(state)
    :ok
  end

  # ── durability ─────────────────────────────────────────────────────────────

  defp persist?,
    do: :kiln_cms |> Application.get_env(KilnCMS.Collab.Crdt, []) |> Keyword.get(:persist?, true)

  # Every update is pending for both the database checkpoint and the record
  # write-back; the two flags are cleared by different events, so each is set
  # on its own. Folding them together let a rejoin inside the checkpoint
  # window skip the write-back (#2756).
  defp mark_dirty(state), do: state |> mark_materialize_dirty() |> mark_persist_dirty()

  defp mark_materialize_dirty(state) do
    if materialize?(), do: %{state | materialize_dirty?: true}, else: state
  end

  # Schedule one flush per dirty transition; further updates before the flush
  # ride along with it. With persistence off nothing is ever dirty, so neither
  # checkpoints nor the terminate flush touch the database.
  defp mark_persist_dirty(%{dirty?: true} = state), do: state

  defp mark_persist_dirty(state) do
    if persist?() do
      Process.send_after(self(), :checkpoint, @checkpoint_after)
      %{state | dirty?: true}
    else
      state
    end
  end

  defp persist(%{dirty?: false} = state), do: state

  defp persist(state) do
    {:ok, full} = Yex.encode_state_as_update(state.doc)

    Repo.query!(
      """
      INSERT INTO collab_doc_states (doc_key, state, updated_at)
      VALUES ($1, $2, now())
      ON CONFLICT (doc_key) DO UPDATE SET state = EXCLUDED.state, updated_at = now()
      """,
      [state.doc_key, full]
    )

    %{state | dirty?: false}
  end

  defp materialize? do
    :kiln_cms
    |> Application.get_env(KilnCMS.Collab.Crdt, [])
    |> Keyword.get(:materialize?, true)
  end

  defp materialize(%{materialize_dirty?: false} = state), do: state

  defp materialize(state) do
    KilnCMS.Collab.Crdt.Checkpoint.write_back(state.doc_key, state.doc, state.org_id)
    %{state | materialize_dirty?: false}
  end

  defp maybe_restore(%{restored?: true} = state), do: state

  defp maybe_restore(state) do
    # Opportunistic GC: docs untouched for a month are dead sessions.
    Repo.query!(
      "DELETE FROM collab_doc_states WHERE updated_at < now() - interval '#{@prune_after_days} days'"
    )

    state =
      case Repo.query!("SELECT state FROM collab_doc_states WHERE doc_key = $1", [state.doc_key]) do
        %{rows: [[stored]]} -> restore(state, stored)
        %{rows: []} -> state
      end

    %{state | restored?: true}
  end

  # Applied to a fresh doc and swapped in only on success, so a half-applied
  # update can never become the room. A failure leaves the (still empty) doc in
  # place and moves the bytes aside, so the next persist cannot overwrite them.
  #
  # When the quarantine finds the row already changed (`:gone`), another server
  # for the same key wrote it in between, most likely a valid checkpoint. That
  # row is read and restored once more, rather than starting this room empty
  # and letting its next checkpoint overwrite the other server's state.
  defp restore(state, stored) do
    case restore_doc(state.doc_key, stored) do
      {:ok, doc} -> %{state | doc: doc}
      :empty -> state
    end
  end

  @doc false
  # The doc `stored` decodes to, or `:empty` (after quarantining it) when it
  # won't decode. Public for the race test: the read and the quarantine can't
  # be interleaved with another server's write from outside.
  @spec restore_doc(String.t(), binary(), non_neg_integer()) :: {:ok, term()} | :empty
  def restore_doc(doc_key, stored, retries \\ 1) do
    doc = Yex.Doc.new()

    case safe_apply(doc, stored) do
      :ok ->
        {:ok, doc}

      {:error, reason} ->
        outcome = quarantine(doc_key, stored)
        log_unrestorable(doc_key, stored, reason, outcome)

        case {outcome, retries > 0 && current_state(doc_key)} do
          {:gone, replaced} when is_binary(replaced) and replaced != stored ->
            restore_doc(doc_key, replaced, retries - 1)

          _ ->
            :empty
        end
    end
  end

  defp current_state(doc_key) do
    case Repo.query!("SELECT state FROM collab_doc_states WHERE doc_key = $1", [doc_key]) do
      %{rows: [[stored]]} -> stored
      %{rows: []} -> nil
    end
  end

  # The NIF reports a bad encoding as `{:error, _}`, but a panic raises; either
  # way the room must come up rather than crash on every attach (the server is
  # `:transient`, so repeated crashes would take the supervisor down with it).
  defp safe_apply(doc, bytes) do
    case Yex.apply_update(doc, bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc false
  # Moves the stored row aside under a key nothing resolves as a document.
  # Matching on the bytes that were read means a row another server already
  # replaced (a valid checkpoint) or quarantined is left alone: `:gone`. A
  # database failure raises, as every other query here does.
  @spec quarantine(String.t(), binary()) :: {:quarantined, String.t()} | :gone
  def quarantine(doc_key, stored) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    quarantine_key = "corrupt:#{doc_key}:#{System.system_time(:millisecond)}:#{suffix}"

    case Repo.query!(
           """
           UPDATE collab_doc_states SET doc_key = $2, updated_at = now()
           WHERE doc_key = $1 AND state = $3
           """,
           [doc_key, quarantine_key, stored]
         ) do
      %{num_rows: 1} -> {:quarantined, quarantine_key}
      %{num_rows: 0} -> :gone
    end
  end

  defp log_unrestorable(doc_key, stored, reason, {:quarantined, quarantine_key}) do
    Logger.error(
      "Collab doc state for #{doc_key} is corrupt and was not restored " <>
        "(#{byte_size(stored)} bytes: #{inspect(reason)}). The bytes were moved to " <>
        "#{quarantine_key}. The room starts empty, the record's blocks are untouched, " <>
        "and the first client to join seeds the room from the record."
    )
  end

  defp log_unrestorable(doc_key, stored, reason, :gone) do
    Logger.warning(
      "Collab doc state for #{doc_key} is corrupt and was not restored " <>
        "(#{byte_size(stored)} bytes: #{inspect(reason)}); another server already " <>
        "replaced or quarantined the row, so the row as it is now is restored instead, " <>
        "if there is one. Otherwise the room starts empty, the record's blocks are " <>
        "untouched, and the first client to join seeds the room from the record."
    )
  end
end
