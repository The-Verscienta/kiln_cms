defmodule KilnCMS.Accounts.Validations.KeepsRequiredSecondFactor do
  @moduledoc """
  Refuses removing an account's last second factor while a site it uses
  requires one (#2247): `User.:disable_totp` with no passkey left, and
  `Passkey.:destroy` of the only passkey of an account with no authenticator
  app. "Required" is `KilnCMS.Accounts.TwoFactorRequirement.required_somewhere?/1`,
  whether or not the grace period is over: an account that removes its factor
  during the grace would only be held again at once.

  Only the owner's own removal. A platform administrator removing someone
  else's passkey, and the invitation takeover (`:forget_on_takeover`, which
  this is not on), are unaffected: those are how a lost or stolen factor is
  cleared. Replacing the authenticator app (`:setup_totp` then `:confirm_totp`,
  after a recovery-code sign-in included) is not a removal and is not on this
  validation's actions at all. Removing the app while a passkey remains, or a
  passkey while another factor remains, is allowed.

  Declared on `:disable_totp` **before** `ThrottleSecondFactor`, which there
  runs only on a valid changeset, so a refusal here spends none of the
  second-factor budget and compares no code.

  The factor count is read when the changeset is built, so two removals racing
  for the last two passkeys could both pass; the account then has none, and
  the site's gate holds it until it sets one up again.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.LastSecondFactorRequired
  alias KilnCMS.Accounts.Passkey
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Accounts.User

  @impl true
  def validate(changeset, _opts, context) do
    case owner_removal(changeset.data, context.actor) do
      {%User{} = owner, removing} ->
        if last?(owner, removing) and TwoFactorRequirement.required_somewhere?(owner),
          do: {:error, LastSecondFactorRequired.exception([])},
          else: :ok

      # Not the owner's own removal, or the owner is gone.
      _other ->
        :ok
    end
  end

  # The account whose factor this removes, when the actor is that account.
  defp owner_removal(%User{id: id} = user, %User{id: id}), do: {user, :totp}

  defp owner_removal(%Passkey{user_id: id}, %User{id: id} = actor),
    do: {reload(actor), :passkey}

  defp owner_removal(_record, _actor), do: nil

  # What is left once this one goes: the app goes with `:disable_totp`, one
  # passkey with `:destroy`.
  defp last?(owner, :totp), do: Accounts.second_factors(owner).passkeys == 0

  defp last?(owner, :passkey) do
    %{totp?: totp?, passkeys: passkeys} = Accounts.second_factors(owner)
    not totp? and passkeys <= 1
  end

  # The actor's struct may predate an enrolment in another tab; the factors it
  # holds are read from the row as it is now.
  defp reload(%User{} = actor) do
    case Accounts.get_user(actor.id, actor: actor, not_found_error?: false) do
      {:ok, %User{} = user} -> user
      _gone -> nil
    end
  end
end
