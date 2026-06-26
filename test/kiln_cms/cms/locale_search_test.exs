defmodule KilnCMS.CMS.LocaleSearchTest do
  @moduledoc """
  `:search` is locale-aware (Phase A): results are scoped to one locale and
  stemmed with that locale's Postgres text-search config (`kiln_regconfig/1`),
  and the trigger-maintained `search_vector` is weighted so title hits outrank
  body hits.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "loc-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "loc-#{System.unique_integer([:positive])}"

  # The code interface only takes `query` positionally; pass an explicit locale
  # via `for_read`.
  defp search(query, locale, actor) do
    KilnCMS.CMS.Page
    |> Ash.Query.for_read(:search, %{query: query, locale: locale})
    |> Ash.read!(actor: actor)
  end

  test "scopes results to the requested locale" do
    admin = admin()
    tag = "wombat#{System.unique_integer([:positive])}"
    en = CMS.create_page!(%{title: "#{tag} english", slug: slug(), locale: "en"}, actor: admin)
    fr = CMS.create_page!(%{title: "#{tag} français", slug: slug(), locale: "fr"}, actor: admin)

    en_ids = search(tag, "en", admin) |> Enum.map(& &1.id)
    fr_ids = search(tag, "fr", admin) |> Enum.map(& &1.id)

    assert en.id in en_ids
    refute fr.id in en_ids
    assert fr.id in fr_ids
    refute en.id in fr_ids
  end

  test "stems with the locale's language config" do
    admin = admin()
    # "fromage"/"fromages" stem to the same root under French, but not under the
    # `simple` config — so a plural query matching the singular proves French
    # stemming is applied.
    page =
      CMS.create_page!(%{title: "J'aime le fromage", slug: slug(), locale: "fr"}, actor: admin)

    ids = search("fromages", "fr", admin) |> Enum.map(& &1.id)
    assert page.id in ids
  end

  test "defaults to the configured default locale (en)" do
    admin = admin()
    tag = "platypus#{System.unique_integer([:positive])}"
    page = CMS.create_page!(%{title: tag, slug: slug()}, actor: admin)

    # No locale arg → default "en"; the page defaults to "en" too.
    assert [found] = CMS.search_pages!(tag, actor: admin)
    assert found.id == page.id
  end

  test "ranks title matches above body matches (weighted vector)" do
    admin = admin()
    term = "cheese#{System.unique_integer([:positive])}"

    body_match =
      CMS.create_page!(
        %{
          title: "Dairy products",
          slug: slug(),
          blocks: [%{type: :rich_text, content: "<p>A note about #{term}.</p>", order: 0}]
        },
        actor: admin
      )

    title_match = CMS.create_page!(%{title: "All about #{term}", slug: slug()}, actor: admin)

    ids = CMS.search_pages!(term, actor: admin) |> Enum.map(& &1.id)
    assert ids == [title_match.id, body_match.id]
  end
end
