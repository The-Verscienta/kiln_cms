# Closed-loop latency benchmark for Kiln's anonymous headless reads (#1546).
#
#   elixir --sname kiln_bench_cli --cookie "$COOKIE" -S mix run --no-start \
#     scripts/benchmarks/load.exs
#
# Normally run by `api_latency.sh`, which boots the server under test as the
# named node BENCH_SERVER_NODE with the same cookie. This script:
#
#   1. raises every `KilnCMSWeb.RateLimit` bucket on that node through its
#      application config — the same knob `config :kiln_cms, KilnCMSWeb.RateLimit,
#      limits: …` sets, applied at runtime so the build under test is unchanged;
#   2. loads a small telemetry collector onto it, which records the server-side
#      duration of every request carrying an `x-bench-run` header
#      (`[:phoenix, :endpoint, :stop]`: the whole endpoint, rate limiter and
#      tenant resolution included, minus writing the body to the socket);
#   3. for each endpoint and concurrency level, runs a COLD pass (every in-BEAM
#      cache flushed first, then distinct keys) and a WARM pass (a warm-up, then
#      the same few keys over and over), with C workers each sending the next
#      request as soon as the last one answers;
#   4. prints a Markdown table and writes every number to BENCH_OUT as JSON.
#
# Environment (all optional):
#   BENCH_BASE          http://localhost:4000
#   BENCH_SERVER_NODE   kiln_bench_srv@<short hostname>
#   BENCH_CONCURRENCY   1,10,50
#   BENCH_WARM_N        requests per warm run (2000)
#   BENCH_COLD_N        requests per cold run (500)
#   BENCH_ENDPOINTS     comma list of endpoint names to run (default: all)
#   BENCH_OUT           results JSON path (bench-results.json)

{:ok, _} = Application.ensure_all_started(:req)

defmodule Bench.Env do
  def get(name, default), do: System.get_env(name, default)
  def int(name, default), do: name |> get("#{default}") |> String.to_integer()

  def list(name, default),
    do: name |> get(default) |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# Defined here, loaded onto the server node as a binary (`:code.load_binary/3`),
# so the build under test needs no benchmark code of its own.
{:module, collector, collector_bin, _} =
  defmodule Bench.Collector do
    @table :kiln_bench_collector
    @handler "kiln-bench-collector"

    def install do
      if :ets.whereis(@table) == :undefined do
        parent = self()

        spawn(fn ->
          :ets.new(@table, [:named_table, :public, :duplicate_bag, write_concurrency: true])
          send(parent, :ready)
          Process.sleep(:infinity)
        end)

        receive do
          :ready -> :ok
        end
      end

      :telemetry.detach(@handler)
      :telemetry.attach(@handler, [:phoenix, :endpoint, :stop], &__MODULE__.handle/4, nil)
    end

    def handle(_event, %{duration: duration}, %{conn: conn}, _config) do
      case Plug.Conn.get_req_header(conn, "x-bench-run") do
        [run] ->
          :ets.insert(@table, {run, System.convert_time_unit(duration, :native, :microsecond)})

        _ ->
          :ok
      end
    end

    def handle(_, _, _, _), do: :ok

    def take(run), do: @table |> :ets.take(run) |> Enum.map(&elem(&1, 1))

    # Profiles one request, `n` times, in-process on the server: the whole
    # endpoint through `KilnCMSWeb.Endpoint.call/2`, so the plugs, the router
    # and the handler are all in the picture. Returns the wall time, every
    # Repo query it ran (source, query and queue time) and the functions with
    # the most own time under `:tprof`.
    def profile(method, path, body, n) do
      # `:tprof` lives in the `tools` application, which a Mix-started node
      # has not put on its code path.
      for dir <- Path.wildcard(Path.join(to_string(:code.root_dir()), "lib/tools-*/ebin")),
          do: :code.add_patha(to_charlist(dir))

      call = fn ->
        conn =
          method
          |> Plug.Test.conn(path, body && Jason.encode!(body))
          |> Map.put(:host, "localhost")

        conn =
          if body,
            do: Plug.Conn.put_req_header(conn, "content-type", "application/json"),
            else: conn

        KilnCMSWeb.Endpoint.call(conn, [])
      end

      call.()

      :telemetry.attach(
        "kiln-bench-queries",
        [:kiln_cms, :repo, :query],
        &__MODULE__.query/4,
        nil
      )

      t0 = System.monotonic_time(:microsecond)
      for _ <- 1..n, do: call.()
      wall = System.monotonic_time(:microsecond) - t0
      :telemetry.detach("kiln-bench-queries")
      queries = :ets.take(@table, :bench_queries) |> Enum.map(&elem(&1, 1))

      # `apply/3` because the client that compiles this module has no `tools` on its path.
      {_, {:call_time, data}} =
        apply(:tprof, :profile, [
          fn -> for _ <- 1..n, do: call.() end,
          %{type: :call_time, report: :return}
        ])

      top =
        data
        |> Enum.map(fn {m, f, a, per_pid} ->
          {"#{inspect(m)}.#{f}/#{a}", Enum.sum(for {_, _, t} <- per_pid, do: t),
           Enum.sum(for {_, c, _} <- per_pid, do: c)}
        end)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(25)

      %{wall_us: wall, n: n, queries: queries, top: top}
    end

    def query(_event, measurements, meta, _config) do
      ms = fn key ->
        case measurements[key] do
          nil -> 0.0
          t -> System.convert_time_unit(t, :native, :microsecond) / 1000
        end
      end

      :ets.insert(
        @table,
        {:bench_queries,
         {meta[:source], ms.(:query_time) + ms.(:decode_time), ms.(:queue_time), meta[:query]}}
      )
    end
  end

defmodule Bench do
  @words ~w(kiln clay glaze fire studio vessel porcelain stoneware wheel throw trim bisque
            oxide ash reduction cone temperature pottery craft form surface texture colour
            editor content publish delivery headless schema block page post archive season
            garden river mountain city harbour market library museum journey morning winter
            summer autumn spring light shadow window bridge signal network recipe method
            measure balance pattern rhythm detail lesson practice history)

  def main do
    node = String.to_atom(Bench.Env.get("BENCH_SERVER_NODE", "kiln_bench_srv@#{short_host()}"))
    base = Bench.Env.get("BENCH_BASE", "http://localhost:4000")
    out = Bench.Env.get("BENCH_OUT", "bench-results.json")
    levels = "BENCH_CONCURRENCY" |> Bench.Env.list("1,10,50") |> Enum.map(&String.to_integer/1)
    warm_n = Bench.Env.int("BENCH_WARM_N", 2000)
    cold_n = Bench.Env.int("BENCH_COLD_N", 500)

    true = Node.connect(node) || raise "cannot reach #{node} — is the server running?"
    prepare_server!(node)

    {:ok, _} = Finch.start_link(name: Bench.Finch, pools: %{default: [size: 128, count: 1]})
    req = Req.new(base_url: base, finch: Bench.Finch, retry: false, receive_timeout: 30_000)

    slugs = rpc!(node, KilnCMS.Repo, :query!, [slug_sql()]).rows |> List.flatten()
    if slugs == [], do: raise("no published posts on #{node}: was the corpus seeded?")

    selected = Bench.Env.list("BENCH_ENDPOINTS", "")

    endpoints =
      endpoints(slugs)
      |> Enum.filter(fn {name, _} -> selected == [] or name in selected end)

    IO.puts("Corpus: #{length(slugs)} published posts. Levels #{inspect(levels)}.\n")

    results =
      for {name, build} <- endpoints, c <- levels, phase <- [:cold, :warm] do
        label = "#{name}/#{phase}/c#{c}"

        {keyer, n} =
          case phase do
            :cold ->
              rpc!(node, KilnCMS.Cache, :flush_delivery, [])
              rpc!(node, Cachex, :clear, [KilnCMS.Cache.Hosts.cache_name()])
              {& &1, cold_n}

            :warm ->
              # The same 50 keys, touched once before the measured run.
              keyer = &rem(&1, 50)
              run(req, "#{label}/warmup", c, 200, build, keyer)
              rpc!(node, Bench.Collector, :take, ["#{label}/warmup"])
              {keyer, warm_n}
          end

        load_before = loadavg()
        client = run(req, label, c, n, build, keyer)
        server = rpc!(node, Bench.Collector, :take, [label])
        row = summarize(name, phase, c, client, server, load_before)
        IO.puts(format_row(row))
        row
      end

    File.write!(
      out,
      Jason.encode_to_iodata!(%{
        taken_at: DateTime.utc_now(),
        base: base,
        corpus_published_posts: length(slugs),
        machine: machine(),
        results: results
      })
    )

    IO.puts("\n" <> markdown(results))

    for {name, build} <- endpoints(slugs), name in Bench.Env.list("BENCH_PROFILE", "") do
      profile(node, name, build)
    end

    IO.puts("\nWrote #{out}")
  end

  # ── the surfaces under test ───────────────────────────────────────────────

  defp profile(node, name, build) do
    n = Bench.Env.int("BENCH_PROFILE_N", 20)
    {method, path, body} = build.(0)

    %{wall_us: wall, queries: queries, top: top} =
      rpc!(node, Bench.Collector, :profile, [method, path, body, n])

    by_source =
      queries
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {source, qs} ->
        {source, length(qs) / n, Enum.sum(Enum.map(qs, &elem(&1, 1))) / n,
         Enum.sum(Enum.map(qs, &elem(&1, 2))) / n}
      end)
      |> Enum.sort_by(&elem(&1, 2), :desc)

    slowest =
      queries
      |> Enum.group_by(&elem(&1, 3), &elem(&1, 1))
      |> Enum.map(fn {sql, times} -> {Enum.sum(times) / length(times), length(times), sql} end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.take(3)

    IO.puts("""

    ## Profile: #{name} (#{method |> to_string() |> String.upcase()} #{path}), #{n} serial requests in-process

    Wall time per request: #{fmt(wall / n / 1000)} ms. Repo queries per request: \
    #{fmt(length(queries) / n)}, #{fmt(Enum.sum(Enum.map(queries, &elem(&1, 1))) / n)} ms in the database.

    | Source | Queries/req | DB ms/req | Queue ms/req |
    |---|---|---|---|
    #{Enum.map_join(by_source, "\n", fn {s, c, q, w} -> "| #{s || "(raw SQL)"} | #{fmt(c)} | #{fmt(q)} | #{fmt(w)} |" end)}

    Slowest statements (mean ms, times run):

    #{Enum.map_join(slowest, "\n\n", fn {ms, count, sql} -> "#{fmt(ms)} ms × #{count}:\n\n```sql\n#{sql}\n```" end)}

    Top functions by own time under :tprof (all #{n} requests; tracing inflates the absolute numbers):

    | Function | Own µs | Calls |
    |---|---|---|
    #{Enum.map_join(top, "\n", fn {f, t, c} -> "| `#{f}` | #{t} | #{c} |" end)}
    """)
  end

  # Each builder takes a key index and returns {method, path, body}. A cold run
  # uses indices 1..n (distinct documents, pages and queries while they last); a
  # warm run cycles 0..49.
  defp endpoints(slugs) do
    slugs = List.to_tuple(slugs)
    slug = fn i -> elem(slugs, rem(i, tuple_size(slugs))) end
    pages = max(div(tuple_size(slugs), 20), 1)
    offset = fn i -> rem(i, pages) * 20 end
    words = List.to_tuple(@words)
    word = fn i -> elem(words, rem(i, tuple_size(words))) end

    [
      {"jsonapi_list",
       fn i ->
         {:get, "/api/json/posts/published?page[limit]=20&page[offset]=#{offset.(i)}", nil}
       end},
      {"jsonapi_by_slug",
       fn i -> {:get, "/api/json/posts/by-slug/#{slug.(i)}?locale=en", nil} end},
      {"graphql_list",
       fn i ->
         {:post, "/gql",
          %{
            query:
              "query($o:Int){ publishedPosts(limit: 20, offset: $o){ results { id title slug excerpt } } }",
            variables: %{o: offset.(i)}
          }}
       end},
      {"graphql_by_slug",
       fn i ->
         {:post, "/gql",
          %{
            query:
              "query($s:String!){ postBySlug(slug: $s, locale: \"en\"){ id title slug excerpt } }",
            variables: %{s: slug.(i)}
          }}
       end},
      {"content_by_slug", fn i -> {:get, "/api/content/post/#{slug.(i)}", nil} end},
      # A typical query names something a handful of documents mention
      # (seed.exs's rare words). The common-word query matches nearly every
      # document: the worst case for ranking.
      {"search", fn i -> {:get, "/api/search?q=#{rare_word(rem(i * 37, 3000))}", nil} end},
      {"search_common", fn i -> {:get, "/api/search?q=#{word.(i)}", nil} end},
      {"sync_initial",
       fn i ->
         {:get,
          "/api/sync?initial=true&limit=100&type=#{if rem(i, 2) == 0, do: "post", else: "page"}",
          nil}
       end}
    ]
  end

  # The same made-up words seed.exs writes.
  @syllables ~w(ka lo mi re tu sa ven dor pli qua zen fo bri nu tal gor)
  defp rare_word(n),
    do: Enum.map_join([div(n, 256), rem(div(n, 16), 16), rem(n, 16)], &Enum.at(@syllables, &1))

  defp slug_sql,
    do: "SELECT slug FROM posts WHERE state = 'published' AND archived_at IS NULL ORDER BY slug"

  # ── load loop ─────────────────────────────────────────────────────────────

  defp run(req, label, c, n, build, keyer) do
    counter = :atomics.new(1, [])
    t0 = System.monotonic_time(:microsecond)

    samples =
      1..c
      |> Enum.map(fn _ ->
        Task.async(fn -> worker(req, label, counter, n, build, keyer, []) end)
      end)
      |> Enum.flat_map(&Task.await(&1, :infinity))

    %{samples: samples, wall_us: System.monotonic_time(:microsecond) - t0}
  end

  defp worker(req, label, counter, n, build, keyer, acc) do
    i = :atomics.add_get(counter, 1, 1)

    if i > n do
      acc
    else
      {method, path, body} = build.(keyer.(i))
      opts = [method: method, url: path, headers: [{"x-bench-run", label}]]
      opts = if body, do: Keyword.put(opts, :json, body), else: opts
      t = System.monotonic_time(:microsecond)

      status =
        case Req.request(req, opts) do
          {:ok, %{status: status, body: body}} -> graphql_status(status, body)
          {:error, _} -> :error
        end

      worker(req, label, counter, n, build, keyer, [
        {System.monotonic_time(:microsecond) - t, status} | acc
      ])
    end
  end

  # A GraphQL error answers 200; count it as a failure, not a fast success.
  defp graphql_status(200, %{"errors" => [_ | _]}), do: :graphql_error
  defp graphql_status(status, _), do: status

  # ── reporting ─────────────────────────────────────────────────────────────

  defp summarize(name, phase, c, %{samples: samples, wall_us: wall}, server, load) do
    client = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    statuses =
      samples |> Enum.frequencies_by(&elem(&1, 1)) |> Map.new(fn {k, v} -> {"#{k}", v} end)

    %{
      endpoint: name,
      phase: phase,
      concurrency: c,
      requests: length(samples),
      statuses: statuses,
      ok: Map.get(statuses, "200", 0),
      rps: Float.round(length(samples) / (wall / 1_000_000), 1),
      client_ms: percentiles(client),
      server_ms: percentiles(Enum.sort(server)),
      loadavg_before: load
    }
  end

  defp percentiles([]), do: %{p50: nil, p95: nil, p99: nil, max: nil}

  defp percentiles(sorted) do
    n = length(sorted)
    at = fn q -> Enum.at(sorted, min(n - 1, ceil(q * n) - 1)) / 1000 end
    %{p50: at.(0.5), p95: at.(0.95), p99: at.(0.99), max: List.last(sorted) / 1000}
  end

  defp format_row(r) do
    "#{String.pad_trailing("#{r.endpoint}/#{r.phase}/c#{r.concurrency}", 30)} " <>
      "n=#{r.requests} ok=#{r.ok} rps=#{r.rps} " <>
      "server p50/p95/p99=#{fmt(r.server_ms.p50)}/#{fmt(r.server_ms.p95)}/#{fmt(r.server_ms.p99)} " <>
      "client p95=#{fmt(r.client_ms.p95)} load=#{r.loadavg_before}"
  end

  defp markdown(results) do
    header =
      "| Endpoint | Cache | C | Requests (non-200) | req/s | Server p50 | Server p95 | Server p99 | Client p95 |\n" <>
        "|---|---|---|---|---|---|---|---|---|\n"

    header <>
      Enum.map_join(results, "\n", fn r ->
        "| #{r.endpoint} | #{r.phase} | #{r.concurrency} | #{r.requests} (#{r.requests - r.ok}) | " <>
          "#{round(r.rps)} | #{fmt(r.server_ms.p50)} | #{fmt(r.server_ms.p95)} | " <>
          "#{fmt(r.server_ms.p99)} | #{fmt(r.client_ms.p95)} |"
      end)
  end

  defp fmt(nil), do: "–"
  defp fmt(ms), do: :erlang.float_to_binary(ms / 1, decimals: 1)

  # ── the node under test ───────────────────────────────────────────────────

  defp prepare_server!(node) do
    lifted =
      node
      |> rpc!(KilnCMSWeb.RateLimit, :default_limits, [])
      |> Map.new(fn {bucket, _} -> {bucket, {100_000_000, 60_000}} end)

    :ok = rpc!(node, Application, :put_env, [:kiln_cms, KilnCMSWeb.RateLimit, [limits: lifted]])

    {:module, _} =
      rpc!(node, :code, :load_binary, [Bench.Collector, ~c"bench_collector.beam", collector_bin()])

    :ok = rpc!(node, Bench.Collector, :install, [])
  end

  defp collector_bin, do: :persistent_term.get(:bench_collector_bin)

  defp rpc!(node, m, f, a) do
    case :rpc.call(node, m, f, a, 60_000) do
      {:badrpc, reason} -> raise "rpc #{inspect(m)}.#{f} on #{node} failed: #{inspect(reason)}"
      result -> result
    end
  end

  defp short_host do
    {:ok, host} = :inet.gethostname()
    host |> to_string() |> String.split(".") |> hd()
  end

  defp loadavg do
    case System.cmd("sysctl", ["-n", "vm.loadavg"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> String.trim("{") |> String.trim("}") |> String.trim()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp machine do
    sysctl = fn key ->
      case System.cmd("sysctl", ["-n", key], stderr_to_stdout: true) do
        {out, 0} -> String.trim(out)
        _ -> nil
      end
    end

    %{
      cpu: sysctl.("machdep.cpu.brand_string"),
      cores: sysctl.("hw.ncpu"),
      memory_bytes: sysctl.("hw.memsize"),
      os: :os.type() |> Tuple.to_list() |> Enum.join("/"),
      otp: System.otp_release(),
      elixir: System.version()
    }
  rescue
    _ -> %{}
  end
end

:persistent_term.put(:bench_collector_bin, collector_bin)
_ = collector
Bench.main()
