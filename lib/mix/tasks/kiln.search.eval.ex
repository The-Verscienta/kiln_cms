defmodule Mix.Tasks.Kiln.Search.Eval do
  @moduledoc """
  Scores the search ranking against a golden set: recall@k and MRR per query
  class, and the rank every expected record landed at.

      mix kiln.search.eval priv/search_eval/example.json
      mix kiln.search.eval golden.json --ask
      mix kiln.search.eval golden.json --url https://example.com --json > after.json
      mix kiln.search.eval golden.json --fail-below single_entity=0.9@5 --fail-below junk=1.0

  The golden set is a JSON array of `{query, expected, class}` rows — the
  format is documented on `KilnCMS.Search.Eval`, and `priv/search_eval/
  example.json` is one written against the demo seeds. Classes are
  `single_entity`, `multi_entity`, `paraphrase`, `question_form`, `typo` and
  `junk`; a junk row expects nothing and passes only when nothing comes back.

  ## What is measured

  By default each query runs in-process through `KilnCMS.Search.global/2`
  over the content sections, read the way `GET /api/search` reads: anonymous
  and published-only. The sections are sorted together by fused score, and a
  row's `type` narrows the ranking to one content type. `--ask` runs
  `KilnCMS.Ask.answer/2` instead and judges the order its `sources` come in
  (generation stays off). `--url BASE` leaves the local database out of it
  and reads a live deployment's `/api/search` (or `/api/ask` with `--ask`)
  over HTTP, scoring the `score`/`legs` fields those endpoints carry.

  ## Output and exit status

  A summary table per class and overall, then one block per query naming
  the rank of each expected slug (or `missing`) and the legs that found it —
  the part that says *why* a number moved. `--json` prints the same as JSON
  for diffing runs before and after a change. Under GitHub Actions the table
  is also appended to the job summary.

  The exit status is **0 whatever the numbers**, unless `--fail-below` sets a
  threshold: the report is wired into CI as a report, not a gate, until a
  deployment's baselines have settled. `--fail-below CLASS=MIN[@K]` (repeatable;
  `CLASS` may be `overall`; `K` defaults to the largest `--k`) then makes the
  task fail when that class's recall@K is under `MIN`.

  ## Options

    * `--k 1,3,5,10` — the cutoffs to report (default `1,3,5,10`).
    * `--ask` — judge `/api/ask`'s source order instead of the search sections.
    * `--url BASE` — evaluate a live deployment over HTTP instead of this database.
    * `--org SLUG` — the organization to search within (default: the default org).
    * `--locale L` — the content locale for rows that carry none.
    * `--json` — print the report as JSON.
    * `--fail-below CLASS=MIN[@K]` — fail when a class's recall@K is below MIN.
    * `--ef-search N` — scan the HNSW index with `hnsw.ef_search = N` (1..1000).
    * `--exact` — bypass the HNSW index: exact vector search (see below).

  ## How the vector legs were scanned

  The header names the scan mode the semantic legs ran under, read back from
  the database connection — `exact`, or approximate at some `hnsw.ef_search` —
  and the JSON carries it as `scan`, so a number is never separated from how it
  was measured. Approximate below ef_search 200 is flagged: pgvector's default
  of 40 can drop a row nearer than the ones it returns, which is noise in a
  before/after comparison. **Measurement runs use `--ef-search 200` or
  `--exact`** (`KilnCMS.Search.VectorScan` explains both, and what exact costs).

  The flags apply to this run's own connections only, and override
  `KILN_HNSW_EF_SEARCH` / `KILN_VECTOR_SEARCH_EXACT`; without them the
  configured mode is used and reported. They cannot reach a `--url` server,
  so combining them is refused: there the scan mode is the server's, the
  report says so, and the env vars are the way to set it.

  The golden-set path is read as given — no globbing, no directory walk, no
  expansion — and must be a regular file.
  """
  @shortdoc "Scores search ranking against a golden set (recall@k, MRR per class)"

  use Mix.Task

  alias KilnCMS.Search.Eval
  alias KilnCMS.Search.Eval.Retriever
  alias KilnCMS.Search.VectorScan

  @switches [
    k: :string,
    ask: :boolean,
    url: :string,
    org: :string,
    locale: :string,
    json: :boolean,
    fail_below: :keep,
    ef_search: :integer,
    exact: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)

    path =
      case positional do
        [path] -> path
        _other -> Mix.raise("usage: mix kiln.search.eval GOLDEN_SET.json [options]")
      end

    ks = parse_ks(Keyword.get(opts, :k))
    thresholds = parse_thresholds(Keyword.get_values(opts, :fail_below), Enum.max(ks))
    rows = read_golden_set(path)

    scan_mode = scan_mode(opts)

    {source, scan, retrieve} = retriever(opts, ks, scan_mode)

    report = Eval.report(rows, retrieve, ks)
    render_opts = [source: source, scan: scan]

    if opts[:json] do
      Mix.shell().info(Jason.encode!(Eval.to_json_map(report, render_opts), pretty: true))
    else
      Mix.shell().info(Eval.format_text(report, render_opts))
    end

    case System.get_env("GITHUB_STEP_SUMMARY") do
      nil -> :ok
      summary -> File.write!(summary, Eval.format_markdown(report, render_opts), [:append])
    end

    case Eval.failures(report.summary, thresholds) do
      [] ->
        :ok

      failures ->
        Mix.raise(
          "search eval below threshold:\n" <>
            Enum.map_join(failures, "\n", fn f ->
              "  #{f.class} recall@#{f.k} = #{format(f.actual)} < #{format(f.min)}"
            end)
        )
    end
  end

  # `--ef-search` / `--exact`, validated before anything starts. A `--url` run
  # cannot apply either — the server's connections are not ours — so asking
  # for one there is refused rather than printed under a label it never had.
  defp scan_mode(opts) do
    mode =
      try do
        VectorScan.from_flags!(opts)
      rescue
        error in ArgumentError -> Mix.raise(Exception.message(error))
      end

    if mode != :default and opts[:url] do
      Mix.raise(
        "--ef-search/--exact set this process's database connections, and a --url run " <>
          "uses the server's. Set KILN_HNSW_EF_SEARCH or KILN_VECTOR_SEARCH_EXACT on " <>
          "that deployment instead."
      )
    end

    mode
  end

  # Only the HTTP mode leaves the application down: it measures a deployment,
  # not this database, and an operator pointing the task at production should
  # not need a local Postgres to do it.
  #
  # The scan mode is written between `app.config` (which would overwrite it from
  # runtime.exs) and `app.start` (whose repo `init/2` reads it), then read back
  # from a live connection: the header reports what the legs ran under, and
  # `check!/2` refuses a flag that did not take.
  defp retriever(opts, ks, scan_mode) do
    limit = Enum.max(ks)
    locale = opts[:locale]

    case opts[:url] do
      nil ->
        Mix.Task.run("app.config")
        VectorScan.put_repo_config(scan_mode)
        Mix.Task.run("app.start")
        scan = VectorScan.effective()
        check_scan!(scan_mode, scan)
        tenant = resolve_org(opts[:org])

        if opts[:ask] do
          {"ask (in-process)", scan,
           &Retriever.ask(&1, tenant: tenant, limit: limit, locale: locale)}
        else
          {"global (in-process)", scan,
           &Retriever.global(&1, tenant: tenant, limit: limit, locale: locale)}
        end

      url ->
        base_url = validate_url(url)
        Mix.Task.run("app.config")
        {:ok, _apps} = Application.ensure_all_started(:req)
        endpoint = if opts[:ask], do: "/api/ask", else: "/api/search"

        {"#{base_url}#{endpoint}", :remote,
         &Retriever.remote(&1,
           base_url: base_url,
           ask: opts[:ask] || false,
           limit: limit,
           locale: locale
         )}
    end
  end

  defp check_scan!(mode, scan) do
    VectorScan.check!(mode, scan)
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  defp resolve_org(nil), do: KilnCMS.Accounts.default_org_id()

  defp resolve_org(slug) do
    # authorize?: false — an operator-run task resolving the org it was told
    # to evaluate (#1659): the organization registry has no anonymous read, the
    # operator is no member, and this is not a request.
    case KilnCMS.Accounts.get_organization_by_slug(slug, authorize?: false) do
      {:ok, %{id: id}} -> id
      _none -> Mix.raise("no organization with slug #{inspect(slug)}")
    end
  end

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        String.trim_trailing(url, "/")

      _other ->
        Mix.raise("--url must be an http(s) base URL, got: #{url}")
    end
  end

  defp parse_ks(nil), do: Eval.default_ks()

  defp parse_ks(spec) do
    ks =
      spec
      |> String.split(",", trim: true)
      |> Enum.map(fn part ->
        case Integer.parse(String.trim(part)) do
          {k, ""} when k > 0 -> k
          _other -> Mix.raise("--k expects positive integers separated by commas, got: #{spec}")
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    if ks == [], do: Mix.raise("--k expects at least one cutoff"), else: ks
  end

  defp parse_thresholds(specs, default_k) do
    Enum.map(specs, fn spec ->
      case Eval.parse_threshold(spec, default_k) do
        {:ok, threshold} -> threshold
        {:error, reason} -> Mix.raise(reason)
      end
    end)
  end

  defp read_golden_set(path) do
    unless File.regular?(path) do
      Mix.raise("#{path} is not a file")
    end

    with {:ok, json} <- File.read(path),
         {:ok, rows} <- Eval.parse(json) do
      rows
    else
      {:error, reason} when is_atom(reason) ->
        Mix.raise("cannot read #{path}: #{:file.format_error(reason)}")

      {:error, reason} ->
        Mix.raise("#{path}: #{reason}")
    end
  end

  defp format(nil), do: "n/a"
  defp format(value), do: :erlang.float_to_binary(value, decimals: 3)
end
