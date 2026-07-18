defmodule KilnCMS.Automation do
  @moduledoc """
  Oban-backed editorial automation — Kiln's answer to Directus Flows (#342).

  A no-code "**when** X happens, **do** Y" layer over the primitives Kiln already
  runs: the content state machine (the triggers), Oban (the executor), and
  PubSub/MTA/cache (the reactions). No embedded scripting runtime.

  `handle_event/2` is the entry point: it's called for every editorial event
  (from `KilnCMS.Webhooks.dispatch/2`, the single funnel for `<type>.published`
  / `.unpublished` / `.updated`), finds the enabled rules that match, and
  enqueues one `KilnCMS.Automation.RuleWorker` per rule. Rules run off-request,
  isolated per job, retried by Oban — a slow email or a failing reaction never
  blocks (or breaks) the publish that triggered it.
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
  Evaluate automation rules for an editorial `event` (e.g. `"post.published"`)
  and enqueue a worker per matching rule. A no-op for events that aren't a
  supported lifecycle trigger (`ping`, `form.submitted`, …). Never raises — a
  problem here must not break the content action that emitted the event.
  """
  @spec handle_event(String.t(), map()) :: :ok
  def handle_event(event, payload) when is_binary(event) do
    with [type, verb] <- String.split(event, ".", parts: 2),
         {:ok, trigger} <- parse_trigger(verb),
         {:ok, rules} <- rules_for(trigger, type, authorize?: false) do
      Enum.each(rules, &enqueue(&1, event, payload))
    end

    :ok
  rescue
    error ->
      Logger.error("Automation.handle_event failed for #{inspect(event)}: #{inspect(error)}")
      :ok
  end

  def handle_event(_event, _payload), do: :ok

  defp enqueue(rule, event, payload) do
    %{"rule_id" => rule.id, "event" => event, "payload" => payload}
    |> KilnCMS.Automation.RuleWorker.new()
    |> Oban.insert()
  end

  defp parse_trigger("published"), do: {:ok, :published}
  defp parse_trigger("unpublished"), do: {:ok, :unpublished}
  defp parse_trigger("updated"), do: {:ok, :updated}
  defp parse_trigger(_other), do: :error
end
