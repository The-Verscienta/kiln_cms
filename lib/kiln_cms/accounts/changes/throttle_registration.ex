defmodule KilnCMS.Accounts.Changes.ThrottleRegistration do
  @moduledoc """
  Bounds `:register_with_password` per client address (#724).

  The sharp one of the four credential forms. `RegisterForm` submits over
  `/live` like the rest, so it passed no router pipeline and touched no bucket:
  one websocket replaying `submit` was unlimited account creation, at a bcrypt
  hash and a confirmation mail per event, from a single address, with nothing
  counting. `register_with_password` carried `RegistrationEnabled`,
  `HashPasswordChange` and `GenerateTokenChange` — no per-IP and no per-account
  budget of any kind.

  ## Its own bucket, not `:auth`

  Sharing sign-in's would mean a burst of legitimate sign-ups locks *sign-in*
  for that address — the shared-NAT trade residual risk 4 already records, and
  an office or CI runner behind one egress address is exactly where a burst of
  sign-ups comes from. `:register` is tighter than `:auth` in absolute terms
  because account creation is rarer and more expensive than a sign-in attempt,
  and it cannot take the door beside it down with it.

  There is deliberately no per-*account* budget here, because there is no
  account yet: the address being registered is attacker-chosen, so keying on it
  would let anyone deny a specific address its first registration.

  Charged from `before_action` for the reason in `KilnCMS.Accounts.ClientIpBudget`
  — a `change/3` body runs per `AshPhoenix.Form.validate/2`, which is per
  keystroke on a `phx-change` form.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.ClientIpBudget
  alias KilnCMS.Accounts.Errors.AddressThrottled

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case ClientIpBudget.check(changeset.context, :register) do
        :allow ->
          changeset

        {:deny, _retry_after} ->
          # Not `ClientIpBudget.refusal/2`: that returns the forbidden-class
          # `AuthenticationFailed` a refused *sign-in* needs, and
          # `AshPhoenix.Form` surfaces a forbidden error as no field error at
          # all — so the Register button appeared to do nothing. A registration
          # refusal has no secret to keep, so it says so, on a field.
          Ash.Changeset.add_error(changeset, AddressThrottled.exception(field: :email))
      end
    end)
  end
end
