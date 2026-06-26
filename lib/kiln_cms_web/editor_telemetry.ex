defmodule KilnCMSWeb.EditorTelemetry do
  @moduledoc """
  `:telemetry` instrumentation for content-editor actions so the editor hot path
  (save / autosave / publish + the other workflow transitions) can be profiled
  via LiveDashboard's Metrics page or scraped into Prometheus/Grafana.

  All events share the `[:kiln_cms, :editor, …]` prefix:

    * `[:kiln_cms, :editor, :save]`     — explicit **Save** button
    * `[:kiln_cms, :editor, :autosave]` — debounced draft autosave
    * `[:kiln_cms, :editor, :publish]`  — the **publish** workflow transition
    * `[:kiln_cms, :editor, :workflow]` — other transitions (submit/return/unpublish/archive)

  Measurements:

    * `:duration` — wall-clock of the underlying Ash submit/transition, in
      `System.monotonic_time/0` native units (render with `unit: {:native, :millisecond}`)
    * `:count` — always `1`, for event counters

  Metadata: `%{kind: atom, action: atom, result: :ok | :error}` (the `:action`
  key is only present on `:workflow` events). The matching `Telemetry.Metrics`
  definitions live in `KilnCMSWeb.Telemetry.metrics/0`.
  """

  @prefix [:kiln_cms, :editor]

  @doc """
  Times `fun`, emits the `[:kiln_cms, :editor, event]` telemetry event, and
  returns `fun`'s result unchanged.

  `result` metadata is derived from the return value: an `{:error, _}` tuple maps
  to `:error`, anything else to `:ok`. `metadata` is merged into the event
  metadata (typically `%{kind: kind}`, plus `%{action: action}` for workflows).
  """
  @spec span(atom(), map(), (-> result)) :: result when result: var
  def span(event, metadata, fun) when is_atom(event) and is_map(metadata) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start

    :telemetry.execute(
      @prefix ++ [event],
      %{duration: duration, count: 1},
      Map.put(metadata, :result, outcome(result))
    )

    result
  end

  defp outcome({:error, _}), do: :error
  defp outcome(_), do: :ok
end
