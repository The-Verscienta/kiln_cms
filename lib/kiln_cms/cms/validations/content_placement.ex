defmodule KilnCMS.CMS.Validations.ContentPlacement do
  @moduledoc """
  Guards where a document may sit in the content tree (#1597, D21): under a
  parent of its own type **in its own organization**, no deeper than
  `KilnCMS.CMS.ContentTree.max_depth/0` *counting the subtree it brings with
  it*, and never inside its own subtree.

  This is `KilnCMS.CMS.Validations.MenuItemPlacement` applied to content, and it
  keeps that module's two load-bearing shapes for the same reasons.

  **It only runs when `parent_id` is actually changing.** A depth check that
  fired on every write would freeze any row that ended up too deep — an editor
  could not rename it, and could not outdent it either, because outdenting is
  itself a write. Placement is a property of a move, so it is validated on moves.
  (`Ash.Changeset.get_attribute/2` falls back to the stored value, so an
  unconditional check also re-judges data the write never mentioned — the trap
  `KilnCMS.CMS.Validations.TagGroupInTenant` documents. Skipping unchanged
  attributes also spares a `SELECT` per keystroke under
  `AshPhoenix.Form.validate`.)

  **A move carries the moving document's children.** Checking only the moved
  record's new ancestor chain would let an editor re-parent a three-level subtree
  one level down and land its leaves past the cap — accepted at write time, then
  permanently unmovable. So the check is `ancestors + 1 + subtree height`.

  ## Two things content adds that menus did not

  **Tenancy.** `parent_id` is a plain FK to the same table with no org
  component, and content is `strategy :attribute` multitenant on `org_id`, so in
  a build that is not running strict tenancy nothing else stops a write naming
  another site's document as parent (the shape of #526, one table over). The
  parent is resolved under the writer's **own** org, which makes same-org a
  property of the lookup rather than an extra check — and the org is read from
  `to_tenant`, not from the `org_id` attribute, because on `:create` that
  attribute is not stamped until the action runs. Reading it instead would
  resolve every scoped create under the default org and invert the control.

  **Readability.** Menu items are world-readable; content is not. The walk reads
  as the caller with `authorize_with: :error` (via
  `KilnCMS.CMS.Validations.Lookup`), so a refused read is a `Forbidden` rejection
  rather than a quietly short answer — a subtree read short would under-count its
  height and accept a move that nests too deep.
  """
  use Ash.Resource.Validation

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.ContentTree
  alias KilnCMS.CMS.Validations.Lookup

  @impl true
  def validate(changeset, _opts, context) do
    if Ash.Changeset.changing_attribute?(changeset, :parent_id) do
      validate_move(changeset, Lookup.as_caller(context, org_id(changeset)))
    else
      :ok
    end
  end

  defp validate_move(changeset, read_opts) do
    case Ash.Changeset.get_attribute(changeset, :parent_id) do
      nil -> :ok
      parent_id -> validate_parent(changeset, parent_id, read_opts)
    end
  rescue
    forbidden in Ash.Error.Forbidden -> {:error, forbidden}
  end

  defp validate_parent(changeset, parent_id, read_opts) do
    id = Map.get(changeset.data, :id)

    if parent_id == id do
      {:error, invalid(parent_id, "can't be the document itself")}
    else
      check_ancestry(changeset, parent_id, id, read_opts)
    end
  end

  defp check_ancestry(changeset, parent_id, id, read_opts) do
    case ancestors(changeset, read_opts, parent_id) do
      {:error, message} ->
        {:error, invalid(parent_id, message)}

      {:ok, chain} ->
        cond do
          id && id in Enum.map(chain, & &1.id) ->
            {:error, invalid(parent_id, "can't be one of this document's own children")}

          # `chain` is the new ancestors, `+ 1` is the document itself, and
          # `height` is how many further levels it drags along.
          length(chain) + 1 + height(changeset.resource, read_opts, id) >
              ContentTree.max_depth() ->
            {:error,
             invalid(
               parent_id,
               "would nest deeper than #{ContentTree.max_depth()} levels"
             )}

          true ->
            :ok
        end
    end
  end

  # The parent and everything above it, nearest first. Bounded by `max_depth`
  # plus one: a longer chain means pre-existing corruption (a cycle committed by
  # two concurrent moves), and walking it forever is what this exists to prevent.
  defp ancestors(changeset, read_opts, parent_id, acc \\ []) do
    if length(acc) > ContentTree.max_depth() do
      {:error, "is nested too deeply"}
    else
      case fetch(changeset.resource, read_opts, parent_id) do
        nil -> {:error, "is not a #{label(changeset)} in this site"}
        %{parent_id: nil} = record -> {:ok, Enum.reverse([record | acc])}
        record -> ancestors(changeset, read_opts, record.parent_id, [record | acc])
      end
    end
  end

  # Levels of descendants below `id` (0 for a leaf, and for a create — a new
  # document has no children yet). Stops once it has seen more than `max_depth`
  # levels: past that the answer is "too deep" either way, and the bound is what
  # keeps a corrupt cycle from spinning.
  defp height(resource, read_opts, id, level \\ 0)

  defp height(_resource, _read_opts, nil, level), do: level

  defp height(resource, read_opts, id, level) do
    if level > ContentTree.max_depth() do
      level
    else
      case child_ids(resource, read_opts, id) do
        [] ->
          level

        children ->
          children |> Enum.map(&height(resource, read_opts, &1, level + 1)) |> Enum.max()
      end
    end
  end

  defp fetch(resource, read_opts, id) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :parent_id])
    |> Ash.read_one!(read_opts)
  end

  defp child_ids(resource, read_opts, id) do
    resource
    |> Ash.Query.filter(parent_id == ^id)
    |> Ash.Query.select([:id])
    |> Ash.read!(read_opts)
    |> Enum.map(& &1.id)
  end

  defp invalid(value, message),
    do: InvalidAttribute.exception(field: :parent_id, message: message, value: value)

  # Names the type in the editor-facing message, resolving a dynamic entry to
  # its own type name rather than the generic "entry" the module alone yields.
  defp label(changeset), do: KilnCMS.CMS.ContentTypes.type_name_for(changeset) || "document"

  # The writer's org. `to_tenant` is populated at changeset-build time, so it is
  # what a validation can trust; the `org_id` ATTRIBUTE is not stamped from the
  # tenant until the action runs, so on `:create` it is still nil here. Mirrors
  # `KilnCMS.CMS.Validations.TagGroupInTenant`.
  defp org_id(%{to_tenant: org_id}) when is_binary(org_id), do: org_id
  defp org_id(%{to_tenant: %{id: org_id}}) when is_binary(org_id), do: org_id

  defp org_id(changeset),
    do: Ash.Changeset.get_attribute(changeset, :org_id) || KilnCMS.Accounts.default_org_id()
end
