defmodule KilnCMS.Search.PassageTest do
  @moduledoc """
  The `passage` calc: the excerpt `/api/ask` grounds a generator on. Where
  `highlight` is 18 words around the match with `<mark>` tags, this is up to
  three fragments of 40 words with no tags — and when the headline still comes
  back short (the match cluster is the title-and-headings prefix of
  `search_text`, i.e. a query that names the record), the document's opening
  300 characters instead. "Pad Thai Ingredients Method Sen Lek" grounds no
  answer.
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

  @body "Sen lek is a flat rice noodle of the kway teow family made across central " <>
          "Thailand. The noodle is soaked overnight and stir-fried in a hot wok as a " <>
          "thai street staple, with a tamarind sauce that balances the sour notes of " <>
          "the dish and the sweet palm sugar. It is served with Tom Yum at night markets."

  test "a match in the body yields a long, mark-free passage" do
    actor = admin()

    page =
      CMS.create_page!(
        %{
          title: "Pad Thai",
          slug: slug(),
          blocks: [%{type: :rich_text, content: "<p>#{@body}</p>", order: 0}]
        },
        actor: actor
      )

    loaded = load(page, "tamarind sauce", actor)

    assert String.length(loaded.passage) >= 120
    assert loaded.passage =~ "tamarind sauce"
    refute loaded.passage =~ "<mark>"
    # The search-page snippet keeps its own tuning.
    assert loaded.highlight =~ "<mark>tamarind</mark>"
  end

  test "a title-only match falls back to the document's opening text" do
    actor = admin()

    page =
      CMS.create_page!(
        %{
          title: "Pad Thai",
          slug: slug(),
          blocks: [%{type: :rich_text, content: "<p>#{@body}</p>", order: 0}]
        },
        actor: actor
      )

    loaded = load(page, "pad thai", actor)

    # Not "Pad Thai" and a heading: the passage reaches into the body.
    assert String.length(loaded.passage) >= 120
    assert loaded.passage =~ "kway teow family"
    assert String.starts_with?(loaded.passage, "Pad Thai")
  end

  test "a short document's passage is the whole document" do
    actor = admin()
    page = CMS.create_page!(%{title: "Pad Thai", slug: slug(), blocks: []}, actor: actor)

    loaded = load(page, "pad thai", actor)

    assert loaded.passage == String.trim(page.search_text)
  end
end
