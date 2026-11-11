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
    * Relationship arguments (`tag_ids`, its `add_`/`remove_` merge verbs, and
      related links) are curation, not attributes — ungoverned here
      (documented in docs/granular-rbac.md).
    * Creates are ungoverned: authoring a *new* document is gated by
      `editable_types`; field grants refine stewardship of existing content.
      (The exception is `Changes.EnforceCustomFieldGrants`: a grant holding
      any `custom_fields.*` entry also holds the editor to those keys on a
      create, and a hidden private field cannot be written on one.)
    * `custom_fields` is judged here only for the all-or-nothing grant. Once
      the grant lists a `custom_fields.*` entry, `EnforceCustomFieldGrants`
      judges the keys the editor actually changed instead (#2281).
    * Admins (and system/actor-less writes) are exempt, mirroring the policy
      bypass.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.FieldAccess
  alias KilnCMS.CMS.WorkingCopy

  @impl true
  def change(changeset, _opts, %{actor: %{} = actor}) do
    # Per-org tiers (#419): grants bind whoever is an EFFECTIVE editor here;
    # effective admins are exempt (mirroring the policy bypass).
    if Scoping.effective_tier(actor, changeset) == :editor do
      # The RECORD's type, not its module: every dynamic type shares `Entry`,
      # so asking the module returns "entry" for all of them and a per-type
      # grant reads as no grant at all (#927).
      type = KilnCMS.CMS.ContentTypes.type_name_for(changeset)

      case Scoping.field_grant(actor, changeset, type) do
        nil -> changeset
        allowed -> enforce(changeset, allowed)
      end
    else
      changeset
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
    |> Enum.reduce(changeset, &add_violation(&2, &1))
    |> maybe_block_tree_violation(allowed)
  end

  # Per-custom-field entries (`custom_fields.<name>`, #2281) move the judgement
  # of `custom_fields` to `Changes.EnforceCustomFieldGrants`, which compares the
  # keys the editor supplied. Without any, the bare `custom_fields` key is the
  # all-or-nothing grant it always was.
  defp violation?(changeset, attr, allowed) do
    supplied?(changeset.params, attr) and
      changing?(changeset, attr) and
      grant_name(attr) not in allowed and
      not (attr == :custom_fields and FieldAccess.per_key?(allowed))
  end

  # The editing verbs an editor reaches from the editor UI: `:autosave` inherits
  # `:update`'s accept list, and every other update action that accepts content
  # attributes is a system write (published-version bookkeeping, re-indexing,
  # author reassignment) an editor-facing grant has no business listing.
  @grantable_actions [:update, :move, :save_working_copy]

  @doc """
  The field names a `field_grants` entry for a content type can usefully list,
  for the team UI's picker (#2141). Takes a `KilnCMS.CMS.ContentTypes`
  descriptor; a dynamic type reads the shared `KilnCMS.CMS.Entry` actions.

  Built from the same `accept` lists and the same `grant_name/1` mapping the
  check above compares against, so a name offered here is one enforcement
  recognizes: `working_title`/`working_blocks` collapse into `title`/`blocks`,
  and `custom_fields` is a single name. Per-custom-field entries
  (`custom_fields.<name>`, `custom_fields.<group>.<sub>`, #2281) are written
  against the type's `FieldDefinition`s and judged by
  `Changes.EnforceCustomFieldGrants`; the team UI's picker offers them from the
  definitions, not from this list.
  `type_definition_id` is left out (a dynamic entry never changes type through
  the editor), and so is `excerpt` for a dynamic type without one. Ordered
  title, blocks, then the rest in accept order.
  """
  @spec grantable_fields(KilnCMS.CMS.ContentTypes.t()) :: [String.t()]
  def grantable_fields(%{} = descriptor) do
    resource = descriptor.resource || KilnCMS.CMS.Entry

    names =
      @grantable_actions
      |> Enum.map(&Ash.Resource.Info.action(resource, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(& &1.accept)
      |> Enum.map(&grant_name/1)
      |> Enum.uniq()
      |> Enum.reject(&ungrantable?(&1, descriptor))

    Enum.filter(["title", "blocks"], &(&1 in names)) ++ (names -- ["title", "blocks"])
  end

  defp ungrantable?("type_definition_id", _descriptor), do: true
  defp ungrantable?("excerpt", %{source: :dynamic, excerpt?: excerpt?}), do: not excerpt?
  defp ungrantable?(_name, _descriptor), do: false

  # The working copy of a live document (docs/working-copy.md) is the title and
  # body under another column name: an editor granted `title` and `blocks` may
  # write them, and one who is not may not smuggle either through the copy.
  defp grant_name(:working_title), do: "title"
  defp grant_name(:working_blocks), do: "blocks"
  defp grant_name(attr), do: to_string(attr)

  # "Changed" for the working copy means changed against the text it runs ahead
  # of (`KilnCMS.CMS.WorkingCopy.basis/1`), not against the bare column: the
  # editor posts the whole text on every save, so the first working-copy save
  # after a publish carries the live body verbatim, and reading that as a
  # write of `blocks` would refuse a title-only editor their first keystroke.
  defp changing?(changeset, :working_title),
    do: Ash.Changeset.get_attribute(changeset, :working_title) != basis(changeset).title

  defp changing?(changeset, :working_blocks) do
    not WorkingCopy.same_blocks?(
      changeset.resource,
      Ash.Changeset.get_attribute(changeset, :working_blocks),
      basis(changeset).blocks
    )
  end

  defp changing?(changeset, attr), do: Ash.Changeset.changing_attribute?(changeset, attr)

  defp basis(changeset), do: WorkingCopy.basis(changeset.data)

  # `block_tree` and `body_markdown` are arguments, not accepted attributes —
  # either force-changes `blocks` downstream (ApplyBlocksInput), so both are
  # gated on the "blocks" grant. Markdown is the same write in another syntax;
  # ungated it would be the way around the grant.
  defp maybe_block_tree_violation(changeset, allowed) do
    body_arg? =
      Ash.Changeset.get_argument(changeset, :block_tree) != nil or
        Ash.Changeset.get_argument(changeset, :body_markdown) != nil

    if body_arg? and "blocks" not in allowed do
      add_violation(changeset, :blocks)
    else
      changeset
    end
  end

  # The error carries the attribute as an ATOM: a form field's `.errors` only
  # matches atom keys, so a string field name was shown nowhere in the editor.
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
