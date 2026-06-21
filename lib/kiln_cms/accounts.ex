defmodule KilnCMS.Accounts do
  use Ash.Domain,
    otp_app: :kiln_cms

  resources do
    resource KilnCMS.Accounts.Token

    resource KilnCMS.Accounts.User do
      define :list_users, action: :read
      define :get_user_by_email, action: :get_by_email, args: [:email]
    end
  end
end
