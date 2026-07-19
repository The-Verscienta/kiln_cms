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

  policies do
    # Managed exclusively by AshAuthentication's own machinery during OAuth
    # flows; nothing else reads or writes identities.
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      forbid_if always()
    end
  end
end
