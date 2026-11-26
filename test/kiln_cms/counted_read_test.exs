defmodule KilnCMS.CountedReadTest do
  @moduledoc """
  A count-paginated read with `authorize_with: :error` keeps a refusal a
  refusal (#2934). The backup history (`Backups.run_history/1`, the `:history`
  read) is the subject: it is countable, and the `:backups` system actor reads
  runs but is refused that action, so it is refused by policy rather than by
  a missing role.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.Test.BackupSchedules

  alias KilnCMS.Backups
  alias KilnCMS.CountedRead

  defp run!(n) do
    Backups.start_run!(
      %{
        stamp: "202601#{String.pad_leading(Integer.to_string(n), 2, "0")}-030000",
        trigger: "schedule",
        schedule_ids: [],
        started_at: DateTime.add(~U[2026-01-01 00:00:00.000000Z], n, :hour)
      },
      actor: Backups.system()
    )
  end

  defp history(actor, count?) do
    Backups.run_history(actor: actor, authorize_with: :error, page: [limit: 1, count: count?])
  end

  # The upstream defect itself. When this starts failing, Ash accepts
  # AshPostgres's `{:error, :no_rollback, _}` from `run_aggregate_query/3`,
  # and `KilnCMS.CountedRead` can be retired.
  test "canary: the count of a refused read still raises Ash.Error.Framework upstream" do
    assert_raise Ash.Error.Framework, ~r/run_aggregate_query/, fn ->
      history(Backups.system(), true)
    end
  end

  test "a refused count-paginated read is Forbidden, not a raise" do
    run!(1)

    for actor <- [Backups.system(), user(:editor), site_admin()] do
      assert {:error, %Ash.Error.Forbidden{}} = CountedRead.read(&history(actor, &1))
    end
  end

  test "an allowed read keeps its page and count" do
    for n <- 1..3, do: run!(n)

    assert {:ok, %Ash.Page.Offset{count: 3, results: [_]}} =
             CountedRead.read(&history(platform_admin(), &1))
  end

  # A refusal that only the counted rows reach: the uncounted read has no
  # error to give, so the count's own error comes back, as an error.
  test "the count's error is returned when the uncounted read succeeds" do
    read = fn
      true -> history(Backups.system(), true)
      false -> {:ok, :uncounted_page}
    end

    assert {:error, %Ash.Error.Framework{}} = CountedRead.read(read)
  end

  test "other errors and raises pass through untouched" do
    assert CountedRead.read(fn _count? -> {:error, :elsewhere} end) == {:error, :elsewhere}

    assert_raise RuntimeError, "boom", fn ->
      CountedRead.read(fn _count? -> raise "boom" end)
    end
  end
end
