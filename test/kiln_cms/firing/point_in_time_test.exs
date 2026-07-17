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
    post = CMS.create_post!(%{title: "Original guidance", slug: slug()}, actor: admin)
    post = CMS.publish_post!(post, %{}, actor: admin)

    as_of = DateTime.utc_now()

    # Revise: unpublish → edit → republish (the workflow to change live content).
    post = CMS.unpublish_post!(post, %{}, actor: admin)
    post = CMS.update_post!(post, %{title: "Revised guidance"}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    assert {:ok, historical, published_at} = PointInTime.read(CMS.Post, post.id, :json, as_of)
    assert historical["title"] == "Original guidance"
    assert %DateTime{} = published_at

    assert {:ok, current, _} = PointInTime.read(CMS.Post, post.id, :json, DateTime.utc_now())
    assert current["title"] == "Revised guidance"
  end

  test "fires any surface for the historical state" do
    admin = admin()
    post = CMS.create_post!(%{title: "Heading", slug: slug()}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    assert {:ok, %{"@context" => "https://schema.org"}, _} =
             PointInTime.read(CMS.Post, post.id, :json_ld, DateTime.utc_now())
  end

  test "returns not_published before the first publish" do
    admin = admin()
    post = CMS.create_post!(%{title: "Draft only", slug: slug()}, actor: admin)
    before_publish = DateTime.utc_now()
    CMS.publish_post!(post, %{}, actor: admin)

    assert {:error, :not_published} = PointInTime.read(CMS.Post, post.id, :json, before_publish)
  end
end
