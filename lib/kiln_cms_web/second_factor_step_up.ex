defmodule KilnCMSWeb.SecondFactorStepUp do
  @moduledoc """
  Whether a first factor that has just passed must stop at the second-factor
  prompt (#2247). One decision for both sign-in doors —
  `KilnCMSWeb.AuthController.success/4` and
  `KilnCMSWeb.ApiAuthController.sign_in/2` — so they cannot disagree about
  who owes a second factor.

    * `:prompt` — divert to the prompt; the sign-in is not complete.
    * `:none` — the first factor completes the sign-in.

  Today it answers `:prompt` exactly when the account has the authenticator
  app, which is what both doors did inline before it. A passkey-only account
  is **not** diverted: its passkey can complete the prompt (`/sign-in/verify`
  offers it when the account has one), but nothing requires a second factor
  of it yet, so its password alone still signs it in. A site policy that
  requires one is what will widen this.
  """

  alias KilnCMS.Accounts

  @type decision :: :none | :prompt

  @doc "The decision for `user`, whose first factor passed on `conn`."
  @spec decide(Plug.Conn.t(), Accounts.User.t()) :: decision()
  def decide(_conn, %Accounts.User{} = user) do
    if Accounts.totp_enabled?(user), do: :prompt, else: :none
  end
end
