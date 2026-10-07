defmodule KilnCMS.Portability.CLI do
  @moduledoc """
  The shared command-line edges of the import/export tasks (#487): resolving
  which user and organization a run acts as, and printing a report.

  Kept out of the mix tasks themselves so `kiln.import.wordpress`,
  `kiln.import.content` and `kiln.export.content` cannot drift on the one thing
  an operator must be able to trust across all three — *who* the run acted as.
  A task that quietly fell back to a different actor than the one printed would
  produce content attributed to the wrong person with no way to tell afterwards.

  Nothing here touches Mix, because the release runs the same code
  (`KilnCMS.Portability.Commands`, `KilnCMS.Release.import_wordpress/2`) and a
  release has no Mix. Output goes through the caller's one-argument `shell`
  function, and refusals come back as `{:error, message}` for the caller to
  raise (a mix task) or print (a release).

  Not localized. These are operator tools invoked from a shell on a server, and
  their output is read next to logs; the admin-facing surfaces are where
  gettext belongs.
  """

  alias KilnCMS.Accounts

  @typedoc "Where output goes: `&Mix.shell().info(&1)` from a mix task, `&IO.puts/1` from a release."
  @type shell :: (String.t() -> any())

  @doc """
  Resolve `--actor` / `--org` into `{:ok, [actor:, tenant:]}`, the scope every
  portability call takes, printing what it settled on through `shell`.

  Returns `{:error, message}` when no usable actor or organization exists. An
  import that ran with `actor: nil` would either be refused by policy
  (confusing) or, worse, create content with no author — so refusing up front
  is the kinder failure. Nothing is printed before a refusal: an "Acting as"
  line would name an actor the run never used.
  """
  @spec scope(keyword(), shell()) :: {:ok, keyword()} | {:error, String.t()}
  def scope(opts, shell) do
    with {:ok, actor} <- resolve_actor(opts[:actor]),
         {:ok, tenant} <- resolve_org(opts[:org]) do
      shell.("Acting as #{actor.email} in org #{org_label(tenant)}\n")
      {:ok, [actor: actor, tenant: tenant]}
    end
  end

  defp resolve_actor(nil) do
    # authorize?: false — this finds the actor, so there is none yet; a system User grant reads every account
    case Accounts.list_users!(authorize?: false, query: [filter: [role: :admin], limit: 1]) do
      [admin | _] ->
        {:ok, admin}

      [] ->
        {:error,
         """
         No admin user to run as, and no --actor given.

         Pass --actor EMAIL, or create an admin first.
         """}
    end
  end

  defp resolve_actor(email) do
    # authorize?: false — the operator's --actor lookup, before any actor exists (same reason as above)
    case Accounts.list_users!(authorize?: false, query: [filter: [email: email], limit: 1]) do
      [user | _] -> {:ok, user}
      [] -> {:error, "No user with email #{email}"}
    end
  end

  defp resolve_org(nil), do: {:ok, Accounts.default_org_id()}

  defp resolve_org(slug) do
    # authorize?: false — the operator's --org lookup at a shell on the host, before any actor exists
    case Accounts.list_organizations!(authorize?: false, query: [filter: [slug: slug], limit: 1]) do
      [org | _] -> {:ok, org.id}
      [] -> {:error, "No organization with slug #{slug}"}
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
  @spec print_report(map(), shell()) :: :ok
  def print_report(report, shell) do
    if report.dry_run do
      shell.("── DRY RUN — nothing was written ──────────────────────────")
    end

    incomplete = Map.get(report, :incomplete, [])

    shell.("""
    Records:   #{length(report.created)} #{verb(report.dry_run, "would be created", "created")}\
    #{incomplete_note(incomplete)}, \
    #{length(report.skipped)} skipped (already present), #{length(report.failed)} failed
    Taxonomy:  #{term_line(report.taxonomy.categories)} categories, \
    #{term_line(report.taxonomy.tags)} tags
    Media:     #{media_line(report.media)}
    Redirects: #{Map.get(report.redirects, :created, 0)} \
    #{verb(report.dry_run, "would be created", "created")}\
    """)

    print_authors(shell, Map.get(report, :authors))

    print_list(shell, "Failed", report.failed, &"  #{&1.kind} #{inspect(&1.title)}: #{&1.reason}")

    # A record that landed but not as the source had it — a publish the actor
    # was not allowed to make, a state that could not be restored, a byline
    # that did not resolve. It counts as created, because it exists; saying
    # only that would leave the operator to discover the difference in the
    # editor, or not at all.
    print_list(
      shell,
      "Imported, but not as the source had it",
      incomplete,
      &"  #{&1.kind} #{inspect(&1.title)}: #{Enum.join(&1.issues, "; ")}"
    )

    print_list(
      shell,
      "Media that could not be fetched",
      Map.get(report.media, :failed, []),
      &"  #{&1.url}: #{inspect(&1.reason)}"
    )

    if report.dry_run do
      shell.("\n── DRY RUN — re-run without --dry-run to apply ────────────")
    end

    :ok
  end

  # The source's authors, and which of them resolved to a Kiln user. Printed
  # rather than counted: an operator who can only see "3 authors" cannot decide
  # whether the unmapped ones matter, and the alternative is opening the XML.
  defp print_authors(_shell, nil), do: :ok
  defp print_authors(_shell, %{found: []}), do: :ok

  defp print_authors(shell, %{found: found, mapped: mapped, unmapped: unmapped}) do
    shell.("\nAuthors (#{length(mapped)} mapped, #{length(unmapped)} unmapped):")

    for author <- found do
      mark = if author.login in mapped, do: "->", else: " ~"
      shell.("  #{mark} #{author.login} #{inspect(author.name)} <#{author.email}>")
    end

    if unmapped != [] do
      shell.(
        "  Unmapped authors' content is attributed to the acting user. " <>
          "Map them with --author-map login=kiln@email (repeatable)."
      )
    end
  end

  @doc """
  Parse repeated `--author-map login=email` flags into the map
  `KilnCMS.Portability.Import.resolve_authors/2` takes. A map (a release
  caller's `author_map: %{"jo" => "jo@example.com"}`) is checked the same way.

  A value with no `=` is rejected loudly rather than ignored: a silently dropped
  mapping looks identical to one that found no user, and the whole point of the
  flag is to be sure about attribution.
  """
  @spec author_map([String.t()] | %{optional(String.t()) => String.t()}) ::
          {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def author_map(%{} = map) do
    map
    |> Enum.map(fn {source, email} -> "#{source}=#{email}" end)
    |> author_map()
  end

  def author_map(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
      case String.split(pair, "=", parts: 2) do
        [source, email] when source != "" and email != "" ->
          {:cont, {:ok, Map.put(acc, String.trim(source), String.trim(email))}}

        _ ->
          {:halt, {:error, "--author-map expects login=email, got: #{inspect(pair)}"}}
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
  @spec maybe_drain_media(boolean() | nil, shell()) :: :ok
  def maybe_drain_media(true, shell) do
    shell.("\nDraining the media queue …")
    result = Oban.drain_queue(queue: :media, with_recursion: true)
    shell.("Media jobs: #{inspect(result)}")
    :ok
  end

  def maybe_drain_media(_other, _shell), do: :ok

  # Truncated: a failing import can fail thousands of times, and a wall of
  # identical messages buries the one line that explains why. The count in the
  # summary above is the complete number.
  @max_listed 20

  defp print_list(_shell, _heading, [], _format), do: :ok

  defp print_list(shell, heading, items, format) do
    shell.("\n#{heading} (#{length(items)}):")
    items |> Enum.take(@max_listed) |> Enum.each(&shell.(format.(&1)))

    if length(items) > @max_listed do
      shell.("  … and #{length(items) - @max_listed} more")
    end
  end

  defp incomplete_note([]), do: ""
  defp incomplete_note(incomplete), do: " (#{length(incomplete)} not as the source had it)"

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
