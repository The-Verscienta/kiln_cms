defmodule KilnCMS.CMS.Validations.EditableReleaseContent do
  @moduledoc """
  Applies the granular-RBAC content-type scope (#332) to a release item's
  `content_type` (#500).

  `KilnCMS.CMS.Checks.EditableContentType` can't do this job: it is a policy
  check that reads the type off the *resource being written*, and the resource
  here is `ReleaseItem`, not the page. So the scope has to be evaluated against
  the `content_type` attribute instead — which is what this validation is.

  Without it, "add to release" is a hole straight through the type scope, and a
  wide one: the release preview link renders every pending item's full
  unpublished body to anyone holding the token, with no account at all. A
  `readable_types: ["post"]` editor who obtained a page id from one of the
  unscoped `{content_type, content_id}` surfaces (tasks, comments) could put it
  in a release and read the page. Gating the *add* is the containment: a release
  can only ever expose what the editor who filled it was already allowed to see.

  Dynamic types (D17) collapse to the `entry` storage key, exactly as the policy
  check does — `["entry"]` scopes an editor to all admin-defined types as a
  group.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.ContentTypes

  @impl true
  def validate(changeset, _opts, context) do
    content_type =
      Ash.Changeset.get_attribute(changeset, :content_type) ||
        Map.get(changeset.data, :content_type)

    if permitted?(context.actor, changeset, content_type), do: :ok, else: refuse(content_type)
  end

  # No actor is a system caller (the worker, seeds): the authorization decision
  # was made elsewhere, exactly as everywhere else in this feature.
  defp permitted?(nil, _changeset, _content_type), do: true
  defp permitted?(_actor, _changeset, nil), do: true

  defp permitted?(actor, changeset, content_type) do
    case Scoping.effective_tier(actor, changeset) do
      :admin ->
        true

      :editor ->
        Scoping.permitted?(actor, changeset, :editable_types, scope_key(changeset, content_type))

      _ ->
        false
    end
  end

  # The scope names storage keys, so a dynamic type resolves through the
  # registry. An unresolvable name falls back to itself rather than to nil,
  # which would compare against every scope entry as "no type" and pass.
  defp scope_key(changeset, content_type) do
    case ContentTypes.storage_type(content_type, org_id(changeset)) do
      nil -> content_type
      storage -> to_string(storage)
    end
  end

  defp org_id(changeset) do
    case changeset.tenant do
      %{id: id} -> id
      id when is_binary(id) -> id
      _ -> KilnCMS.Accounts.default_org_id()
    end
  end

  defp refuse(content_type) do
    {:error,
     InvalidAttribute.exception(
       field: :content_type,
       message: "is outside your content-type scope",
       value: content_type
     )}
  end
end
