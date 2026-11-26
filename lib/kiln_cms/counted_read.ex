defmodule KilnCMS.CountedRead do
  @moduledoc """
  A count-paginated read that keeps a refusal a refusal (#2934).

  With `authorize_with: :error`, Ash turns a refused read into a filter that
  raises inside Postgres. For the rows that is fine: AshPostgres's
  `run_query/2` hands the raise back as `{:error, :no_rollback, %Forbidden{}}`
  and the read returns `{:error, %Ash.Error.Forbidden{}}`. The count of a
  count-paginated read (`page: [count: true]`) goes through
  `run_aggregate_query/3` instead, which returns the same three-tuple, and
  Ash only accepts `{:ok, _}` or `{:error, _}` there. So the read raises
  `Ash.Error.Framework` ("Invalid value returned from
  AshPostgres.DataLayer.run_aggregate_query/3") and the refusal is lost: a
  500 where a 403 belongs. Seen on ash 3.38.1 / ash_postgres 2.15.2, and
  the same code is on both projects' main branches.

  `read/1` runs the read with the count and, when the count fails that way,
  runs it again without one. That second read fails as the rows do: with
  the refusal itself (`{:error, %Ash.Error.Forbidden{}}`) for an actor the
  policy refuses outright. When it succeeds anyway (a refusal that hangs on
  rows the uncounted page didn't reach), the count still has no answer, so
  the Framework error comes back as `{:error, error}` rather than a raise.

  The JSON:API, GraphQL and MCP reads authorize with Ash's default
  `:filter`, which drops refused rows instead of raising, so they never
  reach this; it is for our own `authorize_with: :error` reads that count.
  `test/kiln_cms/counted_read_test.exs` holds a canary that fails once Ash
  accepts the three-tuple, at which point this can go.
  """

  @typedoc "Runs the read: with the count when given `true`, without when `false`."
  @type read_fun :: (count? :: boolean() -> {:ok, term()} | {:error, term()})

  @doc """
  Runs `read.(true)`, the count-paginated read. If its count fails as
  described in the moduledoc, runs `read.(false)` and returns its error, or
  `{:error, %Ash.Error.Framework{}}` when that read succeeds.
  """
  @spec read(read_fun()) :: {:ok, term()} | {:error, term()}
  def read(read) when is_function(read, 1) do
    case counted(read) do
      {:error, error} ->
        if bad_count_return?(error), do: uncounted(read, error), else: {:error, error}

      ok ->
        ok
    end
  end

  # The read raises the Framework error rather than returning it; a rescue
  # keeps that raise from reaching the caller as a crash. Any other exception
  # is not ours to handle and is re-raised.
  defp counted(read) do
    read.(true)
  rescue
    error in Ash.Error.Framework ->
      if bad_count_return?(error), do: {:error, error}, else: reraise(error, __STACKTRACE__)
  end

  defp uncounted(read, count_error) do
    case read.(false) do
      {:error, error} -> {:error, error}
      {:ok, _} -> {:error, count_error}
    end
  end

  defp bad_count_return?(%Ash.Error.Framework{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Framework.InvalidReturnType{message: message} ->
        String.contains?(message, "run_aggregate_query")

      _other ->
        false
    end)
  end

  defp bad_count_return?(_error), do: false
end
