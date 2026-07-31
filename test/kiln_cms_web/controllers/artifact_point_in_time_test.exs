defmodule KilnCMSWeb.ArtifactPointInTimeTest do
  @moduledoc "The /api/content/:type/:slug?as_of=… point-in-time endpoint (#338)."
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pit-ctrl-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "pitc-#{System.unique_integer([:positive])}"

  test "as_of serves the historical published state; drafts/edits after it don't leak", %{
    conn: conn
  } do
    admin = admin()
    the_slug = slug()

    post = CMS.create_post!(%{title: "Original", slug: the_slug}, actor: admin)
    post = CMS.publish_post!(post, %{}, actor: admin)
    as_of = DateTime.utc_now() |> DateTime.to_iso8601()

    post = CMS.unpublish_post!(post, %{}, actor: admin)
    post = CMS.update_post!(post, %{title: "Revised"}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    conn = get(conn, "/api/content/post/#{the_slug}?as_of=#{as_of}")
    body = json_response(conn, 200)

    assert body["title"] == "Original"
    assert [pub_at] = get_resp_header(conn, "x-kiln-published-at")
    assert pub_at =~ ~r/^\d{4}-\d{2}-\d{2}T/
  end

  test "a bare date is accepted (end of day)", %{conn: conn} do
    admin = admin()
    the_slug = slug()
    post = CMS.create_post!(%{title: "Dated", slug: the_slug}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    today = Date.utc_today() |> Date.to_iso8601()
    body = conn |> get("/api/content/post/#{the_slug}?as_of=#{today}") |> json_response(200)
    assert body["title"] == "Dated"
  end

  test "an invalid as_of returns 400", %{conn: conn} do
    body = conn |> get("/api/content/post/whatever?as_of=not-a-date") |> json_response(400)
    assert hd(body["errors"])["code"] == "invalid_as_of"
  end

  test "as_of before any publish returns 404 not_published", %{conn: conn} do
    admin = admin()
    the_slug = slug()
    post = CMS.create_post!(%{title: "T", slug: the_slug}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    # Yesterday — before this content was ever published.
    yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()
    body = conn |> get("/api/content/post/#{the_slug}?as_of=#{yesterday}") |> json_response(404)
    assert hd(body["errors"])["code"] == "not_published"
  end

  test "as_of inside an unpublish window reports withdrawn, not the prior publish", %{conn: conn} do
    admin = admin()
    the_slug = slug()

    # Published, then taken down, then put back — ask about the gap between.
    post = CMS.create_post!(%{title: "Live then pulled", slug: the_slug}, actor: admin)
    post = CMS.publish_post!(post, %{}, actor: admin)
    post = CMS.unpublish_post!(post, %{}, actor: admin)
    dark = DateTime.utc_now() |> DateTime.to_iso8601()
    CMS.publish_post!(post, %{}, actor: admin)

    body = conn |> get("/api/content/post/#{the_slug}?as_of=#{dark}") |> json_response(404)

    # Serving "Live then pulled" here would assert the content was published at
    # a moment it had already been withdrawn.
    assert hd(body["errors"])["code"] == "withdrawn"
  end

  test "the historical index and the per-document snapshot agree about a dark window", %{
    conn: conn
  } do
    admin = admin()
    the_slug = slug()

    post = CMS.create_post!(%{title: "Withdrawn", slug: the_slug}, actor: admin)
    post = CMS.publish_post!(post, %{}, actor: admin)
    CMS.unpublish_post!(post, %{}, actor: admin)
    dark = DateTime.utc_now() |> DateTime.to_iso8601()

    index = conn |> get("/api/content/post?as_of=#{dark}") |> json_response(200)
    refute Enum.any?(index["entries"], &(&1["slug"] == the_slug))

    # The index already excluded it; the snapshot must not contradict that.
    conn |> get("/api/content/post/#{the_slug}?as_of=#{dark}") |> json_response(404)
  end
end
