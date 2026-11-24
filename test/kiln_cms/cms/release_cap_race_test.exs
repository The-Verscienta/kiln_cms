defmodule KilnCMS.CMS.ReleaseCapRaceTest do
  @moduledoc """
  A release's size cap under concurrency (#3073): two adds to a release's
  last free slot at the same moment must not both get it, and an add must not
  deadlock against a cancel on the same release.

  The sandbox runs every test on one connection inside one transaction, where
  nothing ever waits on a row lock — so these tests run **outside** it
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`), on real connections whose
  writes commit, in an organization of their own that is deleted again on
  exit.
  """
  # async: false — the cap is lowered with `Application.put_env/3`, which every
  # concurrently running test would see.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Releases
  alias KilnCMS.Repo

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp slug, do: "release-race-#{System.unique_integer([:positive])}"

  setup do
    previous = Application.get_env(:kiln_cms, Releases, [])
    Application.put_env(:kiln_cms, Releases, Keyword.put(previous, :max_items, 2))
    on_exit(fn -> Application.put_env(:kiln_cms, Releases, previous) end)

    {org, admin} =
      unboxed(fn ->
        org =
          Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
            name: "release race",
            slug: slug(),
            status: :active
          })

        admin =
          Ash.Seed.seed!(KilnCMS.Accounts.User, %{
            email: "release-race-#{System.unique_integer([:positive])}@example.com",
            hashed_password: Bcrypt.hash_pwd_salt("password123456"),
            confirmed_at: DateTime.utc_now(),
            role: :admin
          })

        {org, admin}
      end)

    on_exit(fn -> unboxed(fn -> delete_org(org.id, admin.id) end) end)

    %{opts: [actor: admin, tenant: org.id]}
  end

  # A release with one item in it, so one slot is left, and `count` pages
  # that are in no release yet.
  defp fixtures(opts, count) do
    unboxed(fn ->
      release = CMS.create_release!(%{name: "Race #{slug()}"}, opts)
      [first | pages] = for _ <- 0..count, do: CMS.create_page!(%{title: "P", slug: slug()}, opts)
      {:ok, item} = add(release, first, opts)
      {release, item, pages}
    end)
  end

  defp add(release, page, opts),
    do:
      CMS.add_release_item(
        %{release_id: release.id, content_type: "page", content_id: page.id},
        opts
      )

  # The open transaction around a write is the point of these tests, so its
  # `after_transaction` hooks running early is too: silenced here rather than
  # left as noise in the log, and its notifications returned, not missed.
  defp held(opts),
    do:
      opts
      |> Keyword.put(:return_notifications?, true)
      |> Keyword.put(:context, %{warn_on_transaction_hooks?: false})

  defp pending(release, opts) do
    unboxed(fn ->
      CMS.list_release_items_with_status!(
        release.id,
        :pending,
        Keyword.put(opts, :authorize?, false)
      )
    end)
  end

  test "a second add waits for the first to commit, then sees it and is refused",
       %{opts: opts} do
    {release, _item, [a, b]} = fixtures(opts, 2)

    second =
      unboxed(fn ->
        {:ok, second} =
          Repo.transaction(fn ->
            {:ok, _item, _notifications} = add(release, a, held(opts))

            second = Task.async(fn -> unboxed(fn -> add(release, b, opts) end) end)

            # Blocked on the release row, not counting yet: under `FOR SHARE`
            # it would count 1 (the first add is uncommitted) and take the
            # slot too.
            refute Task.yield(second, 300)
            second
          end)

        second
      end)

    assert {:error, %Ash.Error.Invalid{} = error} = Task.await(second, 10_000)
    assert Exception.message(error) =~ "full"
    assert length(pending(release, opts)) == 2
  end

  test "two adds taking the last slot at once: exactly one wins", %{opts: opts} do
    for _round <- 1..5 do
      {release, _item, pages} = fixtures(opts, 2)
      parent = self()

      tasks =
        for page <- pages do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> unboxed(fn -> add(release, page, opts) end)
            end
          end)
        end

      pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
      Enum.each(pids, &send(&1, :go))

      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, %Ash.Error.Invalid{}}, &1)) == 1
      assert length(pending(release, opts)) == 2
    end
  end

  test "an add and a cancel on one release wait for each other and both complete",
       %{opts: opts} do
    # Each order: one write holds its transaction open while the other starts
    # on its own connection. Both lock the release row first, before any item
    # row, so the second waits and then completes; neither is a deadlock.
    {release, item, [page]} = fixtures(opts, 1)

    cancel = fn -> CMS.cancel_release_item(item, %{}, opts) end

    second =
      unboxed(fn ->
        {:ok, second} =
          Repo.transaction(fn ->
            {:ok, _added, _notifications} = add(release, page, held(opts))
            second = Task.async(fn -> unboxed(cancel) end)
            refute Task.yield(second, 300)
            second
          end)

        second
      end)

    assert {:ok, %{status: :cancelled}} = Task.await(second, 10_000)

    {release, item, [page]} = fixtures(opts, 1)

    second =
      unboxed(fn ->
        {:ok, second} =
          Repo.transaction(fn ->
            {:ok, _cancelled, _notifications} =
              CMS.cancel_release_item(item, %{}, held(opts))

            second = Task.async(fn -> unboxed(fn -> add(release, page, opts) end) end)
            refute Task.yield(second, 300)
            second
          end)

        second
      end)

    assert {:ok, %{status: :pending}} = Task.await(second, 10_000)
    assert length(pending(release, opts)) == 1
  end

  # Everything the tests committed lives in their own organization: delete it
  # table by table. A foreign key between two org-scoped tables can refuse a
  # delete until the referencing table is emptied, so loop until a pass makes
  # no progress. (The same helper as `KilnCMS.CMS.ReferenceCapRaceTest`.)
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
