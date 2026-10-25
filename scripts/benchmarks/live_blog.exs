# Live-blog firing benchmark (#2049): one small published update every few
# seconds, each related to one parent story.
#
#   MIX_ENV=prod mix run scripts/benchmarks/live_blog.exs
#
# Normally run by `live_blog.sh`, against its OWN throwaway database (it
# refuses any database not named `kiln_cms_bench*`), after `seed.exs` has put
# a published corpus around it. Everything runs in this one BEAM with the
# application started, so the Oban queues that fire the updates are the ones
# measured.
#
# The model is the one in docs/plans/2026-10-19-verscienta-news.md (N3): a
# `LiveStory` and its `LiveUpdate`s, each update its own published record
# related to the story. Here the story is a published page and each update a
# published post whose `:reference` custom field `live_story` points at it
# (with an inverse, `live_updates`, so the story lists them). Both sit in one
# category, the section front. The compiled page/post types stand in for the
# overlay's own types: they fire through the same engine, with the same
# reference edges.
#
# Per leg (one per BENCH_SUBSCRIBERS value), on a fresh story:
#
#   1. BENCH_DURATION seconds of updates, one every BENCH_INTERVAL_MIN to
#      BENCH_INTERVAL_MAX ms, each created and published through the domain
#      actions as an admin;
#   2. a wait until every update has fired;
#   3. one edit of the story itself, and a wait until the re-fire wave it
#      starts has drained (BENCH_WAVE_TIMEOUT seconds at most).
#
# Measured:
#
#   * fire latency: publish start → the update's `{:fired, …}` broadcast on the
#     `"firing"` PubSub topic (sent once its artifacts are persisted);
#   * whether the parent story or anything else re-fired (every `"firing"`
#     broadcast is counted by type and id);
#   * Oban queue depth, sampled every second (`available` + `executing`);
#   * DB load: Repo queries and their time (`[:kiln_cms, :repo, :query]`) and
#     the `pg_stat_database` counters for the benchmark database;
#   * publish-to-feed-event: publish start → the update's `published` event on
#     the change feed (`KilnCMS.Delivery.Feed`, #2050), timed by its
#     `[:kiln_cms, :delivery, :feed, :event]` telemetry, emitted once the
#     PubSub broadcast has been sent; and how many feed events each update and
#     the story edit produce;
#   * with N subscribers: N processes subscribed to the site's feed topic, and
#     the time from publish start to the LAST of them receiving the update's
#     event. In-BEAM subscribers: no transport, socket or network (those are
#     #2050's 2.2).
#
# Environment (all optional):
#   BENCH_DURATION        seconds of updates per leg (1800)
#   BENCH_INTERVAL_MIN    ms between updates, lower bound (2000)
#   BENCH_INTERVAL_MAX    ms between updates, upper bound (5000)
#   BENCH_SUBSCRIBERS     comma list, one leg each (0,1000,10000)
#   BENCH_WAVE_TIMEOUT    seconds to wait for the story-edit wave (600)
#   BENCH_BASELINE        seconds of idle baseline, after the legs (300)
#   BENCH_OUT             results JSON path (live-blog-results.json)
#   BENCH_SEED            RNG seed (2049)

alias KilnCMS.Accounts
alias KilnCMS.Accounts.User
alias KilnCMS.CMS

db = KilnCMS.Repo.config()[:database] || ""

unless String.starts_with?(db, "kiln_cms_bench") do
  Mix.raise(
    "Refusing to run against #{inspect(db)}: the benchmark only writes to kiln_cms_bench*"
  )
end

defmodule LiveBench.Env do
  def int(name, default), do: name |> System.get_env("#{default}") |> String.to_integer()

  def list(name, default),
    do:
      name
      |> System.get_env(default)
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))
end

defmodule LiveBench.Stats do
  # Nearest-rank, like load.exs and `KilnCMS.Propagation.percentiles/2`.
  def pct([], _p), do: nil

  def pct(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, max(ceil(p / 100 * length(sorted)) - 1, 0))
  end

  def summary(values) do
    %{
      n: length(values),
      p50: pct(values, 50),
      p95: pct(values, 95),
      p99: pct(values, 99),
      max: if(values == [], do: nil, else: Enum.max(values))
    }
  end

  def fmt(nil), do: "–"
  def fmt(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  def fmt(v), do: to_string(v)

  def ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000
end

defmodule LiveBench.Tables do
  # One owner process for the ETS tables, so they outlive any task.
  def start do
    parent = self()

    spawn(fn ->
      # `{:fired, type, id}` → [monotonic times], every broadcast on "firing".
      :ets.new(:lb_fired, [:named_table, :public, :duplicate_bag, write_concurrency: true])
      # `{:last_sub, id}` → receive counter / the last subscriber's time.
      :ets.new(:lb_subs, [:named_table, :public, :set, write_concurrency: true])
      # Repo queries: `{:q, pid?}` rows aggregated by the handler.
      :ets.new(:lb_repo, [:named_table, :public, :set, write_concurrency: true])
      # `{kind, id}` → [monotonic times], every feed event's telemetry.
      :ets.new(:lb_feed, [:named_table, :public, :duplicate_bag, write_concurrency: true])
      send(parent, :ready)
      Process.sleep(:infinity)
    end)

    receive do
      :ready -> :ok
    end
  end
end

defmodule LiveBench.Firing do
  # Records every "firing" broadcast with its arrival time.
  def start do
    parent = self()

    pid =
      spawn(fn ->
        Phoenix.PubSub.subscribe(KilnCMS.PubSub, "firing")
        send(parent, :subscribed)
        loop()
      end)

    receive do
      :subscribed -> pid
    end
  end

  defp loop do
    receive do
      {:fired, type, id} ->
        :ets.insert(:lb_fired, {{type, id}, System.monotonic_time()})
        loop()

      _other ->
        loop()
    end
  end

  def times(type, id), do: :ets.lookup(:lb_fired, {type, id}) |> Enum.map(&elem(&1, 1))

  def all, do: :ets.tab2list(:lb_fired)
end

defmodule LiveBench.Feed do
  @handler "live-bench-feed"

  def attach do
    :telemetry.attach(
      @handler,
      KilnCMS.Delivery.Feed.telemetry_event(),
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(_event, _measurements, %{kind: kind, id: id}, _config) do
    :ets.insert(:lb_feed, {{kind, id}, System.monotonic_time()})
  end

  def times(kind, id), do: :ets.lookup(:lb_feed, {kind, id}) |> Enum.map(&elem(&1, 1))

  def between(t0, t1),
    do: :lb_feed |> :ets.tab2list() |> Enum.filter(fn {_, t} -> t >= t0 and t <= t1 end)
end

defmodule LiveBench.Subscribers do
  # N processes on the site's feed topic, each recording only whether it was the last of the
  # N to see a given update: the subscriber whose increment reaches N stamps
  # the time. One ETS counter per event, not N rows.
  def start(0, _topic), do: []

  def start(n, topic) do
    for _ <- 1..n do
      parent = self()

      pid =
        spawn(fn ->
          Phoenix.PubSub.subscribe(KilnCMS.PubSub, topic)
          send(parent, {:sub_ready, self()})
          loop(n)
        end)

      receive do
        {:sub_ready, ^pid} -> pid
      end
    end
  end

  defp loop(n) do
    receive do
      :stop ->
        :ok

      {:kiln_feed, %{kind: :published, id: id}} ->
        count = :ets.update_counter(:lb_subs, {:count, id}, 1, {{:count, id}, 0})
        if count == n, do: :ets.insert(:lb_subs, {{:last, id}, System.monotonic_time()})
        loop(n)

      _other ->
        loop(n)
    end
  end

  def last(id) do
    case :ets.lookup(:lb_subs, {:last, id}) do
      [{_, t}] -> t
      [] -> nil
    end
  end

  def stop(pids), do: Enum.each(pids, &send(&1, :stop))
end

defmodule LiveBench.Repo do
  @handler "live-bench-repo"

  def attach do
    :telemetry.attach(@handler, [:kiln_cms, :repo, :query], &__MODULE__.handle/4, nil)
  end

  def handle(_event, measurements, metadata, _config) do
    # The sampler's own polling is the benchmark, not the workload.
    unless self() == :persistent_term.get(:lb_sampler, nil) do
      total = Map.get(measurements, :total_time, 0)
      :ets.update_counter(:lb_repo, :count, 1, {:count, 0})
      :ets.update_counter(:lb_repo, :time, total, {:time, 0})
      source = Map.get(metadata, :source) || "(raw)"
      :ets.update_counter(:lb_repo, {:source, source}, 1, {{:source, source}, 0})
    end
  end

  def snapshot do
    rows = :ets.tab2list(:lb_repo)

    %{
      count: Keyword.get(rows, :count, 0),
      time_ms: LiveBench.Stats.ms(Keyword.get(rows, :time, 0)),
      sources: for({{:source, s}, n} <- rows, into: %{}, do: {s, n})
    }
  end

  def reset, do: :ets.delete_all_objects(:lb_repo)
end

defmodule LiveBench.Sampler do
  # Oban queue depth once a second, `available` + `executing` by queue.
  def start do
    parent = self()

    pid =
      spawn(fn ->
        :persistent_term.put(:lb_sampler, self())
        send(parent, :sampling)
        loop([])
      end)

    receive do
      :sampling -> pid
    end
  end

  defp loop(samples) do
    receive do
      {:collect, from} ->
        send(from, {:samples, Enum.reverse(samples)})
        loop([])
    after
      1_000 ->
        %{rows: rows} =
          KilnCMS.Repo.query!(
            "SELECT queue, count(*) FROM oban_jobs WHERE state IN ('available','executing') GROUP BY queue"
          )

        loop([Map.new(rows, fn [q, n] -> {q, n} end) | samples])
    end
  end

  def collect(pid) do
    send(pid, {:collect, self()})

    receive do
      {:samples, samples} -> samples
    end
  end
end

defmodule LiveBench.PgStat do
  @cols ~w(xact_commit xact_rollback tup_returned tup_fetched tup_inserted tup_updated
           tup_deleted blks_read blks_hit)

  def snapshot do
    %{rows: [row]} =
      KilnCMS.Repo.query!(
        "SELECT #{Enum.join(@cols, ", ")} FROM pg_stat_database WHERE datname = current_database()"
      )

    @cols |> Enum.zip(row) |> Map.new()
  end

  # pg_stat counters are flushed by each backend at most once a second.
  def delta(before) do
    Process.sleep(1_500)
    now = snapshot()
    Map.new(now, fn {k, v} -> {k, v - before[k]} end)
  end
end

defmodule LiveBench.Machine do
  def info do
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
      otp: System.otp_release(),
      elixir: System.version(),
      pool_size: KilnCMS.Repo.config()[:pool_size],
      firing_queue: Application.get_env(:kiln_cms, Oban)[:queues][:firing]
    }
  rescue
    _ -> %{}
  end

  def loadavg do
    case System.cmd("sysctl", ["-n", "vm.loadavg"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> String.trim("{") |> String.trim("}") |> String.trim()
      _ -> nil
    end
  rescue
    _ -> nil
  end
end

defmodule LiveBench.Wait do
  def until(deadline_ms, fun) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline_ms -> :timeout
      true -> Process.sleep(200) && until(deadline_ms, fun)
    end
  end
end

alias LiveBench.Stats, as: S

duration_s = LiveBench.Env.int("BENCH_DURATION", 1800)
interval_min = LiveBench.Env.int("BENCH_INTERVAL_MIN", 2000)
interval_max = LiveBench.Env.int("BENCH_INTERVAL_MAX", 5000)
legs = LiveBench.Env.list("BENCH_SUBSCRIBERS", "0,1000,10000")
wave_timeout_s = LiveBench.Env.int("BENCH_WAVE_TIMEOUT", 600)
baseline_s = LiveBench.Env.int("BENCH_BASELINE", 300)
out = System.get_env("BENCH_OUT", "live-blog-results.json")
:rand.seed(:exsss, {LiveBench.Env.int("BENCH_SEED", 2049), 5, 7})

tenant = Accounts.default_org_id()

admin =
  Ash.Seed.seed!(User, %{
    email: "live-bench-#{System.unique_integer([:positive])}@kiln.test",
    name: "Live Bench",
    hashed_password: Bcrypt.hash_pwd_salt(Base.encode64(:crypto.strong_rand_bytes(24))),
    confirmed_at: DateTime.utc_now(),
    role: :admin
  })

opts = [actor: admin, tenant: tenant]

section =
  CMS.create_category!(%{name: "Live", slug: "live-#{System.unique_integer([:positive])}"}, opts)

field =
  CMS.create_field_definition!(
    %{
      content_type: :post,
      name: "live_story",
      label: "Live story",
      field_type: :reference,
      target_type: "page",
      multiple: false,
      inverse_label: "Live updates",
      inverse_name: "live_updates"
    },
    opts
  )

LiveBench.Tables.start()
LiveBench.Firing.start()
LiveBench.Repo.attach()
LiveBench.Feed.attach()

para = fn n ->
  KilnCMS.Blocks.PortableText.from_html(
    "<p>Update #{n}: #{Enum.map_join(1..Enum.random(20..60), " ", fn _ -> Enum.random(~w(officials said the river crossed its banks at dawn and crews are moving north toward the harbour while the market stays closed)) end)}.</p>"
  )
end

run_leg = fn subscribers ->
  IO.puts(
    "\n== leg: #{subscribers} subscribers, #{duration_s} s, an update every #{interval_min}–#{interval_max} ms"
  )

  story =
    CMS.create_page!(
      %{
        title: "Live: storm coverage (#{subscribers} subscribers)",
        slug: "live-story-#{subscribers}-#{System.unique_integer([:positive])}",
        category_id: section.id,
        blocks: [%{"_type" => "rich_text", "body" => para.(0)}]
      },
      opts
    )

  story = CMS.publish_page!(story, %{}, opts)
  # Let the story's own fire land before the clock starts.
  LiveBench.Wait.until(System.monotonic_time(:millisecond) + 30_000, fn ->
    LiveBench.Firing.times(:page, story.id) != []
  end)

  leg_t0 = System.monotonic_time()

  # Subscribers are on the feed before the first update.
  subs = LiveBench.Subscribers.start(subscribers, KilnCMS.Delivery.Feed.topic(tenant))
  sampler = LiveBench.Sampler.start()
  LiveBench.Repo.reset()
  pg0 = LiveBench.PgStat.snapshot()
  load0 = LiveBench.Machine.loadavg()
  t_end = System.monotonic_time(:millisecond) + duration_s * 1000

  updates =
    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while([], fn n, acc ->
      if System.monotonic_time(:millisecond) >= t_end do
        {:halt, Enum.reverse(acc)}
      else
        t0 = System.monotonic_time()

        post =
          CMS.create_post!(
            %{
              title: "Update #{n}",
              slug: "live-update-#{story.id |> binary_part(0, 8)}-#{n}",
              category_id: section.id,
              custom_fields: %{field.name => %{"id" => story.id}},
              blocks: [%{"_type" => "rich_text", "body" => para.(n)}]
            },
            opts
          )

        t1 = System.monotonic_time()
        _ = CMS.publish_post!(post, %{}, opts)
        t2 = System.monotonic_time()

        if rem(n, 50) == 0, do: IO.puts("  #{n} updates")
        Process.sleep(Enum.random(interval_min..interval_max))

        {:cont,
         [
           %{id: post.id, t0: t0, create_ms: S.ms(t1 - t0), publish_ms: S.ms(t2 - t1), t_pub: t1}
           | acc
         ]}
      end
    end)

  IO.puts("  #{length(updates)} updates published; waiting for every fire")

  drain =
    LiveBench.Wait.until(System.monotonic_time(:millisecond) + 120_000, fn ->
      Enum.all?(updates, &(LiveBench.Firing.times(:post, &1.id) != [])) and
        (subscribers == 0 or Enum.all?(updates, &LiveBench.Subscribers.last(&1.id)))
    end)

  leg_t1 = System.monotonic_time()
  samples = LiveBench.Sampler.collect(sampler)
  Process.exit(sampler, :kill)
  :persistent_term.erase(:lb_sampler)
  repo = LiveBench.Repo.snapshot()
  pg = LiveBench.PgStat.delta(pg0)

  first_fire = fn u ->
    case LiveBench.Firing.times(:post, u.id) do
      [] -> nil
      ts -> Enum.min(ts)
    end
  end

  fire_ms = for u <- updates, t = first_fire.(u), do: S.ms(t - u.t0)
  fire_after_publish_ms = for u <- updates, t = first_fire.(u), do: S.ms(t - u.t_pub)
  sub_ms = for u <- updates, t = LiveBench.Subscribers.last(u.id), do: S.ms(t - u.t0)

  feed_ms =
    for u <- updates,
        t = LiveBench.Feed.times(:published, u.id) |> Enum.min(fn -> nil end),
        do: S.ms(t - u.t0)

  feed_events = LiveBench.Feed.between(leg_t0, leg_t1)
  update_ids = MapSet.new(updates, & &1.id)

  # Every fire during the leg that was not an update's first: the parent's, a
  # section front's, or a re-fire of an update.
  all_fired = Enum.filter(LiveBench.Firing.all(), fn {_, t} -> t >= leg_t0 and t <= leg_t1 end)

  other_fires =
    all_fired
    |> Enum.reject(fn {{type, id}, _} -> type == :post and MapSet.member?(update_ids, id) end)
    |> Enum.frequencies_by(fn {{type, id}, _} -> {type, id} end)

  repeat_update_fires =
    all_fired
    |> Enum.filter(fn {{type, id}, _} -> type == :post and MapSet.member?(update_ids, id) end)
    |> length()
    |> Kernel.-(length(fire_ms))

  story_fires = Enum.count(all_fired, fn {key, _} -> key == {:page, story.id} end)

  depth = fn queue -> Enum.map(samples, &Map.get(&1, queue, 0)) end
  total_depth = Enum.map(samples, fn s -> s |> Map.values() |> Enum.sum() end)

  LiveBench.Subscribers.stop(subs)

  # The story edit: one live edit of the parent, which every update references.
  IO.puts("  editing the story (#{length(updates)} updates reference it)")
  LiveBench.Repo.reset()
  sampler = LiveBench.Sampler.start()
  pg_wave0 = LiveBench.PgStat.snapshot()
  marks = Map.new(updates, fn u -> {u.id, length(LiveBench.Firing.times(:post, u.id))} end)
  w0 = System.monotonic_time()
  _ = CMS.update_page!(story, %{title: "Live: storm coverage (updated)"}, opts)
  w1 = System.monotonic_time()
  # Long enough for anything the wave publishes on the feed to land.
  Process.sleep(2_000)

  refired = fn ->
    Enum.count(updates, fn u -> length(LiveBench.Firing.times(:post, u.id)) > marks[u.id] end)
  end

  wave_drain =
    LiveBench.Wait.until(System.monotonic_time(:millisecond) + wave_timeout_s * 1000, fn ->
      refired.() == length(updates)
    end)

  wave_last =
    updates
    |> Enum.flat_map(&LiveBench.Firing.times(:post, &1.id))
    |> Enum.filter(&(&1 > w0))
    |> Enum.max(fn -> nil end)

  wave_samples = LiveBench.Sampler.collect(sampler)
  Process.exit(sampler, :kill)
  :persistent_term.erase(:lb_sampler)
  wave_repo = LiveBench.Repo.snapshot()
  wave_pg = LiveBench.PgStat.delta(pg_wave0)
  wave_depth = Enum.map(wave_samples, &Map.get(&1, "firing", 0))

  %{
    subscribers: subscribers,
    loadavg_before: load0,
    loadavg_after: LiveBench.Machine.loadavg(),
    updates: length(updates),
    seconds: S.ms(leg_t1 - leg_t0) / 1000,
    drained: drain == :ok,
    create_ms: S.summary(Enum.map(updates, & &1.create_ms)),
    publish_ms: S.summary(Enum.map(updates, & &1.publish_ms)),
    fire_ms: S.summary(fire_ms),
    fire_after_publish_ms: S.summary(fire_after_publish_ms),
    last_subscriber_ms: S.summary(sub_ms),
    feed_ms: S.summary(feed_ms),
    feed_events: length(feed_events),
    feed_events_by_kind: Enum.frequencies_by(feed_events, fn {{kind, _}, _} -> kind end),
    story_refires: story_fires,
    other_fires:
      other_fires
      |> Enum.map(fn {{type, id}, n} ->
        %{type: type, id: id, fires: n, story: id == story.id}
      end),
    repeat_update_fires: repeat_update_fires,
    queue_depth: %{
      total: S.summary(total_depth),
      firing: S.summary(depth.("firing")),
      search: S.summary(depth.("search")),
      webhooks: S.summary(depth.("webhooks"))
    },
    repo:
      Map.update!(
        repo,
        :sources,
        &(&1 |> Enum.sort_by(fn {_, n} -> -n end) |> Enum.take(12) |> Map.new())
      ),
    pg: pg,
    wave: %{
      references: length(updates),
      refired: refired.(),
      drained: wave_drain == :ok,
      edit_ms: S.ms(w1 - w0),
      feed_events: length(LiveBench.Feed.between(w0, System.monotonic_time())),
      last_fire_ms: wave_last && S.ms(wave_last - w0),
      firing_depth: S.summary(wave_depth),
      repo: Map.take(wave_repo, [:count, :time_ms]),
      pg: wave_pg
    }
  }
end

# Boot enqueues one-off jobs (backfills, the first cron ticks); let them pass.
Process.sleep(30_000)

results = Enum.map(legs, run_leg)

# The idle cost, after the legs: the same measurements with nothing published, so a
# leg's DB load can be read net of Oban's own polling and the app's timers.
IO.puts("\n== baseline: #{baseline_s} s idle")
sampler = LiveBench.Sampler.start()
LiveBench.Repo.reset()
pg0 = LiveBench.PgStat.snapshot()
Process.sleep(baseline_s * 1000)
_ = LiveBench.Sampler.collect(sampler)
Process.exit(sampler, :kill)
:persistent_term.erase(:lb_sampler)
baseline_repo = LiveBench.Repo.snapshot()

baseline = %{
  seconds: baseline_s,
  repo: baseline_repo,
  pg: LiveBench.PgStat.delta(pg0),
  queries_per_s: baseline_repo.count / max(baseline_s, 1),
  query_ms_per_s: baseline_repo.time_ms / max(baseline_s, 1)
}

File.write!(
  out,
  Jason.encode_to_iodata!(
    %{
      machine: LiveBench.Machine.info(),
      duration_s: duration_s,
      baseline: baseline,
      interval_ms: [interval_min, interval_max],
      legs: results
    },
    pretty: true
  )
)

IO.puts("\n## Results\n")

IO.puts(
  "| Subscribers | Updates | Publish p95 | Fire p50 | Fire p95 | Fire p99 | Feed event p95 | Feed events | Last subscriber p95 | Story re-fires | Other fires | Firing depth p95 / max | Total depth max | Queries / update | Query ms / update | Commits / update | load |"
)

IO.puts("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")

for r <- results do
  # Net of the idle baseline over the same wall time.
  net = fn v, per_s -> if r.updates > 0, do: (v - per_s * r.seconds) / r.updates, else: nil end
  base_commits = baseline.pg["xact_commit"] / max(baseline_s, 1)

  IO.puts(
    "| #{r.subscribers} | #{r.updates} | #{S.fmt(r.publish_ms.p95)} | #{S.fmt(r.fire_ms.p50)} | #{S.fmt(r.fire_ms.p95)} | " <>
      "#{S.fmt(r.fire_ms.p99)} | #{S.fmt(r.feed_ms.p95)} | #{r.feed_events} | #{S.fmt(r.last_subscriber_ms.p95)} | #{r.story_refires} | #{r.other_fires |> Enum.reject(& &1.story) |> Enum.map(& &1.fires) |> Enum.sum()} | " <>
      "#{S.fmt(r.queue_depth.firing.p95)} / #{S.fmt(r.queue_depth.firing.max)} | #{S.fmt(r.queue_depth.total.max)} | " <>
      "#{S.fmt(net.(r.repo.count, baseline.queries_per_s))} | #{S.fmt(net.(r.repo.time_ms, baseline.query_ms_per_s))} | " <>
      "#{S.fmt(net.(r.pg["xact_commit"], base_commits))} | #{r.loadavg_before} |"
  )
end

IO.puts(
  "\nIdle baseline over #{baseline_s} s: #{S.fmt(baseline.queries_per_s)} queries/s, " <>
    "#{S.fmt(baseline.query_ms_per_s)} query ms/s, #{S.fmt(baseline.pg["xact_commit"] / max(baseline_s, 1))} commits/s. " <>
    "Per-update figures above are net of it."
)

IO.puts("\n## Story edit (re-fire wave)\n")

IO.puts(
  "| Subscribers | Updates referencing | Re-fired | Edit ms | Last re-fire ms | Firing depth max | Feed events | Queries | Commits |"
)

IO.puts("|---|---|---|---|---|---|---|---|---|")

for %{wave: w} = r <- results do
  IO.puts(
    "| #{r.subscribers} | #{w.references} | #{w.refired}#{if w.drained, do: "", else: " (timed out)"} | #{S.fmt(w.edit_ms)} | " <>
      "#{S.fmt(w.last_fire_ms)} | #{S.fmt(w.firing_depth.max)} | #{w.feed_events} | #{w.repo.count} | #{w.pg["xact_commit"]} |"
  )
end

IO.puts("\nFull numbers in #{out}")
