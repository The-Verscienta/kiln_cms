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

  ## What is not imported

  Comments, users, widgets, menus, theme settings and plugin data. WXR carries
  some of them; none map onto anything in this CMS without an editorial
  decision that a mix task should not be making silently. Post revisions are
  skipped too — the imported record is the current version, and its history
  starts here.
  """

  use Mix.Task

  alias KilnCMS.Portability.Import
  alias KilnCMS.Portability.WXR

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
    author_map: :keep
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    path =
      case args do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix kiln.import.wordpress <export.xml> [--dry-run]")
      end

    case WXR.parse_file(path) do
      {:ok, parsed} -> import_parsed(parsed, opts)
      {:error, reason} -> Mix.raise("Could not read #{path}: #{inspect(reason)}")
    end
  end

  defp import_parsed(parsed, opts) do
    Mix.shell().info("""
    Read #{length(parsed.records)} importable records, \
    #{length(parsed.attachments)} attachments, #{length(parsed.authors)} authors\
    #{site_line(parsed.site)}
    """)

    run_opts = KilnCMS.Portability.CLI.scope!(opts) ++ import_opts(opts)

    # `run/2` reports per-record failures inside the report rather than failing
    # the run — one unimportable post must not abandon the other 3,999.
    {:ok, report} = Import.run(parsed, run_opts)
    KilnCMS.Portability.CLI.print_report(report)
  end

  defp site_line(%{title: title, url: url}) when is_binary(title),
    do: "\nSource site: #{title}#{if url, do: " (#{url})", else: ""}"

  defp site_line(_site), do: ""

  defp import_opts(opts) do
    [
      dry_run: Keyword.get(opts, :dry_run, false),
      skip_media: Keyword.get(opts, :skip_media, false),
      redirects: Keyword.get(opts, :redirects, true),
      locale: Keyword.get(opts, :locale, "en"),
      on_conflict: on_conflict(opts[:on_conflict]),
      author_map: opts |> Keyword.get_values(:author_map) |> KilnCMS.Portability.CLI.author_map!()
    ]
    |> maybe_put(:limit, opts[:limit])
  end

  defp on_conflict("error"), do: :error
  defp on_conflict(_other), do: :skip

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)
end
