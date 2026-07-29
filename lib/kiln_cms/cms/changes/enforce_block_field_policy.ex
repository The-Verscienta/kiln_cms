defmodule KilnCMS.CMS.Changes.EnforceBlockFieldPolicy do
  @moduledoc """
  Server-side enforcement of `Kiln.Block` field policies (#51).

  A block field may declare `editable_by: [roles]` (`Kiln.Block.Policy`) — e.g.
  an editor may write a `Quote`'s text but only an admin may toggle `featured`.
  Until this change existed the rule was enforced *only* by the content editor
  filtering the field list it renders (`Kiln.Block.Policy.can_edit_field?/3` in
  `ContentEditorLive`). `authorize_changes/3` was documented as the persistence
  gate but had no caller, so any path that does not go through that form — the
  write API's `block_tree` argument, MCP tools, GraphQL mutations, a crafted
  LiveView event — could set an admin-only field as an editor.

  Applied once in the shared Content macro's `changes` block on create and
  update, so every write path is covered at the resource boundary rather than
  per-caller. Admins and system/actor-less writes are exempt, mirroring the
  policy bypass.

  ## What counts as a violation

  The check runs in a `before_action` hook, after `ApplyBlocksInput` has cast
  the `block_tree` argument into the `blocks` union, so it always sees the
  final typed tree regardless of change ordering.

    * **Existing block** (its id is present in the stored tree) — a restricted
      field violates when its value differs from the stored one. Resubmitting
      an unchanged value is not a violation, matching the semantics
      `EnforceFieldGrants` documents: the editor form posts every field on save.
    * **New block** (id absent from the stored tree) — a restricted field
      violates when it differs from the field's declared default. An editor may
      add a quote; they may not add one that arrives pre-`featured`.

  Block ids round-trip: the editor resubmits each block with its id, so an
  in-place edit diffs against the stored block. A headless client that omits
  ids gets fresh ids, so every block is judged as new — correctly, since the
  `blocks` attribute is not `public?` and such a client cannot have read the
  current values it would be claiming to preserve.

  ## Known limits

  `columns` nests its children as raw maps (`{:array, :map}`) rather than union
  members, to avoid a recursive-type compile cycle. Nested children therefore
  carry no stable identity to diff against, so they are held to the stricter
  new-block rule: a restricted field on a nested block must equal its default.
  This closes the "nest it in a column to bypass the check" hole at the cost of
  refusing an edit to a column that already contains an admin-set value.

  A restricted field can still be *cleared* by a headless client that drops the
  block's id and omits the field, since the default then legitimately applies.
  Recorded as residual risk in `docs/threat-model.md`.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.Scoping

  @impl true
  def change(changeset, _opts, %{actor: %{} = actor}) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      # Per-org tiers (#419): effective admins are exempt, like the policy
      # bypass. `Kiln.Block.Policy` takes the same role atom.
      case Scoping.effective_tier(actor, changeset) do
        :admin -> changeset
        role -> enforce(changeset, role)
      end
    end)
  end

  def change(changeset, _opts, _context), do: changeset

  defp enforce(changeset, role) do
    if Ash.Changeset.changing_attribute?(changeset, :blocks) do
      stored = index_by_id(changeset.data)

      changeset
      |> Ash.Changeset.get_attribute(:blocks)
      |> List.wrap()
      |> Enum.reduce(changeset, &check_block(&2, &1, stored, role))
    else
      changeset
    end
  end

  # Stored blocks keyed by id, so an in-place edit diffs against its own
  # previous value. `data` is `%Ash.Changeset{}.data` — a struct on update, and
  # a bare struct with no blocks on create.
  defp index_by_id(%{blocks: blocks}) when is_list(blocks) do
    Map.new(blocks, fn
      %Ash.Union{value: %{id: id} = value} -> {id, value}
      other -> {nil, other}
    end)
  end

  defp index_by_id(_data), do: %{}

  defp check_block(changeset, %Ash.Union{value: %module{} = block}, stored, role) do
    previous = Map.get(stored, Map.get(block, :id))

    module
    |> restricted_fields(role)
    |> Enum.reduce(changeset, fn field, acc ->
      new_value = Map.get(block, field.name)

      if new_value == permitted_value(field, previous) do
        acc
      else
        add_violation(acc, module, field.name)
      end
    end)
    |> check_nested(block, module, role)
  end

  defp check_block(changeset, _other, _stored, _role), do: changeset

  # An existing block may keep whatever it already had; a new one must carry the
  # field's declared default.
  defp permitted_value(field, nil), do: field.default
  defp permitted_value(field, previous), do: Map.get(previous, field.name)

  # `columns` (and any future nesting) holds children as raw maps tagged with
  # `_type`, so walk the block's own field values for anything that resolves to
  # a known block module. Nested children have no id to diff, so they are held
  # to the default-value rule.
  defp check_nested(changeset, block, module, role) do
    module
    |> Kiln.Block.Info.fields()
    |> Enum.reduce(changeset, fn field, acc ->
      walk_nested(acc, Map.get(block, field.name), role)
    end)
  end

  defp walk_nested(changeset, value, role) when is_list(value),
    do: Enum.reduce(value, changeset, &walk_nested(&2, &1, role))

  defp walk_nested(changeset, %Ash.Union{}, _role), do: changeset

  defp walk_nested(changeset, %{} = value, role) when not is_struct(value) do
    changeset = check_nested_map(changeset, value, role)

    Enum.reduce(Map.values(value), changeset, &walk_nested(&2, &1, role))
  end

  defp walk_nested(changeset, _value, _role), do: changeset

  defp check_nested_map(changeset, map, role) do
    with {:ok, type} <- fetch_type(map),
         {:ok, module} <- KilnCMS.Blocks.fetch(type) do
      module
      |> restricted_fields(role)
      |> Enum.reduce(changeset, &check_nested_field(&2, map, module, &1))
    else
      _ -> changeset
    end
  end

  defp check_nested_field(changeset, map, module, field) do
    case fetch_field(map, field.name) do
      {:ok, value} when not is_nil(value) ->
        if value == field.default,
          do: changeset,
          else: add_violation(changeset, module, field.name)

      _ ->
        changeset
    end
  end

  # Nested maps arrive with string keys from the API/editor and atom keys from
  # code interfaces.
  defp fetch_type(map) do
    case fetch_field(map, :_type) do
      {:ok, type} when is_binary(type) -> {:ok, String.to_existing_atom(type)}
      {:ok, type} when is_atom(type) and not is_nil(type) -> {:ok, type}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp fetch_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, to_string(key))
    end
  end

  defp restricted_fields(module, role) do
    module
    |> Kiln.Block.Info.fields()
    |> Enum.reject(&Kiln.Block.Policy.can_edit_field?(module, &1.name, role))
  end

  defp add_violation(changeset, module, field_name) do
    type = Kiln.Block.Info.name(module)

    Ash.Changeset.add_error(changeset,
      field: :blocks,
      message: "cannot change `#{field_name}` on a #{type} block: restricted to other roles"
    )
  end
end
