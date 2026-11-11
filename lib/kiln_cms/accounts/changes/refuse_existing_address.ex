defmodule KilnCMS.Accounts.Changes.RefuseExistingAddress do
  @moduledoc """
  `:register_with_password` creates no row for an address that already has an
  account, and mails its owner instead (#2255).

  Left to the `:unique_email` identity, registering a known address failed with
  "has already been taken" while an unknown one succeeded, which answered "does
  this address have an account?" for anyone who asked. This raises
  `KilnCMS.Accounts.Errors.AlreadyRegistered` instead, and the two callers turn
  that into the same "check your email" answer a new address gets.

  ## Ordering matters

  Declared **after** `HashPasswordChange` on the action, so the hook below runs
  after the bcrypt hash. A known address that skipped the hash would answer
  ~100 ms faster than an unknown one, which is the same oracle by clock.

  The owner is mailed from `after_transaction`, not from the hook that refuses:
  that one runs inside the create's transaction, and the refusal rolls it back
  with the notice's Oban job in it.

  The lookup is `authorize?: false`: a registration has no actor, and the answer
  only decides whether to refuse; it is never shown to the caller.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.AlreadyRegistered
  alias KilnCMS.Accounts.User.Senders.SendRegistrationNotice

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      email = Ash.Changeset.get_attribute(changeset, :email)

      # authorize?: false — pre-auth registration lookup, no actor exists
      if match?({:ok, %{}}, Accounts.get_user_by_email(email, authorize?: false)) do
        Ash.Changeset.add_error(changeset, AlreadyRegistered.exception(field: :email))
      else
        changeset
      end
    end)
    |> Ash.Changeset.after_transaction(fn changeset, result ->
      if AlreadyRegistered.in?(result_error(result)) do
        SendRegistrationNotice.deliver(to_string(Ash.Changeset.get_attribute(changeset, :email)))
      end

      result
    end)
  end

  defp result_error({:error, error}), do: error
  defp result_error(_ok), do: nil
end
