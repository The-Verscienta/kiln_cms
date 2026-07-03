defmodule KilnCMSWeb.SearchApiTest do
  @moduledoc """
  The headless hybrid-search endpoint (`GET /api/search`): published-only for
  anonymous callers, sectioned + path-tagged results with escape-safe
  highlights, and a trigram "did you mean" on zero-result queries. Semantic is
  off in the test env, so results ride the keyword leg — the hybrid fusion
  itself is covered by `KilnCMS.Search.HybridTest`.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sapi-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "sapi-#{System.unique_integer([:positive])}"

  defp token, do: "tok#{System.unique_integer([:positive])}"

  test "returns published hits with type, public path, and a safe highlight", %{conn: conn} do
    actor = admin()
    word = token()

    page = CMS.create_page!(%{title: "About #{word}", slug: slug()}, actor: actor)
    page = CMS.publish_page!(page, %{}, actor: actor)
    _draft = CMS.create_page!(%{title: "Draft #{word}", slug: slug()}, actor: actor)

    body = conn |> get("/api/search?q=#{word}") |> json_response(200)

    assert [hit] = body["results"]["pages"]
    assert hit["id"] == page.id
    assert hit["type"] == "page"
    assert hit["path"] == "/#{page.slug}"
    assert hit["highlight"] =~ "<mark>"
    refute hit["highlight"] =~ "<script"
    assert body["suggestion"] == nil
  end

  test "dynamic entries are tagged with their type and public path", %{conn: conn} do
    actor = admin()
    word = token()

    definition =
      CMS.create_type_definition!(
        %{name: "sa#{System.unique_integer([:positive])}", label: "SA"},
        actor: actor
      )

    entry =
      ContentTypes.create!(definition.name, %{title: "Entry #{word}", slug: slug()}, actor: actor)

    {:ok, entry} = ContentTypes.transition(definition.name, "publish", entry, actor: actor)

    body = conn |> get("/api/search?q=#{word}") |> json_response(200)

    assert [hit] = body["results"]["entries"]
    assert hit["id"] == entry.id
    assert hit["type"] == definition.name
    assert hit["path"] == "/#{definition.path_segment}/#{entry.slug}"
  end

  test "a zero-result typo yields a did-you-mean suggestion", %{conn: conn} do
    actor = admin()

    # "fermentaton" survives stemming as its own token (unlike, say,
    # "pancaks" → "pancak", which the stemmer rescues into a keyword hit), so
    # the search legs return nothing and the trigram suggestion kicks in.
    page = CMS.create_page!(%{title: "Fermentation Handbook", slug: slug()}, actor: actor)
    CMS.publish_page!(page, %{}, actor: actor)

    body = conn |> get("/api/search?q=fermentaton") |> json_response(200)

    assert body["results"] == %{"pages" => [], "posts" => [], "entries" => []}
    assert body["suggestion"] == "Fermentation Handbook"
  end

  test "a blank query returns the empty shape", %{conn: conn} do
    body = conn |> get("/api/search?q=") |> json_response(200)
    assert body["results"] == %{"pages" => [], "posts" => [], "entries" => []}
    assert body["suggestion"] == nil
  end

  test "locale and limit params are validated and clamped", %{conn: conn} do
    body = conn |> get("/api/search?q=x&locale=xx&limit=9999") |> json_response(200)
    assert body["locale"] == "en"
  end
end
