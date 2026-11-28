defmodule KilnCMS.Backups.ProgressTest do
  @moduledoc """
  Live backup progress over PubSub (#3489): the versioned, whitelisted
  payload, the approximate percent, and that every producer sends only once
  its write has committed.

  The topic is instance-wide and other suites write runs while this one
  runs, so every assertion matches the test's own chain, stamp or run id.
  `async: false`: it changes the VM-wide `Application` env and takes the
  singleton backup lock.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, Lock, Progress, Recorder, Steps}
  alias KilnCMS.Repo
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bkp_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    File.mkdir_p!(dir)

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: nil, keep_days: 14)
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    :ok = Progress.subscribe()
    :ok
  end

  defp stamp do
    n = System.unique_integer([:positive])
    "20260104-" <> String.pad_leading(Integer.to_string(rem(n, 1_000_000)), 6, "0")
  end

  defp lock_row, do: Backups.backup_lock!(actor: Backups.system())

  defp assert_whitelisted(payload) do
    assert payload |> Map.keys() |> Enum.sort() == Enum.sort(Progress.keys())
    payload
  end

  describe "the payload" do
    test "has exactly the whitelisted keys, whatever it is given" do
      secrets = %{
        log: "pg_dump: password=hunter2",
        error: "connection refused to db.internal",
        path: "/srv/backups/media/alice-passport.jpg",
        file: "alice-passport.jpg",
        env: %{"DATABASE_URL" => "postgres://u:hunter2@h/db"},
        destination: %{"remote" => ":s3,secret_access_key=x:bucket"}
      }

      for fields <- [
            %{},
            secrets,
            Map.merge(secrets, %{chain: "c", stamp: "s", run: "r", step: :dump, part: 2}),
            %{chain: 1, stamp: :atom, run: %{}, step: "dump", part: -1, phase: :done},
            %{percent: 101, step: :not_a_step, phase: "running"}
          ] do
        payload = assert_whitelisted(Progress.payload(fields))
        rendered = inspect(payload)

        for leak <- ["hunter2", "passport", "db.internal", "secret_access_key"],
            do: refute(rendered =~ leak)
      end
    end

    test "keeps ids as strings, and step and phase only as the lock has them" do
      assert %{chain: "c", stamp: "s", run: "r", step: :archive, part: 2, phase: :finishing} =
               Progress.payload(%{
                 chain: "c",
                 stamp: "s",
                 run: "r",
                 step: "archive",
                 part: 2,
                 phase: :finishing
               })

      assert %{chain: nil, step: nil, part: nil, phase: nil, percent: nil} =
               Progress.payload(%{chain: 7, step: :nope, part: 0, phase: :paused, percent: -1})

      for step <- Lock.steps(), do: assert(%{step: ^step} = Progress.payload(%{step: step}))
    end

    test "a release still names the chain it released" do
      held = %Lock{chain_id: "chain-a", stamp: "20260104-000001", step: :finish, part: nil}
      cleared = %Lock{chain_id: nil, stamp: nil, step: nil, part: nil}

      assert %{chain: "chain-a", stamp: "20260104-000001", step: nil, percent: nil} =
               Progress.lock(cleared, held)
    end
  end

  describe "percent/3" do
    test "start is 0, the steps climb, and a held lock never reads 100" do
      assert Progress.percent(:start, nil, nil) == 0

      percents =
        for step <- [:dump, :plan, :archive, :checksum, :prune, :offsite, :finish],
            do: Progress.percent(step, nil, nil)

      assert percents == Enum.sort(percents)
      assert Enum.uniq(percents) == percents
      assert Enum.all?(percents, &(&1 in 0..99))
    end

    test "the archive step splits its share by part" do
      first = Progress.percent(:archive, 1, 4)
      third = Progress.percent(:archive, 3, 4)

      assert first == Progress.percent(:archive, nil, nil)
      assert third > first
      assert third < Progress.percent(:checksum, nil, nil)
      # A part past its total, or no total, is the step's start.
      assert Progress.percent(:archive, 9, 4) == first
    end

    test "a step outside the unit list doesn't raise" do
      assert Progress.percent(nil, nil, nil) == nil
      assert Progress.percent(:unknown, 1, 2) == nil
      assert Progress.percent("not-a-step", nil, nil) == nil
      assert Progress.percent("dump", nil, nil) == Progress.percent(:dump, nil, nil)
      assert Progress.percent(:resend, 2, 4) == 25
      assert Progress.percent(:resend, nil, nil) == nil
    end
  end

  describe "after the commit, never inside it" do
    test "broadcast/1 sends nothing while a transaction is open" do
      chain = Ash.UUID.generate()

      {:ok, :done} =
        Repo.transaction(fn ->
          Progress.broadcast(%{chain: chain})
          :done
        end)

      refute_receive {:kiln_backup_progress, _, %{chain: ^chain}}, 100

      Progress.broadcast(%{chain: chain})
      assert_receive {:kiln_backup_progress, 1, %{chain: ^chain} = payload}
      assert_whitelisted(payload)
    end

    test "a message queued in with_lock goes out once it commits" do
      chain = Ash.UUID.generate()

      {:ok, :held} =
        Chain.with_lock(fn _row ->
          Progress.after_commit(%{chain: chain})
          refute_received {:kiln_backup_progress, _, %{chain: ^chain}}
          {:ok, :held}
        end)

      assert_receive {:kiln_backup_progress, 1, %{chain: ^chain}}
    end

    test "a rolled-back with_lock sends nothing" do
      chain = Ash.UUID.generate()

      assert {:error, :nope} =
               Chain.with_lock(fn _row ->
                 Progress.after_commit(%{chain: chain})
                 {:error, :nope}
               end)

      refute_receive {:kiln_backup_progress, _, %{chain: ^chain}}, 100
    end

    test "a request whose lock write rolls back announces no chain" do
      parent = self()

      # The claim runs inside the lock transaction, after the decision's
      # Lock write: the chain it reads there is the one that never was.
      claim = fn _status ->
        send(parent, {:chain, lock_row().chain_id})
        {:error, :window_taken}
      end

      assert {:error, :window_taken} = Chain.request(%{trigger: "schedule", claim: claim})
      assert_received {:chain, chain} when is_binary(chain)
      refute_receive {:kiln_backup_progress, _, %{chain: ^chain}}, 100
      assert %{chain_id: nil} = lock_row()
    end
  end

  describe "the producers" do
    test "a request that starts a chain announces it, from the lock row" do
      assert {:ok, %{status: :started, chain: chain}} = Chain.request(%{trigger: "manual"})

      assert_receive {:kiln_backup_progress, 1,
                      %{chain: ^chain, step: :start, phase: :running, percent: 0} = payload}

      assert_whitelisted(payload)
    end

    test "a queued request announces the running chain it waits behind" do
      {:ok, %{status: :started, chain: chain}} = Chain.request(%{trigger: "manual"})
      assert_receive {:kiln_backup_progress, 1, %{chain: ^chain}}

      {:ok, %{status: :queued, chain: ^chain}} = Chain.request(%{trigger: "manual"})
      assert_receive {:kiln_backup_progress, 1, %{chain: ^chain} = payload}
      assert_whitelisted(payload)
    end

    test "the Recorder's Run writes name the run" do
      chain = Ash.UUID.generate()
      stamp = stamp()

      rec = Recorder.open(stamp, "test", DateTime.utc_now(), [:db], nil, chain)
      assert %{run: %{id: id}} = rec

      assert_receive {:kiln_backup_progress, 1, %{run: ^id, chain: ^chain, stamp: ^stamp} = p}
      assert_whitelisted(p)

      rec |> Recorder.log(:info, "dump", "a line that never travels") |> Recorder.progress()
      assert_receive {:kiln_backup_progress, 1, %{run: ^id} = p}
      refute inspect(p) =~ "never travels"

      Recorder.finish(rec)
      assert_receive {:kiln_backup_progress, 1, %{run: ^id}}
    end

    test "a skipped run is announced; a write that fails is not" do
      stamp = stamp()
      :ok = Recorder.skip(stamp, "test", DateTime.utc_now(), [:db], "backups are off")
      assert_receive {:kiln_backup_progress, 1, %{stamp: ^stamp, run: run} = p}
      assert is_binary(run)
      assert_whitelisted(p)

      # The stamp is taken now: the second skip's write is refused.
      :ok = Recorder.skip(stamp, "test", DateTime.utc_now(), [:db], "backups are off")
      refute_receive {:kiln_backup_progress, _, %{stamp: ^stamp}}, 100
    end

    test "a settled chain is announced" do
      chain = Ash.UUID.generate()
      Steps.settled(%{chain: chain, stamp: "20260104-000002"}, :ok)

      assert_receive {:kiln_backup_progress, 1, %{chain: ^chain, stamp: "20260104-000002"} = p}
      assert_whitelisted(p)
    end

    @tag :pg_tools
    test "a whole backup announces every step and its end, each whitelisted" do
      {:ok, %{status: :started, chain: chain}} = Chain.request(%{trigger: "manual"})
      BackupChain.drain()

      messages = collect(chain, [])
      assert messages != []
      Enum.each(messages, &assert_whitelisted/1)

      steps = messages |> Enum.map(& &1.step) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      assert [:start, :dump | _] = steps
      assert :finish in steps
      assert Enum.any?(messages, &is_binary(&1.run))

      # The last says it was released: the lock is free.
      assert %{chain: ^chain, step: nil} = List.last(messages)
      assert %{chain_id: nil} = lock_row()
    end

    test "a Cancel's own lock writes are dropped; its settled message says it" do
      {:ok, %{status: :started, chain: chain}} = Chain.request(%{trigger: "manual"})
      assert_receive {:kiln_backup_progress, 1, %{chain: ^chain, step: :start}}

      stamp = stamp()

      run =
        Ash.Seed.seed!(KilnCMS.Backups.Run, %{stamp: stamp, status: :running, chain_id: chain})

      admin =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "progress-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      {:ok, _canceled} = Backups.cancel_run(run, actor: admin)

      assert_receive {:kiln_backup_progress, 1, %{chain: ^chain, stamp: ^stamp} = p}
      assert_whitelisted(p)
      assert %{chain_id: nil} = lock_row()
    end
  end

  defp collect(chain, acc) do
    receive do
      {:kiln_backup_progress, 1, %{chain: ^chain} = payload} -> collect(chain, [payload | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end
end
