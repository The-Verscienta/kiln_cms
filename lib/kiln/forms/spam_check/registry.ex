defmodule Kiln.Forms.SpamCheck.Registry do
  @moduledoc """
  Discovers spam checks and runs them — the `Kiln.Advisory.Registry` analogue
  for #477.

  Core checks come from config; plugin checks come from `Kiln.Plugins`, the
  same fan-out that collects advisories, blocks, and field types:

      config :kiln_cms, Kiln.Forms.SpamCheck, checks: [MyApp.SpamChecks.Whatever]

  ## Failure is contained

  A check that raises is dropped, logged, and the rest still run — a bad
  plugin check must not fail a visitor's submission, and losing one check's
  opinion is a far better outcome than 500ing a public, anonymous endpoint.
  """

  require Logger

  alias Kiln.Forms.SpamCheck.Context

  @type outcome :: {module(), Kiln.Forms.SpamCheck.outcome()}

  @doc "Every registered check module, core first."
  @spec checks() :: [module()]
  def checks, do: configured() ++ Kiln.Plugins.spam_checks()

  @doc """
  Run every registered check against `context`.

  Returns `{module, outcome}` pairs — the module is kept so a misbehaving
  check is nameable in a log.
  """
  @spec run(Context.t()) :: [outcome()]
  def run(%Context{} = context), do: run(context, checks())

  @doc "Run a specific list of checks — for tests."
  @spec run(Context.t(), [module()]) :: [outcome()]
  def run(%Context{} = context, modules) do
    Enum.flat_map(modules, &safe_check(&1, context))
  end

  @doc "The summed weight of every flagged outcome."
  @spec score([outcome()]) :: non_neg_integer()
  def score(outcomes) do
    Enum.reduce(outcomes, 0, fn
      {_module, {:flag, _reason, weight}}, acc -> acc + weight
      {_module, :ok}, acc -> acc
    end)
  end

  @doc "The reason codes of every flagged outcome, in registration order."
  @spec reasons([outcome()]) :: [atom()]
  def reasons(outcomes), do: for({_module, {:flag, reason, _weight}} <- outcomes, do: reason)

  defp safe_check(module, context) do
    module.check(context)
    |> List.wrap()
    |> Enum.map(&{module, &1})
  rescue
    exception ->
      Logger.error("Spam check #{inspect(module)} raised: #{Exception.message(exception)}")

      []
  catch
    kind, reason ->
      Logger.error("Spam check #{inspect(module)} #{kind}: #{inspect(reason)}")
      []
  end

  defp configured do
    :kiln_cms
    |> Application.get_env(Kiln.Forms.SpamCheck, [])
    |> Keyword.get(:checks, [])
  end
end
