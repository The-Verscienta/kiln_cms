defmodule KilnCMS.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use KilnCMS.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias KilnCMS.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import KilnCMS.DataCase
    end
  end

  setup tags do
    KilnCMS.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(KilnCMS.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Drain **every** configured Oban queue until no job runs, aggregating the
  per-queue results. Jobs are split across workload queues (firing/search/mail/
  …), and a job in one queue can enqueue into another, so draining a single
  queue is no longer sufficient — this loops over all queues until a full pass
  runs nothing. Returns the summed `%{success:, failure:, …}` map.
  """
  def drain_oban(acc \\ %{}) do
    queues =
      :kiln_cms |> Application.fetch_env!(Oban) |> Keyword.fetch!(:queues) |> Keyword.keys()

    pass =
      Enum.reduce(queues, %{}, fn queue, totals ->
        queue
        |> then(&Oban.drain_queue(queue: &1, with_recursion: true))
        |> Map.merge(totals, fn _k, v1, v2 -> v1 + v2 end)
      end)

    acc = Map.merge(acc, pass, fn _k, v1, v2 -> v1 + v2 end)

    if pass |> Map.values() |> Enum.sum() > 0, do: drain_oban(acc), else: acc
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
