defmodule KilnCMS.CMS.FieldSectionLockTest do
  @moduledoc """
  A section layout's create against a write that moves the section's only
  field out of it, committed by another transaction at the same moment
  (#3061, `KilnCMS.CMS.Validations.SectionCarried`).

  The create reads the carrying field `FOR SHARE`; the move takes it
  `FOR UPDATE`. Whichever goes first, the other waits, and no layout is left
  without a field. Without the lock, both orders leave one.

  Run **outside** the sandbox (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`), on
  real connections whose writes commit, for the reason
  `KilnCMS.Accounts.ErasureRaceTest` gives: inside the sandbox a row lock
  never makes anything wait. The first transaction holds on a
  `KilnCMS.Test.Latch` after it has its locks, the second is shown to be
  waiting, then the first is released. Everything is written in an org of
  its own, deleted again on exit. The writes run `authorize?: false`: the
  lock is the subject here, and `KilnCMS.CMS.FieldSectionTest` covers who
  may write. Not `async`, so no other test runs alongside.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.Test.Latch

  @moduletag :capture_log

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    start_supervised!({Latch, name: :section_lock, listener: self()})

    {org, field} =
      unboxed(fn ->
        org =
          Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
            name: "section lock",
            slug: "section-lock-#{System.unique_integer([:positive])}",
            status: :active
          })

        field =
          CMS.create_field_definition!(
            %{content_type: :page, name: "lock_latin", label: "Latin", section: "Lock Names"},
            authorize?: false,
            tenant: org.id
          )

        {org, field}
      end)

    on_exit(fn -> unboxed(fn -> cleanup(org.id) end) end)

    %{org: org, field: field}
  end

  defp opts(org), do: [authorize?: false, tenant: org.id]

  defp create(org),
    do:
      CMS.create_field_section(
        %{content_type: :page, name: "Lock Names", display: :tab},
        opts(org)
      )

  defp move(field, org),
    do: CMS.update_field_definition(field, %{section: "Lock Other"}, opts(org))

  defp layouts(org), do: unboxed(fn -> CMS.field_sections_for!(:page, opts(org)) end)

  # `fun` in a transaction held open, after it ran, until released.
  defp held(fun),
    do: Task.async(fn -> unboxed(fn -> Repo.transaction(fn -> hold(fun.()) end) end) end)

  defp hold(result) do
    Latch.enter(:section_lock)
    result
  end

  # Once the first transaction holds its locks, start `second` and show it
  # waits on them; then let the first commit. Returns the second's result.
  defp race(second) do
    assert_receive {:latch_started, :section_lock, 1}, 5_000
    task = Task.async(fn -> unboxed(second) end)
    refute Task.yield(task, 300), "the second transaction did not wait for the first"
    assert [_] = Latch.release_all(:section_lock)
    Task.await(task)
  end

  test "a create waits for a move in flight, then is refused", %{org: org, field: field} do
    first = held(fn -> move(field, org) end)
    result = race(fn -> create(org) end)

    assert {:ok, {:ok, _moved}} = Task.await(first)

    assert {:error,
            %Ash.Error.Invalid{errors: [%Ash.Error.Changes.InvalidAttribute{field: :name}]}} =
             result

    assert layouts(org) == []
    refute_received {:latch_timeout, _, _}
  end

  test "a move waits for a create in flight, then prunes its layout", %{org: org, field: field} do
    first = held(fn -> create(org) end)
    result = race(fn -> move(field, org) end)

    assert {:ok, {:ok, _layout}} = Task.await(first)
    assert {:ok, %{section: "Lock Other"}} = result
    assert layouts(org) == []
    refute_received {:latch_timeout, _, _}
  end

  defp cleanup(org_id) do
    org = Ecto.UUID.dump!(org_id)

    %{rows: tables} =
      Repo.query!("""
      SELECT table_name FROM information_schema.columns
      WHERE column_name = 'org_id' AND table_schema = 'public'
      """)

    sweep(Enum.map(tables, &hd/1), org, 10)
    Repo.query!("DELETE FROM oban_jobs WHERE args::text ~ $1", [org_id])
    Repo.query!("DELETE FROM organizations WHERE id = $1", [org])
  end

  defp sweep([], _org, _passes), do: :ok
  defp sweep(_tables, _org, 0), do: :ok

  defp sweep(tables, org, passes) do
    left =
      Enum.reject(tables, fn table ->
        match?({:ok, _}, Repo.query(~s|DELETE FROM "#{table}" WHERE org_id = $1|, [org]))
      end)

    sweep(left, org, passes - 1)
  end
end
