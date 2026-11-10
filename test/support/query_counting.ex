defmodule KilnCMS.Test.QueryCounting do
  @moduledoc """
  The repo queries one test causes, for tests that count them (#2504).

  A telemetry handler is global: attached plainly, it counts every query in the
  VM, and a sync test module is not enough to make that this test's cost
  alone. A process an earlier measurement left running still queries — a
  LiveView's idle-session re-check reads its token row — and a cache bust
  still in the `KilnCMS.Cache.ClusterBust` mailbox can drop a key a warm-up
  cached, so the next measurement pays to fill it again. Both showed up on CI
  as a count off by one (72 vs 73, 69 vs 68).

  So `queries/1` keeps only the queries made on the calling test's behalf (by
  the test process, or by a process that names it in its `$callers`: a
  LiveView it mounted, a `Task` either started), and first waits for every
  bust already sent. `page_queries/2` measures one LiveView page load and stops
  the view, so it cannot query during the next measurement.
  `assert_same_queries/3` compares two measurements by total and per table,
  and names the tables that moved when they differ.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest

  @endpoint KilnCMSWeb.Endpoint

  @typedoc "One repo query: its source table (nil for raw SQL), SQL and bound parameters."
  @type query :: %{source: String.t() | nil, sql: String.t(), params: list()}

  @doc """
  Whether the calling process is working on `test`'s behalf: it is `test`, or
  names it in its `$callers`. For a telemetry handler, which runs in the
  process that made the query.
  """
  @spec on_behalf_of?(pid()) :: boolean()
  def on_behalf_of?(test), do: test in [self() | Process.get(:"$callers", [])]

  @doc """
  `fun`'s result and the queries made on this test's behalf while it ran, in
  the order they were made.

  Waits first for the busts already sent (`settle_busts/0`).
  """
  @spec queries((-> result)) :: {result, [query()]} when result: term()
  def queries(fun) do
    settle_busts()

    handler = "query-counting-#{System.unique_integer([:positive])}"
    # Not stopped afterwards: a handler already running in another process
    # when the detach lands would crash that process on a stopped Agent. It is
    # linked to the test and goes with it.
    {:ok, agent} = Agent.start_link(fn -> [] end)

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      &__MODULE__.handle_query/4,
      {self(), agent}
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, Agent.get(agent, &Enum.reverse/1)}
  end

  @doc """
  Returns once `KilnCMS.Cache.ClusterBust` has handled every bust sent before
  the call: a `:sys` call is answered after every message ahead of it.

  A writer deletes its keys locally and then broadcasts, and its own node's
  subscriber deletes them again when the broadcast arrives. Call this between a
  write and the read that warms a cache, or that second delete can land after
  the warm-up and make the measured read fill the cache again.
  """
  @spec settle_busts() :: :ok
  def settle_busts do
    _ = :sys.get_state(KilnCMS.Cache.ClusterBust)
    :ok
  end

  @doc false
  def handle_query(_event, _measurements, meta, {test, agent}) do
    if on_behalf_of?(test) do
      query = %{source: meta[:source], sql: meta[:query], params: meta[:params]}
      Agent.update(agent, &[query | &1])
    end
  end

  @doc """
  The queries one LiveView page load at `path` makes: the mount and a render.
  The view is stopped once measured.
  """
  @spec page_queries(Plug.Conn.t(), String.t()) :: [query()]
  def page_queries(conn, path) do
    {lv, queries} =
      queries(fn ->
        {:ok, lv, _html} = live(conn, path)
        render(lv)
        lv
      end)

    GenServer.stop(lv.pid)
    queries
  end

  @doc "How many of `queries` read or wrote each source table."
  @spec by_source([query()]) :: %{(String.t() | nil) => pos_integer()}
  def by_source(queries), do: Enum.frequencies_by(queries, & &1.source)

  @doc """
  The tables `left` queried more (positive) or less (negative) often than
  `right`, leaving out the ones they agree on.
  """
  @spec source_diff([query()], [query()]) :: [{String.t() | nil, integer()}]
  def source_diff(left, right) do
    {l, r} = {by_source(left), by_source(right)}

    (Map.keys(l) ++ Map.keys(r))
    |> Enum.uniq()
    |> Enum.map(&{&1, Map.get(l, &1, 0) - Map.get(r, &1, 0)})
    |> Enum.reject(fn {_source, delta} -> delta == 0 end)
  end

  @doc """
  Asserts two measurements made the same number of queries, and the same
  number of each table. `label` names the subtraction the failure message
  prints, e.g. `"30 rows minus 3 rows"`.
  """
  @spec assert_same_queries([query()], [query()], String.t()) :: true
  def assert_same_queries(left, right, label \\ "left minus right") do
    assert length(left) == length(right),
           "query count moved (#{length(left)} vs #{length(right)}); per table, #{label}: " <>
             inspect(source_diff(left, right))

    assert by_source(left) == by_source(right)
  end
end
