defmodule KilnCMS.Accounts.SsoSecrets do
  @moduledoc """
  Resolves the OIDC SSO strategy's settings (#331) from application config,
  loaded from `OIDC_*` environment variables in `runtime.exs`. One module for
  every option, keyed by the option name in the secret path.
  """
  use AshAuthentication.Secret

  def secret_for([:authentication, :strategies, :sso, option], KilnCMS.Accounts.User, _opts, _ctx)
      when option in [:client_id, :client_secret, :base_url, :redirect_uri] do
    case :kiln_cms |> Application.get_env(:sso_oidc, []) |> Keyword.get(option) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end
end
