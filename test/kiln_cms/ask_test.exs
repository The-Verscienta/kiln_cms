defmodule KilnCMS.AskTest do
  @moduledoc "RAG retrieval + generation seam (issue #339)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Ask
  alias KilnCMS.CMS

  # A deterministic generator so the full pipeline (retrieve → generate → cite)
  # is testable without a model.
  defmodule StubGenerator do
    @behaviour KilnCMS.Ask.Generator
    @impl true
    def generate(question, sources) do
      {:ok, "Answer to '#{question}' from #{length(sources)} source(s)."}
    end
  end

  defmodule BoomGenerator do
    @behaviour KilnCMS.Ask.Generator
    @impl true
    def generate(_question, _sources), do: raise("model exploded")
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ask-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "ask-#{System.unique_integer([:positive])}"

  defp published(actor, title) do
    post = CMS.create_post!(%{title: title, slug: slug()}, actor: actor)
    CMS.publish_post!(post, %{}, actor: actor)
  end

  test "retrieves published content as cited sources; retrieval-only by default" do
    actor = admin()
    term = "zorptastic#{System.unique_integer([:positive])}"
    published(actor, "The #{term} handbook")

    # Anonymous (no actor) — published-only.
    result = Ask.answer(term)

    assert result.generated == false
    assert result.answer == nil
    source = Enum.find(result.sources, &String.contains?(&1.title, term))
    assert source, "expected a source matching #{term}"
    assert source.type == "post"
    assert source.url =~ "/blog/"
  end

  test "drafts never appear in the sources" do
    actor = admin()
    term = "zorptastic#{System.unique_integer([:positive])}"
    # Created but NOT published.
    CMS.create_post!(%{title: "Draft #{term}", slug: slug()}, actor: actor)

    result = Ask.answer(term)
    refute Enum.any?(result.sources, &String.contains?(&1.title, term))
  end

  test "synthesizes an answer when a generator is configured" do
    actor = admin()
    term = "zorptastic#{System.unique_integer([:positive])}"
    published(actor, "The #{term} handbook")

    result = Ask.answer(term, generator: StubGenerator)

    assert result.generated == true
    assert result.answer =~ "Answer to"
    assert result.sources != []
  end

  test "a generator that raises degrades to retrieval-only (never crashes the ask)" do
    actor = admin()
    term = "zorptastic#{System.unique_integer([:positive])}"
    published(actor, "The #{term} handbook")

    result = Ask.answer(term, generator: BoomGenerator)

    assert result.generated == false
    assert result.answer == nil
    # Retrieval still succeeded.
    assert Enum.any?(result.sources, &String.contains?(&1.title, term))
  end

  test "an empty question returns no sources and no answer" do
    assert %{answer: nil, generated: false, sources: []} = Ask.answer("   ")
  end

  describe "why generation did not run (#853)" do
    # `generated: false` alone cannot be acted on: "this deployment does not
    # generate" and "you asked too fast" look identical, and only the second has
    # a recovery. Each case below pins the reason AND the retry deadline, since
    # the deadline is the whole reason a client would treat them differently.

    test "no generator configured reports :disabled, with no retry deadline" do
      actor = admin()
      term = "zorptastic#{System.unique_integer([:positive])}"
      published(actor, "The #{term} handbook")

      result = Ask.answer(term, generator: nil)

      assert result.generation == :disabled
      assert result.retry_after == nil
      assert result.generated == false
      assert result.sources != []
    end

    test "a generator that raises reports :failed, with no retry deadline" do
      actor = admin()
      term = "zorptastic#{System.unique_integer([:positive])}"
      published(actor, "The #{term} handbook")

      result = Ask.answer(term, generator: BoomGenerator)

      assert result.generation == :failed
      # Deliberately nil: the generator failing says nothing about when it will
      # stop failing, and inventing a number would be worse than saying nothing.
      assert result.retry_after == nil
    end

    # The `:rate_limited` case lives in `KilnCMS.Ask.GeneratorTest` instead —
    # it has to swap global app env to tighten the budget, and that file is
    # `async: false` for exactly that reason.

    test "a generated answer reports nil, the one value that means success" do
      actor = admin()
      term = "zorptastic#{System.unique_integer([:positive])}"
      published(actor, "The #{term} handbook")

      result = Ask.answer(term, generator: StubGenerator)

      assert result.generation == nil
      assert result.retry_after == nil
      assert result.generated == true
    end

    test "a blank question reports :no_question rather than looking like success" do
      result = Ask.answer("   ")

      assert result.generation == :no_question
      assert result.retry_after == nil
      assert result.generated == false
    end
  end

  describe "source ranking and excerpts (the Shen-beat-Huang-Qi report)" do
    # A deployment asked how two herbs differ and was cited a concept page
    # first and the two herbs seventh and eighth: `retrieve/2` flattened the
    # sections in registry order — sorted by label, so "Concept" before
    # "Herb" — under a comment claiming to interleave by strength, and cited
    # excerpts of five words. These pin the fixes.

    test "sources are ranked by fused score across content types, not by type label" do
      actor = admin()
      term = "zorptastic#{System.unique_integer([:positive])}"

      # "Page" sorts before "Post" in the registry. The page matches the term
      # in its SEO description only — one leg, the keyword one. The post
      # carries it in its title, so the fuzzy title leg returns it too and
      # its fused score is the higher of the two. Registry order would cite
      # the page first.
      page =
        CMS.create_page!(
          %{title: "Unrelated page", slug: slug(), seo_description: "About #{term}"},
          actor: actor
        )

      CMS.publish_page!(page, %{}, actor: actor)
      published(actor, "The #{term} handbook")

      result = Ask.answer(term)

      assert [first, second | _] = result.sources
      assert first.type == "post"
      assert first.title == "The #{term} handbook"
      assert second.type == "page"
      assert first.score > second.score
      assert first.legs == [:keyword, :fuzzy]
      assert second.legs == [:keyword]
    end

    test "an excerpt is a grounding-sized passage, not a five-word title fragment" do
      actor = admin()
      term = "zorptastic#{System.unique_integer([:positive])}"

      body =
        "Astragalus membranaceus is a perennial herb of the legume family native to " <>
          "northern China. The root is harvested in the fourth year and used as a qi " <>
          "tonic that strengthens the defensive energy of the body and supports the " <>
          "spleen and the lungs."

      post =
        CMS.create_post!(
          %{
            title: "The #{term} monograph",
            slug: slug(),
            blocks: [%{type: :rich_text, content: "<p>#{body}</p>", order: 0}]
          },
          actor: actor
        )

      CMS.publish_post!(post, %{}, actor: actor)

      result = Ask.answer(term)
      source = Enum.find(result.sources, &(&1.title == "The #{term} monograph"))
      assert source, "expected the monograph among the sources"

      # The query matches only the title; the old 18-word highlight, stripped
      # of its marks, handed a generator the title and little else.
      assert String.length(source.excerpt) >= 120
      assert source.excerpt =~ "legume family"
      refute source.excerpt =~ "<mark>"
    end
  end
end
