defmodule KilnCMS.CMS.AutocompleteTest do
  @moduledoc """
  Phase C: `:autocomplete` returns same-locale title suggestions by prefix
  (case-insensitive) or word-level trigram similarity (typo-tolerant, via
  pg_trgm), ordered by similarity and capped at 10.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ac-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "ac-#{uniq()}"

  test "matches by case-insensitive prefix" do
    admin = admin()
    tag = "Zonk#{uniq()}"
    page = CMS.create_page!(%{title: "#{tag} Programming", slug: slug()}, actor: admin)

    titles = CMS.autocomplete_pages!(String.downcase(tag), actor: admin) |> Enum.map(& &1.id)
    assert page.id in titles
  end

  test "tolerates a typo via word-trigram similarity" do
    admin = admin()
    marker = "Quibble#{uniq()}"
    page = CMS.create_page!(%{title: "#{marker} Programming", slug: slug()}, actor: admin)

    # "Programmng" (missing i) is not a prefix, but is word-similar to
    # "Programming".
    ids = CMS.autocomplete_pages!("Programmng", actor: admin) |> Enum.map(& &1.id)
    assert page.id in ids
  end

  test "scopes to the default locale" do
    admin = admin()
    tag = "Locale#{uniq()}"
    en = CMS.create_page!(%{title: "#{tag} hello", slug: slug(), locale: "en"}, actor: admin)
    fr = CMS.create_page!(%{title: "#{tag} bonjour", slug: slug(), locale: "fr"}, actor: admin)

    ids = CMS.autocomplete_pages!(tag, actor: admin) |> Enum.map(& &1.id)
    assert en.id in ids
    refute fr.id in ids
  end

  test "caps results at 10" do
    admin = admin()
    tag = "Many#{uniq()}"
    for n <- 1..13, do: CMS.create_page!(%{title: "#{tag} #{n}", slug: slug()}, actor: admin)

    assert length(CMS.autocomplete_pages!(tag, actor: admin)) == 10
  end
end
