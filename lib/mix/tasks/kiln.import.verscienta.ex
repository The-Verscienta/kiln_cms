defmodule Mix.Tasks.Kiln.Import.Verscienta do
  @shortdoc "Import Verscienta's Directus content into KilnCMS"

  @moduledoc """
  One-off migration: import the Verscienta herbal database from its Directus
  backend into KilnCMS content (`herbs`, `formulas`, `conditions`,
  `practitioners`, `clinics`, `modalities`, plus taxonomy, media and relations).

  See `KilnCMS.Verscienta.Importer` for the field-by-field mapping.

  ## Usage

      # Live Directus API (reads DIRECTUS_URL + DIRECTUS_TOKEN from the env)
      DIRECTUS_URL=https://api.verscienta.com \\
      DIRECTUS_TOKEN=xxxxx \\
      mix kiln.import.verscienta

      # …or pass them explicitly
      mix kiln.import.verscienta --url https://api.verscienta.com --token xxxxx

      # Offline dry-run against JSON fixtures (no writes)
      mix kiln.import.verscienta --source priv/verscienta_fixtures --dry-run

  ## Options

    * `--source PATH` — read from JSON fixture files in `PATH` instead of the
      live API (each collection in `PATH/<collection>.json`).
    * `--url URL` / `--token TOKEN` — Directus base URL / read token (override
      the `DIRECTUS_URL` / `DIRECTUS_TOKEN` env vars).
    * `--dry-run` — fetch and transform everything and report counts, but write
      nothing.
    * `--locale LOCALE` — locale for created content (default `en`).
  """

  use Mix.Task

  @requirements ["app.start"]

  alias KilnCMS.Verscienta.Importer

  @switches [source: :string, url: :string, token: :string, dry_run: :boolean, locale: :string]

  @impl true
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    source_spec =
      case opts[:source] do
        nil -> {:directus, url: opts[:url], token: opts[:token]}
        dir -> {:fixtures, dir}
      end

    run_opts =
      [dry_run: opts[:dry_run] || false]
      |> then(fn o -> if opts[:locale], do: Keyword.put(o, :locale, opts[:locale]), else: o end)

    case Importer.run(source_spec, run_opts) do
      {:ok, stats} ->
        Mix.shell().info("Import complete: #{inspect(stats)}")

      {:error, reason} ->
        Mix.raise("Import failed: #{inspect(reason)}")
    end
  end
end
