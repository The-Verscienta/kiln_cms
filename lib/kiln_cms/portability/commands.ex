defmodule KilnCMS.Portability.Commands do
  @moduledoc """
  The import commands themselves, shared by the mix tasks and the release.

  `mix kiln.import.wordpress`, `mix kiln.import.ghost` and
  `mix kiln.import.content` parse their flags and call these with
  `&Mix.shell().info(&1)`. `KilnCMS.Release.import_wordpress/2` and its siblings
  call them with `&IO.puts/1` on a running node, through `bin/kiln_cms rpc`,
  because a release has no Mix. Neither side carries import logic of its own,
  so a fix to either reaches both.

  Every command takes the source path, the options and a one-argument output
  function. It returns `{:ok, report}` or `{:error, message}`, and never
  raises for an operator mistake: the mix task turns the message into
  `Mix.raise/1`, the release prints it.

  ## Options

  The mix tasks' flags, as a keyword list. Unknown keys are refused, so a
  misspelt `dry_run:` cannot turn a dry run into a real import.

    * `dry_run: true`: plan only; no writes, no downloads
    * `actor: "email"`: run as this user (default: the first admin)
    * `org: "slug"`: import into this organization (default: the default org)
    * `locale: "en"`: locale for created records
    * `limit: n`: import at most `n` records
    * `skip_media: true`: do not sideload media
    * `redirects: false`: do not create redirects from old permalinks
    * `on_conflict: :error`: refuse an existing slug instead of skipping it
    * `author_map: %{"login" => "kiln@email"}` (or a list of `"login=email"`
      strings): who wrote what (WordPress and Ghost)
    * `drain_media: true`: run the queued image-variant jobs before returning
    * `site_url: "https://…"`: the Ghost site's address (Ghost only)
    * `type: "listing"`: the content type of a CSV file (envelope only)
  """

  alias KilnCMS.Portability.CLI
  alias KilnCMS.Portability.CSV
  alias KilnCMS.Portability.Ghost
  alias KilnCMS.Portability.Import
  alias KilnCMS.Portability.WXR

  @type shell :: (String.t() -> any())
  @type result :: {:ok, map()} | {:error, String.t()}

  @common [
    :dry_run,
    :actor,
    :org,
    :locale,
    :limit,
    :skip_media,
    :redirects,
    :on_conflict,
    :drain_media
  ]

  @doc "Import a WordPress WXR export. See `Mix.Tasks.Kiln.Import.Wordpress`."
  @spec import_wordpress(Path.t(), keyword(), shell()) :: result()
  def import_wordpress(path, opts, shell) do
    with {:ok, opts} <- validate(opts, [:author_map | @common]),
         {:ok, parsed} <- parse_wxr(path) do
      shell.("""
      Read #{length(parsed.records)} importable records, \
      #{length(parsed.attachments)} attachments, #{length(parsed.authors)} authors\
      #{wordpress_site_line(parsed.site)}
      """)

      import_parsed(parsed, opts, shell)
    end
  end

  defp parse_wxr(path) do
    case WXR.parse_file(path) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, {:too_large, size, max}} ->
        {:error,
         """
         #{path} is #{div(size, 1_048_576)} MB; the parser's ceiling is #{div(max, 1_048_576)} MB.

         WXR is expanded to a charlist at roughly 16 bytes per source byte before
         parsing, so a file this size would exhaust memory with no partial
         progress. Use WordPress's own split export (Tools -> Export produces one
         file per post type / date range) and run this task once per file —
         re-running is safe, because what already landed is skipped.
         """}

      {:error, reason} ->
        {:error, "Could not read #{path}: #{inspect(reason)}"}
    end
  end

  defp wordpress_site_line(%{title: title, url: url}) when is_binary(title),
    do: "\nSource site: #{title}#{if url, do: " (#{url})", else: ""}"

  defp wordpress_site_line(_site), do: ""

  @doc "Import a Ghost JSON export. See `Mix.Tasks.Kiln.Import.Ghost`."
  @spec import_ghost(Path.t(), keyword(), shell()) :: result()
  def import_ghost(path, opts, shell) do
    with {:ok, opts} <- validate(opts, [:author_map, :site_url | @common]),
         {:ok, parsed} <- parse_ghost(path, opts[:site_url]) do
      shell.("""
      Read #{length(parsed.records)} importable records, \
      #{length(parsed.attachments)} feature images, #{length(parsed.authors)} authors\
      #{ghost_site_line(parsed.site)}
      """)

      print_ghost_notes(parsed, shell)
      import_parsed(parsed, opts, shell)
    end
  end

  defp parse_ghost(path, site_url) do
    case Ghost.parse_file(path, site_url: site_url) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, :site_url_required} ->
        {:error,
         """
         #{path} writes the Ghost site's own URLs as __GHOST_URL__, so its images
         cannot be fetched without the site's address. Pass it:

             mix kiln.import.ghost #{path} --site-url https://your-ghost-site.example

         or, from a release:

             bin/kiln_cms rpc 'KilnCMS.Release.import_ghost("#{path}", site_url: "https://your-ghost-site.example")'
         """}

      {:error, :not_a_ghost_export} ->
        {:error,
         """
         #{path} is JSON, but not a Ghost export: there is no db[0].data.posts.
         Export it from Ghost Admin → Settings → Import/Export → Export content.
         """}

      {:error, {:too_large, size, max}} ->
        {:error,
         """
         #{path} is #{div(size, 1_048_576)} MB; the importer's ceiling is \
         #{div(max, 1_048_576)} MB. Run it where it can be read whole, or ask on
         the issue tracker — no Ghost export this size has been seen yet.
         """}

      {:error, reason} ->
        {:error, "Could not read #{path}: #{inspect(reason)}"}
    end
  end

  # Decisions the parser made that the report cannot show — a scheduled post
  # landing as a draft — and the posts it could not read at all.
  defp print_ghost_notes(parsed, shell) do
    notes = for %{note: note} = record <- parsed.records, is_binary(note), do: {record, note}

    if notes != [] do
      shell.("Not as Ghost had it (#{length(notes)}):")
      for {record, note} <- notes, do: shell.("  ~ #{record.title}: #{note}")
      shell.("")
    end

    if parsed.unreadable != [] do
      shell.("Unreadable, not imported (#{length(parsed.unreadable)}):")

      for %{title: title, reason: reason} <- parsed.unreadable,
          do: shell.("  x #{title}: #{reason}")

      shell.("")
    end
  end

  defp ghost_site_line(%{title: title, url: url, version: version}) do
    [
      title && "\nSource site: #{title}",
      url && " (#{url})",
      version && "\nGhost version: #{version}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join()
  end

  # The WordPress and Ghost tail: who the run acts as, the import, the report.
  defp import_parsed(parsed, opts, shell) do
    with {:ok, scope} <- CLI.scope(opts, shell),
         {:ok, author_map} <- opts |> author_map_values() |> CLI.author_map() do
      run_opts =
        scope ++
          [
            dry_run: Keyword.get(opts, :dry_run, false),
            skip_media: Keyword.get(opts, :skip_media, false),
            redirects: Keyword.get(opts, :redirects, true),
            locale: Keyword.get(opts, :locale, "en"),
            on_conflict: on_conflict(opts[:on_conflict]),
            author_map: author_map
          ] ++ maybe(:limit, opts[:limit])

      # `run/2` reports per-record failures inside the report rather than
      # failing the run — one unimportable post must not abandon the other 3,999.
      {:ok, report} = Import.run(parsed, run_opts)
      finish(report, opts, shell)
    end
  end

  # A mix task passes one `author_map:` per `--author-map` flag; a release
  # caller passes one map, or one list of "login=email" strings.
  defp author_map_values(opts) do
    case Keyword.get_values(opts, :author_map) do
      [%{} = map] -> map
      values -> List.flatten(values)
    end
  end

  @doc """
  Load a portable JSON envelope, or a CSV file with `type:`. See
  `Mix.Tasks.Kiln.Import.Content`.
  """
  @spec import_content(Path.t(), keyword(), shell()) :: result()
  def import_content(path, opts, shell) do
    with {:ok, opts} <- validate(opts, [:type | @common]),
         {:ok, envelope} <- read_envelope(path, opts, shell) do
      records = envelope |> Map.get("records", []) |> length()
      shell.("Read #{records} records from the envelope\n")
      import_envelope(envelope, opts, shell)
    end
  end

  # CSV is one type per file and carries no type column, so `type:` names it.
  defp read_envelope(path, opts, shell) do
    if String.ends_with?(path, ".csv"), do: read_csv(path, opts, shell), else: read_json(path)
  end

  # The path is the operator's own argument.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_csv(path, opts, shell) do
    with {:ok, type} <- require_type(opts[:type]),
         {:ok, text} <- File.read(path),
         {:ok, scope} <- CLI.scope(opts, shell),
         {:ok, records} <- CSV.decode(text, type, scope) do
      {:ok, %{"records" => records}}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, :empty} ->
        {:error, "#{path} has no rows"}

      {:error, {:unknown_columns, columns}} ->
        {:error,
         """
         #{path} has columns this type does not define: #{Enum.join(columns, ", ")}

         Expected: title, slug, locale, state, plus this type's fields. A header
         typo would otherwise import every row with that field silently empty.
         """}

      {:error, reason} ->
        {:error, "Could not read #{path}: #{inspect(reason)}"}
    end
  end

  defp require_type(nil), do: {:error, "--type is required for a CSV import"}
  defp require_type(type), do: {:ok, type}

  # The path is the operator's own argument.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_json(path) do
    with {:ok, json} <- File.read(path),
         {:ok, envelope} <- Jason.decode(json) do
      {:ok, envelope}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "#{path} is not valid JSON: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "Could not read #{path}: #{inspect(reason)}"}
    end
  end

  defp import_envelope(envelope, opts, shell) do
    with {:ok, scope} <- CLI.scope(opts, shell) do
      run_opts =
        scope ++
          [
            dry_run: Keyword.get(opts, :dry_run, false),
            skip_media: Keyword.get(opts, :skip_media, false),
            redirects: Keyword.get(opts, :redirects, true),
            on_conflict: on_conflict(opts[:on_conflict]),
            progress: shell
          ] ++ maybe(:locale, opts[:locale]) ++ maybe(:limit, opts[:limit])

      case Import.run_envelope(envelope, run_opts) do
        {:ok, report} -> finish(report, opts, shell)
        {:error, :not_an_export_envelope} -> {:error, "That file has no \"records\" array"}
      end
    end
  end

  defp finish(report, opts, shell) do
    CLI.print_report(report, shell)
    CLI.maybe_drain_media(opts[:drain_media], shell)
    {:ok, report}
  end

  # The mix tasks parse with `strict:`, so this only ever refuses a release
  # caller's typo. Repeated keys (a mix task's `--author-map`, kept) survive.
  defp validate(opts, allowed) do
    case Keyword.keys(opts) -- allowed do
      [] ->
        {:ok, opts}

      unknown ->
        {:error,
         "Unknown option(s) #{unknown |> Enum.uniq() |> Enum.map_join(", ", &inspect/1)}; " <>
           "expected some of #{Enum.map_join(allowed, ", ", &inspect/1)}"}
    end
  end

  defp on_conflict(value) when value in [:error, "error"], do: :error
  defp on_conflict(_other), do: :skip

  defp maybe(_key, nil), do: []
  defp maybe(key, value), do: [{key, value}]
end
