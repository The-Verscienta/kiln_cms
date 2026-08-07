defmodule KilnCMSWeb.AshStateMachineErrors do
  @moduledoc """
  Client-facing translations of `AshStateMachine.Errors.NoMatchingTransition`
  for the headless surfaces (#880).

  The four content workflow transitions — `submit_for_review`, `return_to_draft`,
  `publish`, `unpublish` — are state-machine actions. Calling one on a record
  that is in the wrong state (double-tapping "Return", approving what a colleague
  just approved, retrying a request that already landed) raises
  `NoMatchingTransition`. It is the single most common *client* error on the
  review surface, not a server fault.

  Neither `AshJsonApi.ToJsonApiError` nor `AshGraphql.Error` is implemented for
  it upstream, so without the impls below:

    * JSON:API takes the fallback branch in `AshJsonApi.Error`'s
      `to_json_api_error` clause and returns an opaque `something_went_wrong`
      400 with a random error id —
      indistinguishable to a client from a genuine 500 — **and** logs a formatted
      stacktrace per request (the warning fires precisely because the protocol is
      unimplemented). A retrying client spams it.
    * GraphQL masks it as a generic error in the `errors` field.

  Both impls report a **409 Conflict** — the request was well-formed, the
  resource is simply in a state the transition does not apply to — with a stable
  `invalid_state_transition` code and a detail that names the current state, so a
  client can tell "already in that state" from a server fault and reconcile
  without parsing prose. The current and target states also ride in the JSON:API
  `meta` / GraphQL `vars` for machine consumption.

  Lives here beside `KilnCMSWeb.AshFormErrors` — the other cross-cutting Ash
  error translation — rather than in the `KilnCMS.CMS` domain, because it is a
  transport concern, and the same transition error from any future state-machine
  resource gets the same treatment for free.
  """

  @doc false
  # A client-facing sentence naming the state the record is actually in and the
  # transition that does not apply to it. Mirrors the arms of
  # `NoMatchingTransition.message/1`, which may leave `old_state` or `target` nil.
  def detail(%{old_state: old, target: target, action: action}) do
    case {old, target} do
      {nil, _} ->
        "This content is not in a state the #{action} action can act on. " <>
          "Reload it to see its current state."

      {old, nil} ->
        "This content is in the #{inspect(to_string(old))} state, which the " <>
          "#{action} action cannot transition from. Reload it to see its current state."

      {old, target} ->
        "This content is in the #{inspect(to_string(old))} state, so the #{action} " <>
          "action (which moves content to #{inspect(to_string(target))}) does not " <>
          "apply. Reload it to see its current state."
    end
  end

  @doc false
  # Machine-readable context for JSON:API `meta` / GraphQL `vars`. Stringified so
  # it survives JSON encoding regardless of the atom states.
  def vars(%{old_state: old, target: target, action: action}) do
    %{
      current_state: state_string(old),
      target_state: state_string(target),
      action: state_string(action)
    }
  end

  defp state_string(nil), do: nil
  defp state_string(value), do: to_string(value)

  defimpl AshJsonApi.ToJsonApiError, for: AshStateMachine.Errors.NoMatchingTransition do
    def to_json_api_error(error) do
      %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 409,
        code: "invalid_state_transition",
        title: "InvalidStateTransition",
        detail: KilnCMSWeb.AshStateMachineErrors.detail(error),
        meta: KilnCMSWeb.AshStateMachineErrors.vars(error)
      }
    end
  end

  defimpl AshGraphql.Error, for: AshStateMachine.Errors.NoMatchingTransition do
    def to_error(error) do
      %{
        message: KilnCMSWeb.AshStateMachineErrors.detail(error),
        short_message: "invalid state transition",
        code: "invalid_state_transition",
        vars: KilnCMSWeb.AshStateMachineErrors.vars(error),
        fields: []
      }
    end
  end
end
