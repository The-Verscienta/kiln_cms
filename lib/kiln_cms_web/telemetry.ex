defmodule KilnCMSWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("kiln_cms.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("kiln_cms.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("kiln_cms.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("kiln_cms.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("kiln_cms.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Editor Action Metrics (emitted by KilnCMSWeb.EditorTelemetry)
      summary("kiln_cms.editor.save.duration",
        unit: {:native, :millisecond},
        tags: [:kind, :result],
        description: "Time to persist an explicit editor Save"
      ),
      counter("kiln_cms.editor.save.count",
        tags: [:kind, :result],
        description: "Number of explicit editor Saves"
      ),
      summary("kiln_cms.editor.autosave.duration",
        unit: {:native, :millisecond},
        tags: [:kind, :result],
        description: "Time to persist a debounced draft autosave"
      ),
      counter("kiln_cms.editor.autosave.count",
        tags: [:kind, :result],
        description: "Number of draft autosaves"
      ),
      summary("kiln_cms.editor.publish.duration",
        unit: {:native, :millisecond},
        tags: [:kind, :result],
        description: "Time to run the publish workflow transition"
      ),
      counter("kiln_cms.editor.publish.count",
        tags: [:kind, :result],
        description: "Number of publish transitions"
      ),
      summary("kiln_cms.editor.workflow.duration",
        unit: {:native, :millisecond},
        tags: [:kind, :action, :result],
        description: "Time to run a non-publish workflow transition"
      ),
      counter("kiln_cms.editor.workflow.count",
        tags: [:kind, :action, :result],
        description: "Number of non-publish workflow transitions"
      ),

      # Delivery / cache / firing Metrics (#206)
      counter("kiln_cms.cache.content.count",
        tags: [:result],
        description: "Public content cache lookups, tagged hit/miss"
      ),
      summary("kiln_cms.firing.fire.duration",
        unit: {:native, :millisecond},
        tags: [:type, :mode],
        description: "Time to render+persist a document's per-surface artifacts"
      ),
      summary("kiln_cms.delivery.render.duration",
        unit: {:native, :millisecond},
        tags: [:type, :status],
        description: "Time to build a public HTML delivery response"
      ),

      # Oban job Metrics (emitted by Oban) — queue throughput, latency, failures
      summary("oban.job.stop.duration",
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

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {KilnCMSWeb, :count_users, []}
    ]
  end
end
