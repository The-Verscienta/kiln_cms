defmodule KilnCMS.Accounts.Changes.GuardLastAdmin do
  @moduledoc """
  `KilnCMS.Accounts.Validations.NotLastAdmin`'s question, asked again where the
  answer can be relied on: inside the write's transaction, under the same
  advisory lock the first-run bootstrap takes.

  The validation counts the other admins with a plain read when the changeset
  is built. Two admins demoting (or erasing) each other at the same moment both
  see the other and both commit, leaving no `role: :admin` row — and an
  instance with none re-opens the anonymous `/setup` wizard
  (`KilnCMS.Accounts.Checks.NoAdminExists`). Here the lock serializes the two
  writes; the second waits for the first to commit, counts again, and is
  refused.

  Takes the validation's options (`demotes?: true` on `:anonymize`), and its
  exemption (`NotLastAdmin.exempt/0`, the staging scrub).
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.Bootstrap
  alias KilnCMS.Accounts.Validations.NotLastAdmin

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, &guard(&1, opts))
  end

  # Only a write that could orphan the instance pays for the lock.
  defp guard(changeset, opts) do
    if NotLastAdmin.orphans?(changeset, opts) or demotes_an_admin?(changeset, opts),
      do: recount(changeset, opts),
      else: changeset
  end

  defp recount(changeset, opts) do
    Bootstrap.lock!()

    if NotLastAdmin.orphans?(changeset, opts),
      do: Ash.Changeset.add_error(changeset, NotLastAdmin.error()),
      else: changeset
  end

  # The build-time count may have seen another admin who is being demoted in a
  # transaction that has not committed yet. Any demotion of a standing admin
  # therefore takes the lock and counts again.
  defp demotes_an_admin?(changeset, opts) do
    changeset.data.role == :admin and
      (Keyword.get(opts, :demotes?, false) or
         Ash.Changeset.get_attribute(changeset, :role) != :admin)
  end
end
