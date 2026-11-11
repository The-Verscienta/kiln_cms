defmodule KilnCMS.ReportingRole do
  @moduledoc """
  Test scaffolding for the `kiln_reporting_v1` views (#2295): a throwaway
  non-superuser role that may only `SELECT` from the views, and a leak
  detector that reads every view the way a BI tool would.

  The role is created inside the test's sandbox transaction, so it vanishes
  with the rollback and concurrent tests never share one. `as/2` runs a
  function with `SET LOCAL ROLE`, then resets it, so the rest of the test
  keeps the owner's rights.
  """

  alias KilnCMS.Repo

  @schema KilnCMS.Reporting.ViewSql.schema()

  @doc "Creates a read-only role that may select from the schema's views; returns its name."
  @spec create!() :: String.t()
  def create! do
    role = "kiln_rpt_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE ROLE #{role} NOLOGIN")
    Repo.query!("GRANT USAGE ON SCHEMA #{@schema} TO #{role}")
    grant_views!(role)
    role
  end

  @doc "Grants `SELECT` on every view in the schema (also ones a test added)."
  @spec grant_views!(String.t()) :: :ok
  def grant_views!(role) do
    Repo.query!("GRANT SELECT ON ALL TABLES IN SCHEMA #{@schema} TO #{role}")
    :ok
  end

  @doc "Runs `fun` as `role`. Resets the role afterwards, even when `fun` raises."
  @spec as(String.t(), (-> result)) :: result when result: term()
  def as(role, fun) do
    Repo.query!("SET LOCAL ROLE #{role}")

    try do
      fun.()
    after
      Repo.query!("RESET ROLE")
    end
  end

  @doc "The names of the views in the schema."
  @spec views() :: [String.t()]
  def views do
    %{rows: rows} =
      Repo.query!(
        "SELECT viewname FROM pg_views WHERE schemaname = $1 ORDER BY viewname",
        [@schema]
      )

    List.flatten(rows)
  end

  @doc "Every row of every view as one JSON text per view, read as `role`."
  @spec dump(String.t()) :: %{String.t() => String.t()}
  def dump(role) do
    as(role, fn ->
      for view <- views(), into: %{} do
        %{rows: rows} =
          Repo.query!("SELECT row_to_json(t)::text FROM #{@schema}.#{view} t ORDER BY 1")

        {view, rows |> List.flatten() |> Enum.join("\n")}
      end
    end)
  end

  @doc """
  The `needles` that appear in any view, as `{view, needle}` pairs. Empty
  means no leak.
  """
  @spec leaks(String.t(), [String.t()]) :: [{String.t(), String.t()}]
  def leaks(role, needles) do
    for {view, text} <- dump(role), needle <- needles, String.contains?(text, needle) do
      {view, needle}
    end
  end
end
