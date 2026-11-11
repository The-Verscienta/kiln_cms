defmodule KilnCMS.Accounts.Checks.RotatableDraftWriteKey do
  @moduledoc """
  The policy on `ApiKey`'s `:rotate` action: the actor authenticated with a
  `:draft_write` API key that is unrevoked, unexpired, and still inside the
  rotation window an admin set when minting it (`rotatable_until`).

  Every other actor is refused — a `:read` or `:read_write` key, a JWT or
  session user, an admin, or no actor. Rotation is how a service keeps the one
  credential it was given alive, not a way for anyone to mint one.

  It judges the key the actor **authenticated with** (`__metadata__.api_key`),
  which is also the only key the action can rotate: `Changes.RotateDraftWriteKey`
  copies everything from it and takes no input. So "a key may rotate only
  itself" holds by construction, and this check is the gate in front of it.

  The struct on the actor was read at sign-in. `RotateDraftWriteKey` re-reads
  the row under a lock before revoking it, so a key revoked between sign-in
  and rotation is caught there; this check is the cheap, early refusal.
  """
  use Ash.Policy.SimpleCheck

  alias KilnCMS.Accounts.ApiKey

  @impl Ash.Policy.Check
  def describe(_opts),
    do: "using a valid draft-write API key that is inside its rotation window"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, _context, _opts) do
    case presenting_key(actor) do
      %ApiKey{} = key -> rotatable?(key, DateTime.utc_now())
      nil -> false
    end
  end

  @doc """
  The API key `actor` authenticated with, whatever its scope, or nil.
  `rotatable?/2` is what decides the scope.
  """
  @spec presenting_key(term()) :: ApiKey.t() | nil
  def presenting_key(%{__metadata__: %{using_api_key?: true, api_key: %ApiKey{} = key}}), do: key
  def presenting_key(_actor), do: nil

  @doc """
  Whether `key` may rotate at `now`: a `:draft_write` key, not revoked, not
  expired, with a `rotatable_until` still in the future. The only place the
  scope is judged — the policy and the row re-check under lock both come here.
  """
  @spec rotatable?(ApiKey.t(), DateTime.t()) :: boolean()
  def rotatable?(%ApiKey{access: :draft_write} = key, now) do
    is_nil(key.revoked_at) and
      after?(key.expires_at, now) and
      after?(key.rotatable_until, now)
  end

  def rotatable?(_key, _now), do: false

  defp after?(%DateTime{} = at, now), do: DateTime.compare(at, now) == :gt
  defp after?(_at, _now), do: false
end
