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
  @spec handle_event(String.t(), map(), Ash.UUID.t()) :: :ok
  def handle_event(event, payload, org_id \\ KilnCMS.Accounts.default_org_id())

  def handle_event(event, payload, org_id) when is_binary(event) do
    with [_type, verb] <- String.split(event, ".", parts: 2),
         {:ok, _trigger} <- parse_trigger(verb) do
      # `org_id` rides into the dispatch worker so rules only fire for their own
      # site (epic #336).
      %{"event" => event, "payload" => payload, "org_id" => org_id}
      |> KilnCMS.Automation.DispatchWorker.new()
      |> Oban.insert()
    end

    :ok
  rescue
    error ->
      Logger.error("Automation.handle_event failed for #{inspect(event)}: #{inspect(error)}")
      :ok
  end

  def handle_event(_event, _payload, _org_id), do: :ok

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor the rule match runs as (#1659): a `KilnCMS.SystemActor`, admitted
  on `KilnCMS.Automation.Rule` for reads only (see `docs/policy-matrix.md`,
  "The system actor"), rather than `authorize?: false`, which would skip every
  policy on it.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:automation)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process, so a test can take the grant away and prove the rule match fails
  # CLOSED instead of reading "no rules". Process-local, and nothing on a
  # request path calls it; code that could call it could equally pass any
  # actor it liked.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun) do
    previous = Process.get(@actor_override, :unset)
    Process.put(@actor_override, actor)

    try do
      fun.()
    after
      if previous == :unset,
        do: Process.delete(@actor_override),
        else: Process.put(@actor_override, previous)
    end
  end

  @doc """
  Match `event` against `org`'s enabled rules and enqueue one `RuleWorker` per
  rule. Runs off the publish transaction (from `DispatchWorker`), so the
  `rules_for` read can't poison the publish.

  Returns `:ok`, or `{:error, reason}` when the rules could not be read, which
  fails the `DispatchWorker` job so Oban retries it. The read runs as
  `system/0` with `authorize_with: :error`: a refused read would filter to
  "no rules", dropping every automation for the event while the job reported
  success. A failed read used to be swallowed the same way.
  """
  @spec dispatch(String.t(), map(), Ash.UUID.t()) :: :ok | {:error, term()}
  def dispatch(event, payload, org_id \\ KilnCMS.Accounts.default_org_id())

  def dispatch(event, payload, org_id) when is_binary(event) do
    with [type, verb] <- String.split(event, ".", parts: 2),
         {:ok, trigger} <- parse_trigger(verb) do
      match_rules(trigger, type, event, payload, org_id)
    else
      _not_a_lifecycle_trigger -> :ok
    end
  end

  defp match_rules(trigger, type, event, payload, org_id) do
    case rules_for(trigger, type, actor: system(), authorize_with: :error, tenant: org_id) do
      {:ok, rules} ->
        Enum.each(rules, &enqueue(&1, event, payload, org_id))

      {:error, reason} ->
        Logger.error(
          "Automation.dispatch could not read the rules for #{inspect(event)} " <>
            "in org #{org_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp enqueue(rule, event, payload, org_id) do
    args = %{
      "rule_id" => rule.id,
      "event" => event,
      # Top-level copy of the document id — Oban unique keys can only address
      # top-level args.
      "document_id" => payload["id"],
      "payload" => payload,
      "org_id" => org_id
    }

    args
    |> KilnCMS.Automation.RuleWorker.new(unique_opts(payload))
    |> Oban.insert()
  end

  # Pending-duplicate dedupe (#377 review follow-up): a re-fired duplicate
  # editorial event collapses onto the still-QUEUED job for the same {rule,
  # event, document}. Deliberately narrow — only :available/:scheduled — so a
  # legitimate follow-up event (second publish/edit of the same document)
  # arriving while the first job is executing or retrying is NEVER dropped;
  # and no uniqueness at all without a document id, so id-less events can't
  # collapse onto each other. (Retry-after-partial-success remains inherent
  # to at-least-once side effects; the newsletter action has its own
  # ledger-level dedupe for exactly that.)
  defp unique_opts(%{"id" => id}) when is_binary(id) do
    [
      unique: [
        period: 60,
        keys: [:rule_id, :event, :document_id],
        states: [:available, :scheduled]
      ]
    ]
  end

  defp unique_opts(_payload), do: []

  # Derived from the canonical Rule.triggers/0 so a new lifecycle trigger only
  # has to be added there (not also here).
  defp parse_trigger(verb) do
    trigger = String.to_existing_atom(verb)
    if trigger in KilnCMS.Automation.Rule.triggers(), do: {:ok, trigger}, else: :error
  rescue
    ArgumentError -> :error
  end
end
