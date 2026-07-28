defmodule KilnCMSWeb.PublishedCacheShapeTest do
  @moduledoc """
  Regression: HTML delivery (`ContentController`) and headless artifact
  delivery (`ArtifactController` via `Firing.Delivery.published/4`) resolve the
  same published `{type, slug, locale}` but cache different shapes — an
  enriched payload map vs the bare record. They once shared a single
  `Cache.fetch_published` key, so whichever endpoint hit a slug first seeded
  the cache and the *other* endpoint then 500'd on the foreign shape
  (`Engine.document_type/1` FunctionClauseError, or `payload.record` KeyError).

  Both request orders must serve 200s off the warm cache.
  """
  # async: false — the shared app-wide content cache is the subject under test;
  # a concurrent test's cache bust would mask the collision being asserted.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS

  setup do
    KilnCMS.Cache.bust_published()
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "shape-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # A published page with its artifacts fired, so both the HTML route and the
  # artifact API can answer 200 (firing is async — drain the queue, #201).
  defp published_page do
    actor = admin()
    slug = "shape-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{
          title: "Shape Regression",
          slug: slug,
          blocks: [%{type: :heading, content: "Hello", data: %{"level" => 1}, order: 0}]
        },
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()
    slug
  end

  test "HTML page first, then the artifact API, both 200", %{conn: conn} do
    slug = published_page()

    assert conn |> get(~p"/#{slug}") |> html_response(200) =~ "Shape Regression"

    body = build_conn() |> get(~p"/api/content/page/#{slug}") |> json_response(200)
    assert body["title"] == "Shape Regression"
  end

  test "artifact API first, then the HTML page, both 200", %{conn: conn} do
    slug = published_page()

    body = conn |> get(~p"/api/content/page/#{slug}") |> json_response(200)
    assert body["title"] == "Shape Regression"

    assert build_conn() |> get(~p"/#{slug}") |> html_response(200) =~ "Shape Regression"
  end
end
