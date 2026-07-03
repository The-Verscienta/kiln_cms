defmodule KilnCMS.Search.SuggestTest do
  @moduledoc """
  The "did you mean" suggestion: the most word-similar published title via the
  trigram autocomplete machinery, with a jaro floor so unrelated titles never
  get suggested — and never parroting the query back.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Search

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sug-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "sug-#{System.unique_integer([:positive])}"

  test "suggests the closest published title for a near-miss" do
    actor = admin()
    page = CMS.create_page!(%{title: "Fermentation Basics", slug: slug()}, actor: actor)
    CMS.publish_page!(page, %{}, actor: actor)

    assert Search.suggest("fermentaton", authorize?: true) == "Fermentation Basics"
  end

  test "anonymous callers never get unpublished titles suggested" do
    actor = admin()
    _draft = CMS.create_page!(%{title: "Xylophone Secrets", slug: slug()}, actor: actor)

    assert Search.suggest("xylophon", authorize?: true) == nil
  end

  test "nothing close means no suggestion" do
    assert Search.suggest("zqxvbnmlkj", authorize?: true) == nil
  end
end
