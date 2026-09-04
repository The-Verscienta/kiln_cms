defmodule KilnCMS.Search.PassageTest do
  @moduledoc """
  The `passage` calc: the excerpt `/api/ask` grounds a generator on. Where
  `highlight` is 18 words around the match with `<mark>` tags, this is up to
  three fragments of 40 words with no tags — and when the headline still comes
  back short (the match cluster is the title-and-headings prefix of
  `search_text`, i.e. a query that names the record), the document's opening
  300 characters instead. "Huang Qi Botanical Description Astragalus" grounds
  no answer.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "passage-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "passage-#{System.unique_integer([:positive])}"

  defp load(record, query, actor) do
    locale = KilnCMS.I18n.default_locale()

    record
    |> Ash.load!(
      [passage: %{query: query, locale: locale}, highlight: %{query: query, locale: locale}],
      actor: actor
    )
  end

  @body "Astragalus membranaceus is a perennial herb of the legume family native to " <>
          "northern China. The root is harvested in the fourth year and used as a qi " <>
          "tonic that strengthens the defensive energy of the body and supports the " <>
          "spleen and the lungs. It is combined with Dang Shen in tonics for fatigue."

  test "a match in the body yields a long, mark-free passage" do
    actor = admin()

    page =
      CMS.create_page!(
        %{
          title: "Huang Qi",
          slug: slug(),
          blocks: [%{type: :rich_text, content: "<p>#{@body}</p>", order: 0}]
        },
        actor: actor
      )

    loaded = load(page, "defensive energy", actor)

    assert String.length(loaded.passage) >= 120
    assert loaded.passage =~ "defensive energy"
    refute loaded.passage =~ "<mark>"
    # The search-page snippet keeps its own tuning.
    assert loaded.highlight =~ "<mark>defensive</mark>"
  end

  test "a title-only match falls back to the document's opening text" do
    actor = admin()

    page =
      CMS.create_page!(
        %{
          title: "Huang Qi",
          slug: slug(),
          blocks: [%{type: :rich_text, content: "<p>#{@body}</p>", order: 0}]
        },
        actor: actor
      )

    loaded = load(page, "huang qi", actor)

    # Not "Huang Qi" and a heading: the passage reaches into the body.
    assert String.length(loaded.passage) >= 120
    assert loaded.passage =~ "legume family"
    assert String.starts_with?(loaded.passage, "Huang Qi")
  end

  test "a short document's passage is the whole document" do
    actor = admin()
    page = CMS.create_page!(%{title: "Huang Qi", slug: slug(), blocks: []}, actor: actor)

    loaded = load(page, "huang qi", actor)

    assert loaded.passage == String.trim(page.search_text)
  end
end
