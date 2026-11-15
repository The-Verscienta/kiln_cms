defmodule KilnCMS.Backups.RetentionTest do
  @moduledoc """
  `Retention.plan/4` (#2219), pure: which units of a hand-built inventory are
  kept, which go, and why. The effectful side (scan, import, fail closed, the
  last look before a delete) is in `RetentionRunTest`.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.{Artifact, Retention}
  alias KilnCMS.Backups.Retention.Policy

  @now 2_000_000_000
  @day 86_400
  @k 14
  @policy Policy.legacy(@k)

  ## Builders

  defp ago(days), do: @now - round(days * @day)

  defp file(name, role, part, days, opts) do
    %{
      name: name,
      role: role,
      part: part,
      type: Keyword.get(opts, :type, :regular),
      size: Keyword.get(opts, :size, 10),
      mtime: ago(days)
    }
  end

  # A db unit: the dump and its sidecar, `days` old.
  defp db(stamp, days, opts \\ []) do
    dump = file("kiln-db-#{stamp}.dump", :data, nil, days, Keyword.get(opts, :dump, []))
    sidecar = file(Artifact.sidecar_name(:db, stamp), :sidecar, nil, days, [])
    files = if Keyword.get(opts, :sidecar?, true), do: [dump, sidecar], else: [dump]
    unit(stamp, :db, files, opts)
  end

  # A media unit: the single archive (`parts: 1`, the default) or `parts`
  # numbered parts plus the sidecar. `part_opts` overrides one part's file opts.
  defp media(stamp, days, opts \\ []) do
    total = Keyword.get(opts, :parts, 1)
    skip = Keyword.get(opts, :missing, [])
    part_opts = Keyword.get(opts, :part_opts, %{})

    data =
      if total == 1 do
        [file("kiln-media-#{stamp}.tar.gz", :data, nil, days, Map.get(part_opts, 1, []))]
      else
        for i <- 1..total, i not in skip do
          file(Artifact.part_name(stamp, i), :data, i, days, Map.get(part_opts, i, []))
        end
      end

    sidecar? = Keyword.get(opts, :sidecar?, true)

    sidecar =
      file(Artifact.sidecar_name(:media, stamp), :sidecar, nil, days, opts[:sidecar] || [])

    extra = Keyword.get(opts, :extra, [])

    unit(stamp, :media, data ++ extra ++ if(sidecar?, do: [sidecar], else: []), opts)
  end

  defp unit(stamp, kind, files, opts) do
    %{
      stamp: stamp,
      kind: kind,
      files: files,
      partials: Enum.map(Keyword.get(opts, :partials, []), &ago/1)
    }
  end

  defp inventory(units, opts) do
    %{
      units: Map.new(units, &{{&1.stamp, &1.kind}, &1}),
      markers: MapSet.new(Keyword.get(opts, :markers, [])),
      work: MapSet.new(Keyword.get(opts, :work, [])),
      strays: Keyword.get(opts, :strays, [])
    }
  end

  defp ok_run(kinds, origin \\ :app, verified \\ true),
    do: %{
      status: :succeeded,
      origin: origin,
      artifacts: Enum.map(kinds, &%{kind: &1, verified: verified})
    }

  defp run_with(status, kinds \\ [:db, :media]),
    do: %{status: status, origin: :app, artifacts: Enum.map(kinds, &%{kind: &1, verified: true})}

  defp plan(units, runs \\ %{}, opts \\ []),
    do: Retention.plan(inventory(units, opts), runs, Keyword.get(opts, :policy, @policy), @now)

  # `%{{stamp, kind} => reason}` for the kept and the deleted.
  defp reasons(%{delete: delete, keep: keep}) do
    %{
      delete: Map.new(delete, &{{&1.stamp, &1.kind}, &1.reason}),
      keep: Map.new(keep, &{{&1.stamp, &1.kind}, &1.reason})
    }
  end

  @a "20260101-000000"
  @b "20260201-000000"
  @c "20260301-000000"
  @d "20260401-000000"

  describe "age (the legacy policy)" do
    test "expired?/3 is find -mtime +K: at least K + 1 whole days" do
      refute Retention.expired?(ago(@k + 1) + 1, @k, @now)
      assert Retention.expired?(ago(@k + 1) - 1, @k, @now)
      refute Retention.expired?(ago(@k + 0.9), @k, @now)
    end

    test "a recorded unit just inside K + 1 days stays; just past it goes" do
      runs = %{@a => ok_run([:db]), @b => ok_run([:db]), @c => ok_run([:db])}

      units = [
        db(@a, @k + 1.01),
        db(@b, @k + 0.99),
        # The newest, so neither of the others is protected by being newest.
        db(@c, 0)
      ]

      assert %{delete: %{{@a, :db} => {:expired, :keep_days, @k}}, keep: keep} =
               reasons(plan(units, runs))

      assert keep[{@b, :db}] == :keep_days
      assert keep[{@c, :db}] == :newest_verified
    end
  end

  describe "the newest backups of each component" do
    test "the newest verified unit of each kind is kept even when everything is old" do
      runs = Map.new([@a, @b, @c], &{&1, ok_run([:db, :media])})
      units = for s <- [@a, @b, @c], u <- [db(s, 400), media(s, 400)], do: u

      assert %{delete: delete, keep: keep} = reasons(plan(units, runs))
      assert keep == %{{@c, :db} => :newest_verified, {@c, :media} => :newest_verified}
      assert Map.keys(delete) |> Enum.sort() == [{@a, :db}, {@a, :media}, {@b, :db}, {@b, :media}]
    end

    test "a newer complete set from a failed run and the older verified one are both kept" do
      runs = %{
        @a => ok_run([:db]),
        @b => ok_run([:db]),
        @c => %{run_with(:failed) | artifacts: [%{kind: :db, verified: false}]}
      }

      units = [db(@a, 400), db(@b, 400), db(@c, 400)]

      assert %{
               delete: %{{@a, :db} => {:expired, :keep_days, @k}},
               keep: %{{@b, :db} => :newest_verified, {@c, :db} => :newest_complete}
             } = reasons(plan(units, runs))
    end

    test "an app run's unverified artifact is not good; an imported one need not be verified" do
      runs = %{
        @a => ok_run([:db], :app),
        @b => ok_run([:db], :app, false),
        @c => ok_run([:media], :imported, false),
        @d => ok_run([:media], :app, false)
      }

      units = [db(@a, 400), db(@b, 400), media(@c, 400), media(@d, 400)]

      assert %{keep: keep, delete: delete} = reasons(plan(units, runs))
      assert keep[{@a, :db}] == :newest_verified
      assert keep[{@b, :db}] == :newest_complete
      assert keep[{@c, :media}] == :newest_verified
      assert keep[{@d, :media}] == :newest_complete
      assert delete == %{}
    end

    test "an incomplete newer unit protects nothing; the newest complete one is kept" do
      # @c's media has a gap; @b is the newest complete (and nothing is verified).
      units = [media(@a, 400), media(@b, 400), media(@c, 400, parts: 3, missing: [2])]
      runs = Map.new([@a, @b, @c], &{&1, run_with(:failed, [:media])})

      assert %{
               keep: %{{@b, :media} => :newest_complete},
               delete: %{{@a, :media} => _, {@c, :media} => _}
             } = reasons(plan(units, runs))
    end

    test "a verified unit that is not complete on disk is not the newest verified" do
      runs = %{@a => ok_run([:media]), @b => ok_run([:media])}
      units = [media(@a, 400), media(@b, 400, parts: 2, sidecar?: false)]

      assert %{keep: %{{@a, :media} => :newest_verified}, delete: %{{@b, :media} => _}} =
               reasons(plan(units, runs))
    end
  end

  describe "last_good (#2219)" do
    test "is the newest verified stamp of each kind, never a newer complete one" do
      runs = %{
        @a => ok_run([:db, :media]),
        @b => ok_run([:db]),
        @c => %{run_with(:failed) | artifacts: [%{kind: :db, verified: false}]}
      }

      units = [db(@a, 400), media(@a, 400), db(@b, 400), db(@c, 400), media(@c, 1)]

      assert %{last_good: %{db: @b, media: @a}} = plan(units, runs)
    end

    test "is nil for a kind with no verified unit, or none at all" do
      runs = %{@a => run_with(:failed)}

      assert %{last_good: %{db: nil, media: nil}} = plan([db(@a, 400)], runs)
      assert %{last_good: %{db: nil, media: nil}} = plan([])
    end

    test "never names a unit in flight" do
      runs = Map.new([@a, @b], &{&1, ok_run([:db])})

      assert %{last_good: %{db: @a}} = plan([db(@a, 400), db(@b, 0)], runs, work: [@b])
    end
  end

  describe "who may hold the newest slots" do
    test "a run in flight never takes newest complete from the last finished backup" do
      # Every earlier run failed, so nothing is verified; @c is the worker's
      # own run, still running.
      runs = %{
        @a => run_with(:failed),
        @b => run_with(:failed),
        @c => run_with(:running)
      }

      units = [db(@a, 400), db(@b, 400), db(@c, 0)]

      assert %{
               keep: %{{@b, :db} => :newest_complete, {@c, :db} => :in_flight},
               delete: %{{@a, :db} => _}
             } = reasons(plan(units, runs))
    end

    test "a unit in .work never takes newest verified, even with a succeeded run" do
      runs = Map.new([@a, @b, @c], &{&1, ok_run([:db])})

      assert %{
               keep: %{{@b, :db} => :newest_verified, {@c, :db} => :in_flight},
               delete: %{{@a, :db} => _}
             } = reasons(plan([db(@a, 400), db(@b, 400), db(@c, 400)], runs, work: [@c]))
    end

    test "a future-dated or impossible stamp can't hold a slot; it ages as usual" do
      future = "29991231-000000"
      impossible = "20251399-000000"
      runs = Map.new([@a, @b, future, impossible], &{&1, ok_run([:db, :media])})

      units = [
        db(@a, 400),
        db(@b, 400),
        db(future, 400),
        media(@b, 400),
        media(impossible, 400),
        media(future, 3)
      ]

      assert %{keep: keep, delete: delete} = reasons(plan(units, runs))
      assert keep[{@b, :db}] == :newest_verified
      assert keep[{@b, :media}] == :newest_verified
      assert keep[{future, :media}] == :keep_days
      assert Map.keys(delete) |> Enum.sort() == [{impossible, :media}, {@a, :db}, {future, :db}]
    end

    test "plausible_stamp?/2: a real instant, no later than a day ahead" do
      now = DateTime.to_unix(~U[2026-11-08 12:00:00Z])

      assert Retention.plausible_stamp?("20241229-235959", now)
      assert Retention.plausible_stamp?("20240229-000000", now)
      assert Retention.plausible_stamp?("20261109-120000", now)
      refute Retention.plausible_stamp?("20261109-120001", now)
      refute Retention.plausible_stamp?("20250229-000000", now)
      refute Retention.plausible_stamp?("21000229-000000", now)
      refute Retention.plausible_stamp?("20251399-000000", now)
      refute Retention.plausible_stamp?("20250431-000000", now)
      refute Retention.plausible_stamp?("20250101-240000", now)
      refute Retention.plausible_stamp?("20250101-006000", now)
      refute Retention.plausible_stamp?("20250101-000060", now)
      refute Retention.plausible_stamp?("19691231-235959", now)
    end
  end

  describe "recovery points" do
    test "a marker pins every component of its stamp, before any other rule" do
      runs = Map.new([@a, @b], &{&1, ok_run([:db, :media])})
      units = [db(@a, 400), media(@a, 400), db(@b, 0), media(@b, 0)]

      assert %{keep: keep, delete: delete} = reasons(plan(units, runs, markers: [@a]))
      assert keep[{@a, :db}] == :recovery_point
      assert keep[{@a, :media}] == :recovery_point
      assert delete == %{}
    end

    test "a marker on the newest stamp leaves the older units to age as usual" do
      runs = Map.new([@a, @b], &{&1, ok_run([:db])})

      assert %{keep: %{{@b, :db} => :recovery_point}, delete: %{{@a, :db} => _}} =
               reasons(plan([db(@a, 400), db(@b, 400)], runs, markers: [@b]))
    end

    test "an orphan marker (no backup of that stamp) changes nothing" do
      runs = Map.new([@a, @b], &{&1, ok_run([:db])})

      assert %{delete: %{{@a, :db} => _}, keep: %{{@b, :db} => :newest_verified}} =
               reasons(plan([db(@a, 400), db(@b, 400)], runs, markers: [@c]))
    end
  end

  describe "in flight" do
    setup do
      runs = %{@a => ok_run([:db, :media]), @c => ok_run([:db, :media])}
      %{runs: runs, newest: [db(@c, 0), media(@c, 0)]}
    end

    test "a running Run", %{newest: newest} do
      runs = %{@a => run_with(:running), @c => ok_run([:db, :media])}

      assert %{keep: %{{@a, :db} => :in_flight, {@a, :media} => :in_flight}} =
               reasons(plan([db(@a, 400), media(@a, 400) | newest], runs))
    end

    test "a .work/<stamp> directory", %{runs: runs, newest: newest} do
      assert %{keep: %{{@a, :db} => :in_flight, {@a, :media} => :in_flight}} =
               reasons(plan([db(@a, 400), media(@a, 400) | newest], runs, work: [@a]))
    end

    test "a fresh .partial protects its own unit only", %{runs: runs, newest: newest} do
      fresh = (Retention.partial_grace_s() - 60) / @day

      assert %{keep: %{{@a, :media} => :in_flight}, delete: %{{@a, :db} => _}} =
               reasons(plan([db(@a, 400), media(@a, 400, partials: [fresh]) | newest], runs))
    end

    test "an old .partial neither protects nor makes the unit incomplete" do
      old = (Retention.partial_grace_s() + 60) / @day
      units = [media(@a, 400), media(@b, 400, partials: [old])]

      # No history at all: @b is still the newest complete unit (the stale
      # partial beside it is ignored), and it is not in flight.
      assert %{keep: %{{@b, :media} => :newest_complete}, delete: %{{@a, :media} => _}} =
               reasons(plan(units, %{}))
    end
  end

  describe "units with no usable history" do
    setup do
      %{newest: [db(@d, 0), media(@d, 0)], runs: %{@d => ok_run([:db, :media])}}
    end

    test "no Run row: kept until keep_days, then deleted as unrecorded", ctx do
      assert %{
               delete: %{{@a, :db} => {:expired, :unrecorded, @k}},
               keep: %{{@b, :db} => :unrecorded}
             } = reasons(plan([db(@a, 400), db(@b, 3) | ctx.newest], ctx.runs))
    end

    test "a skipped Run, or one with no artifact of this kind, is unrecorded too", ctx do
      runs =
        Map.merge(ctx.runs, %{@a => run_with(:skipped, []), @b => ok_run([:media])})

      assert %{
               keep: %{{@a, :db} => :unrecorded, {@b, :db} => :unrecorded},
               delete: %{}
             } = reasons(plan([db(@a, 3), db(@b, 3) | ctx.newest], runs))
    end
  end

  describe "components are independent" do
    test "an old dump goes while the same stamp's fresh media stays" do
      runs = Map.new([@a, @b], &{&1, ok_run([:db, :media])})
      units = [db(@a, 400), media(@a, 1), db(@b, 0), media(@b, 0)]

      assert %{delete: delete, keep: keep} = reasons(plan(units, runs))
      assert Map.keys(delete) == [{@a, :db}]
      assert keep[{@a, :media}] == :keep_days
    end

    test "a fresh sidecar keeps its unit: the newest regular file decides" do
      runs = Map.new([@a, @b], &{&1, ok_run([:media])})

      stale = media(@a, 400, parts: 2)
      fresh_sidecar = %{stale | files: Enum.map(stale.files, &bump_sidecar/1)}

      assert %{keep: %{{@a, :media} => :keep_days}} =
               reasons(plan([fresh_sidecar, media(@b, 0)], runs))
    end
  end

  defp bump_sidecar(%{role: :sidecar} = file), do: %{file | mtime: ago(1)}
  defp bump_sidecar(file), do: file

  describe "complete?/1" do
    test "a db unit needs a regular, non-empty dump" do
      assert Retention.complete?(db(@a, 0))
      assert Retention.complete?(db(@a, 0, sidecar?: false))
      refute Retention.complete?(db(@a, 0, dump: [size: 0]))
      refute Retention.complete?(db(@a, 0, dump: [type: :symlink]))
      refute Retention.complete?(%{db(@a, 0) | files: tl(db(@a, 0).files)})
    end

    test "a legacy single archive is complete with or without a sidecar" do
      assert Retention.complete?(media(@a, 0))
      assert Retention.complete?(media(@a, 0, sidecar?: false))
      refute Retention.complete?(media(@a, 0, part_opts: %{1 => [size: 0]}))
      refute Retention.complete?(media(@a, 0, part_opts: %{1 => [type: :directory]}))
    end

    test "a part set needs parts 01..N, each solid, and a solid sidecar" do
      assert Retention.complete?(media(@a, 0, parts: 3))
      refute Retention.complete?(media(@a, 0, parts: 3, missing: [2]))
      refute Retention.complete?(media(@a, 0, parts: 3, missing: [1]))
      refute Retention.complete?(media(@a, 0, parts: 3, sidecar?: false))
      refute Retention.complete?(media(@a, 0, parts: 3, sidecar: [size: 0]))
      refute Retention.complete?(media(@a, 0, parts: 3, sidecar: [type: :symlink]))
      refute Retention.complete?(media(@a, 0, parts: 3, part_opts: %{2 => [size: 0]}))
      refute Retention.complete?(media(@a, 0, parts: 3, part_opts: %{3 => [type: :symlink]}))
    end

    test "a single archive beside parts is not complete" do
      single = file("kiln-media-#{@a}.tar.gz", :data, nil, 0, [])
      refute Retention.complete?(media(@a, 0, parts: 2, extra: [single]))
    end

    test "three-digit parts (part100) count like any other" do
      assert Retention.complete?(media(@a, 0, parts: 100))
      refute Retention.complete?(media(@a, 0, parts: 101, missing: [100]))
    end
  end

  describe "what a plan entry holds" do
    test "regular files only, data first, parts in order, the sidecar last" do
      runs = Map.new([@a, @b], &{&1, ok_run([:media])})
      link = file("kiln-media-#{@a}.part12.tar.gz", :data, 12, 400, type: :symlink)
      units = [media(@a, 400, parts: 11, extra: [link]), media(@b, 0)]

      assert %{delete: [entry]} = plan(units, runs)
      assert entry.sub == "media"
      assert hd(entry.files) == Artifact.part_name(@a, 1)
      assert List.last(entry.files) == Artifact.sidecar_name(:media, @a)
      refute Artifact.part_name(@a, 12) in entry.files

      parts = Enum.slice(entry.files, 0, 11)
      assert parts == Enum.map(1..11, &Artifact.part_name(@a, &1))
    end

    test "a unit of nothing but symlinks is not in the plan at all" do
      only_links = media(@a, 400, part_opts: %{1 => [type: :symlink]}, sidecar?: false)

      assert plan([only_links]) == %{
               delete: [],
               keep: [],
               last_good: %{db: nil, media: nil},
               holds: %{db: [], media: []}
             }
    end

    test "a stray ages alone under keep_days" do
      strays = [
        %{name: "kiln-media-notes.txt", sub: "media", mtime: ago(400)},
        %{name: "kiln-db-other.txt", sub: "db", mtime: ago(1)}
      ]

      assert %{delete: [old], keep: [young]} = plan([], %{}, strays: strays)

      assert %{kind: :stray, files: ["kiln-media-notes.txt"], reason: {:expired, :stray, @k}} =
               old

      assert %{kind: :stray, files: ["kiln-db-other.txt"], reason: :keep_days} = young
    end
  end

  describe "Policy" do
    test "validate/1 takes a positive keep_days only" do
      assert {:ok, %Policy{keep_days: 7}} = Policy.validate(Policy.legacy(7))
      assert {:error, :invalid_policy} = Policy.validate(Policy.legacy(0))
      assert {:error, :invalid_policy} = Policy.validate(Policy.legacy(-1))
      assert {:error, :invalid_policy} = Policy.validate(Policy.legacy("14"))
      assert {:error, :invalid_policy} = Policy.validate(%{keep_days: 14})
      assert {:error, :invalid_policy} = Policy.validate(nil)
    end
  end

  describe "keep N (#2219)" do
    # Stamp `i` days after 2026-01-01: a larger `i` is a newer backup.
    defp st(i),
      do: ~D[2026-01-01] |> Date.add(i) |> Calendar.strftime("%Y%m%d") |> Kernel.<>("-000000")

    defp sched(kinds, ids, opts \\ []) do
      %{
        status: Keyword.get(opts, :status, :succeeded),
        origin: :app,
        trigger: Keyword.get(opts, :trigger, "schedule"),
        scheduled_components: Keyword.get(opts, :scheduled, kinds),
        schedule_ids: ids,
        artifacts: Enum.map(kinds, &%{kind: &1, verified: Keyword.get(opts, :verified, true)})
      }
    end

    defp manual(kinds), do: Map.put(ok_run(kinds), :trigger, "manual")
    defp imported(kinds), do: Map.put(ok_run(kinds, :imported, nil), :trigger, "cron")

    defp rule(id, kinds, count, days \\ @k),
      do: %{id: id, kinds: kinds, keep_count: count, keep_days: days}

    defp policy(rules), do: %Policy{keep_days: @k, schedules: rules}

    # The newest unit (`st(100)`, a manual one) holds rules 3 and 4, so the
    # units under test are decided by the rules after them.
    defp newest_db, do: {db(st(100), 0), %{st(100) => manual([:db])}}

    defp keep_plan(units_runs, rules, opts \\ []) do
      {newest, newest_runs} = newest_db()
      units = [newest | Enum.map(units_runs, &elem(&1, 0))]
      runs = Enum.reduce(units_runs, newest_runs, fn {u, r}, acc -> Map.put(acc, u.stamp, r) end)
      plan(units, runs, Keyword.put(opts, :policy, policy(rules)))
    end

    defp kept_by_count(plan),
      do: for(%{reason: {:keep_count, ids}} = e <- plan.keep, into: %{}, do: {e.stamp, ids})

    test "a schedule keeps its newest N, however old" do
      units = for i <- 1..5, do: {db(st(i), 400), sched([:db], ["s"])}
      plan = keep_plan(units, [rule("s", [:db], 3)])

      assert kept_by_count(plan) == %{st(3) => ["s"], st(4) => ["s"], st(5) => ["s"]}
      assert reasons(plan).delete |> Map.keys() |> Enum.sort() == [{st(1), :db}, {st(2), :db}]
    end

    test "without keep fields the plan is the legacy plan" do
      units = [
        {db(st(1), 400), sched([:db], ["s"])},
        {db(st(2), 3), sched([:db], ["s"])},
        {db(st(3), 400), imported([:db])},
        {db(st(4), 400), nil}
      ]

      with_schedule = keep_plan(units, [rule("s", [:db], nil)])
      legacy = keep_plan(units, [])

      assert with_schedule == legacy
      assert legacy.holds == %{db: [], media: []}
    end

    test "keep more: the schedule's own and the cron-made backups together" do
      units = [
        {db(st(1), 400), sched([:db], ["s"])},
        {db(st(2), 400), sched([:db], ["s"])},
        {db(st(3), 400), imported([:db])},
        {db(st(4), 400), imported([:db])}
      ]

      # Own newest 2: st(1), st(2). Own and cron newest 2: st(3), st(4).
      plan = keep_plan(units, [rule("s", [:db], 2)])
      assert Map.keys(kept_by_count(plan)) |> Enum.sort() == [st(1), st(2), st(3), st(4)]
    end

    test "a failed or unverified backup doesn't take a slot" do
      units = [
        {db(st(1), 400), sched([:db], ["s"])},
        {db(st(2), 400), sched([:db], ["s"], status: :failed)},
        {db(st(3), 400), sched([:db], ["s"], verified: false)}
      ]

      plan = keep_plan(units, [rule("s", [:db], 1)])
      assert kept_by_count(plan) == %{st(1) => ["s"]}
      assert {:expired, :keep_days, @k} = reasons(plan).delete[{st(2), :db}]
      assert {:expired, :keep_days, @k} = reasons(plan).delete[{st(3), :db}]
    end

    test "a recovery point doesn't take a slot, and stays one" do
      units = [{db(st(1), 400), sched([:db], ["s"])}, {db(st(2), 400), sched([:db], ["s"])}]
      plan = keep_plan(units, [rule("s", [:db], 1)], markers: [st(2)])

      assert kept_by_count(plan) == %{st(1) => ["s"]}
      assert reasons(plan).keep[{st(2), :db}] == :recovery_point
    end

    test "a unit in flight or of an implausible stamp doesn't take a slot" do
      future = "29991231-000000"

      units = [
        {db(st(1), 400), sched([:db], ["s"])},
        {db(st(2), 400), sched([:db], ["s"])},
        {db(future, 400), sched([:db], ["s"])}
      ]

      plan = keep_plan(units, [rule("s", [:db], 1)], work: [st(2)])
      assert kept_by_count(plan) == %{st(1) => ["s"]}
      assert reasons(plan).keep[{st(2), :db}] == :in_flight
      assert {:expired, :keep_days, @k} = reasons(plan).delete[{future, :db}]
    end

    test "manual and console backups are never counted" do
      units = [
        {db(st(1), 400), sched([:db], ["s"])},
        {db(st(2), 400), manual([:db])},
        {db(st(3), 400), Map.put(ok_run([:db]), :trigger, "console")}
      ]

      plan = keep_plan(units, [rule("s", [:db], 2)])
      assert kept_by_count(plan) == %{st(1) => ["s"]}
    end

    test "a fold with a manual request, in either order, is not the schedule's own" do
      # B1: the manual request wins the trigger, so the run is never counted
      # and never ages out sooner than BACKUP_KEEP_DAYS, whatever the schedule.
      folded = sched([:db], ["s"], trigger: "manual")

      plan =
        keep_plan(
          [{db(st(1), 400), folded}, {db(st(2), 10), folded}, {db(st(3), 40), folded}],
          [rule("s", [:db], 5, 3)]
        )

      assert kept_by_count(plan) == %{}
      assert reasons(plan).keep[{st(2), :db}] == :keep_days
      assert {:expired, :keep_days, @k} = reasons(plan).delete[{st(1), :db}]

      # A schedule keeping longer still lifts it: max(BACKUP_KEEP_DAYS, D).
      plan = keep_plan([{db(st(3), 40), folded}], [rule("s", [:db], nil, 60)])
      assert reasons(plan).keep[{st(3), :db}] == :schedule_floor
      assert plan.holds.db == [st(3)]
    end

    test "only the scheduled components of a run count" do
      # The schedule asked for the database; a manual request folded media in.
      run = sched([:db, :media], ["s"], scheduled: [:db])

      units = [
        {db(st(1), 400), run},
        {media(st(1), 400), run},
        {media(st(2), 0), manual([:media])}
      ]

      plan = keep_plan(units, [rule("s", [:db, :media], 1)])
      assert reasons(plan).keep[{st(1), :db}] == {:keep_count, ["s"]}
      assert {:expired, :keep_days, @k} = reasons(plan).delete[{st(1), :media}]
    end

    test "two schedules: the union of what each keeps" do
      units = [
        {db(st(1), 400), sched([:db], ["a"])},
        {db(st(2), 400), sched([:db], ["b"])},
        {db(st(3), 400), sched([:db], ["a", "b"])}
      ]

      plan = keep_plan(units, [rule("a", [:db], 2), rule("b", [:db], 1)])

      assert kept_by_count(plan) == %{st(1) => ["a"], st(3) => ["a", "b"]}
      assert {:expired, :keep_days, @k} = reasons(plan).delete[{st(2), :db}]
    end

    test "each kind is counted on its own" do
      units = [
        {db(st(1), 400), sched([:db, :media], ["s"])},
        {media(st(1), 400), sched([:db, :media], ["s"])},
        {media(st(2), 400), sched([:media], ["s"])},
        {media(st(3), 0), sched([:media], ["s"])}
      ]

      plan = keep_plan(units, [rule("s", [:db, :media], 1)])
      # db: st(1) is its only own one. media: st(3), the newest, takes the slot.
      assert reasons(plan).keep[{st(1), :db}] == {:keep_count, ["s"]}
      assert reasons(plan).keep[{st(3), :media}] == :newest_verified
      assert Map.has_key?(reasons(plan).delete, {st(1), :media})
      assert Map.has_key?(reasons(plan).delete, {st(2), :media})
    end

    test "a deleted schedule's backups count like cron-made ones and age at the floor" do
      gone = sched([:db], ["deleted"])

      units = [
        {db(st(1), 400), sched([:db], ["s"])},
        {db(st(2), 400), gone},
        {db(st(3), 50), gone}
      ]

      # Keep more over own and cron-like: st(3) and st(2).
      plan = keep_plan(units, [rule("s", [:db], 2, 60)])
      assert Map.keys(kept_by_count(plan)) |> Enum.sort() == [st(1), st(2), st(3)]

      # No live schedule covering the kind: plain BACKUP_KEEP_DAYS, never less.
      plan =
        keep_plan([{db(st(2), 10), gone}, {db(st(3), 400), gone}], [rule("x", [:media], 1, 2)])

      assert reasons(plan).keep[{st(2), :db}] == :keep_days
      assert {:expired, :keep_days, @k} = reasons(plan).delete[{st(3), :db}]
    end

    test "a schedule's keep_days below BACKUP_KEEP_DAYS ages its own backups sooner" do
      units = [{db(st(1), 4), sched([:db], ["s"])}, {db(st(2), 2), sched([:db], ["s"])}]
      plan = keep_plan(units, [rule("s", [:db], nil, 2)])

      assert {:expired, :schedule, 2} = reasons(plan).delete[{st(1), :db}]
      assert reasons(plan).keep[{st(2), :db}] == :schedule
      assert plan.holds.db == [st(2)]
    end

    test "a schedule's keep_days above BACKUP_KEEP_DAYS keeps its own backups longer" do
      units = [{db(st(1), 50), sched([:db], ["s"])}, {db(st(2), 70), sched([:db], ["s"])}]
      plan = keep_plan(units, [rule("s", [:db], nil, 60)])

      assert reasons(plan).keep[{st(1), :db}] == :schedule
      assert {:expired, :schedule, 60} = reasons(plan).delete[{st(2), :db}]
    end

    test "unrecorded and imported backups never age out sooner than a covering schedule's" do
      units = [
        {db(st(1), 50), nil},
        {db(st(2), 50), imported([:db])},
        {media(st(3), 50), imported([:media])},
        {media(st(4), 0), imported([:media])}
      ]

      plan = keep_plan(units, [rule("s", [:db], nil, 60), rule("t", [:media], nil, 2)])

      assert reasons(plan).keep[{st(1), :db}] == :unrecorded
      assert reasons(plan).keep[{st(2), :db}] == :schedule_floor
      # A schedule keeping less never lowers the floor.
      assert {:expired, :keep_days, @k} = reasons(plan).delete[{st(3), :media}]
      assert plan.holds.db == [st(1), st(2)]
    end

    test "rules 1 to 4 still decide first" do
      units = for i <- 1..3, do: {db(st(i), 400), sched([:db], ["s"])}
      plan = keep_plan(units, [rule("s", [:db], 5)], markers: [st(1)], work: [st(2)])

      assert reasons(plan).keep[{st(1), :db}] == :recovery_point
      assert reasons(plan).keep[{st(2), :db}] == :in_flight
      assert reasons(plan).keep[{st(3), :db}] == {:keep_count, ["s"]}
      assert reasons(plan).keep[{st(100), :db}] == :newest_verified
    end

    test "holds: every unit a keep count or a schedule's age rule keeps, recovery points included" do
      units = [
        {db(st(1), 400), sched([:db], ["s"])},
        {db(st(2), 400), sched([:db], ["s"])},
        {db(st(3), 30), sched([:db], ["s"])},
        {db(st(4), 400), manual([:db])}
      ]

      # st(1) is a recovery point, never counted, and too old for the age
      # rule; st(2) and st(3) are the newest two (st(3) young enough to be
      # held by its age too); st(4) is a manual backup.
      plan = keep_plan(units, [rule("s", [:db], 2, 60)], markers: [st(1)])

      assert plan.holds.db == [st(2), st(3)]
      assert plan.holds.media == []

      units = [{db(st(1), 30), sched([:db], ["s"])}]
      plan = keep_plan(units, [rule("s", [:db], nil, 60)], markers: [st(1)])
      assert reasons(plan).keep[{st(1), :db}] == :recovery_point
      assert plan.holds.db == [st(1)]
    end
  end

  describe "Policy from schedules (#2219)" do
    test "from_schedules/2 resolves keep_days and drops a component it doesn't know" do
      schedules = [
        %{
          id: "a",
          components: [:db, %KilnCMS.Types.UnknownAtom{value: "x"}],
          keep_count: 3,
          keep_days: nil
        },
        %{id: "b", components: [:media], keep_count: nil, keep_days: 30}
      ]

      assert %Policy{keep_days: 14, schedules: [a, b]} = Policy.from_schedules(14, schedules)
      assert a == %{id: "a", kinds: [:db], keep_count: 3, keep_days: 14}
      assert b == %{id: "b", kinds: [:media], keep_count: nil, keep_days: 30}
    end

    test "validate/1 refuses a rule that isn't positive or well formed" do
      ok = rule("a", [:db], 3)
      assert {:ok, _} = Policy.validate(policy([ok, rule("b", [:media], nil, 1)]))

      for bad <- [
            %{ok | keep_count: 0},
            %{ok | keep_days: 0},
            %{ok | keep_days: nil},
            %{ok | kinds: [:other]},
            %{ok | id: nil},
            Map.delete(ok, :keep_count)
          ] do
        assert {:error, :invalid_policy} = Policy.validate(policy([bad])), inspect(bad)
      end

      assert {:error, :invalid_policy} = Policy.validate(%Policy{keep_days: 14, schedules: nil})
    end
  end

  describe "Artifact names" do
    test "keep_name/1 and parse_keep_name/1 round-trip" do
      assert Artifact.keep_name(@a) == "kiln-#{@a}.keep"
      assert {:ok, @a} = Artifact.parse_keep_name(Artifact.keep_name(@a))
      assert :error = Artifact.parse_keep_name("kiln-foo.keep")
      assert :error = Artifact.parse_keep_name("kiln-db-#{@a}.keep")
      assert :error = Artifact.parse_keep_name("kiln-#{@a}.keep.partial")
      assert :error = Artifact.parse_file(Artifact.keep_name(@a))
    end

    test "parse_sidecar_name/1" do
      assert {:ok, %{kind: :media, stamp: @a, partial?: false}} =
               Artifact.parse_sidecar_name(Artifact.sidecar_name(:media, @a))

      assert {:ok, %{kind: :db, stamp: @a, partial?: true}} =
               Artifact.parse_sidecar_name(Artifact.sidecar_name(:db, @a) <> ".partial")

      assert :error = Artifact.parse_sidecar_name("kiln-db-#{@a}.dump")
      assert :error = Artifact.parse_sidecar_name(Artifact.keep_name(@a))
    end
  end
end
