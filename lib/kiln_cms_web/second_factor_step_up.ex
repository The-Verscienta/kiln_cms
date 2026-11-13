defmodule KilnCMSWeb.SecondFactorStepUp do
  @moduledoc """
  Whether a first factor that has just passed must stop at the second-factor
  prompt (#2247). One decision for both sign-in doors —
  `KilnCMSWeb.AuthController.success/4` and
  `KilnCMSWeb.ApiAuthController.sign_in/2` — and for the sign-in budget
  (`KilnCMS.Accounts.Preparations.ThrottleSignIn`), so none of them can
  disagree about who owes a second factor.

    * `:prompt` — divert to the prompt; the sign-in is not complete.
    * `:none` — the first factor completes the sign-in.
    * `{:refuse, reason}` — the account owes a second factor this door cannot
      take, so the first factor is worth nothing here.

  It follows `KilnCMS.Accounts.TwoFactorRequirement.step_up/3` on the site the
  sign-in resolved to:

    * `:totp` (the account has the authenticator app, whatever the site's
      policy) — `:prompt`;
    * `:passkey_only` (no app, a passkey, a site that requires a second factor
      of the account, and its deadline passed) — `:prompt` in a browser on a
      host where the passkey ceremony runs
      (`KilnCMS.Accounts.WebAuthn.ceremony_host?/1`), and
      `{:refuse, :passkey_host}` on a host where it cannot (a tenant site
      host). The headless door can never assert a passkey, so it is
      `{:refuse, :headless_passkey}` there;
    * `:none` — `:none`.

  Before the deadline, or on a site that requires nothing, a passkey-only
  account's password still completes its sign-in (owner decision 2 on #2247:
  "once enforced").
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Accounts.WebAuthn

  @type reason :: :passkey_host | :headless_passkey
  @type decision :: :none | :prompt | {:refuse, reason()}

  @doc """
  The decision for `user`, whose first factor passed on `conn`, on the site
  `conn` resolved to.

  Options: `:surface` — `:browser` (the default) or `:api`.
  """
  @spec decide(Plug.Conn.t(), Accounts.User.t(), keyword()) :: decision()
  def decide(%Plug.Conn{} = conn, %Accounts.User{} = user, opts \\ []) do
    surface = Keyword.get(opts, :surface, :browser)

    case TwoFactorRequirement.step_up(user, org_id(conn)) do
      :totp -> :prompt
      :passkey_only -> passkey_only(surface, conn.host)
      :none -> :none
    end
  end

  defp passkey_only(:api, _host), do: {:refuse, :headless_passkey}

  defp passkey_only(:browser, host) do
    if WebAuthn.ceremony_host?(host), do: :prompt, else: {:refuse, :passkey_host}
  end

  defp org_id(%Plug.Conn{assigns: %{current_org: %{id: id}}}) when is_binary(id), do: id
  defp org_id(_conn), do: nil
end
