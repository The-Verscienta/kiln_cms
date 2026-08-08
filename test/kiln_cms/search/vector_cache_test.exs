defmodule KilnCMS.Search.VectorCacheTest do
  @moduledoc """
  Memoization of the compute-on-demand embedding path (#964).

  The property under test is a *cost* one, so these count embedder calls rather
  than asserting on vectors: an assertion that the answer is right would pass
  just as well with the cache doing nothing.
  """
  # async: false — swaps the global embedder and shares one Cachex instance.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search.{BlockIndexer, VectorCache}

  # Counts calls in the test process's own counter, so concurrent suites cannot
  # perturb it — the counter name is unique per test.
  defmodule CountingEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      :counters.add(:persistent_term.get({__MODULE__, :counter}), 1, 1)
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  defmodule BrokenEmbedder do
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(_text), do: {:error, :unavailable}
  end

  setup do
    counter = :counters.new(1, [])
    :persistent_term.put({CountingEmbedder, :counter}, counter)

    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.merge(original, semantic: true, embedder: CountingEmbedder)
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Search, original)
      Cachex.clear(VectorCache.cache_name())
    end)

    # A shared instance, so start from a known state rather than inheriting
    # whatever another test in this file embedded.
    Cachex.clear(VectorCache.cache_name())

    %{counter: counter}
  end

  defp calls(counter), do: :counters.get(counter, 1)

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "veccache-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "veccache-#{System.unique_integer([:positive])}"

  defp page(actor, paragraphs) do
    blocks =
      paragraphs
      |> Enum.with_index()
      |> Enum.map(fn {text, i} -> %{type: :rich_text, content: "<p>#{text}</p>", order: i} end)

    CMS.create_page!(%{title: "Doc #{System.unique_integer()}", slug: slug(), blocks: blocks},
      actor: actor
    )
  end

  test "the same text is embedded once, however many times it is asked for", %{counter: counter} do
    first = VectorCache.embed("a paragraph")
    assert is_list(first)
    assert calls(counter) == 1

    # The VALUE, not just that something came back: a key collision or a commit
    # that stored the wrong term would satisfy `is_list/1` and nothing else.
    assert VectorCache.embed("a paragraph") == first
    assert VectorCache.embed("a paragraph") == first
    assert calls(counter) == 1, "a repeated input was re-embedded"

    # …and a different input really is a different entry.
    refute VectorCache.embed("a different paragraph") == first
    assert calls(counter) == 2
  end

  test "entries expire" do
    # `Cachex` silently ignores unknown options, so passing `ttl:` instead of
    # `expire:` compiles, runs, and leaves every entry immortal — the trap
    # `KilnCMS.Firing.Cache` documents. Without this assertion the only
    # reclamation would be the entry cap, which no test reaches either.
    assert is_list(VectorCache.embed("expiring"))

    assert {:ok, ttl} = Cachex.ttl(VectorCache.cache_name(), VectorCache.key("expiring"))
    assert is_integer(ttl) and ttl > 0
  end

  test "swapping the embedder does not serve the previous one's vectors" do
    # `model` is a compile-time constant in practice, so it is not on its own a
    # description of the embedding function — `embedder` and `dim` change the
    # vector while it stays put. Keyed on `model` alone, this returns the first
    # embedder's numbers: well-formed, and from a different space.
    defmodule OnesEmbedder do
      @behaviour KilnCMS.Search.Embedder
      @impl true
      def embed(_text), do: {:ok, List.duplicate(1.0, 384)}
    end

    defmodule TwosEmbedder do
      @behaviour KilnCMS.Search.Embedder
      @impl true
      def embed(_text), do: {:ok, List.duplicate(2.0, 384)}
    end

    previous = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, previous) end)

    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.put(previous, :embedder, OnesEmbedder))
    assert [1.0 | _] = VectorCache.embed("same text")

    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.put(previous, :embedder, TwosEmbedder))
    assert [2.0 | _] = VectorCache.embed("same text")
  end

  test "editing one block re-embeds one block, not the document", %{counter: counter} do
    actor = admin()
    doc = page(actor, ["alpha one", "beta two", "gamma three", "delta four"])

    assert length(BlockIndexer.block_vectors(doc)) == 4
    assert calls(counter) == 4

    edited =
      CMS.update_page!(
        doc,
        %{
          blocks: [
            %{type: :rich_text, content: "<p>alpha one</p>", order: 0},
            %{type: :rich_text, content: "<p>beta two</p>", order: 1},
            %{type: :rich_text, content: "<p>gamma three REWRITTEN</p>", order: 2},
            %{type: :rich_text, content: "<p>delta four</p>", order: 3}
          ]
        },
        actor: actor
      )

    assert length(BlockIndexer.block_vectors(edited)) == 4

    # The stored path gets this reuse from `content_hash`; this is its
    # equivalent for the compute-on-demand path.
    assert calls(counter) == 5, "editing one paragraph re-embedded the whole document"
  end

  test "the title is part of the input, so retitling does re-embed", %{counter: counter} do
    # Not a bug — embeddings are hierarchical, so the ancestor context is
    # genuinely part of what each block means. Pinned so the cost is a known
    # consequence rather than a surprise.
    actor = admin()
    doc = page(actor, ["alpha one", "beta two"])

    _ = BlockIndexer.block_vectors(doc)
    assert calls(counter) == 2

    retitled = CMS.update_page!(doc, %{title: "A different title"}, actor: actor)
    _ = BlockIndexer.block_vectors(retitled)

    assert calls(counter) == 4
  end

  test "two documents sharing a paragraph share its vector", %{counter: counter} do
    actor = admin()

    # Same title AND same body: the input is `"#{title}\n\n#{text}"`, so the
    # titles have to match for the paragraph's input to be identical.
    one = CMS.create_page!(%{title: "Shared", slug: slug(), blocks: para("common")}, actor: actor)
    two = CMS.create_page!(%{title: "Shared", slug: slug(), blocks: para("common")}, actor: actor)

    _ = BlockIndexer.block_vectors(one)
    assert calls(counter) == 1

    _ = BlockIndexer.block_vectors(two)
    assert calls(counter) == 1, "an identical paragraph was embedded twice"
  end

  defp para(text), do: [%{type: :rich_text, content: "<p>#{text}</p>", order: 0}]

  test "an embedder failure is not memoized" do
    previous = Application.get_env(:kiln_cms, KilnCMS.Search, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.put(previous, :embedder, BrokenEmbedder)
    )

    assert VectorCache.embed("transient") == nil

    # No entry at all, which is the part `Cachex.fetch/3`'s behaviour hides:
    # it re-runs its fallback when the stored value is `nil`, so a committed
    # failure would never be *served* — but it would still occupy one of this
    # instance's capped entries, and an outage would evict real vectors to hold
    # placeholders that can only produce a miss.
    assert {:ok, false} =
             Cachex.exists?(
               VectorCache.cache_name(),
               {KilnCMS.Search.model(), key("transient")}
             )

    # And the outage clearing is enough; nothing has to expire first.
    Application.put_env(:kiln_cms, KilnCMS.Search, previous)
    assert is_list(VectorCache.embed("transient"))
  end

  defp key(text), do: :crypto.hash(:sha256, text)

  test "the vector cache is a different instance from the delivery cache" do
    # The whole point of #964: an editing session must not evict the
    # `published:record:*` entries `Firing.Delivery` serves from during a
    # database outage.
    refute VectorCache.cache_name() == KilnCMS.Cache.cache_name()

    Cachex.clear(VectorCache.cache_name())
    before = Cachex.size!(KilnCMS.Cache.cache_name())

    for n <- 1..25, do: VectorCache.embed("paragraph #{n}")

    assert Cachex.size!(VectorCache.cache_name()) >= 25
    assert Cachex.size!(KilnCMS.Cache.cache_name()) == before
  end
end
