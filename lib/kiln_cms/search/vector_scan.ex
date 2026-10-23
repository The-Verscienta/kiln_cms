defmodule KilnCMS.Search.VectorScan do
  @moduledoc """
  How every vector query on a `KilnCMS.Repo` connection is scanned: the
  per-connection `SET`s the repo's `after_connect` callback issues, and the
  knob that changes them for **measurement runs**.

  ## Three modes

    * **default** (nothing configured) — `hnsw.iterative_scan = strict_order`
      and nothing else, exactly what every release before this module sent.
      The HNSW index serves the query with pgvector's default `hnsw.ef_search`
      of 40: fast, and *approximate*. See the #998 comment on
      `KilnCMS.Repo` and docs/semantic-search-plan.md for why `strict_order`.
    * **`ef_search: N`** — the same, plus `SET hnsw.ef_search = N` (1..1000,
      pgvector's legal range). Each batch the index walks is N candidates wide
      instead of 40, which buys recall back at a latency cost. Still
      approximate, however large N is: HNSW is a graph walk, and a wider beam
      makes a miss less likely, not impossible.
    * **`exact: true`** — the same, plus `SET enable_indexscan = off`. Every
      vector query becomes a sequential scan and a sort by true distance, so
      the result is the exact nearest set, with no approximate-recall loss.

  ```elixir
  config :kiln_cms, KilnCMS.Repo, vector_scan: [ef_search: 200]
  config :kiln_cms, KilnCMS.Repo, vector_scan: [exact: true]
  ```

  or, in any environment, `KILN_HNSW_EF_SEARCH=200` / `KILN_VECTOR_SEARCH_EXACT=true`
  (read by `config/runtime/search.exs`). Setting both is **refused**, not
  resolved: a run that asked for two different things would have its numbers
  labelled with only one of them.

  ## Why measurement runs need one

  Search changes are judged on recall@k and MRR (`mix kiln.search.eval`,
  `mix kiln.search.measure_floor`). At `ef_search = 40` the semantic legs can
  drop a row that is genuinely nearer than one they return — so a number moves
  for a reason that has nothing to do with the change being measured, and two
  runs of the same code can disagree. Pre-registered comparisons (#1936, #1937,
  an embedder decision) need that noise gone: ef_search 200 makes it small,
  exact mode makes it zero.

  ## How exact mode works, and what it costs

  pgvector does an exact search whenever the planner does not use the vector
  index, and an HNSW index can serve a query in exactly one way: an ordered
  **index scan** (`ORDER BY embedding <=> q LIMIT n`). It has no bitmap-scan
  support (its access method leaves `amgetbitmap` unset), so
  `enable_indexscan = off` alone removes it from every plan — and leaves
  `enable_bitmapscan` on, which is what keeps every **btree** index usable:
  tenant, slug and primary-key lookups become `Bitmap Index Scan` +
  `Bitmap Heap Scan` on the same index instead of a plain index scan. Verified
  with `EXPLAIN` on PostgreSQL 17 (`test/kiln_cms/search/vector_scan_test.exs`
  pins it).

  It is still connection-wide, and that is the cost. Nothing the planner served
  with an *ordered* btree walk gets one any more — an `ORDER BY … LIMIT` on an
  indexed column (Oban's job fetch, the newest-first lists) reads every matching
  row and sorts — and every vector query reads its whole filtered set. Fine on a
  measurement replica; **not** for a deployment serving traffic.

  Narrower options were weighed and rejected:

    * *Per-query* (`SET LOCAL` around each vector read, or an `ORDER BY` the
      operator class cannot match): the vector legs are spread over the content
      resources, `BlockEmbedding`, `TagEmbedding`, `Related` and `Search`, so it
      is a list to forget an entry on — the very reason `iterative_scan` is per
      connection.
    * *Hiding the index* (`hypopg_hide_index`) needs an extension the stack does
      not ship. *Dropping* the HNSW indexes on the replica is exact too, and
      narrower — but it is a schema change an env var cannot undo, and the next
      `mix ash.migrate` would not put them back.
    * *A huge `ef_search`* is not exact (see above).
  """

  @ef_search_range 1..1000
  @pgvector_default_ef_search 40

  # Measurement runs (#1936, #1937, verscienta-base#894) are pre-registered at
  # ef_search 200 or exact; anything approximate below that is labelled so.
  @measurement_ef_search 200

  @base_statement "SET hnsw.iterative_scan = strict_order"

  @typedoc "A validated scan mode."
  @type mode :: :default | {:ef_search, pos_integer()} | :exact

  @typedoc "What a connection actually reports, from `effective/1`."
  @type effective :: %{
          exact: boolean(),
          ef_search: pos_integer(),
          ef_search_set: boolean(),
          iterative_scan: String.t()
        }

  @doc "pgvector's legal `hnsw.ef_search` range."
  @spec ef_search_range() :: Range.t()
  def ef_search_range, do: @ef_search_range

  @doc "The `ef_search` a measurement run is expected to use, short of exact."
  @spec measurement_ef_search() :: pos_integer()
  def measurement_ef_search, do: @measurement_ef_search

  @doc """
  Validates a `vector_scan:` keyword (or `nil`) into a mode.

  Raises `ArgumentError` on an unknown key, an out-of-range or non-integer
  `ef_search`, a non-boolean `exact`, or both at once — this runs at boot
  (the repo's `init/2`), and a measurement knob that silently fell back to
  the default would produce exactly the numbers it exists to prevent.

      iex> KilnCMS.Search.VectorScan.normalize!(nil)
      :default

      iex> KilnCMS.Search.VectorScan.normalize!(ef_search: 200)
      {:ef_search, 200}

      iex> KilnCMS.Search.VectorScan.normalize!(exact: true)
      :exact

      iex> KilnCMS.Search.VectorScan.normalize!(exact: false)
      :default
  """
  @spec normalize!(keyword() | nil) :: mode()
  def normalize!(nil), do: :default

  def normalize!(opts) when is_list(opts) do
    case Keyword.keys(opts) -- [:ef_search, :exact] do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown vector_scan option(s): #{inspect(unknown)}"
    end

    mode(Keyword.get(opts, :ef_search), Keyword.get(opts, :exact, false))
  end

  def normalize!(other) do
    raise ArgumentError, "vector_scan must be a keyword list, got: #{inspect(other)}"
  end

  defp mode(_ef_search, exact) when not is_boolean(exact) do
    raise ArgumentError, "vector_scan exact: must be a boolean, got: #{inspect(exact)}"
  end

  defp mode(nil, false), do: :default
  defp mode(nil, true), do: :exact

  defp mode(_ef_search, true) do
    raise ArgumentError, """
    vector_scan sets both ef_search and exact. They are two different \
    measurements: exact bypasses the HNSW index, so ef_search would be \
    ignored and the run labelled with the wrong one. Set one \
    (KILN_HNSW_EF_SEARCH or KILN_VECTOR_SEARCH_EXACT, --ef-search or --exact).\
    """
  end

  defp mode(n, false) when is_integer(n) and n in @ef_search_range, do: {:ef_search, n}

  defp mode(bad, false) do
    raise ArgumentError,
          "vector_scan ef_search: must be an integer in " <>
            "#{@ef_search_range.first}..#{@ef_search_range.last} " <>
            "(pgvector's range), got: #{inspect(bad)}"
  end

  @doc """
  The statements one connection runs, in order. One per `Postgrex.query/3`:
  the extended protocol takes one statement at a time, so a semicolon-joined
  pair is a syntax error, not two settings.

  The default is the single statement every earlier release sent.

      iex> KilnCMS.Search.VectorScan.statements(:default)
      ["SET hnsw.iterative_scan = strict_order"]

      iex> KilnCMS.Search.VectorScan.statements({:ef_search, 200})
      ["SET hnsw.iterative_scan = strict_order", "SET hnsw.ef_search = 200"]

      iex> KilnCMS.Search.VectorScan.statements(:exact)
      ["SET hnsw.iterative_scan = strict_order", "SET enable_indexscan = off"]
  """
  @spec statements(mode()) :: [String.t()]
  def statements(:default), do: [@base_statement]

  # Interpolated, because `SET` takes no bind parameters — safe only because
  # `normalize!/1` has already proved `n` an integer in range.
  def statements({:ef_search, n}) when is_integer(n) and n in @ef_search_range,
    do: [@base_statement, "SET hnsw.ef_search = #{n}"]

  def statements(:exact), do: [@base_statement, "SET enable_indexscan = off"]

  @doc """
  The mode the `--ef-search N` / `--exact` flags of a search task ask for, from
  `OptionParser` output. Same rules as `normalize!/1`, both flags included.
  """
  @spec from_flags!(keyword()) :: mode()
  def from_flags!(opts) when is_list(opts) do
    normalize!(ef_search: opts[:ef_search], exact: opts[:exact] || false)
  end

  @doc """
  Writes `mode` into `KilnCMS.Repo`'s application config, over whatever
  `vector_scan:` was configured (the env var included), so the pool started
  next connects with it. A no-op for `:default` — no flag leaves the
  deployment's own setting in force. Run after `app.config` (which would
  otherwise overwrite it) and before `app.start`.
  """
  @spec put_repo_config(mode()) :: :ok
  def put_repo_config(:default), do: :ok

  def put_repo_config(mode) do
    config = Application.get_env(:kiln_cms, KilnCMS.Repo, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Repo,
      Keyword.put(config, :vector_scan, to_config(mode))
    )
  end

  @doc """
  A mode back as the `vector_scan:` keyword that produces it.

  Every key is written, the one the mode turns off included. Runtime config is
  deep-merged over compiled config key by key, so `[exact: true]` from
  `KILN_VECTOR_SEARCH_EXACT` over a compiled `[ef_search: 150]` would merge
  into both and refuse to boot (#2019). Writing the other key as off makes the
  env var's mode replace the compiled one; `normalize!/1` reads
  `ef_search: nil` as unset and `exact: false` as off.

      iex> KilnCMS.Search.VectorScan.to_config({:ef_search, 200})
      [ef_search: 200, exact: false]

      iex> KilnCMS.Search.VectorScan.to_config(:exact)
      [ef_search: nil, exact: true]
  """
  @spec to_config(mode()) :: keyword()
  def to_config(:default), do: []
  def to_config({:ef_search, n}), do: [ef_search: n, exact: false]
  def to_config(:exact), do: [ef_search: nil, exact: true]

  @doc """
  What a connection from `repo` actually has in effect — read back from
  Postgres rather than from config, so a report states how it was *measured*,
  not how it was meant to be.

  `current_setting(_, true)` rather than `SHOW`: a pgvector GUC is unknown to a
  session that has neither loaded the library nor set it, and `SHOW` raises
  there; unset means pgvector's default.
  """
  @spec effective(module()) :: effective()
  def effective(repo \\ KilnCMS.Repo) do
    %{rows: [[indexscan, ef_search, iterative]]} =
      repo.query!(
        "SELECT current_setting('enable_indexscan'), " <>
          "current_setting('hnsw.ef_search', true), " <>
          "current_setting('hnsw.iterative_scan', true)",
        []
      )

    {ef, set?} =
      case ef_search && Integer.parse(ef_search) do
        {n, ""} -> {n, true}
        _unset -> {@pgvector_default_ef_search, false}
      end

    %{
      exact: indexscan == "off",
      ef_search: ef,
      ef_search_set: set? and ef != @pgvector_default_ef_search,
      iterative_scan: iterative || "off"
    }
  end

  @doc """
  Raises unless `effective` is what `mode` asked for. `:default` asks for
  nothing and always passes.

  The mix tasks apply `--ef-search`/`--exact` by writing the repo config
  before the application starts. When it has already started — or a project
  overlay installs its own `after_connect`, which the repo's `init/2` will
  not replace — the flag cannot take effect, and a run that carried on would
  print numbers under a label they were not measured with.
  """
  @spec check!(mode(), effective()) :: :ok
  def check!(:default, _effective), do: :ok
  def check!(:exact, %{exact: true}), do: :ok
  def check!({:ef_search, n}, %{exact: false, ef_search: n}), do: :ok

  def check!(mode, effective) do
    raise ArgumentError, """
    requested vector scan #{inspect(mode)}, but the database connection reports \
    #{describe(effective)}. The setting did not reach the connection pool (was \
    the application already started, or is a custom :after_connect configured?).\
    """
  end

  @doc """
  One line naming the scan mode, for a report header.

      iex> KilnCMS.Search.VectorScan.describe(%{exact: true, ef_search: 40, ef_search_set: false, iterative_scan: "strict_order"})
      "exact (enable_indexscan = off: the HNSW index is not used, every vector query sorts its filtered rows by true distance)"

      iex> KilnCMS.Search.VectorScan.describe(%{exact: false, ef_search: 200, ef_search_set: true, iterative_scan: "strict_order"})
      "approximate HNSW, hnsw.ef_search = 200, iterative_scan = strict_order"
  """
  @spec describe(effective()) :: String.t()
  def describe(%{exact: true}) do
    "exact (enable_indexscan = off: the HNSW index is not used, every vector query " <>
      "sorts its filtered rows by true distance)"
  end

  def describe(%{ef_search: ef, ef_search_set: set?, iterative_scan: iterative}) do
    default = if set?, do: "", else: " (pgvector default)"
    "approximate HNSW, hnsw.ef_search = #{ef}#{default}, iterative_scan = #{iterative}"
  end

  @doc """
  The warning a report carries when its scan was not measurement-grade —
  approximate below ef_search #{@measurement_ef_search} — or `nil`.
  """
  @spec warning(effective()) :: String.t() | nil
  def warning(effective) do
    if measurement_grade?(effective) do
      nil
    else
      "WARNING: approximate vector recall (ef_search #{effective.ef_search}) — the " <>
        "semantic legs can drop rows nearer than the ones they return, so these numbers " <>
        "are not measurement-grade. Rerun with --ef-search #{@measurement_ef_search} or " <>
        "--exact (KILN_HNSW_EF_SEARCH / KILN_VECTOR_SEARCH_EXACT on a server)."
    end
  end

  @doc "Exact, or approximate at ef_search #{@measurement_ef_search} or wider."
  @spec measurement_grade?(effective()) :: boolean()
  def measurement_grade?(%{exact: true}), do: true
  def measurement_grade?(%{ef_search: ef}), do: ef >= @measurement_ef_search

  @doc """
  The header lines a task prints: the mode, then the warning when there is one.
  `:remote` is a run against a live deployment over HTTP, whose connections
  this process cannot see or set.
  """
  @spec header(effective() | :remote) :: String.t()
  def header(:remote) do
    "vector scan: the server's own — not visible over HTTP. For measurement runs, " <>
      "set KILN_HNSW_EF_SEARCH=#{@measurement_ef_search} or KILN_VECTOR_SEARCH_EXACT=true " <>
      "on the deployment."
  end

  def header(effective) do
    Enum.join(["vector scan: " <> describe(effective) | List.wrap(warning(effective))], "\n")
  end

  @doc "The scan mode as it goes into a task's JSON output."
  @spec to_json(effective() | :remote) :: map()
  def to_json(:remote), do: %{mode: "server", known: false}

  def to_json(effective) do
    %{
      mode: if(effective.exact, do: "exact", else: "approximate"),
      known: true,
      ef_search: if(effective.exact, do: nil, else: effective.ef_search),
      iterative_scan: effective.iterative_scan,
      measurement_grade: measurement_grade?(effective)
    }
  end
end
