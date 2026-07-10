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

  # #297: the published-only twins pin `state == :published` server-side. The
  # base queries rely on the read policy, so an authenticated editor/admin
  # actor (e.g. a bearer API key minted on such an account) matches drafts —
  # the twins never do, whatever the credential.
  test "searchPublishedPages hides drafts even for an admin actor" do
    admin = admin()
    term = "gqlpub#{System.unique_integer([:positive])}"
    page = published("#{term} live", admin)
    draft = CMS.create_page!(%{title: "#{term} draft", slug: slug()}, actor: admin)

    base = """
    query Search($q: String!) {
      searchPages(query: $q) { id }
    }
    """

    published_twin = """
    query Search($q: String!) {
      searchPublishedPages(query: $q) { id }
    }
    """

    opts = [variables: %{"q" => term}, context: %{actor: admin}]

    # The base query widens to drafts for the admin actor — the trap.
    assert {:ok, %{data: %{"searchPages" => base_results}}} =
             Absinthe.run(base, @schema, opts)

    base_ids = Enum.map(base_results, & &1["id"])
    assert Enum.sort(base_ids) == Enum.sort([page.id, draft.id])

    # The twin filters server-side under the same actor.
    assert {:ok, %{data: %{"searchPublishedPages" => twin_results}}} =
             Absinthe.run(published_twin, @schema, opts)

    assert Enum.map(twin_results, & &1["id"]) == [page.id]
  end

  test "autocompletePublishedPages hides draft titles from an admin actor" do
    admin = admin()
    term = "Gqlpubauto#{System.unique_integer([:positive])}"
    page = published("#{term} live", admin)
    _draft = CMS.create_page!(%{title: "#{term} draft", slug: slug()}, actor: admin)

    query = """
    query Auto($p: String!) {
      autocompletePublishedPages(prefix: $p) { id }
    }
    """

    assert {:ok, %{data: %{"autocompletePublishedPages" => results}}} =
             Absinthe.run(query, @schema,
               variables: %{"p" => term},
               context: %{actor: admin}
             )

    assert Enum.map(results, & &1["id"]) == [page.id]
  end
end
