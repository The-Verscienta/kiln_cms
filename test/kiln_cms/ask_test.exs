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
end
