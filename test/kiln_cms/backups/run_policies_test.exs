defmodule KilnCMS.Backups.RunPoliciesTest do
  @moduledoc """
  Who may read and write `KilnCMS.Backups.Run` (#2217).

  The history is platform-admin-readable and written by nobody but the
  `:backups` system actor, action by action. The refusals matter more than the
  grants: a platform admin must be refused every write (an `authorize_if
  PlatformAdmin` ahead of the narrowing would admit them to all of them), and an
  org admin who is not a platform admin must be refused everything (the tenant-
  less `OrgAdmin` hazard of `Mail.Settings`).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.{OrgMembership, User}
  alias KilnCMS.Backups
  alias KilnCMS.SystemActor

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "run-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org_admin do
    viewer = user(:viewer)

    Ash.Seed.seed!(OrgMembership, %{
      organization_id: KilnCMS.Accounts.default_org_id(),
      user_id: viewer.id,
      role: :admin
    })

    viewer
  end

  # `YYYYMMDD-HHMMSS`-shaped and unique per call.
  defp stamp do
    n = System.unique_integer([:positive])
    "20260101-" <> String.pad_leading(Integer.to_string(rem(n, 1_000_000)), 6, "0")
  end

  defp run!(attrs \\ %{}) do
    Backups.start_run!(Map.merge(%{stamp: stamp(), trigger: "test"}, attrs),
      actor: Backups.system()
    )
  end

  # {name, fun(actor) -> result} for every write action of the pipeline.
  # `record_progress`, `finish` and `fail` get a fresh running run per call:
  # they land only on a `running` run (#2218), and a refusal by that filter
  # would hide whether the POLICY admitted the actor.
  defp writes(run) do
    [
      start: fn actor ->
        Backups.start_run(%{stamp: stamp(), trigger: "t"}, actor: actor)
      end,
      skip: fn actor ->
        Backups.skip_run(%{stamp: stamp(), trigger: "t", error: "no pg_dump"}, actor: actor)
      end,
      record_progress: fn actor -> Backups.record_run_progress(run!(), %{}, actor: actor) end,
      finish: fn actor -> Backups.finish_run(run!(), %{}, actor: actor) end,
      fail: fn actor -> Backups.fail_run(run!(), %{error: "x"}, actor: actor) end,
      mark_pruned: fn actor -> Backups.mark_run_pruned(run, %{artifacts: []}, actor: actor) end,
      # A fresh failed run per call: the guard refuses anything else, and a
      # refusal by the guard would hide whether the POLICY admitted the actor.
      resume: fn actor ->
        failed = Backups.fail_run!(run!(), %{error: "x"}, actor: Backups.system())
        Backups.resume_run(failed, %{}, actor: actor)
      end,
      import: fn actor ->
        Backups.import_run(%{stamp: stamp(), trigger: "cron", status: :succeeded}, actor: actor)
      end
    ]
  end

  describe "writes" do
    test "the :backups system actor is admitted to every write action" do
      run = run!()

      for {action, call} <- writes(run) do
        assert {:ok, _} = call.(Backups.system()), "#{action} should admit :backups"
      end
    end

    test "a platform admin is refused each write action" do
      run = run!()
      admin = user(:admin)

      for {action, call} <- writes(run) do
        assert {:error, %Ash.Error.Forbidden{}} = call.(admin),
               "#{action} must refuse a platform admin"
      end
    end

    test "editor, viewer, org admin and anonymous are refused each write action" do
      run = run!()

      for actor <- [user(:editor), user(:viewer), org_admin(), nil],
          {action, call} <- writes(run) do
        assert {:error, %Ash.Error.Forbidden{}} = call.(actor),
               "#{action} must refuse #{inspect(actor && actor.role)}"
      end
    end

    test "another subsystem's system actor is refused each write action" do
      run = run!()

      for {action, call} <- writes(run) do
        assert {:error, %Ash.Error.Forbidden{}} = call.(SystemActor.new(:billing)),
               "#{action} must refuse :billing"
      end
    end
  end

  describe "cancel" do
    # The policy alone: `can_cancel_run?/2` decides it without running the
    # action, whose side effects are the `Cancel` change's.
    test "a platform admin may cancel a run" do
      assert Backups.can_cancel_run?(user(:admin), run!())
    end

    test "editor, viewer, org admin and anonymous are refused" do
      run = run!()

      for actor <- [user(:editor), user(:viewer), org_admin(), nil] do
        refute Backups.can_cancel_run?(actor, run),
               "cancel must refuse #{inspect(actor && actor.role)}"

        assert {:error, %Ash.Error.Forbidden{}} = Backups.cancel_run(run, actor: actor)
      end
    end

    test "the :backups system actor is refused: nothing in the pipeline cancels a run" do
      run = run!()

      refute Backups.can_cancel_run?(Backups.system(), run)
      assert {:error, %Ash.Error.Forbidden{}} = Backups.cancel_run(run, actor: Backups.system())
    end
  end

  describe "status" do
    test "the database's status check admits :canceled" do
      run = Ash.Seed.seed!(KilnCMS.Backups.Run, %{stamp: stamp(), status: :canceled})

      assert Backups.get_run_by_stamp!(run.stamp, actor: Backups.system()).status == :canceled
    end

    test "the database's status check still refuses an unknown status" do
      run = run!()

      assert_raise Postgrex.Error, ~r/backup_runs_status_must_be_known/, fn ->
        KilnCMS.Repo.query!("UPDATE backup_runs SET status = 'paused' WHERE id = $1", [
          Ecto.UUID.dump!(run.id)
        ])
      end
    end

    test "record_progress, finish and fail refuse a run that is no longer running" do
      canceled = Ash.Seed.seed!(KilnCMS.Backups.Run, %{stamp: stamp(), status: :canceled})

      for call <- [
            &Backups.record_run_progress(&1, %{}, actor: Backups.system()),
            &Backups.finish_run(&1, %{}, actor: Backups.system()),
            &Backups.fail_run(&1, %{error: "late"}, actor: Backups.system())
          ] do
        assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
                 call.(canceled)
      end

      assert Backups.get_run_by_stamp!(canceled.stamp, actor: Backups.system()).status ==
               :canceled
    end

    test "record_progress, finish and fail refuse a run another chain re-opened (#2538)" do
      chain_a = Ash.UUID.generate()
      chain_b = Ash.UUID.generate()
      ours = run!(%{chain_id: chain_a})

      failed = Backups.fail_run!(ours, %{error: "boom"}, actor: Backups.system())
      Backups.resume_run!(failed, %{chain_id: chain_b}, actor: Backups.system())

      # `ours` is what a step of chain a still holds: running, under a.
      for call <- [
            &Backups.record_run_progress(&1, %{}, actor: Backups.system()),
            &Backups.finish_run(&1, %{}, actor: Backups.system()),
            &Backups.fail_run(&1, %{error: "late"}, actor: Backups.system())
          ] do
        assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
                 call.(ours)
      end

      assert %{status: :running, chain_id: ^chain_b} =
               Backups.get_run!(ours.id, actor: Backups.system())
    end

    test "a run with no chain is written through a struct with no chain, and only that" do
      # A run from before #2218: the stale-run sweep fails it as it reads it.
      legacy = run!()
      assert legacy.chain_id == nil

      assert {:ok, %{status: :failed} = failed} =
               Backups.fail_run(legacy, %{error: "Interrupted"}, actor: Backups.system())

      chain = Ash.UUID.generate()
      Backups.resume_run!(failed, %{chain_id: chain}, actor: Backups.system())

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Backups.fail_run(legacy, %{error: "late"}, actor: Backups.system())

      assert %{status: :running, chain_id: ^chain} =
               Backups.get_run!(legacy.id, actor: Backups.system())
    end

    test "mark_pruned updates a finished run's artifacts" do
      run = Backups.finish_run!(run!(), %{}, actor: Backups.system())

      assert {:ok, %{status: :succeeded}} =
               Backups.mark_run_pruned(run, %{artifacts: []}, actor: Backups.system())
    end
  end

  describe "reads" do
    test "a platform admin reads the list and the paginated history" do
      run = run!()
      admin = user(:admin)

      assert run.id in Enum.map(Backups.list_runs!(actor: admin), & &1.id)

      assert %Ash.Page.Offset{results: results} =
               Backups.run_history!(actor: admin, page: [limit: 5])

      assert run.id in Enum.map(results, & &1.id)
    end

    test "editor, org admin and anonymous read nothing" do
      run!()

      for actor <- [user(:editor), user(:viewer), org_admin(), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.list_runs(actor: actor, authorize_with: :error)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.run_history(actor: actor, authorize_with: :error)
      end
    end

    test "the :backups system actor reads :read, :running and :by_stamp but not :history" do
      run = run!()

      assert run.id in Enum.map(Backups.list_runs!(actor: Backups.system()), & &1.id)
      assert run.id in Enum.map(Backups.list_running_runs!(actor: Backups.system()), & &1.id)
      assert Backups.get_run_by_stamp!(run.stamp, actor: Backups.system()).id == run.id

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.run_history(actor: Backups.system(), authorize_with: :error)
    end

    test "another subsystem's system actor reads nothing" do
      run!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.list_runs(actor: SystemActor.new(:billing), authorize_with: :error)
    end
  end

  describe "with_actor/2 (a revoked grant fails closed)" do
    test "system/0 answers the override only inside the block" do
      assert %SystemActor{} = Backups.system()
      assert Backups.with_actor(nil, fn -> Backups.system() end) == nil
      assert %SystemActor{} = Backups.system()
    end

    test "reconcile_stale_runs/0 raises instead of reporting nothing stale" do
      run!()

      assert_raise Ash.Error.Forbidden, fn ->
        Backups.with_actor(nil, fn -> Backups.reconcile_stale_runs() end)
      end
    end
  end

  describe "import (upsert on the stamp)" do
    test "a second import of the same stamp changes nothing" do
      stamp = stamp()

      first =
        Backups.import_run!(%{stamp: stamp, trigger: "cron", status: :succeeded},
          actor: Backups.system()
        )

      Backups.import_run!(%{stamp: stamp, trigger: "other", status: :failed, error: "x"},
        actor: Backups.system()
      )

      assert [run] =
               Enum.filter(Backups.list_runs!(actor: Backups.system()), &(&1.stamp == stamp))

      assert run.id == first.id
      assert run.trigger == "cron"
      assert run.status == :succeeded
      assert run.origin == :imported
    end

    test "an app-made run on the same stamp is not clobbered" do
      app = run!()

      Backups.import_run!(%{stamp: app.stamp, trigger: "cron", status: :succeeded},
        actor: Backups.system()
      )

      reread = Backups.get_run_by_stamp!(app.stamp, actor: Backups.system())
      assert reread.origin == :app
      assert reread.status == :running
      assert reread.trigger == "test"
    end
  end
end
