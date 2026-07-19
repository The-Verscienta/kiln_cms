defmodule KilnCMSWeb.LlmsControllerTest do
  @moduledoc "GEO: the /llms.txt content index (issue #357)."
  # async: false — /llms.txt is cached under one global Cachex key (like the
  # sitemap), so parallel tests would contaminate each other's index.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "llms-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "llms-#{System.unique_integer([:positive])}"

  test "lists published content grouped by type, excluding drafts", %{conn: conn} do
    actor = admin()

    post = CMS.create_post!(%{title: "Published Post #{slug()}", slug: slug()}, actor: actor)
    CMS.publish_post!(post, %{}, actor: actor)

    page =
      CMS.create_page!(
        %{title: "Published Page #{slug()}", slug: slug(), seo_description: "A useful page"},
        actor: actor
      )

    CMS.publish_page!(page, %{}, actor: actor)

    draft = CMS.create_post!(%{title: "Secret Draft #{slug()}", slug: slug()}, actor: actor)

    conn = get(conn, ~p"/llms.txt")

    assert response(conn, 200)
    assert ["text/markdown" <> _] = get_resp_header(conn, "content-type")

    body = response(conn, 200)

    # Convention header.
    assert body =~ ~r/^# /
    assert body =~ "llmstxt.org"

    # Grouped sections + published entries with links.
    assert body =~ "## Posts"
    assert body =~ "## Pages"
    assert body =~ post.title
    assert body =~ "/#{post.slug}"
    assert body =~ page.title
    # Description rendered when present.
    assert body =~ "A useful page"

    # Drafts never appear.
    refute body =~ draft.title
  end

  test "renders an empty index without error when nothing is published", %{conn: conn} do
    # Bust so a prior test's cached index can't satisfy this request.
    KilnCMS.Cache.bust_llms(KilnCMS.Accounts.default_org_id())

    conn = get(conn, ~p"/llms.txt")
    assert response(conn, 200) =~ ~r/^# /
  end
end
