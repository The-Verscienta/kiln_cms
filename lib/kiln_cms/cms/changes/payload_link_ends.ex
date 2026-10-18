defmodule KilnCMS.CMS.Changes.PayloadLinkEnds do
  @moduledoc """
  Checks both ends of a new payload link (`ContentLink.:create_link`, R8) and
  records their content types.

  The source must be a content record of the writing site (whether the actor
  may update it is the policy's question, `Checks.SourceUpdatable`). The
  target must be one the actor may read: a link to a draft the writer cannot
  see would tell them it exists. A record may not link to itself.
  `source_type` / `target_type` are set from the records, never from input,
  so a consumer can trust them to fetch either end.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.Checks.LinkEndsReadable
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.PayloadLinks

  @impl true
  def change(changeset, _opts, context) do
    tenant = changeset.to_tenant || changeset.tenant
    source_id = Ash.Changeset.get_attribute(changeset, :source_id)
    target_id = Ash.Changeset.get_attribute(changeset, :target_id)

    with {:same, false} <- {:same, not is_nil(source_id) and source_id == target_id},
         {:source, {:ok, source}} <- {:source, PayloadLinks.locate(source_id, tenant)},
         {:target, {:ok, target}} <- {:target, readable_target(target_id, tenant, context)} do
      changeset
      |> Ash.Changeset.force_change_attribute(:source_type, ContentTypes.type_name_for(source))
      |> Ash.Changeset.force_change_attribute(:target_type, ContentTypes.type_name_for(target))
    else
      {:same, true} ->
        Ash.Changeset.add_error(changeset,
          field: :target_id,
          message: "a record can't link to itself"
        )

      {:source, :error} ->
        Ash.Changeset.add_error(changeset,
          field: :source_id,
          message: "is not a content record of this site"
        )

      {:target, :error} ->
        Ash.Changeset.add_error(changeset,
          field: :target_id,
          message: "is not a content record you can read on this site"
        )
    end
  end

  defp readable_target(nil, _tenant, _context), do: :error

  defp readable_target(target_id, tenant, context) do
    org_id = KilnCMS.Accounts.org_id(tenant)

    with {:ok, target} <- PayloadLinks.locate(target_id, tenant),
         true <-
           MapSet.member?(
             LinkEndsReadable.readable_ids(context.actor, org_id, [target_id]),
             target_id
           ) do
      {:ok, target}
    else
      _ -> :error
    end
  end
end
