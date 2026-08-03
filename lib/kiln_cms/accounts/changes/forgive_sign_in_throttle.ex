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

  The second-factor budget (#714) is cleared with it, for the same reason and
  one step further along. Resetting the password is precisely what *stops* an
  attacker grinding that budget — they can no longer complete the first factor
  and mint pending tokens — so a victim who takes the remedy and then finds
  `/sign-in/verify` still answering 429 for the tail of a fifteen-minute window
  has fixed the problem and been punished for it.

  Applied `after_action`, so a reset that fails validation forgives nothing.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.AccountThrottle

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      AccountThrottle.forgive(to_string(record.email))
      AccountThrottle.forgive_second_factor(record.id)
      {:ok, record}
    end)
  end
end
