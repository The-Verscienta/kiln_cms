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

  alias KilnCMS.Portability.CLI
  alias KilnCMS.Portability.Ghost
  alias KilnCMS.Portability.Import

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

    case Ghost.parse_file(path, site_url: opts[:site_url]) do
      {:ok, parsed} ->
        import_parsed(parsed, opts)

      {:error, :site_url_required} ->
        Mix.raise("""
        #{path} writes the Ghost site's own URLs as __GHOST_URL__, so its images
        cannot be fetched without the site's address. Pass it:

            mix kiln.import.ghost #{path} --site-url https://your-ghost-site.example
        """)

      {:error, :not_a_ghost_export} ->
        Mix.raise("""
        #{path} is JSON, but not a Ghost export: there is no db[0].data.posts.
        Export it from Ghost Admin → Settings → Import/Export → Export content.
        """)

      {:error, {:too_large, size, max}} ->
        Mix.raise("""
        #{path} is #{div(size, 1_048_576)} MB; the importer's ceiling is \
        #{div(max, 1_048_576)} MB. Run it where it can be read whole, or ask on
        the issue tracker — no Ghost export this size has been seen yet.
        """)

      {:error, reason} ->
        Mix.raise("Could not read #{path}: #{inspect(reason)}")
    end
  end

  defp import_parsed(parsed, opts) do
    Mix.shell().info("""
    Read #{length(parsed.records)} importable records, \
    #{length(parsed.attachments)} feature images, #{length(parsed.authors)} authors\
    #{site_line(parsed.site)}
    """)

    print_notes(parsed)

    run_opts = CLI.scope!(opts) ++ import_opts(opts)

    {:ok, report} = Import.run(parsed, run_opts)
    CLI.print_report(report)
    CLI.maybe_drain_media(opts[:drain_media])
  end

  # Decisions the parser made that the report cannot show — a scheduled post
  # landing as a draft — and the posts it could not read at all.
  defp print_notes(parsed) do
    notes = for %{note: note} = record <- parsed.records, is_binary(note), do: {record, note}

    if notes != [] do
      Mix.shell().info("Not as Ghost had it (#{length(notes)}):")
      for {record, note} <- notes, do: Mix.shell().info("  ~ #{record.title}: #{note}")
      Mix.shell().info("")
    end

    if parsed.unreadable != [] do
      Mix.shell().info("Unreadable, not imported (#{length(parsed.unreadable)}):")

      for %{title: title, reason: reason} <- parsed.unreadable,
          do: Mix.shell().info("  x #{title}: #{reason}")

      Mix.shell().info("")
    end
  end

  defp site_line(%{title: title, url: url, version: version}) do
    [
      title && "\nSource site: #{title}",
      url && " (#{url})",
      version && "\nGhost version: #{version}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join()
  end

  defp import_opts(opts) do
    [
      dry_run: Keyword.get(opts, :dry_run, false),
      skip_media: Keyword.get(opts, :skip_media, false),
      redirects: Keyword.get(opts, :redirects, true),
      locale: Keyword.get(opts, :locale, "en"),
      on_conflict: if(opts[:on_conflict] == "error", do: :error, else: :skip),
      author_map: opts |> Keyword.get_values(:author_map) |> CLI.author_map!()
    ]
    |> then(fn list ->
      if opts[:limit], do: Keyword.put(list, :limit, opts[:limit]), else: list
    end)
  end
end
