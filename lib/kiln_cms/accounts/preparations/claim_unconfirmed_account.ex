defmodule KilnCMS.Accounts.Preparations.ClaimUnconfirmedAccount do
  @moduledoc """
  On `User.:sign_in_with_magic_link`: when the link signs in to an
  **unconfirmed** account, take the account over for the address's owner
  before the session is minted (#2594), through the system-only
  `User.:take_over_by_magic_link` (`Changes.ClaimUnconfirmedAccount` says what
  that does and why).

  Declared ahead of AshAuthentication's `SignInPreparation`, so its
  `after_action` runs first: it sees the one account the token named only when
  the token verified (an invalid token filters the read to nothing), and the
  record it returns, confirmed and with its factors cleared, is the one the
  library then mints the session for. Minting after the takeover is what lets
  the session survive the takeover's sweep of every token the account held;
  the sweep spares the magic link itself, which the library revokes single-use
  next.

  An account that was confirmed by the time the takeover locked its row
  (`Errors.AlreadyConfirmed`) signs in as it is. Any other failure fails the
  sign-in, rather than signing the owner in to an account a stranger can still
  get into.
  """
  use Ash.Resource.Preparation

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.AlreadyConfirmed
  alias KilnCMS.Accounts.User
  alias KilnCMS.Security.Recorder

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, &claim/2)
  end

  defp claim(query, [%User{confirmed_at: nil} = user]) do
    token = Ash.Query.get_argument(query, :token)

    # authorize?: false — a pre-auth flow with no actor: the magic link the
    # library just verified is the credential, and the action is system-only
    # (`forbid_if always()`, and its change refuses any actor).
    case Accounts.take_over_by_magic_link(user, %{token: token},
           authorize?: false,
           context: Map.take(query.context, [Recorder.context_key(), Recorder.tenant_key()])
         ) do
      {:ok, claimed} ->
        {:ok, [claimed]}

      {:error, error} ->
        if already_confirmed?(error), do: {:ok, [user]}, else: {:error, error}
    end
  end

  defp claim(_query, records), do: {:ok, records}

  defp already_confirmed?(%AlreadyConfirmed{}), do: true

  defp already_confirmed?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &already_confirmed?/1)

  defp already_confirmed?(_error), do: false
end
