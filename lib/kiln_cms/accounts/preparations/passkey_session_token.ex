defmodule KilnCMS.Accounts.Preparations.PasskeySessionToken do
  @moduledoc """
  Mints the session token for a passkey sign-in (#331), exactly like the
  built-in strategies' sign-in preparations: a `"purpose" => "user"` JWT
  (stored, per `store_all_tokens?`) placed in the record's `:token` metadata,
  which `store_in_session/2` requires
  (`require_token_presence_for_authentication?`).

  Only reachable through `User.sign_in_with_passkey`, which the ceremony code
  (`KilnCMS.Accounts.WebAuthn.authenticate/2`) calls **after** Wax verified
  the assertion — the action itself performs no authentication.
  """
  use Ash.Resource.Preparation

  alias AshAuthentication.Jwt

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn _query, users ->
      {:ok, Enum.map(users, &mint/1)}
    end)
  end

  defp mint(user) do
    case Jwt.token_for_user(user, %{"purpose" => "user"}) do
      {:ok, token, _claims} -> Ash.Resource.put_metadata(user, :token, token)
      _ -> user
    end
  end
end
