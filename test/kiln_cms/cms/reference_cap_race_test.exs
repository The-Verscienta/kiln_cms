defmodule KilnCMS.CMS.ReferenceCapRaceTest do
  @moduledoc """
  `max_sources` (R1b) under concurrency: two records connecting to a target's
  last free slot at the same moment must not both get it.

  The sandbox runs every test on one connection inside one transaction, where
  an advisory lock is re-entrant and nothing ever waits — so these tests run
  **outside** it (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`), on real
  connections whose writes commit, in an organization of their own that is
  deleted again on exit.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.CMS
  alias KilnCMS.Repo

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp slug, do: "race-#{System.unique_integer([:positive])}"

  setup do
    {org, admin} =
      unboxed(fn ->
        org =
          Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
            name: "race",
            slug: slug(),
            status: :active
          })

        admin =
          Ash.Seed.seed!(KilnCMS.Accounts.User, %{
            email: "race-#{System.unique_integer([:positive])}@example.com",
            hashed_password: Bcrypt.hash_pwd_salt("password123456"),
            confirmed_at: DateTime.utc_now(),
            role: :admin
          })

        {org, admin}
      end)

    on_exit(fn -> unboxed(fn -> delete_org(org.id, admin.id) end) end)

    opts = [actor: admin, tenant: org.id]
    name = "seat_#{System.unique_integer([:positive])}"

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
    end)

    %{opts: opts, name: name}
  end

  defp fixtures(opts) do
    unboxed(fn ->
      target = CMS.create_page!(%{title: "Last seat", slug: slug()}, opts)
      [a, b] = for t <- ~w(A B), do: CMS.create_post!(%{title: t, slug: slug()}, opts)
      {target, a, b}
    end)
  end

  defp connect(post, name, target, opts),
    do: CMS.update_post(post, %{custom_fields: %{name => target.id}}, opts)

  defp edges(target, opts) do
    unboxed(fn ->
      CMS.list_references_to!(target.id, %{}, Keyword.put(opts, :authorize?, false))
    end)
  end

  test "a second writer waits for the first to commit, then sees it and is refused",
       %{opts: opts, name: name} do
    {target, a, b} = fixtures(opts)

    # The first writer connects inside a transaction it keeps open; the
    # second starts meanwhile, on its own connection.
    second =
      unboxed(fn ->
        {:ok, second} =
          Repo.transaction(fn ->
            # Its notifications are sent after the outer commit, not missed.
            # The transaction around it is the point of the test, so its
            # `after_transaction` hooks running early is too: silenced here
            # rather than left as noise in the log.
            {:ok, _a, _notifications} =
              CMS.update_post(
                a,
                %{custom_fields: %{name => target.id}},
                opts
                |> Keyword.put(:return_notifications?, true)
                |> Keyword.put(:context, %{warn_on_transaction_hooks?: false})
              )

            second = Task.async(fn -> unboxed(fn -> connect(b, name, target, opts) end) end)

            # Blocked on the target's advisory lock, not counting yet: without
            # the lock it would count 0 (the first edge is uncommitted) and
            # take the slot too.
            refute Task.yield(second, 300)
            second
          end)

        second
      end)

    assert {:error, %Ash.Error.Invalid{} = error} = Task.await(second, 10_000)
    assert Exception.message(error) =~ "is full: it already has 1 of 1"
    assert [%{source_id: source_id}] = edges(target, opts)
    assert source_id == a.id
  end

  test "two writers taking the last slot at once: exactly one wins", %{opts: opts, name: name} do
    for _round <- 1..5 do
      {target, a, b} = fixtures(opts)
      parent = self()

      tasks =
        for post <- [a, b] do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> unboxed(fn -> connect(post, name, target, opts) end)
            end
          end)
        end

      pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
      Enum.each(pids, &send(&1, :go))

      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, %Ash.Error.Invalid{}}, &1)) == 1
      assert length(edges(target, opts)) == 1
    end
  end

  # Everything the tests committed lives in their own organization: delete it
  # table by table. A foreign key between two org-scoped tables can refuse a
  # delete until the referencing table is emptied, so loop until a pass makes
  # no progress.
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
