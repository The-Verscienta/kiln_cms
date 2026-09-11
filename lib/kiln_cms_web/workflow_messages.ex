defmodule KilnCMSWeb.WorkflowMessages do
  @moduledoc """
  Flash copy for the content workflow transitions — `submit`, `return`,
  `publish`, `unpublish`, `archive`, `unarchive` — shared by the content list
  (`KilnCMSWeb.EditorLive`) and the content editor
  (`KilnCMSWeb.ContentEditorLive`), so the two surfaces cannot drift apart.

  A failure is described by the error the transition actually returned, never
  by which button was pressed. Only an `Ash.Error.Forbidden` is about the
  actor's role; the Publish, Approve and Return buttons are rendered for admins
  alone, so keying the copy on the verb told an admin whose publish hit a
  publish gate (claim checking, alt text, required consent) that publishing
  "requires an admin approval" — false for them, and it hid the gate's own
  sentence, which is the only thing they could act on. A lost race against a
  colleague's transition (`NoMatchingTransition` / `StaleRecord`, see
  `KilnCMSWeb.AshStateMachineErrors`) is said as such.
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.CoreComponents, only: [ash_error_message: 2, state_label: 1]

  @doc "The success flash for `action`, given the state the record landed in."
  @spec success(String.t(), atom()) :: String.t()
  def success("submit", _state),
    do: gettext("Sent for review — an admin will publish when ready.")

  def success(_action, state), do: gettext("Updated to %{state}.", state: state_label(state))

  @doc "The failure flash for `action`, chosen from the error it returned."
  @spec error(String.t(), term()) :: String.t()
  def error(action, error) do
    cond do
      forbidden?(error) ->
        forbidden(action)

      state_conflict?(error) ->
        gettext("Someone else changed this item's status first — reload to see where it stands.")

      is_exception(error) ->
        ash_error_message(error, fallback: gettext("That action isn't allowed right now."))

      true ->
        gettext("That action isn't allowed right now.")
    end
  end

  @doc "Why `action` is refused to someone whose role may not run it."
  @spec forbidden(String.t()) :: String.t()
  def forbidden("publish"),
    do: gettext("Only an admin can publish. Submit the draft for review instead.")

  def forbidden("return"), do: gettext("Only an admin can return content to draft.")
  def forbidden(_action), do: gettext("You don't have permission to do that.")

  defp forbidden?(error), do: match?(%Ash.Error.Forbidden{}, error_class(error))

  defp state_conflict?(error) do
    error
    |> error_class()
    |> Map.get(:errors, [])
    |> Enum.any?(fn
      %AshStateMachine.Errors.NoMatchingTransition{} -> true
      %Ash.Error.Changes.StaleRecord{} -> true
      _ -> false
    end)
  end

  defp error_class(error) when is_exception(error), do: Ash.Error.to_error_class(error)
  defp error_class(_error), do: %{}
end
