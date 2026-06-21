defmodule KilnCMS.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        KilnCMS.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:kiln_cms, :token_signing_secret)
  end
end
