defmodule KilnCMS.Search.Warmup do
  @moduledoc """
  Holds a new node out of rotation until search can answer at speed (#2166).

  The embedding and reranker servings start after the endpoint
  (`KilnCMS.Application`). A query that reached a node in the seconds after
  it came up waited for the serving to finish compiling, and then for the
  first nearest-neighbour scans and first statements of its connections:
  27.6 s for one production search around a deploy. `/live` already answered
  200 by then, so the platform swapped traffic onto the node.

  This child starts after the servings. It runs one real sweep — the query
  embedding, every content section's legs, the reranker when one is on —
  and then opens a latch that `ready?/0` reads. Until it opens, `/live`,
  `/up` and `/ready` answer 503 (`KilnCMSWeb.Plugs.Liveness`,
  `KilnCMSWeb.HealthController`). The latch never closes again. That makes
  it a startup gate, not a liveness condition: it cannot restart a running
  node, which is why `/live` may read it (#816).

  An install with semantic search and reranking both off has nothing to
  warm, so the latch opens as the child starts. A warm-up that fails, or
  outlasts `timeout/0`, opens it anyway with a warning: a node serving
  keyword-only results beats one the healthcheck restarts in a loop. A slow
  first search is then bounded by `KilnCMS.Search.query_budget/0`.
  """
  use GenServer, restart: :temporary

  require Logger

  @key {__MODULE__, :ready}

  # Something to search for. The sweep's results are discarded; what matters
  # is that every leg runs once.
  @query "warm up"

  @doc "Whether the warm-up has finished (or given up). Never goes back to false."
  @spec ready?() :: boolean()
  def ready?, do: :persistent_term.get(@key, false)

  @doc """
  Milliseconds the warm-up may take before the latch opens anyway. Default
  90 000. The image's healthcheck marks a container unhealthy after its
  60 s start period and three failed 30 s probes, so this must stay under
  150 s.
  """
  @spec timeout() :: pos_integer()
  def timeout do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:timeout, 90_000)
  end

  @doc false
  # For tests of the gates that read `ready?/0`: the latch is node-global.
  @spec put_ready(boolean()) :: :ok
  def put_ready(ready?) when is_boolean(ready?), do: :persistent_term.put(@key, ready?)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if warm?() do
      {:ok, nil, {:continue, :warm}}
    else
      open()
      :ignore
    end
  end

  @impl true
  def handle_continue(:warm, state) do
    started = System.monotonic_time(:millisecond)
    task = Task.Supervisor.async_nolink(KilnCMS.TaskSupervisor, &warm/0)

    case Task.yield(task, timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        Logger.info("search warm-up done in #{System.monotonic_time(:millisecond) - started} ms")

      {:ok, {:error, reason}} ->
        Logger.warning("search warm-up failed, serving anyway: #{inspect(reason)}")

      {:exit, reason} ->
        Logger.warning("search warm-up crashed, serving anyway: #{inspect(reason)}")

      nil ->
        Logger.warning("search warm-up passed #{timeout()} ms, serving anyway")
    end

    open()
    {:stop, :normal, state}
  end

  # `KilnCMS.Ask.rerank?/0` folds the global switch in: true wherever any
  # scope reranks, which is where `KilnCMS.Application` loads the reranker.
  defp warm?, do: KilnCMS.Search.semantic?() or KilnCMS.Ask.rerank?()

  # One anonymous sweep of the default organization's published content —
  # exactly what `GET /api/search` runs, so nothing needs a grant, and with no
  # budget, so a cold leg is waited for rather than skipped. The reranker is
  # asked directly as well: the sweep only reaches it when the query matched.
  defp warm do
    with {:ok, _vector} <- warm_embedding() do
      KilnCMS.Search.global(@query,
        authorize?: true,
        tenant: KilnCMS.Accounts.default_org_id(),
        sections: KilnCMS.Search.content_sections(),
        rerank: KilnCMS.Ask.rerank?(),
        budget: :infinity
      )

      warm_reranker()
    end
  rescue
    error -> {:error, error}
  end

  defp warm_embedding do
    if KilnCMS.Search.semantic?(), do: KilnCMS.Search.embed_query(@query), else: {:ok, nil}
  end

  defp warm_reranker do
    if KilnCMS.Ask.rerank?() do
      case KilnCMS.Search.reranker().scores(@query, [@query]) do
        {:ok, _scores} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp open, do: put_ready(true)
end
