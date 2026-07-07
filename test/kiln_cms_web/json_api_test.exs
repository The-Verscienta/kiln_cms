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
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => user.email,
        "password" => @password
      })

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

    test "an unknown custom field name is a 400" do
      assert {400, _body} =
               api_get(
                 "/api/json/posts?custom_filter[ghost#{System.unique_integer([:positive])}]=x"
               )
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
