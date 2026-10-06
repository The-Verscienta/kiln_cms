defmodule KilnCMS.Organize.TermDuplicateCalibrationTest do
  @moduledoc """
  What `near_duplicate_term_threshold/0` does at the value shipped (#1596),
  read off `KilnCMS.TermDuplicateCorpus`'s recorded distances — no model
  needed. Fails if the default drifts into either failure: a health report
  that calls distinct tags the same, or one that finds no duplicates at all.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Search
  alias KilnCMS.TermDuplicateCorpus

  defp flagged(kind) do
    t = Search.near_duplicate_term_threshold()
    rows = Enum.filter(TermDuplicateCorpus.pairs(), &(elem(&1, 2) == kind))
    {Enum.count(rows, &(elem(&1, 3) <= t)), length(rows)}
  end

  test "is a number cosine distance can produce" do
    t = Search.near_duplicate_term_threshold()
    assert is_number(t) and t > 0 and t <= 2.0
  end

  test "flags at least half of the pairs a person would merge" do
    {kept, total} = flagged(:same)
    assert kept / total >= 0.5, "only #{kept} of #{total} duplicate pairs flagged"
  end

  test "flags no related-but-distinct or unrelated pair" do
    assert {0, _} = flagged(:related)
    assert {0, _} = flagged(:unrelated)
  end
end
