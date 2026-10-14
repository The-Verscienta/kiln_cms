defmodule KilnCMS.Search.ChunkerTest do
  @moduledoc """
  `KilnCMS.Search.Chunker` (#1940) is pure: chunk boundaries and the overlap
  are a function of the text, the title and the options alone. These pin the
  arithmetic, and the one property the whole feature rests on — that the
  head window and the chunks together leave no word unembedded.

  Also pins `KilnCMS.Search.nearest_sections/1`, the min-per-document merge
  that lets a chunk vouch for a document in the block leg.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Search
  alias KilnCMS.Search.Chunker

  doctest Chunker

  # `w1 w2 … wN` — every word names its own position.
  defp words(n), do: Enum.map_join(1..n, " ", &"w#{&1}")

  defp body_words(chunk),
    do: chunk |> String.split("\n\n", parts: 2) |> List.last() |> String.split()

  # 100 tokens is 60 words; a 10-token overlap is 6.
  @opts [window_tokens: 100, overlap_tokens: 10, max_chunks: 8]

  test "a text the window already covers has no chunks" do
    assert Chunker.chunks(words(60), "Title", @opts) == []
    assert Chunker.chunks("", "Title", @opts) == []
    assert Chunker.chunks(nil, nil, @opts) == []
  end

  test "boundaries and overlap are exact" do
    # Head: w1..w60. Body: 60 words less the one-word title = 59. The first
    # chunk starts 6 words before the head ends (w55); each next one starts 6
    # words before the previous ends; the last reaches w200.
    chunks = Chunker.chunks(words(200), "Title", @opts)

    assert Enum.map(chunks, &(&1 |> body_words() |> then(fn ws -> {hd(ws), List.last(ws)} end))) ==
             [{"w55", "w113"}, {"w108", "w166"}, {"w161", "w200"}]

    # Every chunk carries the title as context, the way a block does.
    assert Enum.all?(chunks, &String.starts_with?(&1, "Title\n\n"))

    # Consecutive chunks share exactly the overlap.
    for [a, b] <- Enum.chunk_every(chunks, 2, 1, :discard) do
      assert Enum.take(body_words(a), -6) == Enum.take(body_words(b), 6)
    end
  end

  test "the same input always gives the same chunks" do
    text = words(437)
    assert Chunker.chunks(text, "A title", @opts) == Chunker.chunks(text, "A title", @opts)
  end

  test "whitespace is normalized, so reflowing the text moves no boundary" do
    reflowed = words(200) |> String.replace(" ", "\n  ")
    assert Chunker.chunks(reflowed, "Title", @opts) == Chunker.chunks(words(200), "Title", @opts)
  end

  test "the head and the chunks leave no word out, whatever the length" do
    for n <- [61, 62, 100, 119, 120, 121, 333, 480] do
      chunks = Chunker.chunks(words(n), "Title", Keyword.put(@opts, :max_chunks, 100))
      covered = MapSet.new(Enum.map(1..60, &"w#{&1}") ++ Enum.flat_map(chunks, &body_words/1))
      assert MapSet.size(covered) == n, "a gap at n = #{n}"
      # And the last chunk is the one that reaches the end — no empty tail chunk.
      assert chunks |> List.last() |> body_words() |> List.last() == "w#{n}"
    end
  end

  test "the document prefix spends part of every window, the head's included" do
    # One prefix word: the head is taken to end at w59, so chunk 0 starts at
    # w54, and the body is 60 - 1 (prefix) - 1 (title) = 58 words.
    [first | _] = Chunker.chunks(words(200), "Title", Keyword.put(@opts, :prefix, "passage: "))
    ws = body_words(first)
    assert {hd(ws), length(ws)} == {"w54", 58}
  end

  test "a long title shrinks the body, never below the floor" do
    title = Enum.map_join(1..80, " ", &"t#{&1}")
    [first | _] = Chunker.chunks(words(300), title, @opts)
    assert first |> body_words() |> length() == 32
  end

  test "at most max_chunks are produced; the rest stays unembedded" do
    assert length(Chunker.chunks(words(5_000), "Title", @opts)) == 8
    assert Chunker.chunks(words(5_000), "Title", Keyword.put(@opts, :max_chunks, 0)) == []
  end

  test "no title, no context line" do
    [first | _] = Chunker.chunks(words(200), nil, @opts)
    refute first =~ "\n"
  end

  test "tokens convert to words at the documented ratio" do
    assert Chunker.words_for(512) == 307
    assert Chunker.words_for(64) == 38
    assert Chunker.words_for(0) == 1
  end

  describe "Search.nearest_sections/1 — the block leg's per-document min" do
    test "each document is kept once, at the smallest distance any list gave it" do
      blocks = [{"a", 0.5}, {"b", 0.6}]
      chunks = [{"b", 0.1}, {"a", 0.9}, {"c", 0.7}]

      assert Search.nearest_sections([blocks, chunks]) == [{"b", 0.1}, {"a", 0.5}, {"c", 0.7}]
      # Order of the lists does not matter.
      assert Search.nearest_sections([chunks, blocks]) == [{"b", 0.1}, {"a", 0.5}, {"c", 0.7}]
    end

    test "a single list keeps its own order, ties included" do
      rows = [{"x", 0.2}, {"y", 0.2}, {"z", 0.3}]
      assert Search.nearest_sections([rows, []]) == rows
    end
  end
end
