defmodule KilnCMS.Accounts.Validations.NotLastAdmin do
  @moduledoc """
  Refuses the write that would leave the instance with no platform admin.

  Declared on `KilnCMS.Accounts.User`'s `:manage_access` (which is how a role is
  changed) and `:anonymize` (which resets the role to `:viewer` as part of
  erasure). Both are admin-only actions, so the only caller who can trip this is
  an admin removing the last admin — usually themselves, from the accounts
  console, one click from locking every operator out of `/editor`.

  There is no recovery path for that. `/setup` is gated on
  `KilnCMS.Accounts.Checks.NoAdminExists`, but an account with `role: :viewer`
  still *exists*, so the first-run wizard does not come back; the fix is a
  release console. That asymmetry — trivially reachable, not repairable from the
  UI — is what earns a guard rather than a confirmation dialog.

  A validation, not a policy check, for the reason
  `KilnCMS.Accounts.Validations.NotDemoSharedAccount` gives: admins bypass
  `User`'s policies wholesale, so a `forbid_if` here would never fire, and the
  refusal needs to carry a sentence rather than a bare `Forbidden`.

  ## System calls pass

  Keyed on the actor, like `NotDemoSharedAccount`: a call with **no actor** is a
  system call and is let through. `KilnCMS.Staging.Scrub` erases *every* account on
  a clone of production — the last admin very much included, since the whole point
  is that a staging environment holds no real operator's credentials, and it
  provisions a fresh admin afterwards. Refusing that would break the scrub, and
  for nothing: this guard exists to catch an operator's slip in the console, not
  to stop the application from doing something it was written to do on purpose.

  ## Counted, not reserved

  The count is a plain read, so two admins demoting each other at the same
  instant can both pass it. The narrower race is not worth an advisory lock
  here: unlike the bootstrap it guards against (where the prize is *creating* an
  admin nobody authorized), the failure mode is a lockout an operator can undo
  from a release console, and the realistic mistake — one admin tidying up the
  account list — is caught.

  Only a *demotion* is checked on `:manage_access`: granting a temporary role,
  changing audiences or narrowing type scopes leave the count alone, and that one
  action carries all of them. `:anonymize` passes `demotes?: true` instead of
  being inspected, because the role it writes comes from
  `KilnCMS.Accounts.Changes.AnonymizeUser` — whether this validation sees `:admin`
  or the already-forced `:viewer` depends on which of the two is declared first,
  and an erasure is a demotion either way.
  """
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, opts, context) do
    demotion? = Keyword.get(opts, :demotes?, false) or demoting_an_admin?(changeset)

    # `not is_nil/1`, not `&&`: `and` raises on a non-boolean left side, and a
    # system call's actor is `nil`.
    if not is_nil(context.actor) and demotion? and standing_admin?(changeset) and
         last_admin?(changeset.data.id) do
      {:error,
       field: :role,
       message: "would leave this instance with no admin. Promote someone else to admin first."}
    else
      :ok
    end
  end

  # The record was read through `KilnCMS.Accounts.Preparations.FoldRoleGrant`, so
  # `changeset.data.role` may be an *effective* tier — and an admin who is only
  # temporarily an admin is not one this guard should count on keeping.
  # `RoleGrant.standing_role/1` unfolds it back to the tier the row actually
  # stores, which is what `last_admin?/1`'s count sees.
  defp standing_admin?(changeset),
    do: KilnCMS.Accounts.RoleGrant.standing_role(changeset.data) == :admin

  defp demoting_an_admin?(changeset),
    do: Ash.Changeset.get_attribute(changeset, :role) != :admin

  # Any *other* standing admin is enough. `granted_role` is deliberately not
  # counted: a grant expires, and an instance whose only admin is an expiring one
  # is the lockout this exists to prevent, just deferred.
  defp last_admin?(id) do
    KilnCMS.Accounts.User
    |> Ash.Query.filter(role == :admin and id != ^id)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.empty?()
  end
end
