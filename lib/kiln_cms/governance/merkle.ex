defmodule KilnCMS.Governance.Merkle do
  @moduledoc """
  A binary hash tree over a checkpoint's leaf set, with per-leaf inclusion
  proofs (#666).

  A governance checkpoint commits to the head anchor of **every** anchored
  document in an org. Verifying one document against it must not mean reading
  the whole set back — a site with ten thousand documents would pay ten thousand
  rows to answer a question about one. So the checkpoint signs a single `root`,
  each stored leaf carries the `O(log n)` sibling hashes on its path to that
  root, and verification is one row plus one signature check.

  ## Shape

  Leaves are hashed with a `0x00` prefix and interior nodes with `0x01`
  (RFC 6962 §2's domain separation). Without it, an interior hash could be
  presented as a leaf: an attacker who chooses leaf content chooses a value that
  is *also* a valid internal node, and a proof for the fabricated subtree
  verifies against the same root.

  A level with an odd number of nodes **promotes** the last node unchanged
  rather than duplicating it. Duplication is the Bitcoin CVE-2012-2459 shape:
  `[a, b, c]` and `[a, b, c, c]` hash to the same root, so a set can be extended
  without changing the commitment. Promotion is not ambiguous that way — the
  levels differ in width, so the paths differ.

  Hashes are lowercase hex SHA-256, matching `KilnCMS.Governance.Chain`'s
  `anchor_digest/1`, so an operator reading the two side by side sees one
  format.

  ## Proof encoding

  A proof is an ordered list of `%{"h" => hex, "d" => "l" | "r"}`, walking from
  the leaf upward. `"d"` is the side the **sibling** sits on, which is what
  fixes the concatenation order — a proof without it verifies against a root the
  prover chooses by reordering, since `hash(a <> b)` and `hash(b <> a)` are both
  reachable. Plain maps with string keys because a proof round-trips through a
  `:map` column.
  """

  @typedoc "One step on the path from a leaf to the root."
  @type step :: %{required(String.t()) => String.t()}

  @typedoc "A leaf's inclusion proof, leaf-first."
  @type proof :: [step()]

  # The commitment for an org with nothing anchored yet. A checkpoint is still
  # minted and signed in that state, so the empty set needs a defined root
  # rather than a nil the signature cannot cover.
  @empty Base.encode16(:crypto.hash(:sha256, "kiln-governance-checkpoint-v1:empty"), case: :lower)

  @doc "The root of an empty leaf set."
  @spec empty_root() :: String.t()
  def empty_root, do: @empty

  @doc """
  Hash one leaf's canonical encoding.

  `term` is canonicalized by `KilnCMS.Provenance.Canonical`, so the caller hands
  in a plain map and the byte layout is defined in one place.
  """
  @spec leaf(term()) :: String.t()
  def leaf(term) do
    :sha256
    |> :crypto.hash(<<0>> <> KilnCMS.Provenance.Canonical.encode(term))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Build the tree over `leaves` (already-hashed, in the order they are committed).

  Returns `{root, proofs}`, `proofs` in the same order as `leaves`.
  """
  @spec build([String.t()]) :: {String.t(), [proof()]}
  def build([]), do: {@empty, []}

  def build(leaves) when is_list(leaves) do
    # Each level is a list of `{hash, leaf_indices}`: the node and which leaves
    # sit beneath it. Carrying the membership is what lets one upward pass emit
    # every proof, instead of re-walking the tree per leaf.
    level = Enum.with_index(leaves, fn hash, index -> {hash, [index]} end)
    {root, steps} = climb(level, %{})

    {root, Enum.map(0..(length(leaves) - 1), &Enum.reverse(Map.get(steps, &1, [])))}
  end

  @doc "The root over `leaves` without building proofs."
  @spec root([String.t()]) :: String.t()
  def root(leaves), do: leaves |> build() |> elem(0)

  @doc """
  Whether `leaf` with `proof` reconstructs `root`.

  Returns false rather than raising on a malformed proof: it arrives from a
  database column an attacker with write access may have rewritten, so a shape
  this does not recognise is a failed verification, not a crash on the audit
  path.
  """
  @spec verify(String.t(), proof() | nil, String.t()) :: boolean()
  def verify(leaf, proof, root) when is_binary(leaf) and is_binary(root) and is_list(proof) do
    proof
    |> Enum.reduce_while({:ok, leaf}, fn
      %{"h" => sibling, "d" => "l"}, {:ok, acc} when is_binary(sibling) ->
        {:cont, {:ok, node_hash(sibling, acc)}}

      %{"h" => sibling, "d" => "r"}, {:ok, acc} when is_binary(sibling) ->
        {:cont, {:ok, node_hash(acc, sibling)}}

      _malformed, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, computed} -> Plug.Crypto.secure_compare(computed, root)
      :error -> false
    end
  end

  def verify(_leaf, _proof, _root), do: false

  defp climb([{root, _members}], steps), do: {root, steps}

  defp climb(level, steps) do
    {parents, steps} = pair(level, [], steps)
    climb(Enum.reverse(parents), steps)
  end

  defp pair([{left, left_members}, {right, right_members} | rest], parents, steps) do
    steps =
      steps
      |> record(left_members, %{"h" => right, "d" => "r"})
      |> record(right_members, %{"h" => left, "d" => "l"})

    parent = {node_hash(left, right), left_members ++ right_members}
    pair(rest, [parent | parents], steps)
  end

  # Odd node out: promoted unchanged, so nothing beneath it gains a step.
  defp pair([last], parents, steps), do: {[last | parents], steps}
  defp pair([], parents, steps), do: {parents, steps}

  defp record(steps, members, step) do
    Enum.reduce(members, steps, fn index, acc ->
      Map.update(acc, index, [step], &[step | &1])
    end)
  end

  defp node_hash(left, right) do
    :sha256
    |> :crypto.hash(<<1>> <> left <> right)
    |> Base.encode16(case: :lower)
  end
end
