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

  defp admin_token(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => user.email,
        "password" => "password123456"
      })

    signed_in.__metadata__.token
  end

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

  test "an admin-minted key gets no gated or locked rows, and no highlight of them", %{conn: conn} do
    # The exploit #1013 actually names. This endpoint used to pass
    # `conn.assigns[:current_user]` as the actor, and the `OrgAdmin` policy
    # BYPASS authorizes an admin past both the audience grant and the
    # passphrase check — so a front end holding an admin-minted delivery key
    # read gated and locked rows here. Worse than the JSON:API twins: every hit
    # carries a `highlight` built from `search_text`, so the leak was a
    # `<mark>`-ed extract of the body itself, not just a title.
    actor = admin()
    word = token()

    live =
      CMS.create_page!(%{title: "Open #{word}", slug: slug()}, actor: actor)
      |> then(&CMS.publish_page!(&1, %{}, actor: actor))

    _gated =
      CMS.create_page!(%{title: "Members #{word}", slug: slug(), audience: :member}, actor: actor)
      |> then(&CMS.publish_page!(&1, %{}, actor: actor))

    _locked =
      CMS.create_page!(%{title: "Locked #{word}", slug: slug()}, actor: actor)
      |> then(&CMS.publish_page!(&1, %{}, actor: actor))
      |> then(&CMS.update_page!(&1, %{access_password: "shared secret"}, actor: actor))

    body =
      conn
      |> put_req_header("authorization", "Bearer #{admin_token(actor)}")
      |> get("/api/search?q=#{word}&facets=true")
      |> json_response(200)

    assert [hit] = body["results"]["pages"]
    assert hit["id"] == live.id

    # And the two derived surfaces that take the same read opts: neither the
    # facet counts nor the "did you mean" may be computed over rows this
    # caller cannot see. `suggest/2` is the sharper of the two — it returns a
    # TITLE with no result row to hang it on.
    refute body["suggestion"]
    assert Map.has_key?(body, "facets")
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

    # One empty section per *registered* content type and per taxonomy
    # resource, not a hardcoded list: since #311 the controller sweeps the
    # ContentTypes registry (so a downstream tree running this suite with a
    # project domain registered gets that project's sections too), and since
    # #530 the taxonomy sections come from `Taxonomy.searchable/0`.
    taxonomy = Map.new(KilnCMS.CMS.Taxonomy.searchable(), &{to_string(elem(&1, 0)), []})

    expected =
      KilnCMS.CMS.ContentTypes.all()
      |> Map.new(fn ct -> {to_string(ct.section), []} end)
      |> Map.merge(taxonomy)
      |> Map.put("entries", [])

    assert body["results"] == expected

    assert body["suggestion"] == nil
  end

  # #296: the sections are DERIVED from the content-type registry, not a
  # hardcoded module list — a type a plugin/project registers on
  # `:content_domains` gets a section (and counts toward the analytics/
  # did-you-mean total) with no controller or Search edit. Seeding goes
  # through the registry dispatch too, so this exercises whatever set of
  # types the running config declares — in the core repo: page and post.
  test "every compiled content type in the registry gets a result section", %{conn: conn} do
    actor = admin()
    word = token()

    seeded =
      for ct <- ContentTypes.all() do
        record =
          ContentTypes.create!(ct.type, %{title: "#{ct.label} #{word}", slug: slug()},
            actor: actor
          )

        {:ok, record} = ContentTypes.transition(ct.type, "publish", record, actor: actor)
        {ct, record}
      end

    body = conn |> get("/api/search?q=#{word}") |> json_response(200)

    for {ct, record} <- seeded do
      assert [hit] = body["results"][ct.plural]
      assert hit["id"] == record.id
      assert hit["type"] == to_string(ct.type)
    end
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

    # Tag groups are searchable too (#530) — they were the one taxonomy
    # resource this surface never returned, with nothing failing to say so.
    group =
      KilnCMS.CMS.create_tag_group!(%{name: "#{word} themes", slug: slug()}, actor: actor)

    body = conn |> get("/api/search?q=#{word}") |> json_response(200)

    assert [%{"id" => gid, "type" => "tag_group", "name" => _, "slug" => _}] =
             body["results"]["tag_groups"]

    assert gid == group.id

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
