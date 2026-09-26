defmodule KilnCMSWeb.Telemetry do
  @moduledoc """
  The `Telemetry.Metrics` definitions for the whole app, and the supervisor that
  starts whatever consumes them.

  `metrics/0` has two consumers:

    * **LiveDashboard** (`/dev/dashboard/metrics`), in development only — the
      route is compiled out with `dev_routes`.
    * **`KilnCMSWeb.Metrics`**, the Prometheus exporter, in any environment but
      only when `KILN_METRICS_ENABLED` is on (#1362). Off is the default, and
      then nothing records these: `:telemetry.execute/3` dispatches to an empty
      handler list, exactly as before the exporter existed.

  So a definition here is not, on its own, a signal an operator can see. A stock
  install scrapes nothing. Anything that must reach *every* operator goes
  through `Logger` or Sentry as well (`KilnCMSWeb.TenantRefusalAlert`,
  `KilnCMS.CMS.CalendarRequeryMonitor`) — see `docs/observability.md`.

  ## Shapes, for the exporter

  Durations are `distribution`s, never `summary`: no Prometheus reporter
  exports a summary (Peep drops them with a warning), and a p95 needs the
  histogram anyway. Point-in-time readings (VM memory, run queues) are
  `last_value` gauges. LiveDashboard renders both.

  ## Tags, for cardinality

  Every tag is bounded, because each distinct combination is its own series in
  Prometheus and a multi-tenant deployment multiplies anything per-org. No
  metric carries an org id, a content id, a user or a slug. The one tag that
  could grow with tenants is the content type — admin-defined types are
  per-org — so `type` and `kind` keep a compiled type's name and fold every
  admin-defined type into `"dynamic"` (see `bound_content_type/3`).
  """
  use Supervisor
  import Telemetry.Metrics

  alias KilnCMS.CMS.ContentTypes

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    # The exporter's children first, so its handlers are attached before the
    # poller's first sample. An empty list unless KILN_METRICS_ENABLED is on.
    children =
      KilnCMSWeb.Metrics.children() ++
        [
          # Telemetry poller will execute the given period measurements
          # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
          {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    compiled_types = compiled_type_names()
    kind = &bound_content_type(&1, :kind, compiled_types)
    type = &bound_content_type(&1, :type, compiled_types)

    [
      # Phoenix Metrics
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        description: "Time to serve a request through the endpoint"
      ),
      # `route` is the router's pattern (`/api/content/:type/:slug`), never the
      # request path, so it is bounded by the route table. This is the series
      # the headless-API p95 in docs/performance.md is read from.
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        description: "Time to serve a request, by matched route"
      ),
      distribution("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        description: "Time to a request that raised, by matched route"
      ),
      distribution("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      distribution("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      distribution("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      distribution("kiln_cms.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      distribution("kiln_cms.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      distribution("kiln_cms.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      distribution("kiln_cms.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      distribution("kiln_cms.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Editor Action Metrics (emitted by KilnCMSWeb.EditorTelemetry)
      distribution("kiln_cms.editor.save.duration",
        unit: {:native, :millisecond},
        tags: [:kind, :result],
        tag_values: kind,
        description: "Time to persist an explicit editor Save"
      ),
      counter("kiln_cms.editor.save.count",
        tags: [:kind, :result],
        tag_values: kind,
        description: "Number of explicit editor Saves"
      ),
      distribution("kiln_cms.editor.autosave.duration",
        unit: {:native, :millisecond},
        tags: [:kind, :result],
        tag_values: kind,
        description: "Time to persist a debounced draft autosave"
      ),
      counter("kiln_cms.editor.autosave.count",
        tags: [:kind, :result],
        tag_values: kind,
        description: "Number of draft autosaves"
      ),
      distribution("kiln_cms.editor.publish.duration",
        unit: {:native, :millisecond},
        tags: [:kind, :result],
        tag_values: kind,
        description: "Time to run the publish workflow transition"
      ),
      counter("kiln_cms.editor.publish.count",
        tags: [:kind, :result],
        tag_values: kind,
        description: "Number of publish transitions"
      ),
      distribution("kiln_cms.editor.workflow.duration",
        unit: {:native, :millisecond},
        tags: [:kind, :action, :result],
        tag_values: kind,
        description: "Time to run a non-publish workflow transition"
      ),
      counter("kiln_cms.editor.workflow.count",
        tags: [:kind, :action, :result],
        tag_values: kind,
        description: "Number of non-publish workflow transitions"
      ),
      # Untagged on purpose: the event's `org_id` is metadata for
      # KilnCMS.CMS.CalendarRequeryMonitor's per-org log line, not a label.
      distribution("kiln_cms.calendar.requery.messages",
        description:
          "How many :calendar_changed messages each calendar re-query coalesced " <>
            "(1 = a lone change; consistently 1 under bursty writes = coalescing is broken)"
      ),

      # Delivery / cache / firing Metrics (#206)
      counter("kiln_cms.cache.content.count",
        tags: [:result],
        description:
          "Public content cache lookups, tagged hit / miss / coalesced (deduplicated " <>
            "into another caller's in-flight read, #1377) / error (the fetch failed and " <>
            "the caller recomputed outside the stampede guard, #1376)"
      ),
      distribution("kiln_cms.firing.fire.duration",
        unit: {:native, :millisecond},
        tags: [:type, :mode],
        tag_values: type,
        description: "Time to render+persist a document's per-surface artifacts"
      ),
      distribution("kiln_cms.delivery.render.duration",
        unit: {:native, :millisecond},
        tags: [:type, :status],
        tag_values: type,
        description: "Time to build a public HTML delivery response"
      ),
      counter("kiln_cms.analytics.view.count",
        tags: [:type, :surface],
        tag_values: type,
        description:
          "Public content views recorded, by content type and delivery surface " <>
            "(\"html\" for the rendered site, otherwise the fired surface a " <>
            "headless client fetched). Aggregate only — the event's content_id " <>
            "metadata is deliberately not a tag (it would be an unbounded " <>
            "series); `surface` is safe because KilnCMSWeb.ViewTracking bounds " <>
            "it to the known surface names."
      ),

      # Oban job Metrics (emitted by Oban) — queue throughput, latency, failures
      distribution("oban.job.stop.duration",
        unit: {:native, :millisecond},
        tags: [:queue, :worker],
        description: "Time to execute an Oban job"
      ),
      counter("oban.job.stop.count",
        tags: [:queue, :worker],
        description: "Completed Oban jobs"
      ),
      counter("oban.job.exception.count",
        tags: [:queue, :worker],
        description: "Failed Oban jobs"
      ),

      # VM Metrics (from telemetry_poller's default poller)
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ]
  end

  @doc """
  Bounds a content-type tag in `metadata` for export.

  A compiled type keeps its name. An admin-defined type is folded into
  `"dynamic"`: those are per-org, so on a multi-tenant deployment one series
  per type name has no ceiling. Compiled types arrive as atoms from some
  emitters and as strings from others (`to_string(ct.type)`); dynamic types are
  always strings, and never atoms (D17) — so an atom is compiled by
  construction, and a string is compiled only when `compiled` names it.

      iex> compiled = MapSet.new(["page"])
      iex> KilnCMSWeb.Telemetry.bound_content_type(%{type: "page"}, :type, compiled)
      %{type: "page"}
      iex> KilnCMSWeb.Telemetry.bound_content_type(%{kind: :page}, :kind, compiled)
      %{kind: :page}
      iex> KilnCMSWeb.Telemetry.bound_content_type(%{type: "acme_recipe"}, :type, compiled)
      %{type: "dynamic"}
  """
  @spec bound_content_type(map(), atom(), MapSet.t(String.t())) :: map()
  def bound_content_type(metadata, key, compiled) do
    case metadata do
      %{^key => name} when is_binary(name) ->
        if MapSet.member?(compiled, name),
          do: metadata,
          else: Map.put(metadata, key, "dynamic")

      _atom_or_absent ->
        metadata
    end
  end

  # The compiled content types' names. Not `ContentTypes.types/0`: that filters
  # with `function_exported?/3`, which is false for a module not yet loaded — and
  # this runs as the application's first child, before anything has touched the
  # resources in dev/test's interactive code mode. `type_name/1` loads each one.
  defp compiled_type_names do
    ContentTypes.content_domains()
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.flat_map(&List.wrap(ContentTypes.type_name(&1)))
    |> MapSet.new()
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {KilnCMSWeb, :count_users, []}
    ]
  end
end
