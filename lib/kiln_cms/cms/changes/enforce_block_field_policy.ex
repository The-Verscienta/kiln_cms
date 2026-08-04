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

  ## Omitted is not the same as default (#566)

  Judging an id-less block against the field's default left one way through:
  drop the ids **and** omit the restricted field, and the default applies
  legitimately — silently clearing a value an admin set. An editor could not
  *set* `featured` that way, but they could clear it.

  So a field the client did not send is no longer read as a write of the
  default. It is checked against the **raw `block_tree` argument**, where an
  omitted key is genuinely absent — the cast tree cannot answer the question,
  because the union's cast has already filled every omitted field with its
  default, which is precisely why the two were indistinguishable.

  When a **wholly id-less** tree omits a restricted field that some stored block
  of that type holds, the write is **refused**. Refused rather than guessed at:
  with no id there is no identity, and the obvious substitutes are worse than
  the gap. Pairing by position looks like identity and is not — it refuses an
  editor inserting a block above a featured one, and it hands the featured slot
  to whatever new content lands in that position. Carrying the value forward
  silently writes something the client never sent.

  *Wholly* id-less matters. A tree carrying any id shows the client can
  round-trip them, so a block without one there is genuinely new and is judged
  as before — otherwise inserting a plain block above a featured one would be
  refused for not carrying a value it has no business carrying.

  So this only ever refuses more; it never permits a write that used to fail,
  and it never writes a value nobody submitted. The cost is that an editor
  cannot rewrite the body of a page holding an admin-set field without either
  round-tripping ids or resubmitting the value — and they were never allowed to
  change it, so nothing is lost but the silence.

  ## What it still does not cover

  Reusing the **id of another block of the same type** substitutes that block's
  permitted value, so an editor can move an admin-set field off the block that
  had it. And an empty `block_tree` deletes the block outright. Both are about
  which block an id names rather than what a field may hold, and both predate
  this; closing them needs the write path to verify that a submitted id belongs
  to the block it claims. Nested `columns` children have no identity at all —
  see the note above — so the omission rule cannot reach them either. Recorded
  as residual risk in `docs/threat-model.md`.
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
      raw = raw_input(changeset)
      # Only a *wholly* id-less tree cannot say which block is which. A tree
      # carrying any id shows the client can round-trip them, so a block without
      # one there is genuinely new — and holding it to the omission rule would
      # refuse an editor simply inserting a block above a featured one.
      identified? = Enum.any?(raw, &has_id?/1)

      changeset
      |> Ash.Changeset.get_attribute(:blocks)
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.reduce(changeset, fn {block, index}, acc ->
        check_block(acc, block, stored, role, Enum.at(raw, index), identified?)
      end)
    else
      changeset
    end
  end

  # The `block_tree` argument as the client sent it, index-aligned with the cast
  # tree. Absent when the write set `blocks` directly — which the editor form
  # and the inline-editing bridge both do — and then there is nothing to have
  # omitted, so every field reads as supplied and the rules are unchanged.
  defp raw_input(changeset) do
    case Ash.Changeset.fetch_argument(changeset, :block_tree) do
      {:ok, blocks} when is_list(blocks) -> blocks
      _ -> []
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

  defp check_block(
         changeset,
         %Ash.Union{value: %module{} = block},
         stored,
         role,
         raw,
         identified?
       ) do
    previous = Map.get(stored, Map.get(block, :id))

    module
    |> restricted_fields(role)
    |> Enum.reduce(changeset, fn field, acc ->
      new_value = Map.get(block, field.name)

      cond do
        new_value != permitted_value(field, previous) ->
          add_violation(acc, module, field.name)

        # The value is permitted, but only because the cast supplied the default
        # for a field the client never sent — and somewhere in the stored tree
        # that field is set. Accepting it clears an admin's value by omission
        # (#566); there is no id to tell us whether this block is that one.
        not identified? and clears_by_omission?(field, previous, raw, stored, module) ->
          add_omission_violation(acc, module, field.name)

        true ->
          acc
      end
    end)
    |> check_nested(block, module, role)
  end

  defp check_block(changeset, _other, _stored, _role, _raw, _identified?), do: changeset

  defp has_id?(raw) when is_map(raw),
    do: not is_nil(Map.get(raw, :id) || Map.get(raw, "id"))

  defp has_id?(_raw), do: false

  # Only for a block with no id match, only for a field the client omitted, and
  # only when some stored block of the same type actually holds a non-default
  # value — so an ordinary page, where nothing restricted is set, is untouched.
  defp clears_by_omission?(field, previous, raw, stored, module) do
    is_nil(previous) and not supplied?(raw, field.name) and
      stored_holds_non_default?(stored, module, field)
  end

  defp stored_holds_non_default?(stored, module, field) do
    Enum.any?(stored, fn
      {_id, %^module{} = block} -> Map.get(block, field.name) != field.default
      _other -> false
    end)
  end

  # A field the client did not send at all. Both key shapes, because the API and
  # editor submit strings while code interfaces submit atoms. No raw entry means
  # the write did not come through `block_tree`, so nothing was omitted.
  defp supplied?(raw, name) when is_map(raw),
    do: Map.has_key?(raw, name) or Map.has_key?(raw, to_string(name))

  defp supplied?(_raw, _name), do: true

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

  # A different mistake with a different fix, so it says so: a client that sent
  # no `featured` at all is not helped by being told it cannot change one, and
  # on the headless path `blocks` is not readable, so it has no way to know the
  # field exists until something says.
  defp add_omission_violation(changeset, module, field_name) do
    type = Kiln.Block.Info.name(module)

    Ash.Changeset.add_error(changeset,
      field: :blocks,
      message:
        "cannot omit `#{field_name}` on a #{type} block: it is set on this content and " <>
          "restricted to other roles, and a block tree carrying no ids cannot say which " <>
          "block is which — send each block's id"
    )
  end
end
