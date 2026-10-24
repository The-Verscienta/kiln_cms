defmodule KilnCMSWeb.GraphqlRelatedOrderTest do
  @moduledoc """
  `related<Type>s` over GraphQL comes back in the order the editor set
  (#2025) — each link's `position` — including with a `limit`, which takes
  the first records of that order for each parent.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gql-related-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published(attrs, admin) do
    attrs
    |> Map.put_new(:slug, "gql-rel-#{System.unique_integer([:positive])}")
    |> CMS.create_post!(actor: admin)
    |> then(&CMS.publish_post!(&1, %{}, actor: admin))
  end

  defp gql(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/gql", Jason.encode!(%{query: query}))
    |> json_response(200)
  end

  test "relatedPosts lists them in the editor's order, a limit taking the first", %{conn: conn} do
    admin = admin()
    [a, b, c] = for t <- ~w(GA GB GC), do: published(%{title: t}, admin)
    source = published(%{title: "GSource", related_post_ids: [c.id, a.id, b.id]}, admin)

    body =
      gql(conn, """
      { postBySlug(slug: "#{source.slug}", locale: "en") {
          all: relatedPosts { title }
          firstTwo: relatedPosts(limit: 2) { title }
          relatedLinks
      } }
      """)

    assert %{"data" => %{"postBySlug" => post}} = body
    assert Enum.map(post["all"], & &1["title"]) == ~w(GC GA GB)
    assert Enum.map(post["firstTwo"], & &1["title"]) == ~w(GC GA)

    assert post["relatedLinks"] |> Enum.map(&Jason.decode!/1) |> Enum.map(& &1["title"]) ==
             ~w(GC GA GB)
  end
end
