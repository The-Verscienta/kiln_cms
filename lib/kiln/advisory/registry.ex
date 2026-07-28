defmodule Kiln.Advisory.Registry do
  @moduledoc """
  Discovers advisory checks and runs them.

  Core checks come from config; plugin checks come from `Kiln.Plugins`, the
  same fan-out that collects blocks and field types:

      config :kiln_cms, Kiln.Advisory, checks: [MyApp.Advisories.Whatever]

  ## Failure is contained

  A check that raises is dropped, logged, and the rest still run. These render
  in the content editor on every keystroke, and a third-party plugin's bad
  check must not be able to take the editor down with it — losing one
  advisory is a far better outcome than losing the author's session.
  """

  require Logger

  alias Kiln.Advisory.Context
  alias Kiln.Advisory.Finding

  @type outcome :: {module(), Kiln.Advisory.outcome()}

  @doc "Every registered check module, core first."
  @spec checks() :: [module()]
  def checks, do: configured() ++ Kiln.Plugins.advisories()

  @doc """
  Run every registered check against `context`.

  Returns `{module, outcome}` pairs — the module is kept so a caller can
  attribute a finding, and so a misbehaving check is nameable in a log.
  """
  @spec run(Context.t()) :: [outcome()]
  def run(%Context{} = context), do: run(context, checks())

  @doc "Run a specific list of checks — for tests, and for narrowing a panel."
  @spec run(Context.t(), [module()]) :: [outcome()]
  def run(%Context{} = context, modules) do
    Enum.flat_map(modules, &safe_check(&1, context))
  end

  @doc "Just the findings, in registration order."
  @spec findings([outcome()]) :: [Finding.t()]
  def findings(outcomes), do: for({_module, %Finding{} = f} <- outcomes, do: f)

  @doc """
  How many applicable checks passed, and how many were applicable.

  `:n_a` outcomes count as neither — a check with nothing to judge is not a
  pass, and counting it as one would flatter an empty draft.
  """
  @spec tally([outcome()]) :: {non_neg_integer(), non_neg_integer()}
  def tally(outcomes) do
    passed = Enum.count(outcomes, &match?({_module, :ok}, &1))
    applicable = Enum.count(outcomes, &(not match?({_module, :n_a}, &1)))

    {passed, applicable}
  end

  defp safe_check(module, context) do
    module.check(context)
    |> List.wrap()
    |> Enum.map(&{module, &1})
  rescue
    exception ->
      Logger.error("Advisory check #{inspect(module)} raised: #{Exception.message(exception)}")

      []
  catch
    kind, reason ->
      Logger.error("Advisory check #{inspect(module)} #{kind}: #{inspect(reason)}")
      []
  end

  defp configured do
    :kiln_cms
    |> Application.get_env(Kiln.Advisory, [])
    |> Keyword.get(:checks, [])
  end
end
