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

  The golden-set path is read as given — no globbing, no directory walk, no
  expansion — and must be a regular file.
  """
  @shortdoc "Scores search ranking against a golden set (recall@k, MRR per class)"

  use Mix.Task

  alias KilnCMS.Search.Eval
  alias KilnCMS.Search.Eval.Retriever

  @switches [
    k: :string,
    ask: :boolean,
    url: :string,
    org: :string,
    locale: :string,
    json: :boolean,
    fail_below: :keep
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

    {source, retrieve} = retriever(opts, ks)

    report = Eval.report(rows, retrieve, ks)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(Eval.to_json_map(report, source: source), pretty: true))
    else
      Mix.shell().info(Eval.format_text(report, source: source))
    end

    case System.get_env("GITHUB_STEP_SUMMARY") do
      nil -> :ok
      summary -> File.write!(summary, Eval.format_markdown(report, source: source), [:append])
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

  # Only the HTTP mode leaves the application down: it measures a deployment,
  # not this database, and an operator pointing the task at production should
  # not need a local Postgres to do it.
  defp retriever(opts, ks) do
    limit = Enum.max(ks)
    locale = opts[:locale]

    case opts[:url] do
      nil ->
        Mix.Task.run("app.start")
        tenant = resolve_org(opts[:org])

        if opts[:ask] do
          {"ask (in-process)", &Retriever.ask(&1, tenant: tenant, limit: limit, locale: locale)}
        else
          {"global (in-process)",
           &Retriever.global(&1, tenant: tenant, limit: limit, locale: locale)}
        end

      url ->
        base_url = validate_url(url)
        Mix.Task.run("app.config")
        {:ok, _apps} = Application.ensure_all_started(:req)
        endpoint = if opts[:ask], do: "/api/ask", else: "/api/search"

        {"#{base_url}#{endpoint}",
         &Retriever.remote(&1,
           base_url: base_url,
           ask: opts[:ask] || false,
           limit: limit,
           locale: locale
         )}
    end
  end

  defp resolve_org(nil), do: KilnCMS.Accounts.default_org_id()

  defp resolve_org(slug) do
    # Operator-run task resolving the org it was told to evaluate — the
    # organization registry has no anonymous read, and this is not a request.
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
