defmodule KilnCMS.Backups.DestinationCapRaceTest do
  @moduledoc """
  The cap of eight enabled destinations under concurrency (#2952): two saves
  enabling the last free place at once must not both get it.

  The sandbox runs every test on one connection inside one transaction, where
  an advisory lock is re-entrant and nothing ever waits, so these tests run
  **outside** it (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`), on real
  connections whose writes commit. Everything they write (the destinations,
  their audit events, the admin) is deleted again on exit.

  `async: false`: the rows commit, and the destinations table is
  instance-wide.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Backups
  alias KilnCMS.Backups.DestinationConfig
  alias KilnCMS.Repo

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    admin =
      unboxed(fn ->
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "dest-race-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })
      end)

    on_exit(fn -> unboxed(fn -> clean_up(admin.id) end) end)

    # Seven enabled: one place left.
    unboxed(fn ->
      for _ <- 1..(DestinationConfig.max_enabled() - 1), do: create!(admin, true)
    end)

    %{admin: admin}
  end

  defp create!(admin, enabled) do
    Backups.create_backup_destination!(
      %{
        name: "Race #{System.unique_integer([:positive])}",
        kind: "fake",
        enabled: enabled,
        settings: %{"mode" => "ok"},
        secrets: %{"token" => "race-token"}
      },
      actor: admin
    )
  end

  defp enable(row, admin),
    do: Backups.update_backup_destination(row, %{enabled: true}, actor: admin)

  defp enabled_count do
    unboxed(fn -> length(Backups.list_enabled_backup_destinations!(actor: Backups.system())) end)
  end

  defp refused_at_the_cap?({:error, %Ash.Error.Invalid{} = error}),
    do: Exception.message(error) =~ "destinations can be enabled"

  defp refused_at_the_cap?(_other), do: false

  test "a second enable waits for the first to commit, then counts it and is refused",
       %{admin: admin} do
    [a, b] = unboxed(fn -> [create!(admin, false), create!(admin, false)] end)

    second =
      unboxed(fn ->
        {:ok, second} =
          Repo.transaction(fn ->
            {:ok, %{enabled: true}} = enable(a, admin)

            second = Task.async(fn -> unboxed(fn -> enable(b, admin) end) end)

            # Blocked on the advisory lock, not counting yet: without the lock
            # it would count seven (the first enable is uncommitted) and take
            # the place too.
            refute Task.yield(second, 300)
            second
          end)

        second
      end)

    assert refused_at_the_cap?(Task.await(second, 10_000))
    assert enabled_count() == DestinationConfig.max_enabled()
  end

  test "two enables, or two creates, of the last place at once: exactly one wins", %{
    admin: admin
  } do
    for round <- 1..3 do
      [a, b] = unboxed(fn -> [create!(admin, false), create!(admin, false)] end)

      enables = race([fn -> enable(a, admin) end, fn -> enable(b, admin) end])
      assert Enum.count(enables, &match?({:ok, _}, &1)) == 1, "round #{round}: enables"
      assert Enum.count(enables, &refused_at_the_cap?/1) == 1
      assert enabled_count() == DestinationConfig.max_enabled()

      # Free the place again for the creates.
      {:ok, winner} = Enum.find(enables, &match?({:ok, _}, &1))

      unboxed(fn ->
        {:ok, _} = Backups.update_backup_destination(winner, %{enabled: false}, actor: admin)
      end)

      creates = race([fn -> create(admin) end, fn -> create(admin) end])
      assert Enum.count(creates, &match?({:ok, _}, &1)) == 1, "round #{round}: creates"
      assert Enum.count(creates, &refused_at_the_cap?/1) == 1
      assert enabled_count() == DestinationConfig.max_enabled()

      {:ok, created} = Enum.find(creates, &match?({:ok, _}, &1))

      unboxed(fn ->
        {:ok, _} = Backups.update_backup_destination(created, %{enabled: false}, actor: admin)
      end)
    end
  end

  defp create(admin) do
    Backups.create_backup_destination(
      %{
        name: "Race #{System.unique_integer([:positive])}",
        kind: "fake",
        settings: %{"mode" => "ok"},
        secrets: %{"token" => "race-token"}
      },
      actor: admin
    )
  end

  # Each fun on its own connection, released together.
  defp race(funs) do
    parent = self()

    tasks =
      for fun <- funs do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive(do: (:go -> unboxed(fun)))
        end)
      end

    pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp clean_up(admin_id) do
    {:ok, uuid} = Ecto.UUID.dump(admin_id)
    Repo.query!("DELETE FROM backup_destinations WHERE name LIKE 'Race %'")
    Repo.query!("DELETE FROM instance_security_events WHERE actor_id = $1", [uuid])
    Repo.query!("DELETE FROM users WHERE id = $1", [uuid])
  end
end
