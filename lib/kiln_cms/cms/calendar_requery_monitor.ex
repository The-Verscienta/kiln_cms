defmodule KilnCMS.CMS.CalendarRequeryMonitor do
  @moduledoc """
  Periodic, aggregated log of how well `KilnCMSWeb.CalendarLive` is coalescing
  `:calendar_changed` bursts (#1336) — the one signal that answers whether the
  mailbox drain holds under real production write bursts.

  ## Why this exists rather than a metric

  `KilnCMSWeb.Telemetry.metrics/0` already declares
  `summary("kiln_cms.calendar.requery.messages", …)`. In production that
  declaration reaches **nobody**: LiveDashboard is compiled out with
  `dev_routes`, the reporter child in `KilnCMSWeb.Telemetry.init/1` is
  commented out, and no `telemetry_metrics_prometheus`/`_statsd` dependency
  exists — so `:telemetry.execute/3` dispatches to an empty handler list. A
  `Telemetry.Metrics` entry is a declaration of intent; on its own it is not
  instrumentation. That mistake is what got #678 withdrawn after its threat-model
  note claimed a counter "can be alerted on" when it was visible nowhere.

  So this attaches a real handler and writes to `Logger`, which reaches stdout
  and therefore the deployment's log viewer today. Settling the reporter
  question properly is tracked separately.

  ## What it logs

  One line per window (default one minute) **only when a calendar actually
  re-queried** — an idle deployment is silent. Per org:

      calendar re-query coalescing, last 60s: org=<uuid> re-queries=412
        messages=498 mean=1.21 max=4

  `mean` is the number the question turns on. `handle_info/2` drains every
  `:calendar_changed` already waiting before it re-queries, so:

    * **mean well above 1** under a burst — the drain is doing its job; each
      re-query answered several writes.
    * **mean pinned near 1 while `re-queries` is large** — the drain is being
      defeated: it sees a mailbox holding one message, re-queries, and the next
      write arrives immediately after. That is #1336's failure mode, and it is
      what a bulk import would produce if the coalescing is racing the sender
      rather than waiting it out.

  A lone editorial change also produces `mean = 1.0`, so the mean alone means
  nothing — it is only evidence when `re-queries` is high at the same time.

  ## What it deliberately does not do

  It does not alert on a threshold. Picking "mean below X over Y re-queries
  means broken" would bake in a tuning constant chosen from argument rather
  than data, which is the objection that closed the first attempt at #1336
  (PR #1344). Read the numbers from a real burst first; a threshold, if one is
  wanted, belongs in a follow-up informed by them.

  ## Cost

  The telemetry handler runs **synchronously in the CalendarLive process** that
  emitted the event, so it does one `send/2` and nothing else — no formatting,
  no aggregation, no calls into this process. Everything else happens here, on
  the window tick. Disable with:

      config :kiln_cms, #{inspect(__MODULE__)}, enabled: false
  """
  use GenServer

  require Logger

  @handler_id "kiln-cms-calendar-requery-monitor"
  @event [:kiln_cms, :calendar, :requery]
  @default_window :timer.minutes(1)

  # Enough orgs to see a pattern, few enough that one busy deployment cannot
  # turn a window into a wall of text. Any beyond this are summarised.
  @max_orgs_logged 5

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # Test seam: flush the current window synchronously and return its summary
  # rows instead of waiting out the timer.
  @spec flush() :: [map()]
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl true
  def init(opts) do
    config = Application.get_env(:kiln_cms, __MODULE__, [])

    if Keyword.get(config, :enabled, true) do
      window = opts[:window] || Keyword.get(config, :window, @default_window)

      # A remote capture, not an anonymous function: `:telemetry` warns that a
      # local/anonymous handler cannot survive a code upgrade and forces the
      # whole module to stay in memory.
      :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, self())

      schedule(window)
      {:ok, %{window: window, orgs: %{}}}
    else
      :ignore
    end
  end

  @doc false
  # Runs in the emitting CalendarLive process. Must stay this cheap, and must
  # never raise: `:telemetry` permanently detaches a handler that throws, which
  # would silently end the instrumentation rather than fail loudly.
  def handle_event(_event, measurements, metadata, monitor) do
    send(monitor, {:requery, Map.get(metadata, :org_id), Map.get(measurements, :messages, 1)})
    :ok
  rescue
    _error -> :ok
  end

  @impl true
  def handle_info({:requery, org_id, messages}, state) when is_integer(messages) do
    {:noreply, %{state | orgs: tally(state.orgs, org_id, messages)}}
  end

  def handle_info({:requery, _org_id, _messages}, state), do: {:noreply, state}

  def handle_info(:flush_window, state) do
    state.orgs |> summarize() |> log(state.window)
    schedule(state.window)
    {:noreply, %{state | orgs: %{}}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, summarize(state.orgs), %{state | orgs: %{}}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  defp schedule(window), do: Process.send_after(self(), :flush_window, window)

  defp tally(orgs, org_id, messages) do
    Map.update(
      orgs,
      org_id,
      %{requeries: 1, messages: messages, max: messages},
      fn acc ->
        %{
          requeries: acc.requeries + 1,
          messages: acc.messages + messages,
          max: max(acc.max, messages)
        }
      end
    )
  end

  defp summarize(orgs) do
    orgs
    |> Enum.map(fn {org_id, acc} ->
      %{
        org_id: org_id,
        requeries: acc.requeries,
        messages: acc.messages,
        # One decimal: the question is "is this pinned at 1.0 or comfortably
        # above it", which more precision does not help answer.
        mean: Float.round(acc.messages / acc.requeries, 2),
        max: acc.max
      }
    end)
    |> Enum.sort_by(& &1.requeries, :desc)
  end

  defp log([], _window), do: :ok

  defp log(rows, window) do
    seconds = div(window, 1000)
    {shown, rest} = Enum.split(rows, @max_orgs_logged)

    lines =
      Enum.map_join(shown, "\n", fn row ->
        "  org=#{row.org_id} re-queries=#{row.requeries} messages=#{row.messages} " <>
          "mean=#{row.mean} max=#{row.max}"
      end)

    tail =
      case rest do
        [] -> ""
        more -> "\n  … and #{length(more)} more org(s) this window"
      end

    Logger.info(
      "calendar re-query coalescing, last #{seconds}s (#1336 — a high " <>
        "re-queries count with mean near 1 is the drain failing to coalesce):\n" <>
        lines <> tail
    )
  end
end
