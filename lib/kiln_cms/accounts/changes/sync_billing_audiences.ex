defmodule KilnCMS.Accounts.Changes.SyncBillingAudiences do
  @moduledoc """
  Guard for `KilnCMS.Accounts.User.sync_billing_audiences`.

  ## Why a change module and not just a policy

  `forbid_if always()` is **not sufficient on this resource**.
  `KilnCMS.Accounts.User` opens its policies with

      bypass actor_attribute_equals(:role, :admin) do
        authorize_if always()
      end

  and a bypass short-circuits every later policy — so an admin actor would sail
  straight past a `forbid_if`. That is exactly why `:sign_in_with_passkey` needed a
  second guard inside `KilnCMS.Accounts.Preparations.PasskeySessionToken`, and this
  is the same belt-and-braces: any actor-carrying call is refused here, leaving
  `authorize?: false` system callers (i.e. `KilnCMS.Billing.Entitlements`) as the
  only way in.

  Also validates the values: a recompute bug must not be able to persist an
  audience outside the configured set, because Ash casts that column to atoms on
  read and a bad value would break every subsequent read of this user.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.Audiences

  @impl true
  def change(changeset, _opts, context) do
    if context.actor do
      Ash.Changeset.add_error(changeset,
        field: :audiences,
        message: "billing entitlements are applied by the system, not by an actor"
      )
    else
      validate_audiences(changeset)
    end
  end

  defp validate_audiences(changeset) do
    audiences = Ash.Changeset.get_attribute(changeset, :audiences) || []

    case Enum.reject(audiences, &Audiences.valid?/1) do
      [] ->
        changeset

      unknown ->
        Ash.Changeset.add_error(changeset,
          field: :audiences,
          message: "contains unconfigured audiences: #{inspect(unknown)}"
        )
    end
  end
end
