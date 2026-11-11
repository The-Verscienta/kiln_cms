defmodule KilnCMS.Accounts.Preparations.InvitationByToken do
  @moduledoc """
  The filter behind `Invitation.:by_token` (#2135): the live row whose stored
  hash matches the presented token, or nothing.

  Hashes the argument and compares hashes, so the plaintext is never in a query
  and a database read cannot be turned back into a link. A row past its
  `expires_at` matches nothing, exactly like a made-up token.

  System-only. The action's policy forbids every authorized caller, and this
  refuses an actor-carrying call itself, because the platform-admin bypass on
  the resource would otherwise pass it (`User.:sign_in_with_passkey` is guarded
  the same way).
  """
  use Ash.Resource.Preparation

  require Ash.Query

  alias KilnCMS.Accounts.Invitations

  @impl true
  def prepare(query, _opts, %{actor: actor}) when not is_nil(actor),
    do: Ash.Query.filter(query, false)

  def prepare(query, _opts, _context) do
    case Ash.Query.get_argument(query, :token) do
      token when is_binary(token) and token != "" ->
        hash = Invitations.hash(token)
        Ash.Query.filter(query, token_hash == ^hash and expires_at > now())

      _blank ->
        Ash.Query.filter(query, false)
    end
  end
end
