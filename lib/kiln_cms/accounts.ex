defmodule KilnCMS.Accounts do
  use Ash.Domain,
    otp_app: :kiln_cms

  resources do
    resource KilnCMS.Accounts.Token
    resource KilnCMS.Accounts.User
  end
end
