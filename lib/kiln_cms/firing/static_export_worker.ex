defmodule KilnCMS.Firing.StaticExportWorker do
  @moduledoc """
  Runs a static/edge export off-request (#353) — the background/admin trigger
  for `KilnCMS.Firing.StaticExport`.

  Enqueue it (from an admin action, a release task, or a cron entry) to write the
  current fired artifacts to the configured output directory:

      Oban.insert(KilnCMS.Firing.StaticExportWorker.new(%{}))

  The output directory and default surfaces come from config; a job may override
  `"out_dir"`/`"surfaces"` in its args:

      config :kiln_cms, KilnCMS.Firing.StaticExport,
        output_dir: "/var/www/edge",
        surfaces: [:web, :json, :json_ld]

  A no-op with a log line when no output directory is configured (so it's safe to
  wire a cron entry that only does work once an operator sets a destination).
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 60, states: [:scheduled, :available, :executing, :retryable, :suspended]]

  require Logger

  alias KilnCMS.Firing.StaticExport

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    config = Application.get_env(:kiln_cms, StaticExport, [])

    case args["out_dir"] || config[:output_dir] do
      nil ->
        Logger.info(
          "StaticExportWorker: no output directory configured " <>
            "(set config :kiln_cms, KilnCMS.Firing.StaticExport, output_dir: …); skipping."
        )

        :ok

      out_dir ->
        opts = surfaces_opt(args["surfaces"] || config[:surfaces])
        {:ok, result} = StaticExport.export(out_dir, opts)

        Logger.info(
          "StaticExportWorker: exported #{result.count} document(s) to #{result.out_dir} " <>
            "(skipped #{result.skipped})."
        )

        :ok
    end
  end

  defp surfaces_opt(nil), do: []

  defp surfaces_opt(surfaces) when is_list(surfaces) do
    [surfaces: Enum.map(surfaces, &to_atom_surface/1)]
  end

  defp to_atom_surface(s) when is_atom(s), do: s
  defp to_atom_surface("web"), do: :web
  defp to_atom_surface("json"), do: :json
  defp to_atom_surface("json_ld"), do: :json_ld
end
