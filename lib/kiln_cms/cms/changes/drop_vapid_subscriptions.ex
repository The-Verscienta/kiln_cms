defmodule KilnCMS.CMS.Changes.DropVapidSubscriptions do
  @moduledoc """
  Deletes this site's push subscriptions made against the key a
  `SiteVapidKey` is losing (#1560) — on `:rotate` and `:destroy`.

  A subscription is bound to the public key the browser subscribed with, and a
  push service refuses a message signed by any other. Keeping the rows would
  only mean a failed delivery per device per notification. Deleting them in
  the same transaction means there is never a moment when a subscription points
  at a key the site no longer holds. Subscriptions made against the
  deployment's key (`vapid_public_key` nil) are not this key's and are left
  alone.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.data do
      %{public_key: old_key, org_id: org_id} when is_binary(old_key) and is_binary(org_id) ->
        Ash.Changeset.after_action(changeset, fn _changeset, result ->
          drop(org_id, old_key)
          {:ok, result}
        end)

      _no_key ->
        changeset
    end
  end

  # A system write. The admin rotating the key does not own the reviewers'
  # subscriptions, and the policy that stops them deleting those rows directly
  # is right everywhere else. This runs only inside the admin-authorized
  # `:rotate`/`:destroy` of this site's own key.
  defp drop(org_id, key) do
    # `authorize?: false`: `bound_to_key` is system-only by policy, and its own
    # filter (this org, this key) is the whole grant.
    subscriptions = Accounts.push_subscriptions_bound_to_key!(org_id, key, authorize?: false)

    Enum.each(subscriptions, fn subscription ->
      # `authorize?: false`: each row came from the scoped read above; the
      # destroy policy (owner only) would refuse the rotating admin.
      Accounts.remove_push_subscription!(subscription, authorize?: false)
    end)
  end
end
