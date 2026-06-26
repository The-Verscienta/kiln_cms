defmodule KilnCMS.Accounts do
  @moduledoc """
  The Accounts domain — authentication and identity (`User`, `Token`).

  Authentication is handled by AshAuthentication (password strategy). The
  `User.role` attribute (`:admin`/`:editor`/`:viewer`) drives RBAC across the
  CMS domain.
  """
  use Ash.Domain,
    otp_app: :kiln_cms

  resources do
    resource KilnCMS.Accounts.Token

    resource KilnCMS.Accounts.User do
      define :list_users, action: :read
      define :get_user_by_email, action: :get_by_email, args: [:email]
      define :update_notification_prefs, action: :update_notification_prefs
    end
  end
end
