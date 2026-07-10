ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(KilnCMS.Repo, :manual)

# Clear stray Oban jobs before the suite runs.
#
# Every test runs inside a sandbox transaction that is rolled back, so nothing
# the suite enqueues is ever committed. Any `oban_jobs` row sitting in the test
# database at boot is therefore garbage, left by an aborted run, a `mix run`
# against MIX_ENV=test, or a concurrent `mix test` sharing this database (use
# MIX_TEST_PARTITION to give each run its own).
#
# Such a row is not inert. `KilnCMS.DataCase.drain_oban/0` drains *every*
# available job, so a stray job is re-executed inside whichever unrelated test
# drains next — delivering a phantom email or webhook into that test's mailbox
# and breaking assertions that count them. Worse, the drain's state update is
# rolled back along with the test's transaction, so the row stays `available`
# and re-poisons every subsequent run until it is deleted by hand.
Ecto.Adapters.SQL.Sandbox.unboxed_run(KilnCMS.Repo, fn ->
  case KilnCMS.Repo.query!("DELETE FROM oban_jobs") do
    %{num_rows: 0} ->
      :ok

    %{num_rows: rows} ->
      IO.puts(
        :stderr,
        "[test_helper] cleared #{rows} stray oban_jobs row(s) from the test database — " <>
          "an aborted or unsandboxed run left them behind; they would have been drained " <>
          "into unrelated tests."
      )
  end
end)
