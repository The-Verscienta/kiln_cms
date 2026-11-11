defmodule KilnCMS.Accounts.Changes.RequireRegistrationChallenge do
  @moduledoc """
  Asks `:register_with_password` for a human-verification challenge when the
  operator's registration mode calls for one (#2249) — always, or once the
  caller's address has registered `registration_threshold` times in the
  window. `KilnCMS.Challenge.Gate.registration/2` decides.

  After `KilnCMS.Accounts.Changes.ThrottleRegistration`, so a flood is bounded
  by the per-address `:register` bucket before any of it reaches a third
  party, and from `before_transaction` for the same two reasons that change
  gives: a change body runs per keystroke on a `phx-change` form, and a counter
  charged inside the transaction is refunded by the rollback a refused
  registration causes. The verification call is a network round trip, which
  has no business holding a transaction open either.

  The refusal says nothing about the address being registered: whether a
  challenge is needed depends on the caller's own address, never on whether the
  submitted one has an account, and it is decided before
  `RefuseExistingAddress` looks.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.Errors.ChallengeRequired
  alias KilnCMS.Challenge.Gate

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      token = Ash.Changeset.get_argument(changeset, :challenge_token)

      case Gate.registration(changeset.context, token) do
        :ok ->
          changeset

        {:refuse, reason} ->
          Ash.Changeset.add_error(changeset, ChallengeRequired.exception(reason: reason))
      end
    end)
  end
end
