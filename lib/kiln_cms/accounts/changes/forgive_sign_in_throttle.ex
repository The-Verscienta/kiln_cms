defmodule KilnCMS.Accounts.Changes.ForgiveSignInThrottle do
  @moduledoc """
  Clears an account's sign-in budget once ownership is proven some other way (#478).

  `KilnCMS.Accounts.AccountThrottle` counts sign-in *attempts*, so a run of wrong
  guesses against a known address holds the real owner out for the tail of a
  window. That is bounded and self-releasing by design — but the owner should not
  have to wait it out when they can prove the account is theirs, and the one
  remedy the alert mail offers them (reset your password) would otherwise leave
  them staring at "invalid email or password" afterwards.

  So a completed password reset forgives the counter. The reset token is a
  single-use secret delivered to the account's own mailbox; holding it is a
  stronger claim than the password the throttle is protecting.

  Applied `after_action`, so a reset that fails validation forgives nothing.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.AccountThrottle

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      AccountThrottle.forgive(to_string(record.email))
      {:ok, record}
    end)
  end
end
