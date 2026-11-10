defmodule KilnCMS.Test.QueryCountingTest do
  @moduledoc """
  The counter the query-count tests stand on (#2504). Its whole point is what
  it leaves out, so that is pinned here rather than assumed: a counter that
  kept every query in the VM would pass these tests' equalities most of the
  time and flake the rest.
  """
  # async: false — the unrelated process below needs the shared sandbox.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Repo
  alias KilnCMS.Test.QueryCounting

  defp select_one, do: Repo.query!("SELECT 1")

  test "counts the test's own queries and those of a process working for it" do
    {result, queries} =
      QueryCounting.queries(fn ->
        select_one()
        Task.await(Task.async(&select_one/0))
        :done
      end)

    assert result == :done
    assert length(queries) == 2
    assert Enum.all?(queries, &(&1.sql == "SELECT 1"))
  end

  test "leaves out a query from a process that is not working for the test" do
    test = self()

    {_, queries} =
      QueryCounting.queries(fn ->
        spawn(fn ->
          select_one()
          send(test, :queried)
        end)

        assert_receive :queried
      end)

    assert queries == []
  end

  test "detaches its handler, even when the measured function raises" do
    assert_raise RuntimeError, fn -> QueryCounting.queries(fn -> raise "boom" end) end

    refute Enum.any?(
             :telemetry.list_handlers([:kiln_cms, :repo, :query]),
             &(is_binary(&1.id) and String.starts_with?(&1.id, "query-counting-"))
           )
  end

  test "a mismatch names the table that moved" do
    left = [%{source: "pages", sql: "", params: []}, %{source: "users", sql: "", params: []}]
    right = [%{source: "pages", sql: "", params: []}]

    error =
      assert_raise ExUnit.AssertionError, fn ->
        QueryCounting.assert_same_queries(left, right, "many minus few")
      end

    assert error.message =~ ~s(many minus few: [{"users", 1}])
  end

  test "an equal total over different tables still fails" do
    left = [%{source: "pages", sql: "", params: []}]
    right = [%{source: "users", sql: "", params: []}]

    assert_raise ExUnit.AssertionError, fn -> QueryCounting.assert_same_queries(left, right) end
  end
end
