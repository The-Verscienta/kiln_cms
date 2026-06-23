defmodule KilnCMSWeb.SearchGraphqlTest do
  @moduledoc """
  Phase C: search/autocomplete are exposed over GraphQL (`/gql`). Anonymous
  queries go through the read policy, so only published content matches.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  @schema KilnCMSWeb.GraphqlSchema

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gql-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "gql-#{System.unique_integer([:positive])}"

  defp published(title, admin) do
    title
    |> then(&CMS.create_page!(%{title: &1, slug: slug()}, actor: admin))
    |> CMS.publish_page!(%{}, actor: admin)
  end

  test "searchPages returns published matches and hides drafts" do
    admin = admin()
    term = "graphqlonly#{System.unique_integer([:positive])}"
    page = published("#{term} live", admin)
    _draft = CMS.create_page!(%{title: "#{term} draft", slug: slug()}, actor: admin)

    query = """
    query Search($q: String!) {
      searchPages(query: $q) { id title }
    }
    """

    assert {:ok, %{data: %{"searchPages" => results}}} =
             Absinthe.run(query, @schema, variables: %{"q" => term})

    ids = Enum.map(results, & &1["id"])
    assert page.id in ids
    assert length(ids) == 1
  end

  test "autocompletePages returns title suggestions" do
    admin = admin()
    term = "Autoql#{System.unique_integer([:positive])}"
    page = published("#{term} suggestion", admin)

    query = """
    query Auto($p: String!) {
      autocompletePages(prefix: $p) { id title }
    }
    """

    assert {:ok, %{data: %{"autocompletePages" => results}}} =
             Absinthe.run(query, @schema, variables: %{"p" => term})

    assert page.id in Enum.map(results, & &1["id"])
  end
end
