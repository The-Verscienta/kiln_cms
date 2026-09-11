defmodule KilnCMSWeb.JsonApiSemanticFloorTest do
  @moduledoc """
  The per-type `semantic-search` JSON:API routes apply `semantic_max_distance`
  themselves (no fusion to leave it to) and exempt a row whose title the
  query names, as the title leg does in hybrid search — so a floor set for
  the search page no longer drops named records from the route delivery
  sites use (the 2026-09-04 search-ranking report, D2).
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.merge(original, KilnCMS.StubEmbedder.search_env() ++ [semantic_max_distance: 0.0])
    )

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "jsf-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_post(admin, title) do
    post =
      CMS.create_post!(%{title: title, slug: "jsf-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    CMS.publish_post!(post, %{}, actor: admin)
  end

  test "the published route keeps a record the query names by a flagged field past the floor",
       %{conn: conn} do
    admin = admin()

    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: "latin_name",
        label: "Latin",
        field_type: :string,
        names_record: true
      },
      actor: admin
    )

    post =
      CMS.create_post!(
        %{
          title: "Huang Qi",
          slug: "jsf-#{System.unique_integer([:positive])}",
          custom_fields: %{"latin_name" => "Astragalus membranaceus"}
        },
        actor: admin
      )

    named = CMS.publish_post!(post, %{}, actor: admin)
    _other = published_post(admin, "Dang Shen")
    KilnCMS.DataCase.drain_oban()

    body =
      conn
      |> get(
        "/api/json/posts/semantic-search/published?query=astragalus%20membranaceus%20root&locale=en"
      )
      |> json_response(200)

    assert Enum.map(body["data"], & &1["id"]) == [named.id]
  end

  test "the published route keeps a record the query names past the floor", %{conn: conn} do
    admin = admin()
    named = published_post(admin, "Pad Thai")
    _other = published_post(admin, "Tom Yum")
    KilnCMS.DataCase.drain_oban()

    body =
      conn
      |> get("/api/json/posts/semantic-search/published?query=pad%20thai%20tom&locale=en")
      |> json_response(200)

    # A floor of 0 admits nothing by distance; "Pad Thai" is named, "Tom
    # Yum" is not ("tom" alone is not its title as a phrase).
    assert Enum.map(body["data"], & &1["id"]) == [named.id]

    body =
      conn
      |> get("/api/json/posts/semantic-search/published?query=nothing%20like%20this&locale=en")
      |> json_response(200)

    assert body["data"] == []
  end
end
