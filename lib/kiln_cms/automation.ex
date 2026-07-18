defmodule KilnCMS.Automation do
  @moduledoc """
  Oban-backed editorial automation — Kiln's answer to Directus Flows (#342).

  A no-code "**when** X happens, **do** Y" layer over the primitives Kiln already
  runs: the content state machine (the triggers), Oban (the executor), and
  PubSub/MTA/cache (the reactions). No embedded scripting runtime.

  `handle_event/2` is the entry point: it's called for every editorial event
  (from `KilnCMS.Webhooks.dispatch/2`, the single funnel for `<type>.published`
  / `.unpublished` / `.updated`). It runs on the publish path, so it does **no
  database work** there — it just enqueues a `DispatchWorker` (an `Oban.insert`,
  which commits/rolls back with the publish). The worker then does the rule
  match (`dispatch/2`) and enqueues one `KilnCMS.Automation.RuleWorker` per rule,
  all off-request — so a slow email or a failing reaction (or a rules read that
  errors) never blocks or rolls back the publish that triggered it.
  """
  use Ash.Domain

  require Logger

  resources do
    resource KilnCMS.Automation.Rule do
      define :list_rules, action: :read
      define :get_rule, action: :read, get_by: [:id]
      define :rules_for, action: :matching, args: [:trigger_event, :content_type]
      define :create_rule, action: :create
      define :update_rule, action: :update
      define :destroy_rule, action: :destroy
    end
  end

  @doc """
  Queue automation evaluation for an editorial `event` (e.g. `"post.published"`).
  Called on the publish path: a cheap string filter (no DB), then an `Oban.insert`
  of a `DispatchWorker` for events that are a supported lifecycle trigger. A
  no-op for other events (`ping`, `form.submitted`, …). Never raises.
  """
  @spec handle_event(String.t(), map()) :: :ok
  def handle_event(event, payload) when is_binary(event) do
    with [_type, verb] <- String.split(event, ".", parts: 2),
         {:ok, _trigger} <- parse_trigger(verb) do
      %{"event" => event, "payload" => payload}
      |> KilnCMS.Automation.DispatchWorker.new()
      |> Oban.insert()
    end

    :ok
  rescue
    error ->
      Logger.error("Automation.handle_event failed for #{inspect(event)}: #{inspect(error)}")
      :ok
  end

  def handle_event(_event, _payload), do: :ok

  @doc """
  Match `event` against the enabled rules and enqueue one `RuleWorker` per rule.
  Runs off the publish transaction (from `DispatchWorker`), so the `rules_for`
  read can't poison the publish. Returns `:ok`.
  """
  @spec dispatch(String.t(), map()) :: :ok
  def dispatch(event, payload) when is_binary(event) do
    with [type, verb] <- String.split(event, ".", parts: 2),
         {:ok, trigger} <- parse_trigger(verb),
         {:ok, rules} <- rules_for(trigger, type, authorize?: false) do
      Enum.each(rules, &enqueue(&1, event, payload))
    end

    :ok
  end

  defp enqueue(rule, event, payload) do
    %{"rule_id" => rule.id, "event" => event, "payload" => payload}
    |> KilnCMS.Automation.RuleWorker.new()
    |> Oban.insert()
  end

  # Derived from the canonical Rule.triggers/0 so a new lifecycle trigger only
  # has to be added there (not also here).
  defp parse_trigger(verb) do
    trigger = String.to_existing_atom(verb)
    if trigger in KilnCMS.Automation.Rule.triggers(), do: {:ok, trigger}, else: :error
  rescue
    ArgumentError -> :error
  end
end
