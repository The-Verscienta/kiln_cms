defmodule KilnCMS.Firing.PointInTimeTest do
  @moduledoc "Point-in-time reconstruction of published content (#338)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Firing.PointInTime

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pit-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "pit-#{System.unique_integer([:positive])}"

  test "reconstructs the published state as of a past date" do
    admin = admin()
    org = KilnCMS.Accounts.default_org_id()
    post = CMS.create_post!(%{title: "Original guidance", slug: slug()}, actor: admin)
    post = CMS.publish_post!(post, %{}, actor: admin)

    as_of = DateTime.utc_now()

    # Revise: unpublish → edit → republish (the workflow to change live content).
    post = CMS.unpublish_post!(post, %{}, actor: admin)
    post = CMS.update_post!(post, %{title: "Revised guidance"}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    assert {:ok, historical, published_at} =
             PointInTime.read(org, CMS.Post, post.id, :json, as_of)

    assert historical["title"] == "Original guidance"
    assert %DateTime{} = published_at

    assert {:ok, current, _} = PointInTime.read(org, CMS.Post, post.id, :json, DateTime.utc_now())
    assert current["title"] == "Revised guidance"
  end

  test "fires any surface for the historical state" do
    admin = admin()
    org = KilnCMS.Accounts.default_org_id()
    post = CMS.create_post!(%{title: "Heading", slug: slug()}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    assert {:ok, %{"@context" => "https://schema.org"}, _} =
             PointInTime.read(org, CMS.Post, post.id, :json_ld, DateTime.utc_now())
  end

  test "returns not_published before the first publish" do
    admin = admin()
    org = KilnCMS.Accounts.default_org_id()
    post = CMS.create_post!(%{title: "Draft only", slug: slug()}, actor: admin)
    before_publish = DateTime.utc_now()
    CMS.publish_post!(post, %{}, actor: admin)

    assert {:error, :not_published} =
             PointInTime.read(org, CMS.Post, post.id, :json, before_publish)
  end

  describe "index/4 — the collection as of a date (#338 phase 2)" do
    test "lists what was published then, respects unpublish, and replays titles" do
      admin = admin()

      a = CMS.create_post!(%{title: "Alpha v1", slug: slug()}, actor: admin)
      a = CMS.publish_post!(a, %{}, actor: admin)
      b = CMS.create_post!(%{title: "Beta", slug: slug()}, actor: admin)
      b = CMS.publish_post!(b, %{}, actor: admin)

      both_live = DateTime.utc_now()

      # Later: B is unpublished and A is renamed (without re-publishing).
      CMS.unpublish_post!(b, %{}, actor: admin)
      CMS.update_post!(a, %{title: "Alpha v2"}, actor: admin)
      after_changes = DateTime.utc_now()

      org = a.org_id

      then_entries = PointInTime.index(org, CMS.Post, both_live)
      then_slugs = Enum.map(then_entries, & &1.slug)
      assert a.slug in then_slugs
      assert b.slug in then_slugs
      # Title as of the last publish ≤ as_of — not today's rename.
      assert %{title: "Alpha v1"} = Enum.find(then_entries, &(&1.slug == a.slug))

      now_entries = PointInTime.index(org, CMS.Post, after_changes)
      now_slugs = Enum.map(now_entries, & &1.slug)
      assert a.slug in now_slugs
      refute b.slug in now_slugs
    end

    test "the REST collection route and the GraphQL twin agree" do
      admin = admin()
      post = CMS.create_post!(%{title: "Twin", slug: slug()}, actor: admin)
      CMS.publish_post!(post, %{}, actor: admin)
      as_of = DateTime.utc_now() |> DateTime.to_iso8601()

      rest =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.dispatch(KilnCMSWeb.Endpoint, :get, "/api/content/post", %{
          "as_of" => as_of
        })

      assert rest.status == 200
      body = Jason.decode!(rest.resp_body)
      assert Enum.any?(body["entries"], &(&1["slug"] == post.slug and &1["title"] == "Twin"))
      assert Enum.all?(body["entries"], &String.contains?(&1["href"], "as_of="))

      gql =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.dispatch(KilnCMSWeb.Endpoint, :post, "/gql", %{
          "query" => """
          query($asOf: DateTime!) {
            contentAsOf(type: "post", asOf: $asOf) { slug title publishedAt }
          }
          """,
          "variables" => %{"asOf" => as_of}
        })

      assert %{"data" => %{"contentAsOf" => entries}} = Jason.decode!(gql.resp_body)
      assert Enum.any?(entries, &(&1["slug"] == post.slug and &1["title"] == "Twin"))
    end

    test "the collection route requires as_of and validates it" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.dispatch(KilnCMSWeb.Endpoint, :get, "/api/content/post", %{})

      assert conn.status == 400
      assert conn.resp_body =~ "missing_as_of"

      bad =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.dispatch(KilnCMSWeb.Endpoint, :get, "/api/content/post", %{
          "as_of" => "not-a-date"
        })

      assert bad.status == 400
    end
  end
end
