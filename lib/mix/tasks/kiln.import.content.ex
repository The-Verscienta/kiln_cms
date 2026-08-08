defmodule Mix.Tasks.Kiln.Import.Content do
  @shortdoc "Load a portable JSON envelope produced by kiln.export.content"

  @moduledoc """
  Load the JSON envelope `mix kiln.export.content` writes (#487).

      mix kiln.import.content content.json --dry-run
      mix kiln.import.content content.json --org staging

  Records are created through each type's ordinary create action, so slug
  generation, custom fields, sanitization, tenancy and policy all apply. Media
  named in the envelope's manifest is sideloaded from the URLs it carries — so
  the source site must still be reachable, or `--skip-media` will keep the
  blocks pointing at it.

  Existing `(slug, locale)` matches are **skipped**, which makes re-running safe
  and makes resuming after a partial run cheap.

  ## Options

      --dry-run          plan only; no writes, no downloads
      --actor EMAIL      run as this user (default: the first admin)
      --org SLUG         import into this organization (default: the default org)
      --locale LOCALE    override the locale for created records
      --limit N          import at most N records
      --skip-media       do not sideload media
      --no-redirects     do not create redirects (envelopes carry none anyway)
      --on-conflict      skip (default) | error
      --type NAME        required for a .csv file — a CSV carries one type and
                         no type column
  """

  use Mix.Task

  alias KilnCMS.Portability.CLI
  alias KilnCMS.Portability.CSV
  alias KilnCMS.Portability.Import

  @requirements ["app.start"]

  @switches [
    dry_run: :boolean,
    actor: :string,
    org: :string,
    locale: :string,
    limit: :integer,
    skip_media: :boolean,
    redirects: :boolean,
    on_conflict: :string,
    drain_media: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    path =
      case args do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix kiln.import.content <export.json> [--dry-run]")
      end

    path |> read_envelope!(opts) |> import_envelope(opts)
  end

  # CSV is one type per file and carries no type column, so `--type` names it.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_envelope!(path, opts) do
    if String.ends_with?(path, ".csv"), do: read_csv!(path, opts), else: read_json!(path)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_csv!(path, opts) do
    type = opts[:type] || Mix.raise("--type is required for a CSV import")

    with {:ok, text} <- File.read(path),
         {:ok, records} <- CSV.decode(text, type, CLI.scope!(opts)) do
      %{"records" => records}
    else
      {:error, :empty} ->
        Mix.raise("#{path} has no rows")

      {:error, {:unknown_columns, columns}} ->
        Mix.raise("""
        #{path} has columns this type does not define: #{Enum.join(columns, ", ")}

        Expected: title, slug, locale, state, plus this type's fields. A header
        typo would otherwise import every row with that field silently empty.
        """)

      {:error, reason} ->
        Mix.raise("Could not read #{path}: #{inspect(reason)}")
    end
  end

  # The path is an operator's own command-line argument.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_json!(path) do
    with {:ok, json} <- File.read(path),
         {:ok, envelope} <- Jason.decode(json) do
      envelope
    else
      {:error, %Jason.DecodeError{} = error} ->
        Mix.raise("#{path} is not valid JSON: #{Exception.message(error)}")

      {:error, reason} ->
        Mix.raise("Could not read #{path}: #{inspect(reason)}")
    end
  end

  defp import_envelope(envelope, opts) do
    records = envelope |> Map.get("records", []) |> length()
    Mix.shell().info("Read #{records} records from the envelope\n")

    run_opts =
      CLI.scope!(opts) ++
        [
          dry_run: Keyword.get(opts, :dry_run, false),
          skip_media: Keyword.get(opts, :skip_media, false),
          redirects: Keyword.get(opts, :redirects, true),
          on_conflict: on_conflict(opts[:on_conflict]),
          progress: fn line -> Mix.shell().info(line) end
        ] ++
        maybe(:locale, opts[:locale]) ++ maybe(:limit, opts[:limit])

    case Import.run_envelope(envelope, run_opts) do
      {:ok, report} ->
        CLI.print_report(report)
        CLI.maybe_drain_media(opts[:drain_media])

      {:error, :not_an_export_envelope} ->
        Mix.raise("That file has no \"records\" array")
    end
  end

  defp on_conflict("error"), do: :error
  defp on_conflict(_other), do: :skip

  defp maybe(_key, nil), do: []
  defp maybe(key, value), do: [{key, value}]
end
