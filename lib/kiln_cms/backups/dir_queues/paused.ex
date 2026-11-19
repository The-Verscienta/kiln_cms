defmodule KilnCMS.Backups.DirQueues.Paused do
  @moduledoc """
  The backup-directory queues this node's heartbeat paused (#3095), in a
  node-local ETS table that outlives the heartbeat process.

  `KilnCMS.Backups.DirQueues.seeded_state/0` counts a queue it finds paused
  when the heartbeat starts as this heartbeat's own pause only when it is
  here, so a heartbeat that crashed after pausing its directory's queue
  still resumes it when the id comes back. Any other paused queue stays
  `:held` (an operator's, the demo reset's) and is never resumed.

  This process only owns the table; `DirQueues` reads and writes it. The
  table goes with the node, as Oban's runtime queues do. Started before the
  heartbeat in `KilnCMS.Application`. Every function here treats a missing
  table as empty and never raises.
  """
  use GenServer

  @table :kiln_backup_dir_queues_paused

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Record `queue` as paused by this node's heartbeat."
  @spec put(String.t()) :: :ok
  def put(queue) do
    :ets.insert(@table, {queue})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forget `queue`: resumed, found running, held by someone else, or gone."
  @spec delete(String.t()) :: :ok
  def delete(queue) do
    :ets.delete(@table, queue)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Whether this node's heartbeat paused `queue` and hasn't resumed it."
  @spec member?(String.t()) :: boolean()
  def member?(queue) do
    :ets.member(@table, queue)
  rescue
    ArgumentError -> false
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table])
    {:ok, nil}
  end
end
