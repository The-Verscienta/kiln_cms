defmodule KilnCMS.Accounts.Changes.LockAccount do
  @moduledoc """
  Takes the account's `users` row `FOR KEY SHARE` before the write, and
  refuses the write when the account was erased (#2514). See
  `KilnCMS.Accounts.AccountLock` for why, and for the paths that declare it.

  Options:

    * `:user_id` — the attribute that names the account (default `:user_id`;
      `:id` on `User` itself). Read from the changeset, so a create's input
      and an update's row both work;
    * `:refuse_erased?` — `false` to take the lock and leave the refusal of an
      erased account to a later change with its own error
      (`DecideRegistration` refuses approving one as `:erased`). Default
      `true`.

  In a `before_action` hook, so it runs inside the action's transaction and
  before any `before_action` declared after it: on `OrgMembership`'s
  approvals it is declared above `get_and_lock_for_update()`, which keeps the
  lock order users row first, then membership row.

  `atomic/3` attaches the same hook: an atomic update still runs its
  `before_action` hooks, in its transaction, before its one statement. That
  matters on `User`, where the change is declared resource-wide with a
  `where:` naming the three confirming actions, and Ash asks every atomic
  `User` update for the change's atomic form before the condition rules it
  out.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.AccountLock
  alias KilnCMS.Accounts.Errors.AccountErased

  @impl true
  def init(opts) do
    if is_atom(Keyword.get(opts, :user_id, :user_id)),
      do: {:ok, opts},
      else: {:error, "user_id: must be the attribute that names the account"}
  end

  @impl true
  def change(changeset, opts, _context) do
    field = Keyword.get(opts, :user_id, :user_id)
    refuse? = Keyword.get(opts, :refuse_erased?, true)

    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.get_attribute(changeset, field) do
        nil -> changeset
        user_id -> lock(changeset, user_id, field, refuse?)
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp lock(changeset, user_id, field, refuse?) do
    case AccountLock.share(user_id) do
      {:error, :erased} when refuse? ->
        Ash.Changeset.add_error(changeset, AccountErased.exception(field: field))

      # A missing account is the foreign key's, or the action's, to refuse.
      _locked_or_left_to_others ->
        changeset
    end
  end
end
