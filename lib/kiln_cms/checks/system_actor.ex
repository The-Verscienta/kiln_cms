defmodule KilnCMS.Checks.SystemActor do
  @moduledoc """
  Matches a `%KilnCMS.SystemActor{}` whose `subsystem` the grant names — a
  trusted internal caller (#1402), scoped to the subsystems whose code makes
  the call (#1747).

  Admits worker, scheduler, delivery-bookkeeping and mix-task code to one
  specific action on one specific resource, in place of the `authorize?: false`
  that admitted it to *everything* on that resource. See `KilnCMS.SystemActor`
  for what the actor is and is not, and `docs/policy-matrix.md` ("The system
  actor") for the resources that admit it.

  ## `subsystem:` is required

      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :links}
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: [:experiments, :operator]}

  An atom or a non-empty list of atoms, naming exactly the subsystems whose
  code calls the actions the clause admits: the label each caller builds its
  actor with (`SystemActor.new/1`, or a domain's `system/0`). Derive it from
  the call sites, not from the resource. A bare `KilnCMS.Checks.SystemActor`,
  an empty list or a non-atom fails the **build** — `init/1` runs when the
  resource compiles — so a grant cannot be written without saying whom it is
  for.

  ### `action:` — when two actions in one clause have different callers

      forbid_unless action([:complete, :mark_overdue_notified])
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :cms_bookkeeping, action: :complete}
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :notifications, action: :mark_overdue_notified}

  Optional. The clause then matches only while the action being authorized is
  one of those named. Without it, a clause that sits below
  `forbid_unless action([:a, :b])` admits its subsystems to both actions; a
  chain of single checks cannot say "`:a` for one caller, `:b` for another",
  and splitting the grant into per-action policies would mean repeating every
  check written for people in each.

  ## Use `authorize_if`, not `bypass`

      policy action_type([:create, :update, :destroy]) do
        authorize_if {KilnCMS.Checks.SystemActor, subsystem: :firing}
        forbid_if always()
      end

  A `bypass` short-circuits **every policy below it** on the resource, so a
  system-actor `bypass` is the same total grant `authorize?: false` gave, only
  spelled differently — and it would silently swallow a policy a later PR adds
  beneath it. An `authorize_if` grants exactly the policy it is written in; a
  new policy elsewhere in the stack still applies to system code until someone
  deliberately admits it there too. That visibility is the entire point of the
  exercise, so this check must never appear in a `bypass` —
  `KilnCMS.PolicyCoverageTest` fails the build if it does.

  ### When the resource already has a broad policy written for people

  Ash **ANDs** policies, so on a resource whose `action_type(:update)` policy
  exists for people (content — `KilnCMS.CMS.Checks.EditableContentType`),
  adding a *second* policy that admits system code changes nothing: the broad
  one still applies and still refuses. Widening that policy outright would
  grant system code every update on the resource, which is the opposite of
  scoped.

  The answer is still not a bypass. Narrow the grant **inside** the policy
  that would otherwise refuse, using `action/1` as a check:

      policy action_type([:create, :update]) do
        authorize_if KilnCMS.CMS.Checks.EditableContentType

        # System-only actions, and only those.
        forbid_unless action([:reindex_search_text, :set_embedding])
        authorize_if {KilnCMS.Checks.SystemActor, subsystem: :firing, action: :reindex_search_text}
        authorize_if {KilnCMS.Checks.SystemActor, subsystem: :search, action: :set_embedding}
      end

  For a person the first clause has already decided, so the ones below it are
  unreachable; for a system actor every action but the two named forbids at
  the second. Nothing is short-circuited, so every other policy on the
  resource — including one a later PR adds — still applies to system code.

  The one place a top-of-stack clause is already correct is
  `AshOban.Checks.AshObanInteraction` on `publish_scheduled`, where the caller
  genuinely *is* the AshOban scheduler and Ash itself vouches for that: the
  check reads the trigger metadata Ash put on the changeset, not an actor the
  caller chose. Prefer it wherever the caller is the scheduler; this check is
  for the much larger set of callers that are not.

  ## Matching

  Matches on the **actor** struct and the action's name only, and on nothing
  about the subject. A check that pattern-matched the *resource* struct would
  be a compile-time cycle with the `policies` block naming it (see
  `KilnCMS.CMS.Checks.EditorMayPublish`); `KilnCMS.SystemActor` is a plain
  struct that depends on nothing, so naming it here is safe.

  Scope is written down twice, on purpose: by which resources and actions carry
  the clause, and by which subsystems it names. The second half is what keeps
  one subsystem's grant from being every subsystem's. Before #1747 the check
  matched any system actor, so every grant any worker needed was every worker's
  — admitting publishing to `Task :complete` let the automation worker complete
  anyone's task too. The two halves cannot drift apart silently:
  `docs/policy-matrix.md` names each grant's subsystems, and
  `KilnCMS.SystemActorScopeTest` checks from that table that each named
  subsystem is admitted and every other one is refused.
  """
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def init(opts) do
    with {:ok, opts} <- init_list(opts, :subsystem, required: true) do
      init_list(opts, :action, required: false)
    end
  end

  defp init_list(opts, key, required: required?) do
    case Keyword.fetch(opts, key) do
      :error when required? ->
        {:error,
         "KilnCMS.Checks.SystemActor needs `subsystem:` — the subsystem(s) whose code " <>
           "calls the actions this clause admits, e.g. " <>
           "`authorize_if {KilnCMS.Checks.SystemActor, subsystem: :links}` (#1747)"}

      :error ->
        {:ok, opts}

      {:ok, value} ->
        values = List.wrap(value)

        if values != [] and Enum.all?(values, &label?/1) do
          {:ok, Keyword.put(opts, key, values |> Enum.uniq() |> Enum.sort())}
        else
          {:error,
           "KilnCMS.Checks.SystemActor `#{key}:` must be an atom or a non-empty list " <>
             "of atoms, got: #{inspect(value)}"}
        end
    end
  end

  defp label?(value), do: is_atom(value) and value not in [nil, true, false]

  @doc """
  The subsystems a clause admits, from its initialized options.
  """
  @spec subsystems(keyword()) :: [atom()]
  def subsystems(opts), do: Keyword.fetch!(opts, :subsystem)

  @doc """
  The actions a clause is narrowed to with `action:`, or `nil` when it is not.
  """
  @spec actions(keyword()) :: [atom()] | nil
  def actions(opts), do: Keyword.get(opts, :action)

  @impl Ash.Policy.Check
  def describe(opts) do
    who = "a KilnCMS system actor for " <> Enum.map_join(subsystems(opts), ", ", &inspect/1)

    case actions(opts) do
      nil -> who
      actions -> who <> " running " <> Enum.map_join(actions, ", ", &inspect/1)
    end
  end

  @impl Ash.Policy.SimpleCheck
  def match?(%KilnCMS.SystemActor{subsystem: subsystem}, context, opts) do
    subsystem in subsystems(opts) and action_admitted?(context, actions(opts))
  end

  def match?(_actor, _context, _opts), do: false

  defp action_admitted?(_context, nil), do: true
  defp action_admitted?(%{action: %{name: name}}, actions), do: name in actions
  defp action_admitted?(_context, _actions), do: false
end
