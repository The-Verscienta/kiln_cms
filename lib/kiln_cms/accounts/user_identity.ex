defmodule KilnCMS.Accounts.UserIdentity do
  @moduledoc """
  A user's link to an external identity provider (#331, OIDC SSO).

  Stores the provider's stable `iss`/`sub` (as strategy + uid) plus refreshed
  tokens, managed entirely by AshAuthentication's UserIdentity extension. This
  is what makes SSO sign-in stable: after the first (verified-email) link, the
  user is matched by provider identity — an email change at the IdP or in Kiln
  can't detach or re-target the account.
  """
  use Ash.Resource,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.UserIdentity]

  user_identity do
    user_resource KilnCMS.Accounts.User
  end

  postgres do
    table "user_identities"
    repo KilnCMS.Repo
  end

  actions do
    # Accepting a site invitation over an unconfirmed account (#2453): a link
    # to an identity provider made by whoever registered the address first
    # must not survive the invitee setting the account up. No shipped path
    # links one to an unconfirmed account today; the takeover forgets any it
    # finds all the same, so a later path cannot reopen the hole. Both are the
    # invitations system actor's alone (`Changes.ForgetPriorCredentials`).
    #
    # No audit event: there is no event type for an identity link, and none is
    # recorded when one is made either.
    read :for_user do
      description "An account's identity-provider links (the invitation takeover's read)."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    destroy :forget_on_takeover do
      description "Remove an identity-provider link when an invitation takes over an unconfirmed account (system-only)."
    end
  end

  policies do
    # Managed by AshAuthentication's own machinery during OAuth flows; nothing
    # else reads or writes identities but the invitation takeover below.
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: :invitations, action: [:for_user, :forget_on_takeover]}

      forbid_if always()
    end
  end
end
