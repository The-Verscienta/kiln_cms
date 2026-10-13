defmodule KilnCMS.Search.Chunker do
  @moduledoc """
  Splits the part of a document's `search_text` that lies past the embedder's
  window into overlapping windows of its own (#1940). Pure and deterministic:
  the same text, title and options always give the same chunks.

  ## Words, not tokens

  The window is a token count — `KilnCMS.Search.sequence_length/0`, 512 for
  every model Kiln supports — but a token count needs the model's tokenizer,
  and the lean build (no `KILN_ML`) has none: `KilnCMS.Search.ML.available?/0`
  is false there and the embedder is whatever adapter the site configured.
  Chunk boundaries must also be reproducible in tests that never load a
  model, and stable across a re-embed so `content_hash` reuse works. So the
  chunker counts **whitespace-separated words** and converts tokens to words
  at a fixed 0.6 words a token — about 1.7 tokens a word.

  That ratio is deliberately pessimistic. English prose runs at roughly 1.3
  WordPiece tokens a word; the long records that motivated this (#1940:
  botanical and chemical names, pinyin) run higher, and SentencePiece models
  (XLM-R) higher still. Erring towards *more* tokens per word errs towards
  two safe outcomes, never the unsafe one:

    * the window the document's own vector covers is **under**-estimated, so
      the first chunk starts a little before where the head truly ends and
      the two overlap more than they need to — but no text falls in a gap
      between them;
    * a chunk is sized to fit the window with room to spare, so the model
      does not silently truncate its tail.

  A tokenizer-exact chunker would waste less, and would have to be two
  compiled shapes (the ML build's tokenizer, the lean build's guess) whose
  boundaries differ — the stored `content_hash`es of a site that switched
  builds would all miss at once.

  ## The shape

  With `w` the window in words (`window_tokens × 0.6`):

    * the head — what the document's own vector sees — is taken to be the
      first `w` words, less the words of the `prefix` (`document_prefix/0`);
      a document no longer than that has no chunks;
    * each chunk is `title <> "\\n\\n" <> body`, the same title-as-context
      join `KilnCMS.Search.BlockIndexer` gives a block, so a chunk about "the
      roots" still knows whose roots. `body` is `w` words less the title's
      and the prefix's, and never fewer than `@min_body_words`;
    * chunk 0 starts `overlap` words before the head ends; each next chunk
      starts `overlap` words before the previous one ends; the last one
      reaches the end of the text;
    * at most `max_chunks` are produced — the tail of a document longer than
      that stays unembedded, as all of it was before.
  """

  # See the moduledoc, "Words, not tokens": 0.6 words a token, kept as an
  # integer ratio so a boundary never hangs on float rounding (`512 * 0.6`
  # is exact, but `n * 0.6` is not for every `n`).
  @words_per_token {3, 5}

  # A title long enough to eat the whole window must not leave a chunk with
  # no room for the text it exists to carry (or a stride of zero).
  @min_body_words 32

  @typedoc """
  Options: `:window_tokens` (the embedder's window), `:overlap_tokens`,
  `:max_chunks`, and `:prefix` (the document prefix the embedder prepends,
  which spends part of every window).
  """
  @type opts :: [
          window_tokens: pos_integer(),
          overlap_tokens: non_neg_integer(),
          max_chunks: non_neg_integer(),
          prefix: String.t()
        ]

  @doc """
  The texts to embed for the part of `text` past the window, in order — `[]`
  for a text the window already covers.

      iex> words = Enum.map_join(1..40, " ", &"w\#{&1}")
      iex> KilnCMS.Search.Chunker.chunks(words, "T",
      ...>   window_tokens: 20, overlap_tokens: 5, max_chunks: 8)
      ["T\\n\\nw10 w11 w12 w13 w14 w15 w16 w17 w18 w19 w20 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30 w31 w32 w33 w34 w35 w36 w37 w38 w39 w40"]
  """
  @spec chunks(String.t() | nil, String.t() | nil, opts()) :: [String.t()]
  def chunks(text, title, opts) do
    words = String.split(text || "")
    title = String.trim(title || "")
    prefix = Keyword.get(opts, :prefix, "")

    window = words_for(Keyword.fetch!(opts, :window_tokens))
    prefix_words = word_count(prefix)
    head = max(window - prefix_words, 1)
    body = max(window - prefix_words - word_count(title), @min_body_words)
    # An overlap at least as long as the body would never advance.
    overlap = min(words_for(Keyword.fetch!(opts, :overlap_tokens)), div(body, 2))

    words
    |> windows(length(words), max(head - overlap, 0), head, body, overlap)
    |> Enum.take(Keyword.fetch!(opts, :max_chunks))
    |> Enum.map(&join(title, &1))
  end

  @doc """
  How many words `tokens` tokens is taken to be — the conversion the
  moduledoc describes, exposed so a caller (and the tests) can reason in the
  same unit. Never less than 1.
  """
  @spec words_for(non_neg_integer()) :: pos_integer()
  def words_for(tokens) do
    {words, per_tokens} = @words_per_token
    max(div(tokens * words, per_tokens), 1)
  end

  # Nothing past the head: the document's own vector already saw it all.
  defp windows(_words, count, _start, head, _body, _overlap) when count <= head, do: []

  defp windows(words, count, start, _head, body, overlap) do
    start
    |> Stream.iterate(&(&1 + body - overlap))
    |> Stream.transform(:more, fn
      _start, :done -> {:halt, :done}
      start, :more -> {[Enum.slice(words, start, body)], next(start, body, count)}
    end)
    |> Enum.to_list()
  end

  # The chunk that reaches the end of the text is the last one.
  defp next(start, body, count) when start + body >= count, do: :done
  defp next(_start, _body, _count), do: :more

  defp join("", body), do: Enum.join(body, " ")
  defp join(title, body), do: title <> "\n\n" <> Enum.join(body, " ")

  defp word_count(text), do: text |> String.split() |> length()
end
