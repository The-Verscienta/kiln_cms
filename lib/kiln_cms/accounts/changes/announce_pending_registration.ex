defmodule KilnCMS.Accounts.Changes.AnnouncePendingRegistration do
  @moduledoc """
  Tells a site's admins that someone is waiting for their approval (#2251),
  at the moment the applicant confirms their address.

  A registration waits from the moment it is created, but it cannot be
  approved until the address is confirmed (`DecideRegistration`), so that is
  when an admin has something to do. Declared on every `User` update rather
  than on `:confirm_new_user` alone, because three update actions confirm an
  unconfirmed account — `:confirm_new_user`, `:reset_password_with_token` (the
  reset link proves the address too) and `:accept_invitation_with_password` —
  and a list of actions is a list to forget one from.

  Updates only. Every create that confirms (`:register_with_sso`,
  `:register_with_site_sso`, `:register_with_invitation`, `:bootstrap_admin`)
  makes an account that has no pending registration yet: only
  `:register_with_password` queues one, and it leaves the account
  unconfirmed. A later path that queues a confirmed account (a site's own
  single sign-on) calls `KilnCMS.Notifications.Registrations.announce_org/1`
  itself, after its commit.

  The hook is attached only when the row was unconfirmed, and fires only when
  the result is confirmed. The result is the place to look: AshAuthentication
  sets `confirmed_at` in a `before_action`, after this change has run.

  The announcement goes through `KilnCMS.AfterCommit.run/1` from an
  `after_transaction` hook, on success only: it writes notification rows and
  queues mail, and none of that may roll back, or fail, the confirmation that
  caused it. `KilnCMS.Notifications.Registrations.announce/1` never raises.

  `atomic/3` leaves the changeset alone: no update that runs atomically sets
  `confirmed_at`, and without it every atomic `User` update would be refused.
  """
  use Ash.Resource.Change

  alias KilnCMS.AfterCommit
  alias KilnCMS.Notifications.Registrations

  @impl true
  def change(%{data: %{confirmed_at: nil}} = changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, %{confirmed_at: %DateTime{}} = user} = result ->
        AfterCommit.run(fn -> Registrations.announce(user) end)
        result

      _changeset, result ->
        result
    end)
  end

  def change(changeset, _opts, _context), do: changeset

  @impl true
  def atomic(changeset, _opts, _context), do: {:ok, changeset}
end
