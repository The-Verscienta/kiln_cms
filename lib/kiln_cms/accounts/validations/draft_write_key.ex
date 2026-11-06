defmodule KilnCMS.Accounts.Validations.DraftWriteKey do
  @moduledoc """
  The mint-time rules for a `:draft_write` API key (#2273). Inert for every
  other `access` value.

    * **A capped lifetime.** The key expires within
      `config :kiln_cms, :draft_write_key_max_ttl_days` days (default 30). The scope exists for a service that holds the credential
      unattended, so an immortal-in-practice key is the thing to refuse; "short
      lived" is a ceiling an operator sets, not a hope.

    * **A service-grade owner.** The owning user must not be able to edit or
      publish: no standing or live temporary `:editor`/`:admin` tier, on the
      platform or in any organization membership. A key authenticates AS its
      owner, so an editor-capable owner would make the scope a request to be
      careful.

  The owner rule is **defense in depth**. The control is the forbid in the
  `Content` policy, which sits above the admin bypass and does not look at the
  owner's role, so promoting the owner after the key was minted widens nothing.
  What this prevents is a configuration that reads as safe in the key list and
  is only held in place by that one policy.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts.RoleGrant

  @default_max_ttl_days 30
  @capable [:editor, :admin]

  @doc "The configured ceiling, in days, on a `:draft_write` key's lifetime."
  @spec max_ttl_days() :: pos_integer()
  def max_ttl_days,
    do: Application.get_env(:kiln_cms, :draft_write_key_max_ttl_days, @default_max_ttl_days)

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :access) == :draft_write do
      with :ok <- check_ttl(changeset) do
        check_owner(changeset)
      end
    else
      :ok
    end
  end

  defp check_ttl(changeset) do
    case Ash.Changeset.get_attribute(changeset, :expires_at) do
      %DateTime{} = expires_at ->
        limit = DateTime.add(DateTime.utc_now(), max_ttl_days(), :day)

        if DateTime.compare(expires_at, limit) == :gt do
          {:error,
           field: :expires_at,
           message: "a draft-write key may live at most #{max_ttl_days()} days"}
        else
          :ok
        end

      _ ->
        # `allow_nil?: false` reports the missing expiry.
        :ok
    end
  end

  defp check_owner(changeset) do
    case Ash.Changeset.get_attribute(changeset, :user_id) do
      nil ->
        :ok

      user_id ->
        if editor_capable?(user_id) do
          {:error,
           field: :user_id,
           message:
             "a draft-write key needs an owner who cannot edit or publish: use a viewer-tier service account"}
        else
          :ok
        end
    end
  end

  defp editor_capable?(user_id) do
    # authorize?: false — the owner is read only to judge their tier and is never
    # returned; mint is admin-only, and User's read policy is self-only, so the
    # minting admin could not read the owner under their own actor.
    case KilnCMS.Accounts.get_user(user_id, authorize?: false, load: [:org_memberships]) do
      {:ok, user} ->
        RoleGrant.effective_role(user) in @capable or
          Enum.any?(user.org_memberships, &(RoleGrant.effective_role(&1) in @capable))

      # No such user: the foreign key reports it; refuse here too rather than guess.
      _ ->
        true
    end
  end
end
