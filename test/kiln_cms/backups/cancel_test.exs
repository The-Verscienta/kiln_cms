defmodule KilnCMS.Backups.CancelTest do
  @moduledoc """
  Canceling a running backup (#2218, D4/D5): the run's step jobs are canceled,
  the lock released (the queued request starts), the run marked `canceled` and
  audited, and nothing on disk is touched, so Resume carries on from the files
  already written.

  Runs real `pg_dump` and `tar` (`:pg_tools`), stepping the chain one job at a
  time to cancel between steps. `async: false`: it changes the VM-wide
  `Application` env and PATH.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  alias KilnCMS.Accounts.User
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Chain, Manifest}
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log
  @moduletag :pg_tools

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bkx_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    media = Path.join(base, "media")
    File.mkdir_p!(media)

    # Six 300-byte files with a 700-byte cap: three parts of two files each.
    for n <- 1..6, do: File.write!(Path.join(media, "f#{n}.bin"), :crypto.strong_rand_bytes(300))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original,
        enabled: true,
        dir: dir,
        media_dir: media,
        keep_days: 14,
        media_part_bytes: 700
      )
    )

    path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", path)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    # A good backup from before: a cancel must leave its manifest alone.
    :ok =
      Manifest.write(dir, %Manifest{
        finished_at: DateTime.utc_now(),
        trigger: "cron",
        ok: true,
        artifacts: [%{kind: "db", path: "db/x.dump", bytes: 1, verified: true}]
      })

    %{base: base, dir: dir, media: media, admin: user(:admin)}
  end

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "cancel-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp request(opts \\ []), do: Backups.request(opts, Backups.system())

  defp lock, do: Backups.backup_lock!(actor: Backups.system())

  defp run_of(stamp), do: Backups.get_run_by_stamp!(stamp, actor: Backups.system())

  defp step_jobs(chain) do
    Repo.all(
      from(j in Oban.Job,
        where: j.queue == "backup_steps" and fragment("?->>'chain' = ?", j.args, ^chain),
        order_by: j.id
      )
    )
  end

  defp current_job, do: Repo.get!(Oban.Job, lock().step_job_id)

  # Run the chain's jobs one at a time until the lock points at `step` (`part`).
  defp step_until(step, part \\ nil) do
    row = lock()

    if to_string(row.step) == step and row.part == part do
      current_job()
    else
      %{success: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
      step_until(step, part)
    end
  end

  defp canceled_events do
    Security.list_events!(
      actor: user(:admin),
      tenant: KilnCMS.Accounts.default_org_id(),
      page: [limit: 100]
    )
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == :backup_canceled))
  end

  defp aged(path) do
    File.touch!(path, System.os_time(:second) - 7200)
    File.stat!(path, time: :posix).mtime
  end

  defp mtime(path), do: File.stat!(path, time: :posix).mtime

  defp fake_rclone!(base) do
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "rclone"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(bin, "rclone"), 0o755)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :rclone_remote, "r2:kiln")
    )
  end

  describe "cancel during archive" do
    test "the run is canceled, its jobs canceled, the lock freed; Resume reuses the parts and " <>
           "succeeds",
         %{dir: dir, admin: admin} do
      {:ok, %{status: :started, chain: chain}} = request()
      step_until("archive", 2)
      %{stamp: stamp} = lock()
      manifest = File.read!(Manifest.path(dir))

      dump = Path.join([dir, "db", "kiln-db-#{stamp}.dump"])
      p1 = Path.join([dir, "media", Artifact.part_name(stamp, 1)])
      old = Map.new([dump, p1], &{&1, aged(&1)})

      run = run_of(stamp)
      assert run.status == :running

      BackupChain.listen(fn ->
        assert {:ok, %{status: :canceled} = canceled} = Backups.cancel_run(run, actor: admin)
        assert canceled.error == "Canceled by a platform admin"
        assert List.last(canceled.log).message == "Canceled by #{admin.email}"
        assert {:error, :canceled} = BackupChain.settled(chain)
      end)

      assert Enum.all?(step_jobs(chain), &(&1.state in ["completed", "cancelled"]))
      assert Enum.any?(step_jobs(chain), &(&1.state == "cancelled"))
      assert Backups.in_flight() == nil
      assert %{status: :canceled} = run_of(stamp)

      # D4: the manifest, the work dir and the finished files stay.
      assert File.read!(Manifest.path(dir)) == manifest
      assert Backups.work_state?(stamp)
      assert %{success: 0} = BackupChain.drain()

      assert :ok = BackupChain.resume(stamp)

      for {path, at} <- old, do: assert(mtime(path) == at, "#{path} was rebuilt")
      assert %{status: :succeeded} = run = run_of(stamp)
      assert Enum.any?(run.log, &(&1.message =~ "Resuming a canceled backup"))
      assert Manifest.read(dir).ok
    end
  end

  describe "D4: cancel never writes the manifest" do
    for step <- ["dump", "offsite"] do
      test "canceled at #{step}", %{base: base, dir: dir, admin: admin} do
        fake_rclone!(base)
        {:ok, %{status: :started}} = request()
        step_until(unquote(step))
        %{stamp: stamp} = lock()
        manifest = File.read!(Manifest.path(dir))

        assert {:ok, %{status: :canceled}} = Backups.cancel_run(run_of(stamp), actor: admin)

        BackupChain.drain()
        assert File.read!(Manifest.path(dir)) == manifest
        assert %{status: :canceled} = run_of(stamp)
      end
    end
  end

  describe "refusals" do
    test "a backup that is finishing can't be canceled; nothing changes and no event is written",
         %{admin: admin} do
      {:ok, %{status: :started, chain: chain}} = request()
      step_until("finish")
      %{stamp: stamp} = row = lock()
      Backups.mark_backup_lock_finishing!(row, %{}, actor: Backups.system())

      assert {:error, %Ash.Error.Invalid{} = error} =
               Backups.cancel_run(run_of(stamp), actor: admin)

      assert Exception.message(error) =~ "too late to cancel"
      assert %{status: :running} = run_of(stamp)
      assert %{chain: ^chain, phase: :finishing} = Backups.in_flight()
      assert Enum.any?(step_jobs(chain), &(&1.state == "available"))
      assert canceled_events() == []
    end

    test "a run that finished meanwhile is stale: already finished, no event", %{admin: admin} do
      {:ok, %{status: :started, chain: chain}} = request()
      step_until("dump")
      %{stamp: stamp} = lock()
      run = run_of(stamp)

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert :ok = BackupChain.settled(chain)
      end)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Backups.cancel_run(run, actor: admin)

      assert %{status: :succeeded} = run_of(stamp)
      assert canceled_events() == []
    end

    test "a person other than a platform admin is refused, and no event is written" do
      {:ok, %{status: :started, chain: chain}} = request()
      step_until("dump")
      %{stamp: stamp} = lock()

      for actor <- [user(:editor), user(:viewer), nil, Backups.system()] do
        assert {:error, %Ash.Error.Forbidden{}} = Backups.cancel_run(run_of(stamp), actor: actor)
      end

      assert %{status: :running} = run_of(stamp)
      assert %{chain: ^chain} = Backups.in_flight()
      assert canceled_events() == []
    end

    test "an imported run can't be canceled", %{admin: admin} do
      run =
        Backups.import_run!(
          %{stamp: "20200101-000000", trigger: "cron", status: :running},
          actor: Backups.system()
        )

      assert {:error, %Ash.Error.Invalid{}} = Backups.cancel_run(run, actor: admin)
    end
  end

  describe "the lock and the queue" do
    test "cancel starts the queued request", %{admin: admin} do
      {:ok, %{status: :started, chain: chain}} = request()
      step_until("dump")
      %{stamp: stamp} = lock()
      {:ok, %{status: :queued}} = request(trigger: "schedule")

      assert {:ok, %{status: :canceled}} = Backups.cancel_run(run_of(stamp), actor: admin)

      assert %{chain: promoted, trigger: "schedule", step: :start, waiting: nil} =
               Backups.in_flight()

      assert promoted != chain
    end

    test "a running row the lock doesn't hold is just marked canceled, and is resumable", %{
      admin: admin
    } do
      run =
        Backups.start_run!(%{stamp: "20200102-000000", trigger: "manual"},
          actor: Backups.system()
        )

      assert {:ok, %{status: :canceled} = canceled} = Backups.cancel_run(run, actor: admin)
      assert Backups.in_flight() == nil
      assert Backups.run_resumable?(canceled)
      assert [%{metadata: metadata}] = canceled_events()
      assert metadata == %{"stamp" => run.stamp}
    end

    test "the killed step's late writes don't overwrite :canceled", %{admin: admin} do
      {:ok, %{status: :started}} = request()
      job = step_until("archive", 1)
      %{stamp: stamp} = lock()

      # The step had begun when the cancel landed.
      {:ok, zombie} = Chain.begin_step(job)
      assert {:ok, _} = Backups.cancel_run(run_of(stamp), actor: admin)

      assert {:error, :superseded} = Chain.advance(zombie, "archive", 2)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Backups.record_run_progress(run_of(stamp), %{}, actor: Backups.system())

      assert {:error, _} =
               Backups.fail_run(run_of(stamp), %{error: "late"}, actor: Backups.system())

      assert %{status: :canceled} = run_of(stamp)
    end
  end

  describe "audit (D5)" do
    test "records backup_canceled in the default org's log, with the stamp and step", %{
      admin: admin
    } do
      {:ok, %{status: :started}} = request()
      step_until("archive", 2)
      %{stamp: stamp} = lock()
      run = run_of(stamp)

      assert {:ok, _} = Backups.cancel_run(run, actor: admin)

      assert [event] = canceled_events()
      assert event.actor_id == admin.id
      assert event.target_type == "backup_run"
      assert event.target_id == run.id
      assert event.metadata == %{"stamp" => stamp, "step" => "archive part 2"}
    end
  end
end
