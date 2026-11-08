defmodule KilnCMS.CMS.Changes.ReplaceExpiredIpBlock do
  @moduledoc """
  Lets a range be blocked again once its earlier rule has lapsed (#2242).

  `IpBlockRule` is unique on `[:org_id, :cidr]` and expired rows are not swept,
  so without this an expired rule would keep its slot and the operator would see
  "is already blocked" for a range that blocks nothing. In a `before_action`
  (inside the create's transaction, after `NormalizeIpBlockCidr` has settled the
  spelling) this destroys the same-tenant, same-`cidr` rows whose `expires_at`
  has passed; an *active* duplicate is untouched and the identity still refuses
  it.

  The destroy skips authorization on purpose: the create it rides on has already
  been authorised as an org admin, the rows removed enforce nothing, and the
  query is scoped to the changeset's tenant. It goes through the resource's own
  `:destroy`, so the cache bust still runs.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      cidr = Ash.Changeset.get_attribute(changeset, :cidr)

      if is_binary(cidr) do
        now = DateTime.utc_now()

        # authorize?: false — the create is already authorised as org admin and the rows enforce nothing
        KilnCMS.CMS.IpBlockRule
        |> Ash.Query.filter(cidr == ^cidr and not is_nil(expires_at) and expires_at <= ^now)
        |> Ash.bulk_destroy!(:destroy, %{},
          tenant: changeset.tenant,
          authorize?: false,
          context: %{warn_on_transaction_hooks?: false},
          strategy: [:stream],
          return_errors?: true
        )
      end

      changeset
    end)
  end
end
