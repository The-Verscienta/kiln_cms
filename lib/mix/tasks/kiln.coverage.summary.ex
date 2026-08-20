defmodule Mix.Tasks.Kiln.Coverage.Summary do
  @moduledoc """
  Rolls the line-coverage report up per directory (#1314).

  `mix coveralls.*` prints one row per file — a thousand-plus lines that say
  nothing about *where* the tests land. This reads the JSON report it wrote
  (`cover/excoveralls.json`) and prints one row per source directory instead,
  so the editor / delivery / governance split is visible at a glance:

      directory                            files  relevant  covered      %
      lib/kiln_cms/cms                         N         N        N    N.N
      lib/kiln_cms/firing                      N         N        N    N.N
      lib/kiln_cms_web/live                    N         N        N    N.N
      …
      TOTAL                                    N         N        N    N.N

  A file is grouped by its directory, truncated to depth 3 (`lib/<app>/<sub>`,
  `projects/<name>/<sub>`), so a deep tree rolls up under its feature
  directory rather than scattering across leaves. Files directly under
  `lib/<app>/` roll up as `lib/<app>` itself.

  Under GitHub Actions the same table is appended to the job summary
  (`$GITHUB_STEP_SUMMARY`) as Markdown, so it is readable without opening the
  log.

  This is a *report*, not the gate. The floor is `minimum_coverage` in
  `coveralls.json`, which `mix coveralls.*` enforces itself.

      mix kiln.coverage.summary
      mix kiln.coverage.summary --report cover/excoveralls.json --depth 3
  """
  @shortdoc "Prints line coverage rolled up per source directory"

  use Mix.Task

  @default_report "cover/excoveralls.json"
  @default_depth 3

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [report: :string, depth: :integer])

    report = Keyword.get(opts, :report, @default_report)
    depth = Keyword.get(opts, :depth, @default_depth)

    if depth < 1 do
      Mix.raise("--depth must be a positive integer, got: #{depth}")
    end

    files =
      case File.read(report) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, %{"source_files" => files}} ->
              files

            _ ->
              # A `cover/` left over from another tool, or a half-written file
              # from a killed run. `Map.fetch!/2`'s KeyError named neither the
              # path nor the fix, right next to a sibling error that does both.
              Mix.raise(
                "#{report} is not an excoveralls JSON report (no \"source_files\"). " <>
                  "Delete it and re-run `mix coveralls.multiple --type json …`."
              )
          end

        {:error, reason} ->
          Mix.raise(
            "Cannot read #{report} (#{:file.format_error(reason)}). " <>
              "Run `mix coveralls.json` (or `mix coveralls.multiple --type json …`) first."
          )
      end

    rows = summarize(files, depth)

    Mix.shell().info(format_table(rows))

    case System.get_env("GITHUB_STEP_SUMMARY") do
      nil -> :ok
      path -> File.write!(path, format_markdown(rows), [:append])
    end
  end

  @typedoc "One aggregated row: `{directory, files, relevant, covered}`."
  @type row :: {String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  Aggregates excoveralls `source_files` entries per directory.

  Each entry is `%{"name" => path, "coverage" => [nil | integer, …]}` — one
  slot per source line, `nil` for a line the tracer considers irrelevant, else
  the number of times it ran. Returns rows sorted by directory, with a final
  `"TOTAL"` row. Directories are truncated to `depth` segments.
  """
  @spec summarize([map()], pos_integer()) :: [row()]
  def summarize(files, depth \\ @default_depth) do
    groups = Enum.group_by(files, &group_for(&1["name"], depth))
    rows = for {dir, entries} <- Enum.sort(groups), do: row(dir, entries)
    rows ++ [row("TOTAL", files)]
  end

  # One aggregated row: nil is irrelevant, 0 relevant-but-uncovered, n > 0 covered.
  defp row(dir, entries) do
    {relevant, covered} =
      Enum.reduce(entries, {0, 0}, fn %{"coverage" => lines}, acc ->
        Enum.reduce(lines, acc, fn
          nil, acc -> acc
          0, {rel, cov} -> {rel + 1, cov}
          _hits, {rel, cov} -> {rel + 1, cov + 1}
        end)
      end)

    {dir, length(entries), relevant, covered}
  end

  @doc """
  The directory a source path rolls up under: its dirname, truncated to
  `depth` path segments.

      iex> group_for("lib/kiln_cms/firing/scheduler/worker.ex", 3)
      "lib/kiln_cms/firing"
      iex> group_for("lib/kiln_cms/repo.ex", 3)
      "lib/kiln_cms"
  """
  @spec group_for(String.t(), pos_integer()) :: String.t()
  def group_for(path, depth) do
    path
    |> Path.dirname()
    |> Path.split()
    |> Enum.take(depth)
    |> Path.join()
  end

  @doc """
  Percentage covered, FLOORED to one decimal — the same arithmetic, in the
  same order, as excoveralls' `Stats.get_coverage/2` under `floor_coverage`
  (its default, and what coveralls.json sets), so this table and the `[TOTAL]`
  line the gate compares against `minimum_coverage` never disagree by a
  rounding step. The order matters: `covered / relevant * 100` and
  `covered * 100 / relevant` floor differently for thousands of pairs (29/100
  is 28.9 one way and 29.0 the other).

  Undefined when nothing is relevant — see `format_pct/2`.
  """
  @spec percent(non_neg_integer(), pos_integer()) :: float()
  def percent(covered, relevant) when relevant > 0,
    do: Float.floor(covered / relevant * 100, 1)

  # A directory with no relevant lines has no percentage, so this prints an em
  # dash rather than inventing a number. excoveralls substitutes its
  # `treat_no_relevant_lines_as_covered` setting at exactly this point (0.0,
  # or 100.0 when that is on) — matching it would mean re-reading its config
  # here, and `ExCoveralls.Settings` is a `only: :test` dependency this module
  # cannot call without breaking the dev build. Declining to guess is the one
  # answer that cannot disagree with the gate whatever that setting says, and
  # "no measurable lines" is what a reader should see anyway, not "0% covered".
  @doc false
  def format_pct(_covered, 0), do: "—"

  def format_pct(covered, relevant),
    do: :erlang.float_to_binary(percent(covered, relevant), decimals: 1)

  @doc false
  def format_table(rows) do
    width = Enum.reduce(rows, String.length("directory"), &max(String.length(elem(&1, 0)), &2))

    header =
      String.pad_trailing("directory", width) <>
        "  files  relevant   covered       %"

    lines =
      Enum.map(rows, fn {dir, files, relevant, covered} ->
        String.pad_trailing(dir, width) <>
          String.pad_leading(Integer.to_string(files), 7) <>
          String.pad_leading(Integer.to_string(relevant), 10) <>
          String.pad_leading(Integer.to_string(covered), 10) <>
          String.pad_leading(format_pct(covered, relevant), 8)
      end)

    Enum.join(["Coverage by directory:", header | lines], "\n")
  end

  @doc false
  def format_markdown(rows) do
    body =
      Enum.map_join(rows, "\n", fn {dir, files, relevant, covered} ->
        name = if dir == "TOTAL", do: "**TOTAL**", else: "`#{dir}`"

        "| #{name} | #{files} | #{relevant} | #{covered} | " <>
          "#{format_pct(covered, relevant)} |"
      end)

    """
    ### Coverage by directory

    | directory | files | relevant | covered | % |
    | --- | ---: | ---: | ---: | ---: |
    #{body}

    """
  end
end
