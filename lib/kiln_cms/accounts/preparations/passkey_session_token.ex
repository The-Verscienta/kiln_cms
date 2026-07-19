defmodule KilnCMS.Accounts.Preparations.PasskeySessionToken do
  @moduledoc """
  Mints the session token for a passkey sign-in (#331), exactly like the
  built-in strategies' sign-in preparations: a `"purpose" => "user"` JWT
  (stored, per `store_all_tokens?`) placed in the record's `:token` metadata,
  which `store_in_session/2` requires
  (`require_token_presence_for_authentication?`).

  Two fail-closed guards:

    * an **actor-carrying** call returns nothing — token minting is reserved
      for the `authorize?: false` ceremony path
      (`KilnCMS.Accounts.WebAuthn.authenticate/2`, post-Wax-verification), so
      even the admin policy bypass cannot turn this read into a
      mint-a-session-for-anyone primitive;
    * a token-minting failure **errors the read** instead of returning a
      token-less user — a silent nil token would report sign-in success and
      then bounce the browser at the session check, untraceably.
  """
  use Ash.Resource.Preparation

  alias AshAuthentication.Jwt

  require Ash.Query

  @impl true
  def prepare(query, _opts, context) do
    if context.actor do
      Ash.Query.filter(query, false)
    else
      Ash.Query.after_action(query, fn _query, users -> mint_all(users) end)
    end
  end

  defp mint_all(users) do
    users
    |> Enum.reduce_while({:ok, []}, fn user, {:ok, acc} ->
      case Jwt.token_for_user(user, %{"purpose" => "user"}) do
        {:ok, token, _claims} ->
          {:cont, {:ok, [Ash.Resource.put_metadata(user, :token, token) | acc]}}

        _ ->
          {:halt, {:error, "passkey session token could not be minted"}}
      end
    end)
    |> case do
      {:ok, minted} -> {:ok, Enum.reverse(minted)}
      error -> error
    end
  end
end
