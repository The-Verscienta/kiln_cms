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

  ## Nested children: a whole-tree multiset (#774)

  `columns` nests its children as raw maps (`{:array, :map}`) rather than union
  members, to avoid a recursive-type compile cycle, so nested children carry no
  stable identity to diff one-for-one. Rather than the old per-child "must equal
  its default" rule — which closed the smuggle hole but refused an editor even
  resubmitting an admin's value, and (#774) still let them CLEAR one by omission
  — the check compares the **whole tree's multiset** of role-restricted
  non-default nested values before and after. A non-admin write must leave that
  multiset identical: it can neither introduce a restricted value (smuggle/set)
  nor drop one (omit/clear), but it may resubmit a column holding an admin-set
  value unchanged, and it may edit the permitted fields around it.

  A multiset preserves the *count* of admin-set values, not their *binding* to
  specific content, so on its own it let a non-admin **re-target** one: clear it
  on one child and set it on another of the same type in the same write, leaving
  the count equal. A structural delete that removes a child holding an admin-set
  value shrinks the multiset and is refused — stricter than the top-level layer,
  which errs safe.

  ## Nested children: bound to the child that holds them (#865)

  `KilnCMSWeb.ContentEditorLive` stamps every nested child an `"id"` for its own
  bookkeeping, and that key survives into storage. Where those ids exist the
  multiset can be sharpened from *how many* admin-set values there are to
  *which child* holds each one. Three rules are layered on it:

    * **an id names one child.** Two children submitted under the same id are
      refused. This one always applies: without it the two collapse when indexed
      and the last wins, which is a collision that makes the check refuse
      *less* — send the real child cleared and a decoy of the same id carrying
      the value, decoy last, and the stored content quietly loses it.
    * **a child that comes back under an id we know** must come back with the
      value that id had. This is what sees a re-target: moving a value changes
      both children while leaving the count alone.
    * **a child that held a restricted non-default value** must come back, under
      the same id, still holding it — otherwise the rule above is sidestepped by
      presenting the same content under a fresh id.

  The last two are **required, not opt-in** (#954). They used to apply only
  when the client demonstrably round-tripped ids, because nested child ids were
  unreadable — demanding one back named a remedy the caller could not perform.
  Every caller can now read them: the public `block_ids` calculation projects
  the tree to `_id`/`_type` on any policy-scoped read (drafts included,
  editor-scoped by the row read policy), the fired `:json` artifact carries
  `_id` for published content, and the write path accepts either spelling. So a
  submission that strips the ids of an identified tree is refused, with the
  surface named in the error, rather than quietly downgraded to the count-only
  multiset — which is what #774's re-target needed.

  Two deliberate carve-outs, both keyed on what is actually stored:

    * **`restore_version` folding an id-less tree.** The submission is our own
      history, vetted by this policy when written, and versions captured before
      the editor stamped children fold back id-less by construction — no
      surface can ever hand those ids back. A restore that does carry ids keeps
      the binding like any other write, so nothing that was checked before is
      loosened.
    * **A stored tree whose children carry no ids** binds nothing (its entries
      are empty), so it is governed by the multiset exactly as before — old
      rows and headlessly-authored ones are not bricked by a demand for ids
      that were never stored. The document becomes strict the first time an
      id-stamping client (the editor, or any client echoing `block_ids`) saves
      it. The cost is the narrowed residual: a restricted value stored on an
      id-less child can still be re-targeted until then; recorded in
      `docs/threat-model.md`.

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
  to the block it claims.

  The same is true one level down, and for the same missing primitive: a client
  that supplies its own nested child ids can relabel which child an id names, so
  the binding above believes the labels it is handed. It is checked for the one
  case that is decidable without ownership — an id naming two children at once —
  and otherwise holds only as well as the ids do. Nested children additionally
  keep the id-less-STORED residual described above: a restricted value stored on
  a child that has no id has no identity to bind until an id-stamping save gives
  it one.

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
      raw = raw_input(changeset)
      # Only a *wholly* id-less tree cannot say which block is which. A tree
      # carrying any id shows the client can round-trip them, so a block without
      # one there is genuinely new — and holding it to the omission rule would
      # refuse an editor simply inserting a block above a featured one.
      identified? = Enum.any?(raw, &has_id?/1)

      blocks = changeset |> Ash.Changeset.get_attribute(:blocks) |> List.wrap()

      blocks
      |> Enum.with_index()
      |> Enum.reduce(changeset, fn {block, index}, acc ->
        check_block(acc, block, stored, role, Enum.at(raw, index), identified?)
      end)
      |> check_nested_tree(blocks, role)
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

  # Two checks over the nested tree, run against one walk of each side rather
  # than one walk per check — `collect_maps/1` descends every map value, so on a
  # page with a long `rich_text` body it walks the whole Portable Text document.
  defp check_nested_tree(changeset, submitted, role) do
    stored = changeset.data |> stored_blocks() |> nested_child_maps()
    now = nested_child_maps(submitted)

    changeset
    |> check_nested_multiset(stored, now, role)
    |> check_nested_identity(stored, now, role)
  end

  defp nested_child_maps(blocks), do: Enum.flat_map(blocks, &nested_maps/1)

  # The WHOLE tree's multiset of role-restricted non-default nested values must
  # be identical before and after (#774): a non-admin can neither introduce one
  # (the #51 "smuggle" and #566 "set" cases) nor drop one (the #774 omission —
  # nest a featured quote in a column, then resubmit the column with `featured`
  # gone). It compares counts, not bindings, so it allows a *child* to move
  # between columns as long as it keeps its value.
  #
  # Retained alongside the per-child binding below, and not redundant with it:
  # this is the SOLE enforcement for a child the stored tree has never seen.
  # `moved_values/2` says nothing about an unknown id and `dropped_values/2` only
  # demands stored non-defaults back, so a brand-new nested child arriving
  # pre-`featured` is invisible to both — the count going up is what catches it.
  defp check_nested_multiset(changeset, stored_maps, now_maps, role) do
    before = nested_restricted(stored_maps, role)
    now = nested_restricted(now_maps, role)

    (Map.keys(before) ++ Map.keys(now))
    |> Enum.uniq()
    |> Enum.reduce(changeset, fn {module, field_name} = key, acc ->
      if Map.get(before, key, []) == Map.get(now, key, []),
        do: acc,
        else: add_nested_violation(acc, module, field_name)
    end)
  end

  # Which child holds each admin-set value, not just how many do (#865).
  #
  # The multiset compares sorted VALUES keyed by `{module, field}`, so a
  # non-admin could clear `featured` on one nested quote and set it on another
  # in the same write: the count is unchanged, so it saw nothing. Now that
  # `TypedBlocks` stamps every nested child an id on the way in, the value can
  # be bound to the child that held it.
  #
  # Layered on rather than replacing the multiset, and purely additive — it can
  # only refuse writes that used to pass, never permit one that used to fail
  # (#566's constraint). That also makes it safe for rows written before the
  # stamping existed: their stored children carry no id, match nothing here, and
  # are governed by the multiset exactly as before.
  defp check_nested_identity(changeset, stored_maps, now_maps, role) do
    stored_entries = nested_entries(stored_maps, role)
    now_entries = nested_entries(now_maps, role)

    stored = Map.new(stored_entries)
    now = Map.new(now_entries)

    bound =
      if binding_applies?(changeset, stored, now),
        do: moved_values(now, stored) ++ dropped_values(stored, now),
        else: []

    (duplicate_ids(now_entries) ++ bound)
    |> Enum.uniq()
    |> Enum.reduce(changeset, fn
      {:duplicate, module, field_name}, acc ->
        add_duplicate_id_violation(acc, module, field_name)

      {:binding, module, field_name}, acc ->
        add_nested_identity_violation(acc, module, field_name)
    end)
  end

  # The binding is REQUIRED, not gated on the client demonstrating it
  # round-trips ids (#954). It used to be gated, because nested child ids were
  # unreadable — a rule demanding one back refused headless callers permanently
  # while naming a remedy they could not perform. That premise is gone: the
  # `block_ids` calculation projects the tree to `_id`/`_type` on every
  # policy-scoped read (drafts included, editor-scoped by the row policy), the
  # fired artifact carries `_id` for published content, and the write path
  # accepts either spelling. Stripping ids is therefore a refusal rather than a
  # fallback to the count-only multiset, which is what closes #774's id-less
  # re-target.
  #
  # The one exemption: a `restore_version` fold that carries no ids. The
  # submitted tree is our own history — vetted by this same policy when it was
  # written — and versions captured before the editor stamped children fold
  # back id-less by construction; there is no surface that can ever hand those
  # ids back. A restore that DOES round-trip ids keeps the binding exactly as
  # any other write, so this exemption never loosens a case that was previously
  # checked.
  defp binding_applies?(changeset, stored, now),
    do: round_trips_ids?(stored, now) or not restoring_version?(changeset)

  defp round_trips_ids?(stored, now),
    do: Enum.any?(Map.keys(now), &Map.has_key?(stored, &1))

  # Keyed on the ACTION, not on a caller-set flag. `:restore_version` is
  # `accept []` with a single `version_id` argument (see `KilnCMS.CMS.Content`),
  # so it takes no content input at all — the tree it writes comes wholly from
  # our own version history through `Changes.RestoreVersion`, never from the
  # request. An attacker who reaches this action can choose *which* vetted
  # arrangement to replay (a documented residual, bounded by the multiset,
  # which still runs on a restore) but cannot smuggle a fresh tree through it.
  #
  # Deliberately not a `changeset.context` flag: that would rest the whole
  # exemption on no external surface ever threading request data into private
  # context, which is true today but is a barrier a future plug could quietly
  # lower. The action name cannot be forged onto a plain `:update`, and a
  # `:restore_version` write cannot carry a hostile tree, so there is nothing
  # to leak.
  defp restoring_version?(%{action: %{name: :restore_version}}), do: true
  defp restoring_version?(_changeset), do: false

  # An id names one child. A tree where it names two collapses in `Map.new/1`
  # above and the LAST one wins, which is a collision that makes the check
  # refuse *less*: submit the real child cleared and a decoy of the same id
  # carrying the value, decoy last, and `moved_values/2` reads the decoy's value
  # while the stored content quietly loses it. Verified reachable before this
  # existed, so it is checked rather than reasoned away.
  defp duplicate_ids(entries) do
    entries
    |> Enum.frequencies_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn
      {{_id, module, field_name}, count} when count > 1 -> [{:duplicate, module, field_name}]
      _unique -> []
    end)
  end

  # A child that came back under an id we know must come back with the value
  # that id had. An id we do not know is a new child, and the multiset already
  # refuses it arriving pre-set.
  defp moved_values(now, stored) do
    Enum.flat_map(now, fn {{_id, module, field_name} = key, {_field, value}} ->
      case Map.fetch(stored, key) do
        {:ok, {_field, ^value}} -> []
        {:ok, _different} -> [{:binding, module, field_name}]
        :error -> []
      end
    end)
  end

  # ...and a child that held one must still be there holding it. Without this
  # the rule above is evaded by simply dropping the ids: an id-less child
  # matches nothing stored, and the multiset only counts. It is also what
  # refuses the #774 clear-by-omission on an identified child, this time naming
  # the child rather than the tree — and, now that the binding is required
  # (#954), what refuses the wholly id-less submission against an identified
  # stored tree.
  #
  # Only non-default stored values are required back, so an ordinary page —
  # where nothing restricted is set — is untouched, and a child may still be
  # deleted outright unless it is holding an admin-set value.
  defp dropped_values(stored, now) do
    Enum.flat_map(stored, fn {{_id, module, field_name} = key, {field, value}} ->
      if value != field.default and not Map.has_key?(now, key),
        do: [{:binding, module, field_name}],
        else: []
    end)
  end

  # `{{child_id, module, field_name}, {field, value}}` for every role-restricted
  # field of every nested child that carries an id, at any depth. A LIST rather
  # than a map, so `duplicate_ids/1` can still see a key that appears twice.
  #
  # Unlike `nested_restricted/2` this keeps default values too: clearing a field
  # is a write of its default, and that is exactly what has to be caught.
  #
  # A field the child omits reads as the default here, and that is right
  # *because* there is an id. The top-level rule cannot read an omission as a
  # default write (#566) precisely because with no id it cannot tell which
  # block is which; with one, "you sent this child back without the field it
  # had" is an unambiguous clear.
  defp nested_entries(child_maps, role),
    do: Enum.flat_map(child_maps, &identified_entries(&1, role))

  defp identified_entries(map, role) do
    with {:ok, id} when is_binary(id) <- fetch_field(map, :id),
         {:ok, type} <- fetch_type(map),
         {:ok, module} <- KilnCMS.Blocks.fetch(type) do
      module
      |> restricted_fields(role)
      |> Enum.map(&{{id, module, &1.name}, {&1, field_value(map, &1)}})
    else
      _ -> []
    end
  end

  defp field_value(map, field) do
    case fetch_field(map, field.name) do
      {:ok, value} -> value
      :error -> field.default
    end
  end

  defp stored_blocks(%{blocks: blocks}) when is_list(blocks), do: blocks
  defp stored_blocks(_data), do: []

  # `{module, field_name}` => the sorted multiset of non-default values held under
  # role-restricted fields, across every nested typed child map in the tree, at
  # any depth. Omitted and default-valued fields contribute nothing, so an
  # ordinary page with nothing restricted set yields an empty map on both sides.
  defp nested_restricted(child_maps, role) do
    child_maps
    |> Enum.reduce(%{}, &collect_restricted(&1, role, &2))
    |> Map.new(fn {key, values} -> {key, Enum.sort(values)} end)
  end

  # Every nested child map inside a block — **asked of the block**, not searched
  # for (#956).
  #
  # This used to walk the whole term looking for maps that carried a `"blocks"`
  # key. That is a guess about where children live, and a guess is defeatable:
  # `field :columns, {:array, :map}` has no `fields` constraint, so an attacker
  # could park a whole child list under any key of their choosing —
  # `%{"blocks" => [real], "trash" => [%{"blocks" => [parked]}]}` — and the
  # traversal counted the parked one while the renderer never showed it. That
  # offsets the removal of a real admin-set value, so the two multisets compared
  # equal and the removal went through. It did not even need a `columns` block:
  # `gallery.images` is `{:array, :map}` too, and unknown keys survive
  # sanitization there as well.
  #
  # The traversal has to mirror the renderer exactly — see the value only where
  # a reader would — and the module that renders is the one that knows. So a
  # block declares its children (`Columns.child_maps/1`) and everything else has
  # none.
  #
  # A block type that nests children and does NOT declare them here is invisible
  # to this check, which fails open. That is the cost of mirroring rather than
  # guessing, and it is the safer trade: guessing failed open too — silently, and
  # for content the renderer never shows.
  defp nested_maps(%Ash.Union{value: value}), do: nested_maps(value)

  defp nested_maps(%KilnCMS.Blocks.Columns{} = block),
    do: KilnCMS.Blocks.Columns.child_maps(block)

  defp nested_maps(_other), do: []

  defp collect_restricted(map, role, acc) do
    with {:ok, type} <- fetch_type(map),
         {:ok, module} <- KilnCMS.Blocks.fetch(type) do
      module
      |> restricted_fields(role)
      |> Enum.reduce(acc, &collect_field_value(map, module, &1, &2))
    else
      _ -> acc
    end
  end

  # Split out of `collect_restricted/3` rather than written inline: `with` ->
  # `reduce` -> `case` nests one level past the limit `mix credo --strict`
  # enforces.
  defp collect_field_value(map, module, field, acc) do
    case fetch_field(map, field.name) do
      {:ok, value} when not is_nil(value) and value != field.default ->
        Map.update(acc, {module, field.name}, [value], &[value | &1])

      _ ->
        acc
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

  # Nested children have no id, so the message can't point at one block. It names
  # the field and the type and says what the rule is: the admin-set value has to
  # come back unchanged — covering both introducing a value and dropping one.
  defp add_nested_violation(changeset, module, field_name) do
    type = Kiln.Block.Info.name(module)

    Ash.Changeset.add_error(changeset,
      field: :blocks,
      message:
        "cannot change `#{field_name}` on a nested #{type} block: it is restricted to other " <>
          "roles, so an admin-set value must be resubmitted unchanged, not introduced or dropped"
    )
  end

  # An id that names two children is refused outright rather than resolved: any
  # rule that picks one of them is picking which claim to believe, and the whole
  # point of the id is that there is nothing to pick between.
  defp add_duplicate_id_violation(changeset, module, field_name) do
    type = Kiln.Block.Info.name(module)

    Ash.Changeset.add_error(changeset,
      field: :blocks,
      message:
        "two nested #{type} blocks were submitted under the same id, and `#{field_name}` on " <>
          "them is restricted to other roles: an id must name one child"
    )
  end

  # Nested children now DO have an id, so this one can say which value moved
  # and what the remedy is — resubmit the child that held it, holding it. The
  # ids are readable (#954): `block_ids` on any policy-scoped read, `_id` in
  # the fired artifact for published content. The message names the surface,
  # because a client that dropped every id has no other way to learn that one
  # exists.
  defp add_nested_identity_violation(changeset, module, field_name) do
    type = Kiln.Block.Info.name(module)

    Ash.Changeset.add_error(changeset,
      field: :blocks,
      message:
        "cannot move or clear `#{field_name}` on a nested #{type} block: it is restricted to " <>
          "other roles, so the child that holds it must come back under the same id still " <>
          "holding it — read each child's `_id` from the `block_ids` calculation (or the " <>
          "fired artifact) and send it back"
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
