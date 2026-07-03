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

  test "a typo gets fuzzy-rescued hits plus a did-you-mean naming the correction", %{conn: conn} do
    actor = admin()

    # "fermentaton" survives stemming as its own token (unlike, say,
    # "pancaks" → "pancak", which the stemmer rescues into a keyword hit), so
    # the keyword leg is empty — the trigram fallback leg still surfaces the
    # page, and the suggestion names the corrected term alongside it.
    page = CMS.create_page!(%{title: "Fermentation Handbook", slug: slug()}, actor: actor)
    CMS.publish_page!(page, %{}, actor: actor)

    body = conn |> get("/api/search?q=fermentaton") |> json_response(200)

    assert [%{"id" => id}] = body["results"]["pages"]
    assert id == page.id
    assert body["suggestion"] == "Fermentation Handbook"
  end

  test "a blank query returns the empty shape", %{conn: conn} do
    body = conn |> get("/api/search?q=") |> json_response(200)

    assert body["results"] == %{
             "pages" => [],
             "posts" => [],
             "entries" => [],
             "categories" => [],
             "tags" => []
           }

    assert body["suggestion"] == nil
  end

  test "taxonomy matches ride their own sections with name and slug", %{conn: conn} do
    actor = admin()
    word = token()

    category =
      KilnCMS.CMS.create_category!(%{name: "#{word} recipes", slug: slug()}, actor: actor)

    tag = KilnCMS.CMS.create_tag!(%{name: "#{word}-style", slug: slug()}, actor: actor)

    body = conn |> get("/api/search?q=#{word}") |> json_response(200)

    assert [%{"id" => cid, "type" => "category", "name" => _, "slug" => _}] =
             body["results"]["categories"]

    assert cid == category.id
    assert [%{"id" => tid, "type" => "tag"}] = body["results"]["tags"]
    assert tid == tag.id

    # Taxonomy-only matches don't suppress the content "did you mean" — but
    # here there's nothing trigram-close either, so no suggestion.
    assert body["suggestion"] == nil
  end

  test "locale and limit params are validated and clamped", %{conn: conn} do
    body = conn |> get("/api/search?q=x&locale=xx&limit=9999") |> json_response(200)
    assert body["locale"] == "en"
  end

  test "facets=true adds counts and category=<slug> filters the hits", %{conn: conn} do
    actor = admin()
    word = token()

    cat =
      KilnCMS.CMS.create_category!(%{name: "Cat #{word}", slug: slug()}, actor: actor)

    inside =
      CMS.create_page!(%{title: "#{word} inside", slug: slug(), category_id: cat.id},
        actor: actor
      )

    inside = CMS.publish_page!(inside, %{}, actor: actor)

    outside = CMS.create_page!(%{title: "#{word} outside", slug: slug()}, actor: actor)
    CMS.publish_page!(outside, %{}, actor: actor)

    body = conn |> get("/api/search?q=#{word}&facets=true") |> json_response(200)

    assert [%{"id" => cat_id, "count" => 1, "slug" => _}] =
             Enum.filter(body["facets"]["categories"], &(&1["id"] == cat.id))

    assert cat_id == cat.id

    filtered =
      conn |> get("/api/search?q=#{word}&category=#{cat.slug}") |> json_response(200)

    assert [%{"id" => id}] = filtered["results"]["pages"]
    assert id == inside.id
    # No facets key unless asked for.
    refute Map.has_key?(filtered, "facets")
  end
end
