defmodule Mix.Tasks.Kiln.Import.Ghost do
  @shortdoc "Import a Ghost JSON export into Kiln"

  @moduledoc """
  Import a Ghost JSON export (#1876).

      mix kiln.import.ghost ghost-export.json --site-url https://blog.example.com --dry-run
      mix kiln.import.ghost ghost-export.json --site-url https://blog.example.com

  Posts and pages become content of the matching type, the rendered HTML
  becomes typed blocks, public tags become tags, feature and body images are
  sideloaded into the media library, members-only posts stay gated, and every
  old `/{slug}/` permalink becomes a redirect.

  It shares `KilnCMS.Portability.Import` with `mix kiln.import.wordpress`, so
  the dry run, the re-run behaviour and the report are the same. Always
  dry-run first.

  A release has no Mix: run `KilnCMS.Release.import_ghost/2` through
  `bin/kiln_cms rpc` instead, with these flags as keyword options
  (`docs/content-portability.md`, "From a release").

  ## Options

      --site-url URL     the Ghost site's address. Required when the export
                         contains `__GHOST_URL__` (Ghost 4 and later) or
                         root-relative image paths (older Ghost), which is
                         how Ghost writes its own image URLs; the images are
                         fetched from there, so keep the old site up until the
                         import is done
      --dry-run          plan only; no writes, no downloads
      --actor EMAIL      run as this user (default: the first admin)
      --org SLUG         import into this organization (default: the default org)
      --locale LOCALE    locale for created records (default: en)
      --limit N          import at most N records
      --skip-media       do not sideload images (blocks keep the source URLs)
      --no-redirects     do not create redirects from old permalinks
      --on-conflict      skip (default) | error
      --author-map       slug=kiln@email, repeatable — attribute imported
                         content to the Kiln user who wrote it. Unmapped authors
                         are matched on their own email, then fall back to
                         --actor; every author is listed in the report.
      --drain-media      run the queued image-variant jobs before exiting

  ## What is not imported

  Members and subscribers, newsletters already sent, comments, tiers and
  offers, code injection, internal (`#`) tags, navigation and theme settings,
  and post revisions. See `docs/compare/migrating-from-ghost.md` for what to do about
  each.
  """

  use Mix.Task

  alias KilnCMS.Portability.Commands

  @requirements ["app.start"]

  @switches [
    site_url: :string,
    dry_run: :boolean,
    actor: :string,
    org: :string,
    locale: :string,
    limit: :integer,
    skip_media: :boolean,
    redirects: :boolean,
    on_conflict: :string,
    author_map: :keep,
    drain_media: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    path =
      case args do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix kiln.import.ghost <export.json> --site-url URL [--dry-run]")
      end

    case Commands.import_ghost(path, opts, &Mix.shell().info(&1)) do
      {:ok, _report} -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
