# SSE fan-out benchmark for the change feed (#2275): N real `GET /api/feed`
# connections over loopback, one published post at a time, timed to the LAST
# connection that received it.
#
#   elixir --sname cli --cookie C -S mix run --no-start scripts/benchmarks/feed_sse.exs
#
# Normally run by `feed_sse.sh`, as a second node beside a `MIX_ENV=prod`
# server on its OWN throwaway database (the server refuses nothing, so this
# script checks the database name over RPC and stops unless it is
# `kiln_cms_bench*`).
#
# Per leg (one per BENCH_CONNECTIONS value):
#
#   1. on the server: the `:feed_join` and `:api` buckets and the stream caps
#      raised past N (every connection comes from 127.0.0.1, one client), the
#      same configuration keys a deployment sets, applied to the running node;
#   2. a memory snapshot of the server, N connections opened (each waits for
#      its `event: ready`), a second snapshot;
#   3. BENCH_PUBLISHES posts created and published through the domain actions
#      as an admin, one every BENCH_INTERVAL_MS, each timed from just before
#      the RPC that publishes it to the moment the last of the N connections
#      parsed its `event: published` frame;
#   4. every connection closed, and the time until the server has freed every
#      stream slot (a stream sees its client gone on its next write: at the
#      latest the next 25 s heartbeat).
#
# Both nodes run on the same machine and read the same wall clock
# (`System.os_time/1`), which is what lets a server-side start and a
# client-side receipt be subtracted.
#
# Environment (all optional):
#   BENCH_CONNECTIONS       comma list, one leg each (1000)
#   BENCH_PUBLISHES         publishes per leg (30)
#   BENCH_INTERVAL_MS       ms between publishes (1000)
#   BENCH_OPEN_CONCURRENCY  connections opened at once (50; under the
#                           listen backlog, `kern.ipc.somaxconn` is 128 on macOS)
#   BENCH_SERVER_NODE, BENCH_PORT, BENCH_OUT   set by feed_sse.sh

{:ok, _} = Application.ensure_all_started(:mint)
{:ok, _} = Application.ensure_all_started(:jason)

defmodule FeedBench.Env do
  def int(name, default), do: name |> System.get_env("#{default}") |> String.to_integer()

  def list(name, default),
    do:
      name
      |> System.get_env(default)
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))
end

defmodule FeedBench.Stats do
  def pct([], _p), do: nil

  def pct(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, round(p / 100 * (length(sorted) - 1))))
  end

  def summary(values) do
    %{
      n: length(values),
      p50: pct(values, 50),
      p95: pct(values, 95),
      max: if(values == [], do: nil, else: Enum.max(values))
    }
  end

  def fmt(nil), do: "–"
  def fmt(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  def fmt(v), do: to_string(v)
end

# Runs on the server node: loaded there as a binary.
{:module, server_mod, server_bin, _} =
  defmodule FeedBench.Server do
    def database, do: KilnCMS.Repo.config()[:database] || ""

    def prepare(n) do
      limit = {100_000_000, :timer.minutes(1)}

      Application.put_env(:kiln_cms, KilnCMSWeb.RateLimit,
        limits: %{feed_join: limit, api: limit}
      )

      Application.put_env(:kiln_cms, KilnCMSWeb.FeedStream,
        max_per_client: n * 2,
        max_per_node: n * 2
      )

      admin =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "feed-bench-#{System.unique_integer([:positive])}@kiln.test",
          hashed_password: Bcrypt.hash_pwd_salt("feed-bench-password"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      admin
    end

    def snapshot do
      :erlang.garbage_collect()
      streams = KilnCMSWeb.FeedStream.streams()

      stream_memory =
        streams
        |> Enum.map(fn pid ->
          case Process.info(pid, :memory) do
            {:memory, bytes} -> bytes
            nil -> 0
          end
        end)
        |> Enum.sum()

      %{
        total: :erlang.memory(:total),
        processes: :erlang.memory(:processes),
        binary: :erlang.memory(:binary),
        process_count: :erlang.system_info(:process_count),
        streams: length(streams),
        stream_memory: stream_memory
      }
    end

    def publish(admin) do
      n = System.unique_integer([:positive])
      opts = [actor: admin, tenant: KilnCMS.Accounts.default_org_id()]

      post =
        %{title: "Feed bench #{n}", slug: "feed-bench-#{n}"}
        |> KilnCMS.CMS.create_post!(opts)
        |> KilnCMS.CMS.publish_post!(%{}, opts)

      post.id
    end
  end

defmodule FeedBench.Client do
  @moduledoc false
  # One SSE connection: a Mint socket in active mode, parsed frame by frame.
  # Reports `ready` once, and the receipt time of every `published` frame.

  def start(port, collector) do
    parent = self()

    spawn_link(fn ->
      {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :active, protocols: [:http1])

      {:ok, conn, _ref} =
        Mint.HTTP.request(
          conn,
          "GET",
          "/api/feed",
          [{"host", "localhost"}, {"accept", "text/event-stream"}],
          nil
        )

      loop(conn, "", parent, collector, false)
    end)
  end

  defp loop(conn, buffer, parent, collector, ready?) do
    receive do
      :close ->
        Mint.HTTP.close(conn)

      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            data = for {:data, _ref, chunk} <- responses, into: "", do: chunk
            {frames, rest} = split(buffer <> data)
            now = System.os_time(:microsecond)

            ready? =
              Enum.reduce(frames, ready?, fn frame, ready? ->
                cond do
                  String.starts_with?(frame, "event: published") ->
                    case Regex.run(~r/"id":"([0-9a-f-]{36})"/, frame) do
                      [_, id] -> :ets.insert(collector, {id, now})
                      _ -> :ok
                    end

                    ready?

                  String.starts_with?(frame, "event: ready") and not ready? ->
                    send(parent, {:ready, self()})
                    true

                  true ->
                    ready?
                end
              end)

            loop(conn, rest, parent, collector, ready?)

          {:error, _conn, reason, _responses} ->
            send(parent, {:failed, self(), {reason, buffer}})

          :unknown ->
            loop(conn, buffer, parent, collector, ready?)
        end
    end
  end

  defp split(buffer) do
    parts = String.split(buffer, "\n\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end
end

alias FeedBench.Env
alias FeedBench.Stats

node = System.fetch_env!("BENCH_SERVER_NODE") |> String.to_atom()
port = Env.int("BENCH_PORT", 4100)
legs = Env.list("BENCH_CONNECTIONS", "1000")
publishes = Env.int("BENCH_PUBLISHES", 30)
interval = Env.int("BENCH_INTERVAL_MS", 1000)
open_concurrency = Env.int("BENCH_OPEN_CONCURRENCY", 50)
out = System.get_env("BENCH_OUT", "feed-sse-results.json")

true = Node.connect(node) || raise "cannot reach #{node} — is the server running?"

rpc! = fn m, f, a ->
  case :rpc.call(node, m, f, a, 120_000) do
    {:badrpc, reason} -> raise "rpc #{inspect(m)}.#{f} failed: #{inspect(reason)}"
    result -> result
  end
end

{:module, _} = rpc!.(:code, :load_binary, [server_mod, ~c"feed_bench_server.beam", server_bin])

db = rpc!.(server_mod, :database, [])

unless String.starts_with?(db, "kiln_cms_bench") do
  raise "Refusing to run against #{inspect(db)}: the benchmark only writes to kiln_cms_bench*"
end

collector = :ets.new(:feed_bench, [:public, :duplicate_bag, write_concurrency: true])

results =
  for n <- legs do
    IO.puts(:stderr, "leg: #{n} connections")
    admin = rpc!.(server_mod, :prepare, [n])
    before = rpc!.(server_mod, :snapshot, [])

    t_open = System.monotonic_time(:millisecond)

    clients =
      1..n
      |> Enum.chunk_every(open_concurrency)
      |> Enum.flat_map(fn chunk ->
        pids = Enum.map(chunk, fn _ -> FeedBench.Client.start(port, collector) end)

        Enum.each(pids, fn pid ->
          receive do
            {:ready, ^pid} -> :ok
            {:failed, ^pid, reason} -> raise "connection failed: #{inspect(reason)}"
          after
            60_000 -> raise "a connection never became ready"
          end
        end)

        pids
      end)

    open_ms = System.monotonic_time(:millisecond) - t_open
    connected = rpc!.(server_mod, :snapshot, [])
    IO.puts(:stderr, "  #{connected.streams} streams open in #{open_ms} ms")

    timings =
      for i <- 1..publishes do
        if i > 1, do: Process.sleep(interval)
        t0 = System.os_time(:microsecond)
        id = rpc!.(server_mod, :publish, [admin])
        returned = System.os_time(:microsecond)

        # Every connection has it, or 10 s have passed.
        deadline = System.monotonic_time(:millisecond) + 10_000

        receipts =
          Stream.repeatedly(fn ->
            got = :ets.lookup(collector, id)
            if length(got) < n, do: Process.sleep(5)
            got
          end)
          |> Enum.find(fn got ->
            length(got) >= n or System.monotonic_time(:millisecond) > deadline
          end)

        times = Enum.map(receipts, &elem(&1, 1))

        %{
          received: length(times),
          publish_ms: (returned - t0) / 1000,
          last_ms: if(times == [], do: nil, else: (Enum.max(times) - t0) / 1000),
          first_ms: if(times == [], do: nil, else: (Enum.min(times) - t0) / 1000)
        }
      end

    loaded = rpc!.(server_mod, :snapshot, [])

    # A stream notices its client has gone on its next write, at the latest
    # the next heartbeat (25 s): wait for the server to free every slot, so
    # the next leg starts from an empty registry.
    Enum.each(clients, &send(&1, :close))
    t_close = System.monotonic_time(:millisecond)

    closed =
      Stream.repeatedly(fn ->
        Process.sleep(500)
        rpc!.(server_mod, :snapshot, [])
      end)
      |> Enum.find(fn snap ->
        snap.streams <= before.streams or
          System.monotonic_time(:millisecond) - t_close > 60_000
      end)

    freed_ms = System.monotonic_time(:millisecond) - t_close

    per_conn_total = (connected.total - before.total) / n
    per_conn_process = connected.stream_memory / max(connected.streams, 1)

    %{
      connections: n,
      open_ms: open_ms,
      freed_ms: freed_ms,
      publishes: publishes,
      complete: Enum.count(timings, &(&1.received == n)),
      last_ms: Stats.summary(for t <- timings, t.last_ms, do: t.last_ms),
      first_ms: Stats.summary(for t <- timings, t.first_ms, do: t.first_ms),
      publish_ms: Stats.summary(for t <- timings, do: t.publish_ms),
      memory: %{
        before: before,
        connected: connected,
        after_publishes: loaded,
        closed: closed,
        per_connection_total_bytes: per_conn_total,
        per_connection_process_bytes: per_conn_process
      }
    }
  end

File.write!(out, Jason.encode!(%{results: results}, pretty: true))

{model, cores, ram} =
  {System.cmd("sysctl", ["-n", "hw.model"]) |> elem(0) |> String.trim(),
   :erlang.system_info(:logical_processors_available),
   System.cmd("sysctl", ["-n", "hw.memsize"]) |> elem(0) |> String.trim()}

IO.puts("""
# Change feed SSE fan-out (#2275)

Host: #{model}, #{cores} logical cores, #{div(String.to_integer(ram), 1024 * 1024 * 1024)} GB RAM.
Server and client on one machine, over loopback; MIX_ENV=prod, POOL_SIZE=#{System.get_env("POOL_SIZE", "10")}.
#{publishes} publishes per leg, #{interval} ms apart.

| Connections | Open (ms) | Delivered to all | Publish call p50 / p95 (ms) | Publish → first client p50 / p95 (ms) | Publish → last client p50 / p95 / max (ms) | Memory per connection: BEAM total / stream process (KB) |
|---|---|---|---|---|---|---|
""")

for r <- results do
  IO.puts(
    "| #{r.connections} | #{r.open_ms} | #{r.complete}/#{r.publishes} | " <>
      "#{Stats.fmt(r.publish_ms.p50)} / #{Stats.fmt(r.publish_ms.p95)} | " <>
      "#{Stats.fmt(r.first_ms.p50)} / #{Stats.fmt(r.first_ms.p95)} | " <>
      "#{Stats.fmt(r.last_ms.p50)} / #{Stats.fmt(r.last_ms.p95)} / #{Stats.fmt(r.last_ms.max)} | " <>
      "#{Stats.fmt(r.memory.per_connection_total_bytes / 1024)} / " <>
      "#{Stats.fmt(r.memory.per_connection_process_bytes / 1024)} |"
  )
end

for r <- results do
  IO.puts(
    "\n#{r.connections} connections: streams open #{r.memory.connected.streams}, " <>
      "#{r.memory.closed.streams} still open #{r.freed_ms} ms after the clients closed; BEAM processes #{r.memory.before.process_count} → " <>
      "#{r.memory.connected.process_count}."
  )
end
