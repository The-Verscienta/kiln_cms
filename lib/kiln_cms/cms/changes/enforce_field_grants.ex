defmodule KilnCMS.CMS.Changes.EnforceFieldGrants do
  @moduledoc """
  Per-field write scoping for editors (granular RBAC #332, slice 3).

  When the acting editor's effective `field_grants` (see
  `KilnCMS.Accounts.Scoping.field_grant/3`) names this content type, the
  editor may only *change* the listed attributes; a user-supplied change to
  any other accepted attribute rejects the write with a field-level error.
  No grant entry for the type (the default) means no restriction.

  Applied once, in the shared Content macro's `changes` block, on every
  update action — the same single-check pattern as the type-scope policies.
  Deliberate semantics:

    * Only **user-supplied, actually-changing** input counts. The editor form
      posts every field on save; resubmitting an unchanged value is not a
      violation. Workflow transitions (`submit_for_review`, `publish`, …)
      accept no content attributes, so they pass untouched — a grant scopes
      *what* an editor may edit, not *which verbs* they may run.
    * The headless `block_tree` argument (#330) is the API's way to write the
      `blocks` attribute, so supplying it requires the `"blocks"` grant.
    * `restore_version` rewrites the whole document from a snapshot via
      force-changes that param inspection cannot see — a field-granted editor
      is refused the verb outright rather than silently bypassing the grant.
    * Relationship arguments (`tag_ids`, related links) are curation, not
      attributes — ungoverned here (documented in docs/granular-rbac.md).
    * Creates are ungoverned: authoring a *new* document is gated by
      `editable_types`; field grants refine stewardship of existing content.
    * Admins (and system/actor-less writes) are exempt, mirroring the policy
      bypass.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.Scoping

  @impl true
  def change(changeset, _opts, %{actor: %{role: :editor} = actor}) do
    type = KilnCMS.CMS.ContentTypes.type_name(changeset.resource)

    case Scoping.field_grant(actor, changeset, type) do
      nil -> changeset
      allowed -> enforce(changeset, allowed)
    end
  end

  def change(changeset, _opts, _context), do: changeset

  # A version restore force-changes every restorable field — no param-level
  # grant check can scope it, so a granted editor may not run it at all.
  defp enforce(%{action: %{name: :restore_version}} = changeset, _allowed) do
    Ash.Changeset.add_error(changeset,
      field: :version_id,
      message: "restoring a version requires full field access for this content type"
    )
  end

  defp enforce(changeset, allowed) do
    changeset.action.accept
    |> Enum.filter(&violation?(changeset, &1, allowed))
    |> Enum.map(&to_string/1)
    |> Enum.reduce(changeset, &add_violation(&2, &1))
    |> maybe_block_tree_violation(allowed)
  end

  defp violation?(changeset, attr, allowed) do
    supplied?(changeset.params, attr) and
      Ash.Changeset.changing_attribute?(changeset, attr) and
      to_string(attr) not in allowed
  end

  # `block_tree` is an argument, not an accepted attribute — it force-changes
  # `blocks` downstream (ApplyBlocksInput), so gate it on the "blocks" grant.
  defp maybe_block_tree_violation(changeset, allowed) do
    if Ash.Changeset.get_argument(changeset, :block_tree) != nil and "blocks" not in allowed do
      add_violation(changeset, "blocks")
    else
      changeset
    end
  end

  defp add_violation(changeset, field) do
    Ash.Changeset.add_error(changeset,
      field: field,
      message: "cannot be changed: outside your field grant for this content type"
    )
  end

  # Params arrive with string or atom keys depending on the caller (form vs
  # code interface).
  defp supplied?(params, attr),
    do: Map.has_key?(params, attr) or Map.has_key?(params, to_string(attr))
end
