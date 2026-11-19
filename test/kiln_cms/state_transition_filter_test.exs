defmodule KilnCMS.StateTransitionFilterTest do
  @moduledoc """
  ADR 0074 (#3122): every action named in a `transition ... from:` entry of an
  `AshStateMachine` resource filters its UPDATE on its from-states.

  The machine judges the struct the caller holds, not the row, so without a
  `filter` change a transition from a stale struct passes the machine and
  overwrites whatever moved in between. This walks every resource in the
  configured domains that uses the extension, so a new state machine or a new
  transition action is covered without anyone remembering to list it.

  The check is that an `Ash.Resource.Change.Filter` change is present, not that
  its expression equals the `transitions` block; that comparison stays a review
  matter (ADR 0074, "What is accepted").
  """
  use ExUnit.Case, async: true

  # `{resource, action} => reason`. An entry is a deliberate exception, and the
  # reason has to say why a stale struct cannot do harm there. Empty today: every
  # transition action filters.
  @allowlist %{}

  defp state_machine_resources do
    :kiln_cms
    |> Application.fetch_env!(:ash_domains)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.filter(&(AshStateMachine in Spark.extensions(&1)))
    |> Enum.sort()
  end

  defp transition_actions(resource) do
    resource
    |> AshStateMachine.Info.state_machine_transitions()
    |> Enum.map(& &1.action)
    |> Enum.reject(&(&1 == :*))
    |> Enum.uniq()
  end

  defp filters?(resource, action_name) do
    action = Ash.Resource.Info.action(resource, action_name)

    Enum.any?(action.changes, fn
      %{change: {Ash.Resource.Change.Filter, _}} -> true
      _ -> false
    end)
  end

  test "the walk finds the three state machines" do
    resources = state_machine_resources()

    for resource <- [KilnCMS.CMS.ContentRelease, KilnCMS.Experiments.Experiment, KilnCMS.CMS.Page] do
      assert resource in resources, "#{inspect(resource)} is not in the walk"
    end
  end

  test "every transition action filters on its from-states" do
    missing =
      for resource <- state_machine_resources(),
          action <- transition_actions(resource),
          not Map.has_key?(@allowlist, {resource, action}),
          not filters?(resource, action) do
        "#{inspect(resource)}.#{action}"
      end

    assert missing == [],
           "these transition actions have no `change filter(expr(state ...))` (ADR 0074): " <>
             "#{Enum.join(missing, ", ")}. Add the filter, or allowlist the action here " <>
             "with the reason a stale struct is harmless."
  end

  test "an allowlist entry names a real transition action and says why" do
    for {{resource, action}, reason} <- @allowlist do
      assert action in transition_actions(resource),
             "#{inspect(resource)}.#{action} is allowlisted but is not a transition action"

      assert is_binary(reason) and String.length(reason) > 20
    end
  end

  test "an action with a filter and one without are told apart" do
    # The detector is the only thing here that could rot silently, so pin it on
    # a non-transition action that has no filter.
    refute filters?(KilnCMS.Experiments.Experiment, :update)
    assert filters?(KilnCMS.Experiments.Experiment, :conclude)
  end
end
