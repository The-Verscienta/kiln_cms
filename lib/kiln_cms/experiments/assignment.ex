defmodule KilnCMS.Experiments.Assignment do
  @moduledoc """
  Picks which variant a request sees, and applies its patch (#499).

  ## Two bucketing modes, because there are two kinds of caller

  **Stateless** (the built-in site). A variant is drawn per request, weighted.
  Nothing is stored and no visitor is identified, which is what keeps
  `docs/data-flows.md`'s "no cookie is recorded for visitors" true. The cost is
  that a reload may show a different variant — so only a *same-page* goal can be
  attributed there, which is why `:form_submission` is the goal v1 leads with.

  **Keyed** (headless). `:erlang.phash2/2` over a caller-supplied `variant_key`,
  so the same key always resolves to the same variant. The caller already has a
  session, a user id, or an edge-assigned bucket; they own stickiness and Kiln
  stores nothing. It also makes the response cacheable per variant at the edge.

  Both walk the same weighted list, so a 3:1 split means the same thing on each.

  ## Applying the patch

  `apply_to_record/2` and `apply_to_blocks/2` are separate on purpose, because
  the callers need them separately: the HTML path must patch the *visible* body
  while leaving the canonical record to build `<title>`, the meta description
  and the schema.org graph (invariant 3). Handing it one `apply/2` that did both
  would make the leak the easy mistake.
  """

  alias KilnCMS.Experiments.Variant

  @typedoc "A chosen arm, or nothing when the experiment cannot serve one."
  @type choice :: Variant.t() | nil

  @doc """
  Choose a variant, weighted.

  `key` is `nil` for stateless assignment or a caller-supplied string for
  deterministic assignment. A variant list whose weights sum to zero yields
  `nil` rather than dividing by it — an experiment configured to serve nothing
  serves the canonical document.
  """
  @spec choose([Variant.t()], String.t() | nil) :: choice()
  def choose(variants, key \\ nil)
  def choose([], _key), do: nil

  def choose(variants, key) do
    ordered = Enum.sort_by(variants, & &1.id)
    total = Enum.sum_by(ordered, & &1.weight)

    cond do
      total <= 0 -> nil
      # `phash2/2`'s second argument is the RANGE, not a seed — the result is
      # already in `[0, total)`, so there is nothing left to take a modulo of.
      is_binary(key) and key != "" -> pick(ordered, :erlang.phash2(key, total))
      true -> pick(ordered, :rand.uniform(total) - 1)
    end
  end

  @doc """
  Choose a variant for a sticky **bucket** — an integer in `[0, buckets)` from
  the visitor's cookie (#984).

  Scaled proportionally rather than hashed, and that is the whole reason this
  exists separately from `choose/2`'s keyed branch. `phash2/2` over a small
  value space does not distribute evenly: with 100 possible buckets and a 50/50
  split, which side of the line each bucket falls on is fixed by the hash, so
  the arms would sit at something like 54/46 **permanently** — a systematic bias
  that reads as a real effect and never averages out, because the same buckets
  keep landing the same way.

  The cumulative shares are compared **in bucket space** — arm `i` owns buckets
  below `div(cumulative_weight * buckets, total)`. Scaling the bucket up into
  weight space instead (`div(bucket * total, buckets)`) looks equivalent and is
  not: with weights `[999, 1]` every one of the 100 bucket values lands below
  999, so the second arm is served to **nobody** while the results table shows
  it running. This way each arm gets its weighted share of buckets, truncated,
  and an arm whose share is below `1/buckets` is the only one that can round to
  nothing — which is a real limit of 100 buckets rather than a bias toward
  whichever arm sorts first.
  """
  @spec choose_bucket([Variant.t()], non_neg_integer(), pos_integer()) :: choice()
  def choose_bucket(variants, bucket, buckets)
      when is_integer(bucket) and bucket >= 0 and is_integer(buckets) and buckets > 0 do
    ordered = Enum.sort_by(variants, & &1.id)
    total = Enum.sum_by(ordered, & &1.weight)

    if total <= 0, do: nil, else: pick_bucket(ordered, bucket, 0, total, buckets)
  end

  def choose_bucket(_variants, _bucket, _buckets), do: nil

  defp pick_bucket([variant], _bucket, _taken, _total, _buckets), do: variant

  defp pick_bucket([variant | rest], bucket, taken, total, buckets) do
    taken = taken + variant.weight

    if bucket < div(taken * buckets, total),
      do: variant,
      else: pick_bucket(rest, bucket, taken, total, buckets)
  end

  # Sorted by id first, so the same key maps to the same arm across nodes and
  # restarts — the row order a database happens to return is not a contract.
  defp pick([variant], _bucket), do: variant

  defp pick([variant | rest], bucket) do
    if bucket < variant.weight, do: variant, else: pick(rest, bucket - variant.weight)
  end

  @doc """
  Apply a variant's `fields` patch to a document record.

  Only `KilnCMS.Experiments.Variant.patchable_fields/0` are honoured — the
  validation refuses anything else at write time, and this refuses it again at
  read time. A patch that reached the database through some other path (a
  restored backup, a hand-written row) must not be able to rewrite a slug on
  delivery.
  """
  @spec apply_to_record(struct(), Variant.t() | nil) :: struct()
  def apply_to_record(record, nil), do: record

  def apply_to_record(record, %{patch: patch}) do
    patch
    |> Map.get("fields", %{})
    |> Map.take(Variant.patchable_fields())
    |> Enum.reduce(record, fn {field, value}, acc ->
      Map.put(acc, String.to_existing_atom(field), value)
    end)
  end

  @doc """
  Whether a variant patches any block at all.

  The HTML path rebuilds the whole block pipeline to apply a block patch, which
  is the expensive part of serving an experimented page. Most experiments are
  headline tests and touch no block, so asking first is worth a function.
  """
  @spec patches_blocks?(Variant.t() | nil) :: boolean()
  def patches_blocks?(nil), do: false
  def patches_blocks?(%{patch: patch}), do: Map.get(patch, "blocks", %{}) != %{}

  @doc """
  Apply a variant's `blocks` patch to a stored block list.

  Blocks are addressed by their stable `_id`, so the patch survives reordering.
  Applied to the **stored** block maps — before the typed/legacy conversion and
  the media enrichment — so everything downstream sees a normal block tree and
  no renderer needs to know experiments exist.

  Recurses into `columns` children, since a CTA inside a two-column layout is
  exactly the thing anyone would want to test.
  """
  @spec apply_to_blocks([map()], Variant.t() | nil) :: [map()]
  def apply_to_blocks(blocks, nil), do: blocks

  def apply_to_blocks(blocks, %{patch: patch}) do
    case Map.get(patch, "blocks", %{}) do
      empty when empty == %{} -> blocks
      patches -> blocks |> List.wrap() |> Enum.map(&patch_block(&1, patches))
    end
  end

  # A loaded record's blocks are `%Ash.Union{}`-wrapped typed structs; a block
  # read straight out of jsonb (or written by a test) is a plain string-keyed
  # map. Both shapes reach here, so both are handled — patching only one of them
  # would work on exactly one of the two delivery paths.
  defp patch_block(%Ash.Union{value: value} = union, patches),
    do: %{union | value: patch_block(value, patches)}

  defp patch_block(%_struct{} = block, patches) do
    block
    |> merge_struct_patch(patches)
    |> patch_struct_columns(patches)
  end

  defp patch_block(block, patches) when is_map(block) do
    block
    |> merge_patch(patches)
    |> patch_columns(patches)
  end

  defp patch_block(block, _patches), do: block

  defp merge_patch(block, patches) do
    case patches[block_id(block)] do
      nil -> block
      fields when is_map(fields) -> Map.merge(block, safe_fields(fields))
      _other -> block
    end
  end

  # The struct path is gated by `Map.has_key?` — a struct simply has no field to
  # write. A map-shaped block has no such shape to hide behind, so the
  # structural keys are named and refused: `_type` drives union dispatch and
  # renderer selection (setting it is arbitrary-markup injection into a headless
  # consumer), and `id`/`_id` are the block's identity, which the patch is keyed
  # by. A patch that reached the row some other way — a seed, a hand-written
  # insert — still cannot use them.
  @structural_keys ~w(_type _id _version id __struct__)

  defp safe_fields(fields), do: fields |> stringify() |> Map.drop(@structural_keys)

  # `Map.has_key?` before writing, so a patch can only set fields the block
  # actually declares — it cannot graft an arbitrary key onto a typed struct.
  defp merge_struct_patch(block, patches) do
    case patches[block_id(block)] do
      fields when is_map(fields) -> Enum.reduce(fields, block, &put_declared_field/2)
      _other -> block
    end
  end

  defp put_declared_field({key, value}, block) do
    # `Map.has_key?` alone is not enough: a block struct genuinely HAS `:id`,
    # `:_type` and `:_version`, so the structural keys have to be refused by
    # name here as well.
    with false <- to_string(key) in @structural_keys,
         atom when not is_nil(atom) <- existing_atom(key),
         true <- Map.has_key?(block, atom) do
      Map.put(block, atom, value)
    else
      _not_declared -> block
    end
  end

  defp patch_struct_columns(%{columns: columns} = block, patches) when is_list(columns) do
    %{block | columns: Enum.map(columns, &patch_column(&1, patches))}
  end

  defp patch_struct_columns(block, _patches), do: block

  # `to_existing_atom` and not `to_atom`: the key comes from stored jsonb, and
  # minting an atom per patch key would be an unbounded atom table keyed by
  # whatever anyone once typed.
  defp existing_atom(key) do
    String.to_existing_atom(to_string(key))
  rescue
    ArgumentError -> nil
  end

  # A `columns` block holds child blocks as raw maps under `columns[].blocks`.
  defp patch_columns(%{"columns" => columns} = block, patches) when is_list(columns) do
    Map.put(block, "columns", Enum.map(columns, &patch_column(&1, patches)))
  end

  defp patch_columns(block, _patches), do: block

  defp patch_column(%{"blocks" => children} = column, patches) when is_list(children) do
    Map.put(column, "blocks", Enum.map(children, &patch_block(&1, patches)))
  end

  defp patch_column(column, _patches), do: column

  # Both callers hand this a map — a typed struct or a raw block map — so there
  # is no third shape to fall through to.
  defp block_id(%_struct{id: id}), do: id
  defp block_id(block) when is_map(block), do: Map.get(block, "id") || Map.get(block, :id)

  # A patch arrives from jsonb with string keys; a stored block map may have
  # either, and merging a string key onto an atom-keyed map would double the
  # field rather than replace it.
  defp stringify(fields), do: Map.new(fields, fn {k, v} -> {to_string(k), v} end)

  @doc """
  Apply a variant to a fired `:json` artifact body.

  The headless shape: `%{"title" => …, "blocks" => [%{"_id" => …}, …]}`. Blocks
  carry `_id` here rather than `id`, which is why this cannot reuse
  `apply_to_blocks/2` — same idea, different key, and pretending otherwise would
  silently patch nothing.
  """
  @spec apply_to_artifact(map(), Variant.t() | nil) :: map()
  def apply_to_artifact(body, nil), do: body

  def apply_to_artifact(body, %{patch: patch}) when is_map(body) do
    fields = patch |> Map.get("fields", %{}) |> Map.take(Variant.patchable_fields())
    blocks = Map.get(patch, "blocks", %{})

    body
    |> Map.merge(fields)
    |> Map.update("blocks", [], &patch_artifact_blocks(&1, blocks))
  end

  def apply_to_artifact(body, _variant), do: body

  defp patch_artifact_blocks(blocks, patches) when is_list(blocks) do
    Enum.map(blocks, &patch_artifact_block(&1, patches))
  end

  defp patch_artifact_blocks(blocks, _patches), do: blocks

  defp patch_artifact_block(%{"_id" => id} = block, patches) do
    block
    |> then(fn b -> if fields = patches[id], do: Map.merge(b, safe_fields(fields)), else: b end)
    |> patch_artifact_columns(patches)
  end

  defp patch_artifact_block(block, patches), do: patch_artifact_columns(block, patches)

  defp patch_artifact_columns(%{"columns" => columns} = block, patches) when is_list(columns) do
    Map.put(
      block,
      "columns",
      Enum.map(columns, fn
        %{"blocks" => children} = column when is_list(children) ->
          Map.put(column, "blocks", patch_artifact_blocks(children, patches))

        column ->
          column
      end)
    )
  end

  defp patch_artifact_columns(block, _patches), do: block
end
