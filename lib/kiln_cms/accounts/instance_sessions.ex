defmodule KilnCMS.Accounts.InstanceSessions do
  @moduledoc """
  "Sign out everyone on every site" (#2491) as an Ash action, so the caller is
  authorized by a policy like every other write: `:sign_out_everyone`, run by
  `KilnCMS.Accounts.SignOutEveryone`.

  No data layer: nothing is stored here (the precedent is
  `KilnCMS.Security.PostureReport`). No tenant either: the action reaches
  every site at once, which is why it is a platform admin's act and not a
  site admin's (`KilnCMS.CMS.SiteSessionPolicy`'s `:sign_out_all` is that).

  ## Who may run it

  A platform admin by **effective** role (`KilnCMS.Accounts.Checks.PlatformAdmin`):
  a standing one, or one holding a temporary grant that has not expired. A
  site admin who is not a platform admin is refused, as is anyone signed in
  with an API key (defense in depth: a key's owner may be a platform admin),
  a system actor and an anonymous caller. The policy runs before the typed
  phrase is compared, so a refused caller is refused whatever they typed.

  Not an API surface: absent from JSON:API, GraphQL and MCP.
  """
  use Ash.Resource,
    domain: KilnCMS.Accounts,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    # Returns how many sessions were signed out: browser sessions and
    # headless app tokens (`"user"` rows), not the remember-me cookies and
    # two-factor holds that go with them.
    action :sign_out_everyone, :integer do
      description "Sign out every browser session and app token on every site."

      argument :confirmation, :string do
        description "The phrase `KilnCMS.Accounts.SignOutEveryone.phrase/0` names, typed."
        allow_nil? false
        constraints max_length: 255
      end

      argument :except_session_jti, :string, sensitive?: true

      run KilnCMS.Accounts.SignOutEveryone
    end
  end

  policies do
    policy action(:sign_out_everyone) do
      # A key is for the APIs, and this is on none of them; refused by name
      # even so, in case it ever is.
      forbid_if AshAuthentication.Checks.UsingApiKey
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
    end
  end
end
