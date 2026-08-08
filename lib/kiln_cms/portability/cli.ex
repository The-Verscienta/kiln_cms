defmodule KilnCMS.Portability.CLI do
  @moduledoc """
  The shared command-line edges of the import/export tasks (#487): resolving
  which user and organization a run acts as, and printing a report.

  Kept out of the mix tasks themselves so `kiln.import.wordpress`,
  `kiln.import.content` and `kiln.export.content` cannot drift on the one thing
  an operator must be able to trust across all three — *who* the run acted as.
  A task that quietly fell back to a different actor than the one printed would
  produce content attributed to the wrong person with no way to tell afterwards.

  Not localized. These are operator tools invoked from a shell on a server, and
  their output is read next to logs; the admin-facing surfaces are where
  gettext belongs.
  """

  alias KilnCMS.Accounts

  @doc """
  Resolve `--actor` / `--org` into the `[actor:, tenant:]` every portability
  call takes, printing what it settled on.

  Raises when no usable actor exists. An import that ran with `actor: nil`
  would either be refused by policy (confusing) or, worse, create content with
  no author — so refusing up front is the kinder failure.
  """
  @spec scope!(keyword()) :: keyword()
  def scope!(opts) do
    actor = resolve_actor!(opts[:actor])
    tenant = resolve_org!(opts[:org])

    Mix.shell().info("Acting as #{actor.email} in org #{org_label(tenant)}\n")

    [actor: actor, tenant: tenant]
  end

  defp resolve_actor!(nil) do
    case Accounts.list_users!(authorize?: false, query: [filter: [role: :admin], limit: 1]) do
      [admin | _] ->
        admin

      [] ->
        Mix.raise("""
        No admin user to run as, and no --actor given.

        Pass --actor EMAIL, or create an admin first.
        """)
    end
  end

  defp resolve_actor!(email) do
    case Accounts.list_users!(authorize?: false, query: [filter: [email: email], limit: 1]) do
      [user | _] -> user
      [] -> Mix.raise("No user with email #{email}")
    end
  end

  defp resolve_org!(nil), do: Accounts.default_org_id()

  defp resolve_org!(slug) do
    case Accounts.list_organizations!(authorize?: false, query: [filter: [slug: slug], limit: 1]) do
      [org | _] -> org.id
      [] -> Mix.raise("No organization with slug #{slug}")
    end
  end

  defp org_label(id) when is_binary(id), do: id
  defp org_label(%{slug: slug}), do: slug
  defp org_label(other), do: inspect(other)

  @doc """
  Print an import report.

  A dry run is labelled loudly. The most common way to lose data with an
  importer is to believe a dry run was the real thing (or the reverse), so the
  distinction is the first and last thing printed.
  """
  @spec print_report(map()) :: :ok
  def print_report(report) do
    shell = Mix.shell()

    if report.dry_run do
      shell.info("── DRY RUN — nothing was written ──────────────────────────")
    end

    shell.info("""
    Records:   #{length(report.created)} #{verb(report.dry_run, "would be created", "created")}, \
    #{length(report.skipped)} skipped (already present), #{length(report.failed)} failed
    Taxonomy:  #{term_line(report.taxonomy.categories)} categories, \
    #{term_line(report.taxonomy.tags)} tags
    Media:     #{media_line(report.media)}
    Redirects: #{Map.get(report.redirects, :created, 0)} \
    #{verb(report.dry_run, "would be created", "created")}\
    """)

    print_authors(shell, Map.get(report, :authors))

    print_list(shell, "Failed", report.failed, &"  #{&1.kind} #{inspect(&1.title)}: #{&1.reason}")

    print_list(
      shell,
      "Media that could not be fetched",
      Map.get(report.media, :failed, []),
      &"  #{&1.url}: #{inspect(&1.reason)}"
    )

    if report.dry_run do
      shell.info("\n── DRY RUN — re-run without --dry-run to apply ────────────")
    end

    :ok
  end

  # The source's authors, and which of them resolved to a Kiln user. Printed
  # rather than counted: an operator who can only see "3 authors" cannot decide
  # whether the unmapped ones matter, and the alternative is opening the XML.
  defp print_authors(_shell, nil), do: :ok
  defp print_authors(_shell, %{found: []}), do: :ok

  defp print_authors(shell, %{found: found, mapped: mapped, unmapped: unmapped}) do
    shell.info("\nAuthors (#{length(mapped)} mapped, #{length(unmapped)} unmapped):")

    for author <- found do
      mark = if author.login in mapped, do: "->", else: " ~"
      shell.info("  #{mark} #{author.login} #{inspect(author.name)} <#{author.email}>")
    end

    if unmapped != [] do
      shell.info(
        "  Unmapped authors' content is attributed to the acting user. " <>
          "Map them with --author-map login=kiln@email (repeatable)."
      )
    end
  end

  @doc """
  Parse repeated `--author-map login=email` flags into the map
  `KilnCMS.Portability.Import.resolve_authors/2` takes.

  A value with no `=` is rejected loudly rather than ignored: a silently dropped
  mapping looks identical to one that found no user, and the whole point of the
  flag is to be sure about attribution.
  """
  @spec author_map!([String.t()]) :: %{String.t() => String.t()}
  def author_map!(pairs) do
    Map.new(pairs, fn pair ->
      case String.split(pair, "=", parts: 2) do
        [source, email] when source != "" and email != "" ->
          {String.trim(source), String.trim(email)}

        _ ->
          Mix.raise("--author-map expects login=email, got: #{inspect(pair)}")
      end
    end)
  end

  @doc """
  Run the image-variant jobs the import just queued, then return.

  `Ingest` enqueues `VariantWorker`/`AVWorker` and does not wait — normally
  right, because a running node picks them up. But a migration is often run in a
  one-off container with nothing else consuming the `media` queue, and there the
  jobs sit `available` forever and every imported image renders full size. This
  is the opt-in for that case; `nil`/`false` keeps the asynchronous default.
  """
  @spec maybe_drain_media(boolean() | nil) :: :ok
  def maybe_drain_media(true) do
    Mix.shell().info("\nDraining the media queue …")
    result = Oban.drain_queue(queue: :media, with_recursion: true)
    Mix.shell().info("Media jobs: #{inspect(result)}")
    :ok
  end

  def maybe_drain_media(_other), do: :ok

  # Truncated: a failing import can fail thousands of times, and a wall of
  # identical messages buries the one line that explains why. The count in the
  # summary above is the complete number.
  @max_listed 20

  defp print_list(_shell, _heading, [], _format), do: :ok

  defp print_list(shell, heading, items, format) do
    shell.info("\n#{heading} (#{length(items)}):")
    items |> Enum.take(@max_listed) |> Enum.each(&shell.info(format.(&1)))

    if length(items) > @max_listed do
      shell.info("  … and #{length(items) - @max_listed} more")
    end
  end

  defp verb(true, dry, _real), do: dry
  defp verb(_false, _dry, real), do: real

  defp term_line(%{matched: matched, created: created}),
    do: "#{created} new / #{matched} matched"

  defp term_line(other), do: inspect(other)

  defp media_line(%{imported: imported, failed: failed}),
    do: "#{imported} imported, #{length(failed)} failed"

  defp media_line(%{would_import: n}), do: "#{n} would be imported"
  defp media_line(%{skipped: n}), do: "#{n} skipped (--skip-media)"
  defp media_line(other), do: inspect(other)
end
