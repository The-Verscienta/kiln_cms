defmodule KilnCMSWeb.JsonApiTest do
  @moduledoc """
  Headless JSON:API (`/api/json`) — filtering, sorting and pagination for the
  Page/Post/MediaItem read routes (issue #33, Phase 5).

  Anonymous requests go through the read policy, so only published content is
  visible; a bearer-authenticated editor sees drafts too. Counts are always
  scoped to records seeded by the test (shared-sandbox safety).
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  @accept "application/vnd.api+json"
  @password "password123456"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "json-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp token(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => user.email,
          "password" => @password
        },
        []
      )

    signed_in.__metadata__.token
  end

  defp slug, do: "json-#{System.unique_integer([:positive])}"

  defp category(admin) do
    CMS.create_category!(%{name: "Cat #{System.unique_integer([:positive])}", slug: slug()},
      actor: admin
    )
  end

  defp make_post(attrs, admin) do
    CMS.create_post!(Map.put_new(attrs, :slug, slug()), actor: admin)
  end

  defp published_post(attrs, admin) do
    attrs |> make_post(admin) |> then(&CMS.publish_post!(&1, %{}, actor: admin))
  end

  # Issue a GET against the JSON:API and return {status, decoded_body}.
  defp api_get(path, opts \\ []) do
    conn = put_req_header(build_conn(), "accept", @accept)

    conn =
      case opts[:token] do
        nil -> conn
        tok -> put_req_header(conn, "authorization", "Bearer #{tok}")
      end

    conn = get(conn, path)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp ids(%{"data" => data}) when is_list(data), do: Enum.map(data, & &1["id"])

  describe "filtering" do
    test "anonymous list returns only published content, hiding drafts" do
      admin = user(:admin)
      cat = category(admin)

      live = published_post(%{title: "Live", category_id: cat.id}, admin)
      _draft = make_post(%{title: "Draft", category_id: cat.id}, admin)

      assert {200, body} = api_get("/api/json/posts?filter[category_id]=#{cat.id}")
      assert ids(body) == [live.id]
    end

    test "filters by an exact attribute (slug)" do
      admin = user(:admin)
      cat = category(admin)
      s = slug()

      target = published_post(%{title: "By slug", slug: s, category_id: cat.id}, admin)
      _other = published_post(%{title: "Other", category_id: cat.id}, admin)

      assert {200, body} = api_get("/api/json/posts?filter[slug]=#{s}")
      assert ids(body) == [target.id]
    end

    test "combines filters (category + locale)" do
      admin = user(:admin)
      cat = category(admin)

      en = published_post(%{title: "English", locale: "en", category_id: cat.id}, admin)
      fr = published_post(%{title: "French", locale: "fr", category_id: cat.id}, admin)

      assert {200, both} = api_get("/api/json/posts?filter[category_id]=#{cat.id}&sort=title")
      assert Enum.sort(ids(both)) == Enum.sort([en.id, fr.id])

      assert {200, only_fr} =
               api_get("/api/json/posts?filter[category_id]=#{cat.id}&filter[locale]=fr")

      assert ids(only_fr) == [fr.id]
    end

    test "editor (bearer) sees drafts and can filter by workflow state" do
      admin = user(:admin)
      editor = user(:editor)
      cat = category(admin)

      live = published_post(%{title: "Live", category_id: cat.id}, admin)
      draft = make_post(%{title: "Draft", category_id: cat.id}, admin)

      tok = token(editor)

      assert {200, all} =
               api_get("/api/json/posts?filter[category_id]=#{cat.id}&sort=title", token: tok)

      assert Enum.sort(ids(all)) == Enum.sort([live.id, draft.id])

      assert {200, drafts} =
               api_get(
                 "/api/json/posts?filter[category_id]=#{cat.id}&filter[state]=draft",
                 token: tok
               )

      assert ids(drafts) == [draft.id]
    end
  end

  # `path`/`effective_seo_title` have no `expression/2` — filtering them raises
  # out of AshSql as an unhandled 500, so `filterable? false` rejects it
  # cleanly at the query layer instead (#1139). `path` was missing that
  # declaration (unlike its `effective_seo_*`/`word_count` siblings), so a
  # client filtering on it hit the crash rather than a normal JSON:API error.
  describe "public calculations without an expression cannot be filtered (#1139)" do
    test "filter[path] is rejected with a 400, not a 500" do
      admin = user(:admin)
      published_post(%{title: "Filterable check"}, admin)

      assert {400, _body} = api_get("/api/json/posts?filter[path]=/blog/x")
    end

    test "filter[effective_seo_title] is rejected the same way" do
      admin = user(:admin)
      published_post(%{title: "SEO filter check"}, admin)

      assert {400, _body} = api_get("/api/json/posts?filter[effective_seo_title]=x")
    end

    test "the calculated fields are still readable when requested via fields[]" do
      admin = user(:admin)

      post =
        published_post(%{title: "Readable check", slug: slug(), seo_title: "Custom SEO"}, admin)

      assert {200, body} =
               api_get("/api/json/posts/#{post.id}?fields[post]=title,path,effective_seo_title")

      attrs = body["data"]["attributes"]
      assert attrs["path"] =~ post.slug
      assert attrs["effective_seo_title"] == "Custom SEO"
    end
  end

  describe "block_ids over the wire (#954)" do
    test "an editor reads a DRAFT's block ids via fields[post]=block_ids; anonymous cannot" do
      # The draft-readable id surface the required #865 binding depends on:
      # `blocks` stays non-`public?`, but its identity projection is a public
      # calculation, so a headless client can learn the `_id`s it must echo.
      # Field values must not ride along — the projection is ids and types
      # only — and delivery must not gain drafts: the anonymous request is
      # refused at the row, ids and all.
      admin = user(:admin)
      child = Ash.UUID.generate()

      draft =
        make_post(
          %{
            title: "Draft with ids",
            block_tree: [
              %{
                "_type" => "columns",
                "columns" => [
                  %{
                    "blocks" => [
                      %{"_type" => "quote", "id" => child, "text" => "A", "featured" => true}
                    ]
                  }
                ]
              }
            ]
          },
          admin
        )

      assert {200, body} =
               api_get("/api/json/posts/#{draft.id}?fields[post]=block_ids",
                 token: token(user(:editor))
               )

      assert [%{"_type" => "columns", "_id" => _} = columns] =
               body["data"]["attributes"]["block_ids"]

      # Ids and types only — a field value here would be `blocks` leaking.
      assert columns["columns"] == [
               %{"blocks" => [%{"_type" => "quote", "_id" => child}]}
             ]

      assert {404, _body} = api_get("/api/json/posts/#{draft.id}?fields[post]=block_ids")
    end
  end

  describe "sorting" do
    test "sorts by title ascending and descending" do
      admin = user(:admin)
      cat = category(admin)

      a = published_post(%{title: "Apple", category_id: cat.id}, admin)
      m = published_post(%{title: "Mango", category_id: cat.id}, admin)
      z = published_post(%{title: "Zebra", category_id: cat.id}, admin)

      assert {200, asc} = api_get("/api/json/posts?filter[category_id]=#{cat.id}&sort=title")
      assert ids(asc) == [a.id, m.id, z.id]

      assert {200, desc} = api_get("/api/json/posts?filter[category_id]=#{cat.id}&sort=-title")
      assert ids(desc) == [z.id, m.id, a.id]
    end

    # Regression: timestamps() defaulted to public?: false (the Ash 3 default —
    # create_timestamp overrides writable?/default/type, not public?), so
    # sort=-inserted_at was rejected as invalid_sort and the timestamps never
    # serialized. Found downstream sorting a delivery site by recency
    # (The-Verscienta/verscienta-base#96).
    test "sorts by inserted_at and serializes both timestamps" do
      admin = user(:admin)
      cat = category(admin)

      oldest = published_post(%{title: "First", category_id: cat.id}, admin)
      middle = published_post(%{title: "Second", category_id: cat.id}, admin)
      newest = published_post(%{title: "Third", category_id: cat.id}, admin)

      assert {200, desc} =
               api_get("/api/json/posts?filter[category_id]=#{cat.id}&sort=-inserted_at")

      assert ids(desc) == [newest.id, middle.id, oldest.id]

      assert {200, asc} =
               api_get("/api/json/posts?filter[category_id]=#{cat.id}&sort=inserted_at")

      assert ids(asc) == [oldest.id, middle.id, newest.id]

      [first | _] = desc["data"]
      assert {:ok, _, _} = DateTime.from_iso8601(first["attributes"]["inserted_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(first["attributes"]["updated_at"])
    end

    # Regression: `word_count`/`reading_time_minutes`/`effective_seo_*`/
    # `related_links`/`block_ids` have no `expression/2` (computed in Elixir,
    # not SQL) and are declared `sortable? false` for it — filtering one is
    # already a clean 400 (`filterable? false`), but sorting bypassed the
    # flag and crashed with an unhandled `UndefinedFunctionError` deep in
    # AshSql instead. See `KilnCMS.CMS.Preparations.RejectUnsortableCalculations`.
    test "sorting by a sortable?-false calculation is a clean 400, not a crash" do
      admin = user(:admin)
      cat = category(admin)
      _post = published_post(%{title: "Sortable check", category_id: cat.id}, admin)

      assert {400, body} = api_get("/api/json/posts?sort=word_count")
      assert [%{"code" => "invalid_sort"}] = body["errors"]

      assert {400, body} = api_get("/api/json/posts?sort=-effective_seo_title")
      assert [%{"code" => "invalid_sort"}] = body["errors"]
    end
  end

  # Both carry the order the editor set (#2025): each link's `position`.
  describe "related content order" do
    test "lists the curated related posts in the editor's order" do
      admin = user(:admin)
      cat = category(admin)

      [a, b, c] =
        for t <- ~w(RA RB RC), do: published_post(%{title: t, category_id: cat.id}, admin)

      source =
        %{title: "RSource", category_id: cat.id, related_post_ids: [c.id, a.id, b.id]}
        |> published_post(admin)

      assert {200, body} =
               api_get("/api/json/posts?filter[id]=#{source.id}&fields[post]=title,related_links")

      assert [%{"attributes" => %{"related_links" => links}}] = body["data"]
      assert Enum.map(links, & &1["title"]) == ["RC", "RA", "RB"]

      # The included relationship lists them in the same order.
      assert {200, body} =
               api_get("/api/json/posts?filter[id]=#{source.id}&include=related_posts")

      assert [%{"relationships" => %{"related_posts" => %{"data" => linkage}}}] = body["data"]
      assert Enum.map(linkage, & &1["id"]) == [c.id, a.id, b.id]
    end
  end

  describe "pagination" do
    test "limits the page, reports the total count and links to the next page" do
      admin = user(:admin)
      cat = category(admin)

      a = published_post(%{title: "P1", category_id: cat.id}, admin)
      b = published_post(%{title: "P2", category_id: cat.id}, admin)
      c = published_post(%{title: "P3", category_id: cat.id}, admin)

      assert {200, page1} =
               api_get(
                 "/api/json/posts?filter[category_id]=#{cat.id}&sort=title&page[limit]=2&page[count]=true"
               )

      assert ids(page1) == [a.id, b.id]
      assert page1["meta"]["page"]["total"] == 3
      assert page1["meta"]["page"]["limit"] == 2
      assert is_binary(page1["links"]["next"])

      assert {200, page2} =
               api_get(
                 "/api/json/posts?filter[category_id]=#{cat.id}&sort=title&page[limit]=2&page[offset]=2"
               )

      assert ids(page2) == [c.id]
    end

    test "an oversized page limit is accepted (rows are capped server-side by max_page_size)" do
      admin = user(:admin)
      cat = category(admin)
      p = published_post(%{title: "Big", category_id: cat.id}, admin)

      # `max_page_size: 100` caps how many rows are actually fetched rather than
      # erroring, so a huge requested limit still succeeds.
      assert {200, body} =
               api_get("/api/json/posts?filter[category_id]=#{cat.id}&page[limit]=1000")

      assert ids(body) == [p.id]
    end
  end

  describe "compound documents (include=)" do
    test "declared relationships come back as included resources with linkage" do
      admin = user(:admin)
      cat = category(admin)
      tag = CMS.create_tag!(%{name: "Inc", slug: slug()}, actor: admin)
      other = published_post(%{title: "Linked-to"}, admin)

      post =
        published_post(
          %{title: "Compound", category_id: cat.id, tag_ids: [tag.id]},
          admin
        )

      CMS.create_content_link!(
        %{source_id: post.id, target_id: other.id, kind: :see_also, metadata: %{"note" => "x"}},
        actor: admin
      )

      assert {200, body} =
               api_get("/api/json/posts/#{post.id}?include=tags,category,content_links")

      # Linkage data appears on the requested relationships…
      rels = body["data"]["relationships"]
      assert [%{"type" => "tag", "id" => _}] = rels["tags"]["data"]
      assert %{"type" => "category"} = rels["category"]["data"]
      assert [%{"type" => "content_link"}] = rels["content_links"]["data"]

      # …and the compound members arrive typed, links with their payload.
      included = Enum.group_by(body["included"], & &1["type"])
      assert [%{"attributes" => %{"name" => "Inc"}}] = included["tag"]
      assert [%{"attributes" => link}] = included["content_link"]
      assert link["kind"] == "see_also"
      assert link["metadata"] == %{"note" => "x"}
      assert link["target_id"] == other.id
    end

    test "an undeclared include is still rejected" do
      admin = user(:admin)
      post = published_post(%{title: "P"}, admin)

      assert {400, %{"errors" => [%{"code" => "invalid_includes"}]}} =
               api_get("/api/json/posts/#{post.id}?include=versions")
    end
  end

  # Regression for #183: the JSON:API must not expose author PII. User is not a
  # JSON:API resource (the Accounts domain has no AshJsonApi router), so the
  # author relationship is not includable and the post payload carries only the
  # opaque `author_id` foreign key — never email or role.
  describe "author PII redaction (#183)" do
    test "?include=author is rejected — author is not an exposed resource" do
      admin = user(:admin)
      post = published_post(%{title: "P"}, admin)

      assert {400, %{"errors" => [%{"code" => "invalid_includes"}]}} =
               api_get("/api/json/posts/#{post.id}?include=author")
    end

    test "a post payload exposes author_id but never author email or role" do
      admin = user(:admin)
      post = published_post(%{title: "P"}, admin)

      assert {200, %{"data" => data}} = api_get("/api/json/posts/#{post.id}")

      # The opaque FK is fine; the author's PII must not appear anywhere.
      serialized = Jason.encode!(data)
      refute serialized =~ to_string(admin.email)
      refute serialized =~ ~s("email")
      refute serialized =~ ~s("role")
    end
  end

  # #185: taxonomy is now reachable over JSON:API (parity with GraphQL), not
  # GraphQL-only.
  describe "taxonomy" do
    test "lists categories and fetches one by slug and by id" do
      admin = user(:admin)
      cat = category(admin)

      assert {200, list} = api_get("/api/json/categories?filter[id]=#{cat.id}")
      assert ids(list) == [cat.id]

      assert {200, %{"data" => by_slug}} = api_get("/api/json/categories/by-slug/#{cat.slug}")
      assert by_slug["id"] == cat.id
      assert by_slug["attributes"]["name"] == cat.name

      assert {200, %{"data" => by_id}} = api_get("/api/json/categories/#{cat.id}")
      assert by_id["id"] == cat.id
    end

    test "lists tags and fetches one by slug" do
      admin = user(:admin)

      tag =
        CMS.create_tag!(%{name: "Tag #{System.unique_integer([:positive])}", slug: slug()},
          actor: admin
        )

      assert {200, list} = api_get("/api/json/tags?filter[id]=#{tag.id}")
      assert ids(list) == [tag.id]

      assert {200, %{"data" => by_slug}} = api_get("/api/json/tags/by-slug/#{tag.slug}")
      assert by_slug["id"] == tag.id
    end
  end

  # #186: semantic search is reachable over JSON:API (parity with GraphQL). When
  # embeddings are unavailable (test env) it degrades to an empty 200, not an error.
  describe "semantic search" do
    test "the semantic-search route responds (empty when embeddings unavailable)" do
      admin = user(:admin)
      _post = published_post(%{title: "Semantic"}, admin)

      # Arguments are top-level query params (query is required).
      assert {200, %{"data" => data}} =
               api_get("/api/json/posts/semantic-search?query=anything&locale=en")

      assert is_list(data)

      # Pages have the route too.
      assert {200, %{"data" => _}} =
               api_get("/api/json/pages/semantic-search?query=anything&locale=en")

      # The query argument is required.
      assert {400, %{"errors" => [%{"code" => "required"} | _]}} =
               api_get("/api/json/posts/semantic-search")
    end
  end

  # #197: HTTP contract coverage for the keyword search + autocomplete routes.
  describe "search and autocomplete over HTTP" do
    test "keyword search returns matching published posts" do
      admin = user(:admin)
      term = "httpsearch#{System.unique_integer([:positive])}"
      hit = published_post(%{title: "#{term} match"}, admin)
      _miss = published_post(%{title: "unrelated"}, admin)

      assert {200, body} = api_get("/api/json/posts/search?query=#{term}&locale=en")
      assert ids(body) == [hit.id]
    end

    test "autocomplete returns title prefix matches" do
      admin = user(:admin)
      term = "Autohttp#{System.unique_integer([:positive])}"
      hit = published_post(%{title: "#{term} suggestion"}, admin)

      assert {200, body} = api_get("/api/json/posts/autocomplete?prefix=#{term}&locale=en")
      assert hit.id in ids(body)
    end

    test "keyword search requires the query argument" do
      assert {400, %{"errors" => [%{"code" => "required"} | _]}} =
               api_get("/api/json/posts/search")
    end

    # Pins the sort contract on /search (#301): relevance is only the DEFAULT
    # order. The :search prepare appends its {search_rank, inserted_at} sort
    # with Ash.Query.sort/2, so a caller's explicit sort= keys stay primary
    # and relevance degrades to the tiebreaker. Neither a test nor a doc said
    # so before — consumers (The-Verscienta/verscienta-base#94) re-sorted
    # whole result sets in memory rather than rely on unpinned behavior.
    test "explicit sort= overrides relevance; relevance remains the default order" do
      admin = user(:admin)
      term = "sortsearch#{System.unique_integer([:positive])}"

      # The term appears once in each title → equal ts_rank, so the default
      # order falls to the prepare's own tiebreaker: newest first.
      older = published_post(%{title: "Apple #{term}"}, admin)
      newer = published_post(%{title: "Zebra #{term}"}, admin)

      assert {200, default} = api_get("/api/json/posts/search?query=#{term}&locale=en")
      assert ids(default) == [newer.id, older.id]

      assert {200, sorted} =
               api_get("/api/json/posts/search?query=#{term}&locale=en&sort=title")

      assert ids(sorted) == [older.id, newer.id]
    end
  end

  # #297: the published-only search twins. The base search routes go through
  # the read policy, so a bearer-keyed editor/admin caller silently matches
  # drafts; the `…/published` routes pin `state == :published` server-side and
  # cannot be widened by any credential.
  describe "published-only search twins" do
    test "editor bearer: /search includes drafts, /search/published never does" do
      admin = user(:admin)
      editor = user(:editor)
      term = "pubsearch#{System.unique_integer([:positive])}"

      live = published_post(%{title: "#{term} live"}, admin)
      draft = make_post(%{title: "#{term} draft"}, admin)

      tok = token(editor)

      # The base route widens to drafts for a keyed editor — the trap.
      assert {200, base} = api_get("/api/json/posts/search?query=#{term}&locale=en", token: tok)
      assert Enum.sort(ids(base)) == Enum.sort([live.id, draft.id])

      # The published twin filters server-side, same credential.
      assert {200, published} =
               api_get("/api/json/posts/search/published?query=#{term}&locale=en", token: tok)

      assert ids(published) == [live.id]
    end

    test "admin bearer: the twin hides gated and locked rows too (#1013)" do
      # The trap the twins exist for, one axis further along. An API key
      # authorizes as the account that minted it, and the `OrgAdmin` policy
      # BYPASS authorizes that account for everything — including the
      # passphrase check every other reader has to satisfy. Pinning `state`
      # alone left a front end holding an admin-minted delivery key enumerating
      # member-only and locked documents straight out of `/search/published`.
      # Metadata, not bodies — `blocks` is not public on any read action; the
      # surface that leaked body text is `/api/search`, through its `highlight`
      # over `search_text`, and that one is now actorless.
      admin = user(:admin)
      term = "pubgated#{System.unique_integer([:positive])}"

      live = published_post(%{title: "#{term} live"}, admin)
      gated = published_post(%{title: "#{term} members", audience: :member}, admin)

      locked =
        %{title: "#{term} locked"}
        |> published_post(admin)
        |> then(
          &CMS.update_post!(&1, %{access_password: "shared secret"},
            actor: admin,
            tenant: &1.org_id
          )
        )

      tok = token(admin)

      # The base route still widens for this credential — that is what the
      # twin is for, and the contrast is the point.
      assert {200, base} = api_get("/api/json/posts/search?query=#{term}&locale=en", token: tok)
      assert Enum.sort(ids(base)) == Enum.sort([live.id, gated.id, locked.id])

      assert {200, published} =
               api_get("/api/json/posts/search/published?query=#{term}&locale=en", token: tok)

      assert ids(published) == [live.id]
    end

    test "admin bearer: autocomplete/published hides gated and locked titles too" do
      admin = user(:admin)
      term = "Pubgack#{System.unique_integer([:positive])}"

      live = published_post(%{title: "#{term} live"}, admin)
      _gated = published_post(%{title: "#{term} members", audience: :member}, admin)

      locked =
        %{title: "#{term} locked"}
        |> published_post(admin)
        |> then(
          &CMS.update_post!(&1, %{access_password: "shared secret"},
            actor: admin,
            tenant: &1.org_id
          )
        )

      assert {200, body} =
               api_get("/api/json/posts/autocomplete/published?prefix=#{term}&locale=en",
                 token: token(admin)
               )

      # Named in the test title, so actually asserted: without the locked row
      # here, dropping the passphrase clause from `pinned_state` left this test
      # green.
      refute locked.id in ids(body)
      assert ids(body) == [live.id]
    end

    test "anonymous callers get published matches from the twin too" do
      admin = user(:admin)
      term = "pubanon#{System.unique_integer([:positive])}"
      live = published_post(%{title: "#{term} live"}, admin)
      _draft = make_post(%{title: "#{term} draft"}, admin)

      assert {200, body} = api_get("/api/json/posts/search/published?query=#{term}&locale=en")
      assert ids(body) == [live.id]
    end

    test "editor bearer: autocomplete/published hides draft titles" do
      admin = user(:admin)
      editor = user(:editor)
      term = "Puback#{System.unique_integer([:positive])}"

      live = published_post(%{title: "#{term} live"}, admin)
      draft = make_post(%{title: "#{term} draft"}, admin)

      tok = token(editor)

      # Base route suggests the draft to a keyed editor…
      assert {200, base} =
               api_get("/api/json/posts/autocomplete?prefix=#{term}&locale=en", token: tok)

      assert Enum.sort(ids(base)) == Enum.sort([live.id, draft.id])

      # …the published twin does not.
      assert {200, published} =
               api_get("/api/json/posts/autocomplete/published?prefix=#{term}&locale=en",
                 token: tok
               )

      assert ids(published) == [live.id]
    end

    test "the semantic twin responds (empty when embeddings unavailable) and requires query" do
      admin = user(:admin)
      _post = published_post(%{title: "Semantic published"}, admin)

      assert {200, %{"data" => data}} =
               api_get("/api/json/posts/semantic-search/published?query=anything&locale=en")

      assert is_list(data)

      assert {400, %{"errors" => [%{"code" => "required"} | _]}} =
               api_get("/api/json/posts/semantic-search/published")
    end

    test "the twins expose no state argument to widen" do
      admin = user(:admin)
      editor = user(:editor)
      term = "pubwiden#{System.unique_integer([:positive])}"

      _live = published_post(%{title: "#{term} live"}, admin)
      draft = make_post(%{title: "#{term} draft"}, admin)

      # Even explicitly asking the twin for drafts returns published only.
      assert {200, body} =
               api_get(
                 "/api/json/posts/search/published?query=#{term}&locale=en&state=draft",
                 token: token(editor)
               )

      refute draft.id in ids(body)
    end
  end

  # #300: the /published feed is universal — every content type (not just
  # posts) carries the server-side published-only index the official Elixir
  # client reads by default.
  describe "universal published feed" do
    test "pages have /published and a keyed editor cannot see drafts through it" do
      admin = user(:admin)
      editor = user(:editor)
      live_slug = slug()
      draft_slug = slug()

      live =
        CMS.create_page!(%{title: "Live page", slug: live_slug}, actor: admin)
        |> then(&CMS.publish_page!(&1, %{}, actor: admin))

      _draft = CMS.create_page!(%{title: "Draft page", slug: draft_slug}, actor: admin)

      tok = token(editor)

      assert {200, live_body} =
               api_get("/api/json/pages/published?filter[slug]=#{live_slug}", token: tok)

      assert ids(live_body) == [live.id]

      assert {200, draft_body} =
               api_get("/api/json/pages/published?filter[slug]=#{draft_slug}", token: tok)

      assert ids(draft_body) == []
    end
  end

  describe "single record" do
    test "fetches a published post by id" do
      admin = user(:admin)
      post = published_post(%{title: "Single"}, admin)

      assert {200, %{"data" => data}} = api_get("/api/json/posts/#{post.id}")
      assert data["id"] == post.id
      assert data["attributes"]["title"] == "Single"
    end

    # #192: a stable contract — an unpublished record is filtered out (the read
    # policy's published filter applies), so anonymous and bearer-other callers
    # get a 404 (not a 403 that would reveal the draft exists).
    test "hides an unpublished post by id from anonymous consumers (stable 404)" do
      admin = user(:admin)
      draft = make_post(%{title: "Hidden"}, admin)

      assert {404, _} = api_get("/api/json/posts/#{draft.id}")
    end

    test "hides an unpublished post by id from a bearer viewer (stable 404)" do
      admin = user(:admin)
      viewer = user(:viewer)
      draft = make_post(%{title: "Hidden"}, admin)

      assert {404, _} = api_get("/api/json/posts/#{draft.id}", token: token(viewer))
    end
  end

  describe "published feed route" do
    test "/posts/published returns published content newest first" do
      admin = user(:admin)
      cat = category(admin)

      older = published_post(%{title: "Older", category_id: cat.id}, admin)
      newer = published_post(%{title: "Newer", category_id: cat.id}, admin)

      assert {200, body} = api_get("/api/json/posts/published?filter[category_id]=#{cat.id}")
      # Newest-first default ordering from the `:published` read.
      assert ids(body) == [newer.id, older.id]
    end
  end

  describe "pages" do
    test "lists and filters pages" do
      admin = user(:admin)
      cat = category(admin)

      live = published_post_page(%{title: "Live page", category_id: cat.id}, admin)

      _draft =
        CMS.create_page!(%{title: "Draft page", slug: slug(), category_id: cat.id}, actor: admin)

      assert {200, body} = api_get("/api/json/pages?filter[category_id]=#{cat.id}")
      assert ids(body) == [live.id]
    end
  end

  describe "media items" do
    test "lists media and filters by content_type" do
      admin = user(:admin)

      png =
        CMS.create_media_item!(
          %{filename: "a-#{System.unique_integer([:positive])}.png", content_type: "image/png"},
          actor: admin
        )

      jpg =
        CMS.create_media_item!(
          %{filename: "b-#{System.unique_integer([:positive])}.jpg", content_type: "image/jpeg"},
          actor: admin
        )

      assert {200, all} = api_get("/api/json/media-items?filter[id]=#{png.id}")
      assert ids(all) == [png.id]

      assert {200, pngs} = api_get("/api/json/media-items?filter[content_type]=image/png")
      returned = ids(pngs)
      assert png.id in returned
      refute jpg.id in returned
    end

    test "fetches a media item by id" do
      admin = user(:admin)

      item =
        CMS.create_media_item!(
          %{
            filename: "single-#{System.unique_integer([:positive])}.png",
            content_type: "image/png"
          },
          actor: admin
        )

      assert {200, %{"data" => data}} = api_get("/api/json/media-items/#{item.id}")
      assert data["id"] == item.id
    end

    # The faceted browse (#1316): `/library` takes the `:library` action's
    # arguments as plain query params, like `/search` does.
    test "the library route filters by kind, tag, uploader and unused" do
      admin = user(:admin)
      editor = user(:editor)

      tag =
        CMS.create_tag!(
          %{name: "lib-tag", slug: "lib-tag-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      png =
        CMS.create_media_item!(
          %{filename: "lib-#{System.unique_integer([:positive])}.png", content_type: "image/png"},
          actor: admin
        )

      pdf =
        CMS.create_media_item!(
          %{
            filename: "lib-#{System.unique_integer([:positive])}.pdf",
            content_type: "application/pdf"
          },
          actor: editor
        )

      CMS.update_media_item!(png, %{tag_ids: [tag.id]}, actor: admin)

      Ash.Seed.seed!(KilnCMS.Firing.ReferenceEdge, %{
        from_type: :page,
        from_id: Ash.UUID.generate(),
        to_type: :media,
        to_id: png.id
      })

      assert {200, images} = api_get("/api/json/media-items/library?kind=image")
      assert png.id in ids(images)
      refute pdf.id in ids(images)

      assert {200, tagged} = api_get("/api/json/media-items/library?tag_ids[]=#{tag.id}")
      assert ids(tagged) == [png.id]

      assert {200, by_editor} =
               api_get("/api/json/media-items/library?uploaded_by_id=#{editor.id}")

      assert pdf.id in ids(by_editor)
      refute png.id in ids(by_editor)

      assert {200, unused} = api_get("/api/json/media-items/library?unused=true")
      assert pdf.id in ids(unused)
      refute png.id in ids(unused)

      # And the derived `kind` calculation filters on the base route too.
      assert {200, docs} = api_get("/api/json/media-items?filter[kind]=document")
      assert pdf.id in ids(docs)
      refute png.id in ids(docs)
    end

    # The docs promise `?include=tags` on every media read — the resource must
    # actually declare it (AshJsonApi 400s undeclared includes).
    test "tags are includable on media reads" do
      admin = user(:admin)

      tag =
        CMS.create_tag!(
          %{name: "inc-tag", slug: "inc-tag-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      item =
        CMS.create_media_item!(
          %{
            filename: "inc-#{System.unique_integer([:positive])}.png",
            content_type: "image/png",
            tag_ids: [tag.id]
          },
          actor: admin
        )

      assert {200, body} = api_get("/api/json/media-items/#{item.id}?include=tags")
      assert [included] = body["included"]
      assert included["type"] == "tag"
      assert included["id"] == tag.id
    end
  end

  describe "custom-field filtering and sorting (custom_filter / custom_sort)" do
    test "filters and sorts published posts by an admin-defined field" do
      admin = user(:admin)
      price = "price#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{content_type: :post, name: price, label: "Price", field_type: :integer},
        actor: admin
      )

      cheap = published_post(%{title: "Cheap", custom_fields: %{price => 9}}, admin)
      mid = published_post(%{title: "Mid", custom_fields: %{price => 10}}, admin)
      dear = published_post(%{title: "Dear", custom_fields: %{price => 30}}, admin)

      # Numeric, not lexical: a text comparison would also match "9" > "10".
      assert {200, body} = api_get("/api/json/posts?custom_filter[#{price}][gt]=10")
      assert ids(body) == [dear.id]

      # Typed sort; the null=false predicate scopes the list to this test's rows.
      assert {200, body} =
               api_get(
                 "/api/json/posts?custom_filter[#{price}][null]=false&custom_sort=-#{price}"
               )

      assert ids(body) == [dear.id, mid.id, cheap.id]
    end

    test "entries resolve the field's type through filter[type_name]" do
      admin = user(:admin)
      rating = "rating#{System.unique_integer([:positive])}"

      recipes =
        CMS.create_type_definition!(
          %{name: "jsondyn#{System.unique_integer([:positive])}", label: "Dyn"},
          actor: admin
        )

      CMS.create_field_definition!(
        %{type_definition_id: recipes.id, name: rating, label: "Rating", field_type: :integer},
        actor: admin
      )

      entry! = fn fields ->
        KilnCMS.CMS.ContentTypes.create!(
          recipes.name,
          %{title: "E", slug: slug(), custom_fields: fields},
          actor: admin
        )
      end

      _low = entry!.(%{rating => 2})
      high = entry!.(%{rating => 5})

      # Drafts are visible to the authenticated editor tier.
      assert {200, body} =
               api_get(
                 "/api/json/entries?filter[type_name]=#{recipes.name}&custom_filter[#{rating}][gte]=3",
                 token: token(admin)
               )

      assert ids(body) == [high.id]
    end

    test "relationship operators: has / has_all / has_none / count, and tags (R6)" do
      admin = user(:admin)
      refs = "refs#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: refs,
          label: "Refs",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        actor: admin
      )

      a = published_post_page(%{title: "A"}, admin)
      b = published_post_page(%{title: "B"}, admin)
      draft = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: admin)
      tag = CMS.create_tag!(%{name: "rtag-#{slug()}", slug: slug()}, actor: admin)

      ab =
        published_post(
          %{title: "AB", custom_fields: %{refs => [a.id, b.id]}, tag_ids: [tag.id]},
          admin
        )

      bd = published_post(%{title: "BD", custom_fields: %{refs => [b.id, draft.id]}}, admin)

      q = fn params, opts ->
        assert {200, body} = api_get("/api/json/posts?" <> params, opts)
        Enum.sort(ids(body))
      end

      assert q.("custom_filter[#{refs}][has]=#{a.id}", []) == [ab.id]

      assert q.(
               "custom_filter[#{refs}][has_all][]=#{a.id}&custom_filter[#{refs}][has_all][]=#{b.id}",
               []
             ) ==
               [ab.id]

      assert q.(
               "custom_filter[#{refs}][has]=#{b.id}&custom_filter[#{refs}][has_none][]=#{a.id}",
               []
             ) ==
               [bd.id]

      assert q.("custom_filter[#{refs}][count][gte]=2", []) == [ab.id]
      assert q.("custom_filter[tags][has][]=#{tag.id}", []) == [ab.id]

      # The draft target: invisible to an anonymous caller, there for an editor.
      assert q.("custom_filter[#{refs}][has]=#{draft.id}", []) == []
      assert q.("custom_filter[#{refs}][has]=#{draft.id}", token: token(user(:editor))) == [bd.id]

      assert {400, _} = api_get("/api/json/posts?custom_filter[#{refs}][has]=nope")
      assert {400, _} = api_get("/api/json/posts?custom_filter[#{refs}][count][gt]=x")
    end

    test "a list of numbers: has / has_all / count from the query string (#2289)" do
      admin = user(:admin)
      scores = "scores#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: scores,
          label: "Scores",
          field_type: :integer,
          multiple: true
        },
        actor: admin
      )

      three = published_post(%{title: "3", custom_fields: %{scores => [3, 5]}}, admin)
      _seven = published_post(%{title: "7", custom_fields: %{scores => [7]}}, admin)

      q = fn params ->
        assert {200, body} = api_get("/api/json/posts?" <> params)
        Enum.sort(ids(body))
      end

      assert q.("custom_filter[#{scores}][has][]=3") == [three.id]
      assert q.("custom_filter[#{scores}]=5") == [three.id]

      assert q.("custom_filter[#{scores}][has_all][]=3&custom_filter[#{scores}][has_all][]=5") ==
               [three.id]

      assert q.("custom_filter[#{scores}][count]=2") == [three.id]

      assert {400, body} = api_get("/api/json/posts?custom_filter[#{scores}][gt]=4")
      assert inspect(body) =~ "eq/not_eq/in/has/has_all/has_none/count/null"

      assert {400, _} = api_get("/api/json/posts?custom_sort=#{scores}")
    end

    test "an unknown custom field name is a 400" do
      assert {400, _body} =
               api_get(
                 "/api/json/posts?custom_filter[ghost#{System.unique_integer([:positive])}]=x"
               )
    end

    # #2856: `custom_where` is on the route, but a query string carries one
    # condition. Plug merges every `custom_where[][...]` pair into one list
    # item, and an indexed `custom_where[0][...]` decodes to a map, which the
    # route's schema (an array) refuses.
    test "custom_where takes one condition in the [] form; the indexed form is a 400" do
      admin = user(:admin)
      price = "price#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{content_type: :post, name: price, label: "Price", field_type: :integer},
        actor: admin
      )

      _cheap = published_post(%{title: "Cheap", custom_fields: %{price => 9}}, admin)
      dear = published_post(%{title: "Dear", custom_fields: %{price => 30}}, admin)

      assert {200, body} =
               api_get("/api/json/posts?custom_where[][name]=#{price}&custom_where[][int][gt]=10")

      assert ids(body) == [dear.id]

      assert {400, _body} =
               api_get(
                 "/api/json/posts?custom_where[0][name]=#{price}&custom_where[0][int][gt]=10"
               )
    end
  end

  # #2292: a custom field named like a column, `filter[price]` / `sort=-price`.
  describe "custom-field names in filter[...] and sort (#2292)" do
    defp raw_get(path, opts \\ []) do
      conn = put_req_header(build_conn(), "accept", @accept)

      conn =
        case opts[:token] do
          nil -> conn
          tok -> put_req_header(conn, "authorization", "Bearer #{tok}")
        end

      get(conn, path)
    end

    # The error members that are stable across requests (`id` is random).
    defp error_shape(%{"errors" => errors}) do
      Enum.map(errors, &Map.take(&1, ["code", "source", "detail", "status"]))
    end

    defp priced_posts do
      admin = user(:admin)
      price = "price#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{content_type: :post, name: price, label: "Price", field_type: :integer},
        actor: admin
      )

      posts =
        for {title, p} <- [{"Bb cheap", 9}, {"Aa mid", 10}, {"Cc dear", 30}] do
          {p, published_post(%{title: title, custom_fields: %{price => p}}, admin)}
        end
        |> Map.new()

      {admin, price, posts}
    end

    test "filter[x] and sort=x mean custom_filter[x] and custom_sort=x" do
      {_admin, price, %{9 => cheap, 10 => mid, 30 => dear}} = priced_posts()
      scope = "filter[#{price}][null]=false"

      assert {200, body} = api_get("/api/json/posts?filter[#{price}][gt]=10")
      assert ids(body) == [dear.id]

      assert {200, body} = api_get("/api/json/posts?filter[#{price}]=10")
      assert ids(body) == [mid.id]

      assert {200, body} =
               api_get("/api/json/posts?filter[#{price}][in][]=9&filter[#{price}][in][]=30")

      assert Enum.sort(ids(body)) == Enum.sort([cheap.id, dear.id])

      assert {200, body} = api_get("/api/json/posts?#{scope}&sort=-#{price}")
      assert ids(body) == [dear.id, mid.id, cheap.id]

      # is_nil is the native spelling of null.
      assert {200, body} = api_get("/api/json/posts?filter[#{price}][is_nil]=false&sort=#{price}")
      assert ids(body) == [cheap.id, mid.id, dear.id]

      # built-ins then custom
      assert {200, body} = api_get("/api/json/posts?#{scope}&sort=-state,#{price}")
      assert ids(body) == [cheap.id, mid.id, dear.id]
    end

    test "success bodies are byte-identical to the custom_* spelling; errors keep code/source/detail" do
      {_admin, price, _posts} = priced_posts()

      pairs = [
        {"filter[#{price}][gt]=9&filter[#{price}][null]=false&sort=-#{price}",
         "custom_filter[#{price}][gt]=9&custom_filter[#{price}][null]=false&custom_sort=-#{price}"},
        {"filter[title]=Aa%20mid&custom_filter[#{price}]=10",
         "filter[title]=Aa%20mid&custom_filter[#{price}]=10"},
        {"sort=title&custom_sort=#{price}&custom_filter[#{price}][null]=false",
         "sort=title&custom_sort=#{price}&custom_filter[#{price}][null]=false"}
      ]

      for {alias_query, canonical} <- pairs do
        a = raw_get("/api/json/posts/published?" <> alias_query)
        c = raw_get("/api/json/posts/published?" <> canonical)
        assert a.status == 200 and c.status == 200

        # `links.self` echoes the request URL, which is the one member that
        # may differ.
        strip = fn conn -> conn.resp_body |> Jason.decode!() |> Map.delete("links") end
        assert strip.(a) == strip.(c)

        assert a.resp_body |> Jason.decode!() |> Map.get("data") ==
                 c.resp_body |> Jason.decode!() |> Map.get("data")
      end

      # Same error either way.
      a = raw_get("/api/json/posts?filter[#{price}][gt]=zz")
      c = raw_get("/api/json/posts?custom_filter[#{price}][gt]=zz")
      assert a.status == 400 and c.status == 400
      assert error_shape(Jason.decode!(a.resp_body)) == error_shape(Jason.decode!(c.resp_body))
    end

    test "a built-in name wins; custom_filter[x] reaches a custom field of the same name" do
      admin = user(:admin)

      CMS.create_field_definition!(
        %{content_type: :post, name: "title", label: "Title", field_type: :string},
        actor: admin
      )

      native = "Native#{System.unique_integer([:positive])}"
      other = "Other#{System.unique_integer([:positive])}"
      a = published_post(%{title: native, custom_fields: %{"title" => "custom-a"}}, admin)
      _b = published_post(%{title: other, custom_fields: %{"title" => "custom-b"}}, admin)

      assert {200, body} = api_get("/api/json/posts?filter[title]=#{native}")
      assert ids(body) == [a.id]

      assert {200, body} = api_get("/api/json/posts?custom_filter[title]=custom-a")
      assert ids(body) == [a.id]

      # both present, both apply
      assert {200, body} =
               api_get("/api/json/posts?filter[title]=#{native}&custom_filter[title]=custom-a")

      assert ids(body) == [a.id]

      assert {200, body} =
               api_get("/api/json/posts?filter[title]=#{native}&custom_filter[title]=custom-b")

      assert ids(body) == []

      # built-in filters keep their own meaning for slug/state/category/tags
      assert {200, _} = api_get("/api/json/posts?filter[state]=published")
      assert {200, _} = api_get("/api/json/posts?filter[category][slug]=nope")
      assert {200, _} = api_get("/api/json/posts?filter[tags][slug]=nope")
      assert {200, _} = api_get("/api/json/posts?filter[or][0][title]=a&filter[or][1][title]=b")
    end

    test "both forms of a custom field merge; a clashing operator is a native 400, answered once" do
      {_admin, price, %{10 => mid}} = priced_posts()

      assert {200, body} =
               api_get("/api/json/posts?filter[#{price}][gt]=9&custom_filter[#{price}][lt]=30")

      assert ids(body) == [mid.id]

      assert {400, body} =
               api_get("/api/json/posts?filter[#{price}][gt]=9&custom_filter[#{price}][gt]=1")

      assert [%{} | _] = body["errors"]
    end

    test "a custom sort before a built-in one is one combined order (#2356)" do
      {_admin, price, %{9 => cheap, 10 => mid, 30 => dear}} = priced_posts()
      scope = "filter[#{price}][null]=false"

      assert {200, body} = api_get("/api/json/posts?#{scope}&sort=#{price},title")
      assert ids(body) == [cheap.id, mid.id, dear.id]

      assert {200, body} = api_get("/api/json/posts?#{scope}&sort=-#{price},-title")
      assert ids(body) == [dear.id, mid.id, cheap.id]

      assert {200, body} = api_get("/api/json/posts?#{scope}&sort=title,#{price}")
      assert ids(body) == [mid.id, cheap.id, dear.id]

      # sort=title&custom_sort=… keeps today's meaning
      assert {200, body} = api_get("/api/json/posts?#{scope}&sort=title&custom_sort=#{price}")
      assert ids(body) == [mid.id, cheap.id, dear.id]

      # sort and custom_sort together: moved tokens first
      assert {200, body} = api_get("/api/json/posts?#{scope}&sort=-#{price}&custom_sort=#{price}")
      assert ids(body) == [dear.id, mid.id, cheap.id]
    end

    test "filter[or]/[and]/[not] may name custom fields and built-ins together (#2355)" do
      {_admin, price, %{9 => cheap, 10 => mid, 30 => dear}} = priced_posts()

      assert {200, body} =
               api_get(
                 "/api/json/posts?filter[or][0][#{price}][gt]=20&filter[or][1][title]=Aa mid&sort=title"
               )

      assert ids(body) == [mid.id, dear.id]

      assert {200, body} =
               api_get(
                 "/api/json/posts?filter[#{price}][null]=false&filter[not][#{price}][lt]=10&sort=#{price}"
               )

      assert ids(body) == [mid.id, dear.id]

      assert {200, body} =
               api_get(
                 "/api/json/posts?filter[#{price}][null]=false&filter[and][0][#{price}][lt]=30&filter[and][1][title]=Bb cheap"
               )

      assert ids(body) == [cheap.id]

      # an unknown name inside a group is the same 400 as outside one
      assert {400, body} = api_get("/api/json/posts?filter[or][0][nope#{price}]=1")
      assert [%{"detail" => "unknown custom field" <> _}] = body["errors"]
    end

    test "names that are neither built-in nor custom fail like an unknown custom field" do
      ghost = "ghost#{System.unique_integer([:positive])}"

      assert {400, body} = api_get("/api/json/posts?filter[#{ghost}]=x")

      assert [%{"code" => "invalid_argument", "detail" => "unknown custom field" <> _}] =
               body["errors"]

      assert {400, body} = api_get("/api/json/posts?sort=#{ghost}")

      assert [%{"code" => "invalid_argument", "detail" => "unknown custom field" <> _}] =
               body["errors"]

      # built-in but unfilterable / unsortable: unchanged
      assert {400, _} = api_get("/api/json/posts?filter[path]=x")
      assert {400, body} = api_get("/api/json/posts?sort=word_count")
      assert [%{"code" => "invalid_sort"}] = body["errors"]

      # a non-map filter
      assert {400, _} = api_get("/api/json/posts?filter[]=x")
      assert {400, _} = api_get("/api/json/posts?filter=#{ghost}")
    end

    test "a private field answers an anonymous caller exactly as an unknown one" do
      admin = user(:admin)
      secret = "secret#{System.unique_integer([:positive])}"
      ghost = "ghost#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{content_type: :post, name: secret, label: "S", field_type: :string, private: true},
        actor: admin
      )

      post = make_post(%{title: "Priv", custom_fields: %{secret => "x"}}, admin)

      shape = fn name, opts ->
        conn = raw_get("/api/json/posts?filter[#{name}]=x", opts)

        {conn.status,
         conn.resp_body
         |> Jason.decode!()
         |> error_shape()
         |> inspect()
         |> String.replace(name, "NAME")}
      end

      assert shape.(secret, []) == shape.(ghost, [])
      assert {400, _} = shape.(secret, [])

      editor = token(user(:editor))
      assert {200, body} = api_get("/api/json/posts?filter[#{secret}]=x", token: editor)
      assert ids(body) == [post.id]
    end

    test "relationship operators and reference counts through the alias" do
      admin = user(:admin)
      refs = "refs#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: refs,
          label: "Refs",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        actor: admin
      )

      a = published_post_page(%{title: "A"}, admin)
      b = published_post_page(%{title: "B"}, admin)
      tag = CMS.create_tag!(%{name: "atag-#{slug()}", slug: slug()}, actor: admin)

      ab =
        published_post(
          %{title: "AB", custom_fields: %{refs => [a.id, b.id]}, tag_ids: [tag.id]},
          admin
        )

      _b_only = published_post(%{title: "B", custom_fields: %{refs => [b.id]}}, admin)

      assert {200, body} = api_get("/api/json/posts?filter[#{refs}][has]=#{a.id}")
      assert ids(body) == [ab.id]

      assert {200, body} = api_get("/api/json/posts?filter[#{refs}][count][gte]=2")
      assert ids(body) == [ab.id]

      assert {200, body} = api_get("/api/json/posts?filter[tags][has][]=#{tag.id}")
      assert ids(body) == [ab.id]

      assert {200, body} = api_get("/api/json/posts?filter[tags][slug]=#{tag.slug}")
      assert ab.id in ids(body)
    end

    test "keyset page 2 with a custom sort through the alias, on :read and :published" do
      {_admin, price, %{9 => cheap, 10 => mid, 30 => dear}} = priced_posts()

      for base <- ["/api/json/posts", "/api/json/posts/published"] do
        query = "filter[#{price}][null]=false&sort=#{price}&page[limit]=2"
        assert {200, page1} = api_get("#{base}?#{query}")
        assert ids(page1) == [cheap.id, mid.id]

        %URI{path: path, query: next_query} = URI.parse(page1["links"]["next"])
        assert {200, page2} = api_get("#{path}?#{next_query}")
        assert ids(page2) == [dear.id]
      end
    end

    test "search routes: explicit sort > sort=<custom> > relevance" do
      admin = user(:admin)
      price = "price#{System.unique_integer([:positive])}"
      term = "aliassearch#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{content_type: :post, name: price, label: "Price", field_type: :integer},
        actor: admin
      )

      pricey = published_post(%{title: "Aaa #{term}", custom_fields: %{price => 30}}, admin)
      cheap = published_post(%{title: "Zzz #{term}", custom_fields: %{price => 10}}, admin)
      mid = published_post(%{title: "Mmm #{term}", custom_fields: %{price => 20}}, admin)

      for route <- ["search", "search/published"] do
        base = "/api/json/posts/#{route}?query=#{term}&locale=en"

        assert {200, body} = api_get(base)
        assert ids(body) == [mid.id, cheap.id, pricey.id]

        assert {200, body} = api_get(base <> "&sort=#{price}")
        assert ids(body) == [cheap.id, mid.id, pricey.id]

        assert {200, body} = api_get(base <> "&sort=title,-#{price}")
        assert ids(body) == [pricey.id, mid.id, cheap.id]

        assert {200, body} = api_get(base <> "&sort=title&custom_sort=#{price}")
        assert ids(body) == [pricey.id, mid.id, cheap.id]

        # a custom token before a built-in one (#2356): one combined order,
        # and its keyset page 2 walks on from page 1
        assert {200, body} = api_get(base <> "&sort=#{price},title")
        assert ids(body) == [cheap.id, mid.id, pricey.id]

        assert {200, page1} = api_get(base <> "&sort=#{price},-title&page[limit]=2")
        assert ids(page1) == [cheap.id, mid.id]
        %URI{path: path, query: next_query} = URI.parse(page1["links"]["next"])
        assert {200, page2} = api_get("#{path}?#{next_query}")
        assert ids(page2) == [pricey.id]

        # keyset page 2 with a jsonb sort key
        assert {200, page1} = api_get(base <> "&sort=#{price}&page[limit]=2")
        assert ids(page1) == [cheap.id, mid.id]
        %URI{path: path, query: next_query} = URI.parse(page1["links"]["next"])
        assert {200, page2} = api_get("#{path}?#{next_query}")
        assert ids(page2) == [pricey.id]
      end
    end

    test "other routes are not rewritten: a lookup by id and writes" do
      {admin, price, %{10 => mid}} = priced_posts()

      conn = raw_get("/api/json/posts/#{mid.id}?filter[#{price}]=10")
      refute conn.resp_body =~ "custom field"

      conn =
        build_conn()
        |> put_req_header("accept", @accept)
        |> put_req_header("content-type", @accept)
        |> put_req_header("authorization", "Bearer #{token(admin)}")
        |> post(
          "/api/json/posts?filter[#{price}]=1",
          ~s({"data":{"type":"post","attributes":{}}})
        )

      refute conn.resp_body =~ "unknown custom field"
    end

    test "entries: filter[type_name] scopes the alias; unscoped divergent types are refused" do
      admin = user(:admin)
      rating = "rating#{System.unique_integer([:positive])}"

      mk_type = fn ->
        CMS.create_type_definition!(
          %{name: "aliasdyn#{System.unique_integer([:positive])}", label: "Dyn"},
          actor: admin
        )
      end

      recipes = mk_type.()
      guides = mk_type.()

      for {type, field_type} <- [{recipes, :integer}, {guides, :string}] do
        CMS.create_field_definition!(
          %{type_definition_id: type.id, name: rating, label: "R", field_type: field_type},
          actor: admin
        )
      end

      high =
        KilnCMS.CMS.ContentTypes.create!(
          recipes.name,
          %{title: "E", slug: slug(), custom_fields: %{rating => 5}},
          actor: admin
        )

      _low =
        KilnCMS.CMS.ContentTypes.create!(
          recipes.name,
          %{title: "E2", slug: slug(), custom_fields: %{rating => 2}},
          actor: admin
        )

      tok = token(admin)

      assert {200, body} =
               api_get(
                 "/api/json/entries?filter[type_name]=#{recipes.name}&filter[#{rating}][gte]=3",
                 token: tok
               )

      assert ids(body) == [high.id]

      assert {400, body} = api_get("/api/json/entries?filter[#{rating}][gt]=3", token: tok)
      assert [%{"detail" => detail}] = body["errors"]
      assert detail =~ "different type per content type"
    end
  end

  # #2743: an object or a list sent for a field that holds one value is the
  # field's 400, not a 500 out of `to_string/1`.
  describe "custom field value shapes" do
    defp api_patch(path, body, tok) do
      conn =
        build_conn()
        |> put_req_header("accept", @accept)
        |> put_req_header("content-type", @accept)
        |> put_req_header("authorization", "Bearer #{tok}")
        |> patch(path, Jason.encode!(body))

      {conn.status, Jason.decode!(conn.resp_body)}
    end

    setup do
      admin = user(:admin)
      subtitle = "subtitle#{System.unique_integer([:positive])}"
      notes = "notes#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{content_type: :page, name: subtitle, label: "Subtitle", field_type: :string},
        actor: admin
      )

      CMS.create_field_definition!(
        %{content_type: :page, name: notes, label: "Notes", field_type: :text},
        actor: admin
      )

      page = CMS.create_page!(%{title: "Shapes", slug: slug()}, actor: admin)
      %{admin: admin, page: page, subtitle: subtitle, notes: notes, tok: token(admin)}
    end

    test "a locale map on a field that is not localized is a 400 naming the field", ctx do
      body = %{
        data: %{
          type: "page",
          id: ctx.page.id,
          attributes: %{custom_fields: %{ctx.subtitle => %{"en" => "x"}}}
        }
      }

      assert {400, body} = api_patch("/api/json/pages/#{ctx.page.id}", body, ctx.tok)

      assert [
               %{
                 "code" => "invalid_attribute",
                 "detail" => detail,
                 "source" => %{"pointer" => "/data/attributes/custom_fields"}
               }
             ] = body["errors"]

      assert detail ==
               "Subtitle (#{ctx.subtitle}) must be a single value, not an object or a list"

      assert CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields == %{}
    end

    test "a list on a text field is a 400, not joined into one string", ctx do
      body = %{
        data: %{
          type: "page",
          id: ctx.page.id,
          attributes: %{custom_fields: %{ctx.notes => ["a", "b"]}}
        }
      }

      assert {400, body} = api_patch("/api/json/pages/#{ctx.page.id}", body, ctx.tok)
      assert [%{"code" => "invalid_attribute", "detail" => detail}] = body["errors"]
      assert detail == "Notes (#{ctx.notes}) must be a single value, not an object or a list"
    end
  end

  # Page equivalent of `published_post/2`.
  defp published_post_page(attrs, admin) do
    attrs
    |> Map.put_new(:slug, slug())
    |> then(&CMS.create_page!(&1, actor: admin))
    |> then(&CMS.publish_page!(&1, %{}, actor: admin))
  end
end
