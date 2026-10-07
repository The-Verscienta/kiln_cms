defmodule Mix.Tasks.Kiln.Import.Wordpress do
  @shortdoc "Import a WordPress WXR export into Kiln"

  @moduledoc """
  Import a WordPress eXtended RSS (WXR) export (#487).

      mix kiln.import.wordpress export.xml --dry-run
      mix kiln.import.wordpress export.xml --actor editor@example.com

  Posts and pages become content of the matching type, the body's HTML becomes
  typed blocks, categories and tags become taxonomy, images are sideloaded into
  the media library, and **every old permalink becomes a redirect** — which is
  what makes a migration keep its search rankings and inbound links.

  Always dry-run first. `--dry-run` performs the whole plan with no writes and
  prints exactly what a real run would create, using the same code the real run
  uses.

  A release has no Mix: run `KilnCMS.Release.import_wordpress/2` through
  `bin/kiln_cms rpc` instead, with these flags as keyword options
  (`docs/content-portability.md`, "From a release").

  ## Options

      --dry-run          plan only; no writes, no downloads
      --actor EMAIL      run as this user (default: the first admin)
      --org SLUG         import into this organization (default: the default org)
      --locale LOCALE    locale for created records (default: en)
      --limit N          import at most N records
      --skip-media       do not sideload images (blocks keep the source URLs)
      --no-redirects     do not create redirects from old permalinks
      --on-conflict      skip (default) | error
      --author-map       login=kiln@email, repeatable — attribute imported
                         content to the Kiln user who wrote it. Unmapped authors
                         are matched on their own email, then fall back to
                         --actor; every author is listed in the report.
      --drain-media      run the queued image-variant jobs before exiting, for a
                         one-off container where nothing else consumes the queue

  ## What is not imported

  Comments, users, widgets, menus, theme settings and plugin data. WXR carries
  some of them; none map onto anything in this CMS without an editorial
  decision that a mix task should not be making silently. Post revisions are
  skipped too — the imported record is the current version, and its history
  starts here.
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
    author_map: :keep,
    # Documented at the top of this moduledoc and read at the bottom of
    # `run/1`, but never declared — so `parse!/2` rejected `--drain-media` as
    # an unknown option and `opts[:drain_media]` was permanently nil. The #931
    # class, found by the sweep that issue asked for; `kiln.import.content.ex`
    # declares the same switch.
    drain_media: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    path =
      case args do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix kiln.import.wordpress <export.xml> [--dry-run]")
      end

    case Commands.import_wordpress(path, opts, &Mix.shell().info(&1)) do
      {:ok, _report} -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
