defmodule KilnCMS.Security.Changes.NoticeWebhookSilenced do
  @moduledoc """
  The `alerts_silenced` notice (#2245) of a change to a webhook endpoint that
  was subscribed to security events (any `security.*` before the change):
  a receiver of the site's alerts that stops hearing them, or might.

  | action | when | change |
  |--------|------|--------|
  | `:update` | the URL changed, the endpoint was switched off, or it unsubscribed from a `security.*` event | `webhook_changed` |
  | `:rotate_secret` | always | `webhook_secret_rotated` |
  | `:destroy` | always | `webhook_removed` |
  | `:record_delivery_failure` | the failure auto-disabled it | `webhook_auto_disabled` |

  A secret rotation is on the list because the receiver stops verifying
  deliveries until it is given the new secret. Subscribing to more, and
  switching an endpoint back on, raise nothing.

  Written in the action's transaction (`KilnCMS.Security.AlertGate.insert_notice!/2`)
  and failing closed: the endpoint change rolls back with a notice that
  cannot be written. The notice names the endpoint by id, never its URL.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.User
  alias KilnCMS.Security.AlertGate

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, endpoint ->
      case notice_change(changeset.action.name, changeset.data, endpoint) do
        nil ->
          :ok

        change ->
          AlertGate.insert_notice!(endpoint.org_id, %{
            change: change,
            endpoint_id: endpoint.id,
            actor_id: actor_id(changeset)
          })
      end

      {:ok, endpoint}
    end)
  end

  @doc false
  # The notice `action` raises on `before` becoming `after_change`, or nil.
  @spec notice_change(atom(), map(), map()) :: String.t() | nil
  def notice_change(action, before, after_change) do
    if security_events(before) == [], do: nil, else: change_for(action, before, after_change)
  end

  defp change_for(:update, before, after_change) do
    if before.url != after_change.url or
         (before.active == true and after_change.active != true) or
         security_events(before) -- security_events(after_change) != [],
       do: "webhook_changed"
  end

  defp change_for(:rotate_secret, _before, _after_change), do: "webhook_secret_rotated"
  defp change_for(:destroy, _before, _after_change), do: "webhook_removed"

  defp change_for(:record_delivery_failure, before, after_change) do
    if before.active == true and after_change.active == false, do: "webhook_auto_disabled"
  end

  defp change_for(_action, _before, _after_change), do: nil

  defp security_events(endpoint),
    do: endpoint |> Map.get(:events) |> List.wrap() |> Enum.filter(&security_event?/1)

  defp security_event?("security." <> _), do: true
  defp security_event?(_event), do: false

  defp actor_id(changeset) do
    case changeset.context[:private][:actor] do
      %User{id: id} -> id
      _other -> nil
    end
  end
end
