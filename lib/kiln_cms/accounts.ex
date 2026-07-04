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

    # API keys for third-party / headless read access (admin-managed). Pass
    # `actor: admin` — the resource policies restrict management to admins.
    resource KilnCMS.Accounts.ApiKey do
      define :mint_api_key, action: :create, args: [:user_id, :name, :expires_at]
      define :list_api_keys, action: :for_user, args: [:user_id]
      define :list_all_api_keys, action: :read
      define :get_api_key, action: :read, get_by: [:id]
      define :revoke_api_key, action: :revoke
    end

    resource KilnCMS.Accounts.User do
      define :list_users, action: :read
      define :get_user_by_email, action: :get_by_email, args: [:email]
      define :update_notification_prefs, action: :update_notification_prefs
      # Admin-only: assign role + consumer audiences; pass `actor: admin`.
      define :manage_user_access, action: :manage_access
      # GDPR Art. 17 erasure (#212) — admin-only; pass `actor: admin`.
      define :anonymize_user, action: :anonymize
    end
  end

  @doc """
  A JSON-serializable snapshot of a user's own data for an access/portability
  request (GDPR Art. 15/20, #212): profile fields and notification preferences.
  No secrets (password hash, tokens) are included.
  """
  @spec export_user_data(KilnCMS.Accounts.User.t()) :: map()
  def export_user_data(%KilnCMS.Accounts.User{} = user) do
    %{
      account: %{
        id: user.id,
        email: to_string(user.email),
        name: user.name,
        role: user.role,
        audiences: user.audiences,
        confirmed_at: user.confirmed_at,
        anonymized_at: user.anonymized_at
      },
      notification_preferences: %{
        notify_on_review_request: user.notify_on_review_request,
        notify_on_publish: user.notify_on_publish,
        notify_on_return_to_draft: user.notify_on_return_to_draft
      }
    }
  end
end
