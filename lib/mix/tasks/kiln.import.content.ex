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

  A release has no Mix: run `KilnCMS.Release.import_content/2` through
  `bin/kiln_cms rpc` instead, with these flags as keyword options
  (`docs/content-portability.md`, "From a release").

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

  alias KilnCMS.Portability.Commands

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
    drain_media: :boolean,
    # Same #931 class as `--drain-media` in `kiln.import.wordpress.ex`:
    # documented above, read by `import_csv/2`, never declared — so `--type`
    # raised as an unknown option and the "required for a CSV import" error
    # below it was unreachable.
    type: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    path =
      case args do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix kiln.import.content <export.json> [--dry-run]")
      end

    case Commands.import_content(path, opts, &Mix.shell().info(&1)) do
      {:ok, _report} -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
