defmodule KilnCMS.Billing.Settings.Changes.ClearCredentials do
  @moduledoc """
  The operator's "disconnect": null both billing secrets, reset each provider to
  the `:database` default, and drop the cached account confirmation.

  With no resolvable credentials `KilnCMS.Billing.configured?/0` is false, so the
  join page renders no tiers, checkout 404s, and the webhook route 404s — every
  surface degrades to "billing not set up" rather than erroring.

  The settings row itself is kept so the singleton identity stays stable and a
  later reconnect is an update rather than a create race.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:secret_key_provider, :database)
    |> Ash.Changeset.force_change_attribute(:secret_key_provider_config, %{})
    |> Ash.Changeset.force_change_attribute(:secret_key_encrypted, nil)
    |> Ash.Changeset.force_change_attribute(:webhook_secret_provider, :database)
    |> Ash.Changeset.force_change_attribute(:webhook_secret_provider_config, %{})
    |> Ash.Changeset.force_change_attribute(:webhook_secret_encrypted, nil)
    |> Ash.Changeset.force_change_attribute(:provider_account_id, nil)
    |> Ash.Changeset.force_change_attribute(:livemode, nil)
    |> Ash.Changeset.force_change_attribute(:last_verified_at, nil)
    |> Ash.Changeset.force_change_attribute(:verification_error, nil)
  end
end
