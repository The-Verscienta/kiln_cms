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

  ## One named exemption, not "any system call"

  `KilnCMS.Staging.Scrub` erases *every* account on a clone of production — the
  last admin very much included, since the whole point is that a staging
  environment holds no real operator's credentials, and it provisions a fresh
  admin afterwards. It opts out explicitly with
  `context: %{last_admin_guard?: false}` (see `exempt/0`).

  The exemption is keyed on that flag and **not** on a missing actor. An earlier
  version let every actorless call through, which made `KilnCMS.Beta.Round` —
  which seats testers through `:manage_access` with `authorize?: false` — able to
  demote the instance's only admin, flipping `Bootstrap.bootstrapped?/0` false and
  re-opening the anonymous first-run `:bootstrap_admin` action. A system call that
  would lock every operator out is still refused unless it says, by name, that
  locking them out is the point.

  ## Counted here, reserved in the transaction

  The count here is a plain read at build time, so two admins demoting each
  other at the same instant both pass it. That is not only a lockout: an
  instance with no `role: :admin` row answers `Bootstrap.bootstrapped?/0`
  false, which re-opens the anonymous first-run `:bootstrap_admin` action to
  the next visitor of `/setup`. So `KilnCMS.Accounts.Changes.GuardLastAdmin`,
  declared beside this validation, asks the same question again inside the
  write's transaction under the bootstrap advisory lock, where the two writes
  are serialized and the second one sees the first.

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
  def validate(changeset, opts, _context) do
    if orphans?(changeset, opts), do: {:error, error()}, else: :ok
  end

  @doc """
  Would this write leave the instance with no standing admin? The validation's
  own question, exported so `KilnCMS.Accounts.Changes.GuardLastAdmin` can ask
  it again inside the write's transaction, under the bootstrap lock.
  """
  @spec orphans?(Ash.Changeset.t(), keyword()) :: boolean()
  def orphans?(changeset, opts) do
    demotion? = Keyword.get(opts, :demotes?, false) or demoting_an_admin?(changeset)

    not exempt?(changeset) and demotion? and standing_admin?(changeset) and
      last_admin?(changeset.data.id)
  end

  @doc "The refusal, as `Ash.Changeset.add_error/2` and a validation both take it."
  @spec error() :: keyword()
  def error do
    [
      field: :role,
      message: "would leave this instance with no admin. Promote someone else to admin first."
    ]
  end

  @doc """
  The context that exempts a write from this guard — for
  `KilnCMS.Staging.Scrub`'s whole-instance erasure only. See the moduledoc.
  """
  @spec exempt() :: map()
  def exempt, do: %{last_admin_guard?: false}

  defp exempt?(%{context: %{last_admin_guard?: false}}), do: true
  defp exempt?(_changeset), do: false

  # The STANDING role — the column as stored, which is what `last_admin?/1`'s
  # count sees. An admin who is only temporarily one is not an admin this guard
  # should count on keeping.
  defp standing_admin?(changeset), do: changeset.data.role == :admin

  defp demoting_an_admin?(changeset),
    do: Ash.Changeset.get_attribute(changeset, :role) != :admin

  # Any *other* standing admin is enough. `granted_role` is deliberately not
  # counted: a grant expires, and an instance whose only admin is an expiring one
  # is the lockout this exists to prevent, just deferred.
  defp last_admin?(id) do
    # authorize?: false — the answer has to count every standing admin on the
    # instance, whatever the actor may read. A row-filtered read would hide other
    # admins and refuse a demotion that is safe. It selects ids only.
    KilnCMS.Accounts.User
    |> Ash.Query.filter(role == :admin and id != ^id)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.empty?()
  end
end
