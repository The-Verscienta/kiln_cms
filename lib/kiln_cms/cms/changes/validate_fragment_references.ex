defmodule KilnCMS.CMS.Changes.ValidateFragmentReferences do
  @moduledoc """
  A `KilnCMS.Blocks.Fragment`'s `ref` is validated at write time (#479's own
  ask, tracked as #911): the target must exist and be readable by the
  **acting** actor, checked under their own authorization rather than
  `authorize?: false`.

  Two gaps this closes:

    1. **A dangling reference saved cleanly.** `ref`'s target existence was
       never checked at write time — a reference to a deleted or
       never-existing document was accepted and only failed closed at read
       time (`KilnCMS.CMS.Fragments.expand/3` inlines nothing). The editor
       got no indication; the page just had a hole.
    2. **The picker is actor-scoped; the write was not.** The editor's
       fragment `<select>` only offers documents the actor may read
       (`load_fragment_options/1` passes `actor:`/`tenant:`), but the select
       is client-side — the stored value is whatever the form posts, and
       `normalize_fragment_ref/1` turns any `"type:id"` string into a
       reference with no check at all.

  Delivery fails closed either way (a fragment always expands only a
  **published** target, gated to the reader's audience, `authorize?: false`
  with the filter AS the boundary) — so this is defence in depth plus
  authoring feedback, not an open leak. Resolving the target under the
  actor's own read policy naturally covers `readable_types` too: an editor
  scoped away from a type cannot reference one of its DRAFTS (though a
  *published* one is legitimately visible either way — `readable_types` never
  narrows published visibility, by design).

  Runs in a `before_action` hook, over the CAST `blocks` tree, so it sees
  every `Fragment` — including ones nested inside `columns` — the same
  reach `Changes.EnforceBlockFieldPolicy` uses. Admins and actor-less
  (system/internal) writes are exempt, mirroring that change and the policy
  bypass: a nil actor has nothing to scope a read by, and trusting internal
  callers is the existing convention.
  """
  use Ash.Resource.Change

  alias KilnCMS.Blocks.Columns
  alias KilnCMS.Blocks.Fragment
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs

  @impl true
  def change(changeset, _opts, %{actor: %{} = actor}) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if Ash.Changeset.changing_attribute?(changeset, :blocks) do
        validate(changeset, actor)
      else
        changeset
      end
    end)
  end

  def change(changeset, _opts, _context), do: changeset

  defp validate(changeset, actor) do
    tenant = changeset.tenant || Ash.Changeset.get_attribute(changeset, :org_id)

    changeset
    |> Ash.Changeset.get_attribute(:blocks)
    |> List.wrap()
    |> Enum.flat_map(&fragment_refs/1)
    |> Enum.reduce(changeset, &check_ref(&2, &1, actor, tenant))
  end

  # Every `Fragment`'s `ref`, at any depth `columns` nests — mirroring
  # `KilnCMS.Blocks.Columns.child_blocks_flat/1`'s own reach rather than
  # guessing where children live (the same reasoning
  # `EnforceBlockFieldPolicy` documents for #956).
  defp fragment_refs(%Ash.Union{value: value}), do: fragment_refs(value)
  defp fragment_refs(%Fragment{ref: ref}), do: [ref]

  defp fragment_refs(%Columns{} = block),
    do: block |> Columns.child_blocks_flat() |> Enum.flat_map(&fragment_refs/1)

  defp fragment_refs(_other), do: []

  defp check_ref(changeset, ref, actor, tenant) do
    case reference(ref) do
      nil -> changeset
      {type, id} -> resolve(changeset, type, id, actor, tenant)
    end
  end

  defp resolve(changeset, type, id, actor, tenant) do
    if target_visible?(type, id, actor, tenant) do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :blocks,
        message:
          "a fragment block references #{type}:#{id}, which does not exist or is not " <>
            "readable — pick a target from the fragment list, or check it was not deleted"
      )
    end
  end

  defp target_visible?(type, id, actor, tenant) do
    with %{} = descriptor <- ContentTypes.get(type, tenant),
         resource <- Slugs.storage_resource(descriptor) do
      resource
      |> Ash.Query.filter(id == ^id)
      |> scope_dynamic(descriptor)
      |> Ash.read_one(actor: actor, tenant: tenant, authorize?: true)
      |> case do
        {:ok, %{}} -> true
        _ -> false
      end
    else
      _ -> false
    end
  rescue
    # A malformed id (an importer's junk, a hand-crafted API payload) is a
    # miss, not a 500 on a content write — `Fragments.read_target_live/4`
    # takes the same posture for the same reason.
    _ -> false
  end

  # Entries share one table (D17): a bare id read could otherwise cross
  # dynamic types, resolving a "recipe:<id>" reference to an "event" that
  # happens to share the id. Same guard `Fragments.scope_dynamic/2` applies
  # on the read side.
  defp scope_dynamic(query, %{source: :dynamic, definition: definition}),
    do: Ash.Query.filter(query, type_definition_id == ^definition.id)

  defp scope_dynamic(query, _compiled), do: query

  # The stored reference shape, `%{"type" => …, "id" => …}`. Atom keys
  # accepted because a block built in code (a test, a seed) writes them —
  # same tolerance `Fragments.reference/1` has, for the same reason.
  defp reference(%{"type" => type, "id" => id})
       when (is_binary(type) or is_atom(type)) and is_binary(id),
       do: {to_string(type), id}

  defp reference(%{type: type, id: id})
       when (is_binary(type) or is_atom(type)) and is_binary(id),
       do: {to_string(type), id}

  defp reference(_other), do: nil
end
