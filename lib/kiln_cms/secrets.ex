defmodule KilnCMS.Secrets do
  @moduledoc """
  Resolves AshAuthentication secrets (the token signing secret) from
  application config, which is loaded from the environment in `runtime.exs`.
  """
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
