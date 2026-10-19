defmodule KilnCMS.CMS.JoinSourceCapRaceTest do
  @moduledoc """
  A graduated `max_sources` (#2024) under concurrency: two connections to a
  target's last free slot through the join resource, at the same moment,
  must not both get it — as `KilnCMS.CMS.ReferenceCapRaceTest` proves for the
  field before graduation.

  Outside the sandbox (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`), where an
  advisory lock makes a second connection wait: in an organization of its
  own, deleted again on exit, over a probe table (`KilnCMS.JoinProbe`)
  dropped on exit.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.CMS
  alias KilnCMS.CMS.JoinGraduation
  alias KilnCMS.JoinProbe
  alias KilnCMS.Repo

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp slug, do: "join-race-#{System.unique_integer([:positive])}"

  setup do
    {org, admin} =
      unboxed(fn ->
        org =
          Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
            name: "join race",
            slug: slug(),
            status: :active
          })

        admin =
          Ash.Seed.seed!(KilnCMS.Accounts.User, %{
            email: "join-race-#{System.unique_integer([:positive])}@example.com",
            hashed_password: Bcrypt.hash_pwd_salt("password123456"),
            confirmed_at: DateTime.utc_now(),
            role: :admin
          })

        {org, admin}
      end)

    on_exit(fn -> unboxed(fn -> delete_org(org.id, admin.id) end) end)

    opts = [actor: admin, tenant: org.id]
    name = "seat_#{System.unique_integer([:positive])}"

    spec =
      unboxed(fn ->
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: name,
            label: "Seat",
            field_type: :reference,
            target_type: "page",
            max_sources: 1
          },
          opts
        )

        {:ok, spec} = JoinGraduation.resolve("post.#{name}", org_id: org.id)
        JoinProbe.build!(spec)
      end)

    # Registered last, so it runs first: the table goes before the org's rows.
    on_exit(fn -> unboxed(fn -> JoinProbe.drop!(spec) end) end)

    %{opts: opts, spec: spec}
  end

  defp fixtures(opts) do
    unboxed(fn ->
      target = CMS.create_page!(%{title: "Last seat", slug: slug()}, opts)
      [a, b] = for t <- ~w(A B), do: CMS.create_post!(%{title: t, slug: slug()}, opts)
      {target, a, b}
    end)
  end

  defp connected(spec, target),
    do: unboxed(fn -> JoinGraduation.connected_sources(spec.module, target.id, target.org_id) end)

  test "a second writer waits for the first to commit, then sees it and is refused",
       %{opts: opts, spec: spec} do
    {target, a, b} = fixtures(opts)

    second =
      unboxed(fn ->
        {:ok, second} =
          Repo.transaction(fn ->
            {:ok, _first} = JoinProbe.connect(spec, a, target, opts)

            second =
              Task.async(fn -> unboxed(fn -> JoinProbe.connect(spec, b, target, opts) end) end)

            # Blocked on the field's advisory lock: without it the second
            # would count 0 (the first row is uncommitted) and take the slot.
            refute Task.yield(second, 300)
            second
          end)

        second
      end)

    assert {:error, %Ash.Error.Invalid{} = error} = Task.await(second, 10_000)
    assert Exception.message(error) =~ "is full: it already has 1 of 1"
    assert connected(spec, target) == [a.id]
  end

  test "two writers taking the last slot at once: exactly one wins", %{opts: opts, spec: spec} do
    for _round <- 1..5 do
      {target, a, b} = fixtures(opts)
      parent = self()

      tasks =
        for post <- [a, b] do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> unboxed(fn -> JoinProbe.connect(spec, post, target, opts) end)
            end
          end)
        end

      pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
      Enum.each(pids, &send(&1, :go))

      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, %Ash.Error.Invalid{}}, &1)) == 1
      assert length(connected(spec, target)) == 1
    end
  end

  # As `KilnCMS.CMS.ReferenceCapRaceTest`: everything the tests committed
  # lives in their own organization; delete it table by table, looping while
  # a foreign key between two org-scoped tables refuses a delete.
  defp delete_org(org_id, user_id) do
    {:ok, uuid} = Ecto.UUID.dump(org_id)

    %{rows: tables} =
      Repo.query!("""
      SELECT table_name FROM information_schema.columns
      WHERE column_name = 'org_id' AND table_schema = 'public'
      """)

    sweep(Enum.map(tables, &hd/1), uuid, 10)
    Repo.query!("DELETE FROM organizations WHERE id = $1", [uuid])
    {:ok, user} = Ecto.UUID.dump(user_id)
    Repo.query("DELETE FROM users WHERE id = $1", [user])
  end

  defp sweep([], _uuid, _passes), do: :ok
  defp sweep(_tables, _uuid, 0), do: :ok

  defp sweep(tables, uuid, passes) do
    left =
      Enum.reject(tables, fn table ->
        match?({:ok, _}, Repo.query(~s(DELETE FROM "#{table}" WHERE org_id = $1), [uuid]))
      end)

    sweep(left, uuid, passes - 1)
  end
end
