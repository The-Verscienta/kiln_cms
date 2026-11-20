defmodule KilnCMS.Search.BudgetDbTest do
  @moduledoc """
  The grace after a search budget's deadline (#2614), against a real query:
  a section that finishes its query inside the grace keeps its database
  connection. Killed mid-query instead, Postgrex cancels the query and
  DBConnection drops the connection — in the SQL sandbox, the test's own.
  The scheduler's timing cases are in `KilnCMS.Search.BudgetTest`.
  """
  # async: false — the section's task reaches the test's connection through
  # the shared sandbox, and a regression here takes that connection down.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Repo
  alias KilnCMS.Search.Budget

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  test "a section mid-query at the deadline returns inside the grace on the same connection" do
    before = backend_pid()

    sections = [
      slow: fn _sweep ->
        Repo.query!("SELECT pg_sleep(0.3)")
        :slept
      end
    ]

    outcomes =
      Budget.run(sections, Budget.deadline(100),
        concurrency: 2,
        stall_timeout: 5_000,
        grace: 2_000
      )

    # The connection first: it is what the grace is for, and a section the
    # grace did not save fails here with the reason, not on its outcome.
    after_cut =
      try do
        backend_pid()
      rescue
        error in [DBConnection.OwnershipError, DBConnection.ConnectionError, Postgrex.Error] ->
          flunk("the cut took the sandbox connection down: " <> Exception.message(error))
      catch
        # The sandbox's proxy for the connection stopped with it.
        :exit, reason ->
          flunk("the cut took the sandbox connection down: " <> inspect(reason, limit: 5))
      end

    assert after_cut == before,
           "the section's connection was dropped and reopened " <>
             "(backend #{before} before the cut, #{after_cut} after)"

    assert outcomes == %{slow: {:done, :slept}}
  end
end
