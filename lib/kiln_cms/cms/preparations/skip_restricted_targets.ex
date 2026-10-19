defmodule KilnCMS.CMS.Preparations.SkipRestrictedTargets do
  @moduledoc """
  Leaves out of a read the records that a `:reference` field set to keep
  linked records from being deleted (`on_target_delete: :restrict`, R5 in
  `docs/relationships-plan.md`) still links to.

  The content resources' `:purgeable` read uses it, so the nightly purge of
  old trash (`purge_trashed`) never schedules a purge that
  `Changes.ApplyTargetDeleteRules` would only refuse — once per record, every
  night, as a failed job. Such a record stays in the trash until it is
  unlinked, and the next night's run picks it up. The refusal itself stays
  where it was: this only keeps the scheduler from asking.

  Two reads, as the cms bookkeeping with `authorize_with: :error`: the site's
  `:restrict` reference fields, then the targets of their edges. A site with
  no such field pays the first one only. Plus one read per graduated join
  resource whose target foreign key restricts, if a project has any.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Bookkeeping
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.JoinGraduation

  @impl true
  def prepare(query, _opts, _context) do
    org_id = query.tenant || KilnCMS.Accounts.default_org_id()

    case restricted_target_ids(org_id) do
      [] -> query
      ids -> Ash.Query.filter(query, id not in ^ids)
    end
  end

  @doc """
  The ids of every record a `:restrict` reference field of `org_id` links to,
  whatever their type — through `content_links`, or through a graduated
  field's join table (`KilnCMS.CMS.JoinGraduation.restricted_target_ids/1`).
  """
  @spec restricted_target_ids(Ash.UUID.t()) :: [Ash.UUID.t()]
  def restricted_target_ids(org_id) do
    Enum.uniq(field_target_ids(org_id) ++ JoinGraduation.restricted_target_ids(org_id))
  end

  defp field_target_ids(org_id) do
    case restrict_fields(org_id) do
      [] ->
        []

      fields ->
        [
          actor: Bookkeeping.system(),
          authorize_with: :error,
          tenant: org_id,
          query: [
            filter: [kind: :reference, or: fields],
            select: [:id, :target_id]
          ]
        ]
        |> CMS.list_content_links!()
        |> Enum.map(& &1.target_id)
        |> Enum.uniq()
    end
  end

  # `[source_type: type, field: name]` per `:restrict` reference field: the
  # pair an edge carries. A field of a type that no longer exists has no
  # edges to protect.
  defp restrict_fields(org_id) do
    [
      actor: Bookkeeping.system(),
      authorize_with: :error,
      tenant: org_id,
      query: [filter: [field_type: :reference, on_target_delete: :restrict]]
    ]
    |> CMS.list_field_definitions!()
    |> Enum.flat_map(fn definition ->
      case source_type(definition, org_id) do
        nil -> []
        type -> [[source_type: type, field: definition.name]]
      end
    end)
  end

  defp source_type(%{type_definition_id: id}, org_id) when is_binary(id) do
    org_id
    |> ContentTypes.dynamic_all()
    |> Enum.find_value(&(&1.definition.id == id && &1.type))
  end

  defp source_type(%{content_type: type}, _org_id) when is_atom(type) and not is_nil(type),
    do: if(ContentTypes.type?(type), do: Atom.to_string(type))

  defp source_type(_definition, _org_id), do: nil
end
