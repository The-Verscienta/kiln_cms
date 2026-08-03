defmodule KilnCMS.Governance.MerkleTest do
  @moduledoc """
  The inclusion-proof tree behind governance checkpoints (#666). Every property
  here is load-bearing: the checkpoint signs only the root, so a leaf is
  attested by its proof and by nothing else.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Governance.Merkle

  defp leaves(n), do: for(i <- 1..n, do: Merkle.leaf(%{"i" => i}))

  test "every leaf's proof reconstructs the root, at every width" do
    # Odd widths are where the promotion rule applies, so the sweep covers the
    # ragged shapes rather than only powers of two.
    for n <- 1..17 do
      set = leaves(n)
      {root, proofs} = Merkle.build(set)

      assert length(proofs) == n

      for {leaf, proof} <- Enum.zip(set, proofs) do
        assert Merkle.verify(leaf, proof, root), "leaf failed to verify in a tree of #{n}"
      end
    end
  end

  test "a leaf not in the set does not verify against the root" do
    {root, [proof | _]} = Merkle.build(leaves(8))

    refute Merkle.verify(Merkle.leaf(%{"i" => 99}), proof, root)
  end

  test "a proof step flipped to the other side does not verify" do
    set = leaves(8)
    {root, proofs} = Merkle.build(set)

    flipped =
      proofs
      |> hd()
      |> Enum.map(fn %{"h" => h, "d" => d} ->
        %{"h" => h, "d" => if(d == "l", do: "r", else: "l")}
      end)

    refute Merkle.verify(hd(set), flipped, root)
  end

  test "a malformed proof is false, not a crash" do
    {root, _proofs} = Merkle.build(leaves(4))
    leaf = Merkle.leaf(%{"i" => 1})

    refute Merkle.verify(leaf, [%{"nope" => true}], root)
    refute Merkle.verify(leaf, [%{"h" => 1, "d" => "l"}], root)
    refute Merkle.verify(leaf, nil, root)
  end

  # Promotion rather than duplication of an odd node — the CVE-2012-2459 shape.
  # If the last leaf were duplicated to pad a level, these two sets would commit
  # to the same root and a set could be extended without changing the
  # commitment.
  test "duplicating the last leaf changes the root" do
    set = leaves(3)

    refute Merkle.root(set) == Merkle.root(set ++ [List.last(set)])
  end

  # Domain separation: without the 0x00/0x01 prefixes an interior hash could be
  # presented as a leaf, and a proof for a fabricated subtree would verify.
  test "an interior node hash is not a valid leaf" do
    set = leaves(4)
    {root, proofs} = Merkle.build(set)

    # The first leaf's first proof step IS its sibling leaf; its second is the
    # interior node covering leaves 3 and 4. Presenting that interior hash as a
    # leaf with the remaining path must not verify.
    [_sibling, %{"h" => interior} | _] = hd(proofs)

    refute Merkle.verify(interior, [], root)
    refute Merkle.verify(interior, tl(hd(proofs)), root)
  end

  test "the empty set has a defined root and no proofs" do
    assert {root, []} = Merkle.build([])
    assert root == Merkle.empty_root()
    assert is_binary(root)
  end

  test "reordering the leaves changes the root" do
    set = leaves(5)

    refute Merkle.root(set) == Merkle.root(Enum.reverse(set))
  end
end
