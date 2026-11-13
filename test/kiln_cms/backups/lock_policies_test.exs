defmodule KilnCMS.Backups.LockPoliciesTest do
  @moduledoc """
  Who may touch the backup lock and the node heartbeats (#2218).

  A platform admin asks for a backup (`request`) and reads what is in flight;
  the row itself is the pipeline's, so no person, platform admin included,
  can take, move or release it. The refusals matter more than the grants: a
  site (org) admin who is not a platform admin must not start a backup of the
  whole instance, and a person who could `clear` the lock could start a second
  backup on top of a running one.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.{OrgMembership, User}
  alias KilnCMS.Backups
  alias KilnCMS.Backups.NodeBeat
  alias KilnCMS.SystemActor

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "lock-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # An admin of the default org who is not a platform admin.
  defp site_admin do
    editor = user(:editor)

    Ash.Seed.seed!(OrgMembership, %{
      organization_id: KilnCMS.Accounts.default_org_id(),
      user_id: editor.id,
      role: :admin
    })

    editor
  end

  defp people, do: [user(:admin), user(:editor), user(:viewer), site_admin(), nil]

  defp lock!, do: Backups.ensure_backup_lock!(%{}, actor: Backups.system())

  # {name, fun(actor) -> result} for every write to the row.
  defp row_writes do
    chain = Ash.UUID.generate()

    [
      ensure: fn actor -> Backups.ensure_backup_lock(%{}, actor: actor) end,
      hold: fn actor ->
        Backups.hold_backup_lock(lock!(), %{chain_id: chain, step: :start, step_job_id: 1},
          actor: actor
        )
      end,
      move: fn actor ->
        Backups.move_backup_lock(lock!(), %{step: :dump, step_job_id: 2}, actor: actor)
      end,
      mark_executing: fn actor ->
        Backups.mark_backup_lock_executing(
          lock!(),
          %{executing_boot_id: Ash.UUID.generate(), executing_job_id: 2},
          actor: actor
        )
      end,
      finishing: fn actor -> Backups.mark_backup_lock_finishing(lock!(), actor: actor) end,
      clear: fn actor -> Backups.clear_backup_lock(lock!(), actor: actor) end,
      queue_waiting: fn actor ->
        Backups.queue_backup_request(lock!(), %{waiting_trigger: "manual"}, actor: actor)
      end,
      fold: fn actor -> Backups.fold_backup_request(lock!(), actor: actor) end
    ]
  end

  describe "request" do
    test "a platform admin and the :backups system actor may request a backup" do
      assert Backups.can_request_backup?(user(:admin))
      assert Backups.can_request_backup?(Backups.system())
    end

    test "editor, viewer, site admin and anonymous are refused" do
      for actor <- [user(:editor), user(:viewer), site_admin(), nil] do
        refute Backups.can_request_backup?(actor),
               "request must refuse #{inspect(actor && actor.role)}"

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.request_backup(%{trigger: "manual"}, actor: actor)
      end
    end

    # #2219: naming components is the same request, under the same policy.
    test "a request for some components is refused to editor, viewer, site admin and anonymous" do
      for actor <- [user(:editor), user(:viewer), site_admin(), nil],
          components <- [[:db], [:media], [:db, :media]] do
        refute Backups.can_request_backup?(actor, %{components: components}),
               "request #{inspect(components)} must refuse #{inspect(actor && actor.role)}"

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.request_backup(%{trigger: "manual", components: components},
                   actor: actor
                 )

        assert {:error, :forbidden} = Backups.request([components: components], actor)
      end

      assert Backups.in_flight() == nil
    end

    test "another subsystem's system actor is refused" do
      refute Backups.can_request_backup?(SystemActor.new(:billing))
    end
  end

  # Part of #2219: only the scheduler may ask for a backup that carries
  # `scheduled`/`schedule_ids` and claims windows.
  describe "request_scheduled" do
    test "is refused for a platform admin, editor, viewer, site admin and anonymous" do
      input = %{schedule_ids: [Ash.UUID.generate()], at: DateTime.utc_now()}

      for actor <- people() do
        refute Backups.can_request_scheduled_backup?(actor, input),
               "request_scheduled must refuse #{inspect(actor && actor.role)}"

        assert {:error, :forbidden} =
                 Backups.request_scheduled(input.schedule_ids, input.at, actor)
      end

      refute Backups.can_request_scheduled_backup?(SystemActor.new(:billing), input)
      assert Backups.in_flight() == nil
    end

    test "is admitted for the :backups system actor" do
      input = %{schedule_ids: [Ash.UUID.generate()], at: DateTime.utc_now()}
      assert Backups.can_request_scheduled_backup?(Backups.system(), input)

      assert {:ok, %{status: :nothing_due}} =
               Backups.request_scheduled(input.schedule_ids, input.at, Backups.system())
    end
  end

  describe "the row" do
    test "the :backups system actor makes every write" do
      for {action, call} <- row_writes() do
        assert {:ok, _} = call.(Backups.system()), "#{action} should admit :backups"
      end
    end

    test "no person, platform admin included, holds, moves or clears the lock" do
      lock!()

      for actor <- people(), {action, call} <- row_writes() do
        assert {:error, %Ash.Error.Forbidden{}} = call.(actor),
               "#{action} must refuse #{inspect(actor && actor.role)}"
      end
    end

    test "reclaim_stale is the system actor's alone" do
      for actor <- people() do
        refute Backups.can_reclaim_stale_backups?(actor)
      end

      assert Backups.can_reclaim_stale_backups?(Backups.system())
    end

    test "ensure creates the singleton once and leaves an existing row alone" do
      lock = lock!()
      assert lock.name == "backups"
      assert lock.epoch == 0

      chain = Ash.UUID.generate()

      Backups.hold_backup_lock!(lock, %{chain_id: chain, step: :start, step_job_id: 1},
        actor: Backups.system()
      )

      again = lock!()
      assert again.chain_id == chain
      assert again.epoch == 1
    end

    test "hold, move and clear each advance the epoch; clear keeps the waiting request" do
      sys = Backups.system()

      lock =
        Backups.hold_backup_lock!(lock!(), %{chain_id: Ash.UUID.generate(), step: :start},
          actor: sys
        )

      lock = Backups.queue_backup_request!(lock, %{waiting_trigger: "schedule"}, actor: sys)
      lock = Backups.fold_backup_request!(lock, actor: sys)
      lock = Backups.move_backup_lock!(lock, %{step: :dump, step_job_id: 7}, actor: sys)
      assert lock.epoch == 2
      assert lock.waiting_folds == 1

      lock = Backups.clear_backup_lock!(lock, actor: sys)
      assert lock.epoch == 3
      assert lock.chain_id == nil
      assert lock.step == nil
      assert lock.waiting_trigger == "schedule"
    end

    test "a platform admin and the system actor read it; nobody else does" do
      lock!()

      assert %{name: "backups"} = Backups.backup_lock!(actor: user(:admin))
      assert %{name: "backups"} = Backups.backup_lock!(actor: Backups.system())

      for actor <- [user(:editor), user(:viewer), site_admin(), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.backup_lock(actor: actor, authorize_with: :error)
      end
    end
  end

  describe "node beats" do
    defp beat!(node) do
      Backups.beat_node!(%{node: node, boot_id: Ash.UUID.generate()}, actor: Backups.system())
    end

    test "a beat upserts the node's row with the database's clock" do
      node = "node-#{System.unique_integer([:positive])}"
      first = beat!(node)
      %{rows: [[db_now]]} = KilnCMS.Repo.query!("SELECT now()")

      second = beat!(node)

      assert second.boot_id != first.boot_id
      assert DateTime.compare(second.beat_at, first.beat_at) != :lt
      assert abs(DateTime.diff(second.beat_at, db_now, :second)) < 60

      assert [_one] =
               Enum.filter(Backups.list_node_beats!(actor: Backups.system()), &(&1.node == node))
    end

    test "prune removes only beats a day old" do
      fresh = beat!("fresh-#{System.unique_integer([:positive])}")

      old =
        Ash.Seed.seed!(NodeBeat, %{
          node: "old-#{System.unique_integer([:positive])}",
          boot_id: Ash.UUID.generate(),
          beat_at: DateTime.add(DateTime.utc_now(), -2, :day)
        })

      Backups.prune_node_beats!(actor: Backups.system())

      assert Backups.get_node_beat!(fresh.node, actor: Backups.system())
      refute Backups.get_node_beat!(old.node, actor: Backups.system())
    end

    test "no person, platform admin included, reads or writes a beat" do
      beat = beat!("n-#{System.unique_integer([:positive])}")

      for actor <- people() do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.beat_node(%{node: beat.node, boot_id: Ash.UUID.generate()},
                   actor: actor
                 )

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.list_node_beats(actor: actor, authorize_with: :error)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.list_live_node_beats(600, actor: actor, authorize_with: :error)
      end
    end

    test "another subsystem's system actor can't read the live beats" do
      beat!("n-#{System.unique_integer([:positive])}")

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.list_live_node_beats(600,
                 actor: SystemActor.new(:billing),
                 authorize_with: :error
               )
    end

    # #2789: the window is measured from the database's now(), the clock the
    # beat itself is stamped with, not this node's.
    test "the live beats are those of the last `within_s` seconds on the database's clock" do
      backdated = fn seconds ->
        node = "live-#{seconds}-#{System.unique_integer([:positive])}"
        beat!(node)

        %{num_rows: 1} =
          KilnCMS.Repo.query!(
            "UPDATE backup_node_beats SET beat_at = now() - make_interval(secs => $2) " <>
              "WHERE node = $1",
            [node, seconds]
          )

        node
      end

      fresh = beat!("live-0-#{System.unique_integer([:positive])}").node
      nine = backdated.(9 * 60)
      eleven = backdated.(11 * 60)

      live =
        600
        |> Backups.list_live_node_beats!(actor: Backups.system())
        |> MapSet.new(& &1.node)

      assert fresh in live
      assert nine in live
      refute eleven in live

      assert {:error, %Ash.Error.Invalid{}} =
               Backups.list_live_node_beats(0, actor: Backups.system())
    end
  end
end
