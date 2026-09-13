defmodule KilnCMS.Accounts.Validations.TemporaryRoleGrant do
  @moduledoc """
  A time-boxed tier grant must be complete, in the future, and an elevation.

  Applied to every action that writes `granted_role` / `granted_role_expires_at`
  on `KilnCMS.Accounts.User` and `KilnCMS.Accounts.OrgMembership`. Each rule
  closes a way for a grant to read as something it isn't:

    * **both columns or neither.** A `granted_role` with no expiry is a
      permanent elevation wearing a temporary label — and
      `KilnCMS.Accounts.RoleGrant` deliberately reads it as *no grant at all*
      (fail-closed), so the row would authorize as its standing tier while the
      console showed an elevated one. An expiry with no role is a countdown to
      nothing.

    * **the expiry must be in the future.** A past one is an already-expired
      grant: accepted silently, it would show up in the console as a grant that
      grants nothing, and the sweep would clear it on its next pass. Refusing it
      makes the mistake (a fat-fingered date, a stale form) visible at the
      moment it is made.

    * **it must outrank the standing tier.** See `KilnCMS.Accounts.RoleGrant` —
      a temporary *demotion* must be written to `role`, where it holds until
      someone decides to undo it, rather than expiring quietly back into access
      nobody re-approved.

  Clearing a grant (both fields to `nil`) always passes: that is how the sweep
  and the console's "End now" both revoke one.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts.RoleGrant

  @impl true
  def validate(changeset, _opts, _context) do
    role = Ash.Changeset.get_attribute(changeset, :granted_role)
    expires_at = Ash.Changeset.get_attribute(changeset, :granted_role_expires_at)

    cond do
      is_nil(role) and is_nil(expires_at) -> :ok
      is_nil(role) -> {:error, field: :granted_role, message: "is required for a temporary role"}
      is_nil(expires_at) -> {:error, field: :granted_role_expires_at, message: "is required"}
      not DateTime.after?(expires_at, DateTime.utc_now()) -> expired()
      true -> check_elevation(changeset, role)
    end
  end

  defp expired,
    do: {:error, field: :granted_role_expires_at, message: "must be in the future"}

  # `RoleGrant.standing_role/1` rather than `get_attribute(:role)`, for two
  # reasons: a single submit that sets `role` and the grant together is judged
  # against the tier it is *about to* have, and a changeset built on a folded
  # record (where `role` already shows the live grant) is judged against the tier
  # the row actually stores — otherwise extending a live "admin until Friday"
  # would be refused for not being an elevation over itself.
  defp check_elevation(changeset, role) do
    standing = RoleGrant.standing_role(changeset)

    if RoleGrant.elevation?(role, standing) do
      :ok
    else
      {:error,
       field: :granted_role,
       message: "must be higher than the standing role (#{standing}) to be worth granting"}
    end
  end
end
