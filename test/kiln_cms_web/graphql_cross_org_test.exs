defmodule KilnCMSWeb.GraphqlCrossOrgTest do
  @moduledoc """
  Anonymous HTTP `/gql` is scoped to the org of the `Host` it arrives on
  (threat-model residual 8, #1614).

  `KilnCMSWeb.Plugs.SetTenant` resolves the org in the endpoint and
  `AshGraphql.Plug` copies it into the Absinthe context, so an anonymous query
  is a tenant-scoped read. Nothing pinned that down over HTTP before: the
  strict-host suite covers only the `/ws/gql` socket, and the other GraphQL
  suites call `Absinthe.run/3` with no host at all.

  Every anonymous-readable root field is asked the same question twice, with
  org A's content published: on A's host (the positive control — the query
  really does find A's record, so its absence elsewhere means something) and
  on org B's host, where none of it may appear. B publishes content under the
  *same* slugs, so a single lookup on B's host must answer with B's record,
  not merely with nothing.

  The main suite is built fail-open (`:strict_tenancy` is off outside
  `KILN_STRICT_TEST`), so a request that lost its tenant would read across
  every org rather than fail — which is exactly what these tests would catch.

  `async: false`: the unknown-host cases set `:tenant_strict_host` and the
  `OrgCount` verdict, both VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import KilnCMS.OrgFixtures

  alias KilnCMS.CMS
  alias KilnCMSWeb.Tenant
  alias KilnCMSWeb.Tenant.OrgCount

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gql-xorg-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp host(org), do: "#{org.slug}.#{Tenant.base_host()}"

  # One site's worth of published content, every title carrying `marker` so a
  # raw-body search finds any field that leaks it. Slugs are shared across the
  # two orgs (passed in), so a by-slug lookup has a same-named rival to return.
  defp publish_site(org, marker, slugs, actor) do
    opts = [actor: actor, tenant: org]

    post =
      %{title: "#{marker} post", slug: slugs.post, excerpt: marker}
      |> CMS.create_post!(opts)
      |> CMS.publish_post!(%{}, opts)

    page =
      %{title: "#{marker} page", slug: slugs.page}
      |> CMS.create_page!(opts)
      |> CMS.publish_page!(%{}, opts)

    definition =
      CMS.create_type_definition!(
        %{name: slugs.type, label: "#{marker} type", plural_label: "#{marker} types"},
        opts
      )

    entry =
      %{title: "#{marker} entry", slug: slugs.entry, type_definition_id: definition.id}
      |> CMS.create_entry!(opts)
      |> CMS.publish_entry!(%{}, opts)

    category = CMS.create_category!(%{name: "#{marker} category", slug: slugs.taxon}, opts)
    tag = CMS.create_tag!(%{name: "#{marker} tag", slug: slugs.taxon}, opts)
    group = CMS.create_tag_group!(%{name: "#{marker} group", slug: slugs.taxon}, opts)

    menu = CMS.create_menu!(%{key: slugs.menu, name: "#{marker} menu", locale: "en"}, opts)

    CMS.create_menu_item!(
      %{
        menu_id: menu.id,
        label: "#{marker} item",
        link_type: :content,
        target_type: "page",
        target_id: page.id
      },
      opts
    )

    %{
      org: org,
      marker: marker,
      post: post,
      page: page,
      entry: entry,
      definition: definition,
      category: category,
      tag: tag,
      group: group,
      ids: [post.id, page.id, entry.id, definition.id, category.id, tag.id, group.id, menu.id]
    }
  end

  setup do
    actor = admin()
    n = System.unique_integer([:positive])

    slugs = %{
      post: "xorg-post-#{n}",
      page: "xorg-page-#{n}",
      entry: "xorg-entry-#{n}",
      type: "xorg_type_#{n}",
      taxon: "xorg-taxon-#{n}",
      menu: "xorg-menu-#{n}"
    }

    a = publish_site(org("gql-a"), "alphamark#{n}", slugs, actor)
    b = publish_site(org("gql-b"), "bravomark#{n}", slugs, actor)
    %{a: a, b: b, slugs: slugs}
  end

  # A fresh conn — so a fresh peer address (`ConnCase.build_conn/0`) — per
  # request: the positive control alone sends 62, past the shipped `:gql`
  # budget of 60 a minute per address, and the suite's raised test limit is
  # application env another module may be holding at a different value.
  defp gql(host, query, variables) do
    %{build_conn() | host: host}
    |> put_req_header("content-type", "application/json")
    |> post("/gql", Jason.encode!(%{query: query, variables: variables}))
  end

  # Every anonymous-readable root field of `docs/api/schema.graphql`'s
  # `RootQueryType` except `health` (no data) and the ML-only `semanticSearch*`
  # legs, which need a model this build does not compile. `ids` are the
  # record ids a response on that site's host must contain.
  defp cases(site, slugs) do
    term = site.marker

    [
      {"publishedPosts", "{ publishedPosts { results { id title } } }", %{}, [site.post.id]},
      {"publishedPages", "{ publishedPages { results { id title } } }", %{}, [site.page.id]},
      {"publishedEntries", "{ publishedEntries { results { id title } } }", %{}, [site.entry.id]},
      {"publishedPosts filtered by id",
       "query($id: ID!) { publishedPosts(filter: {id: {eq: $id}}) { results { id title } } }",
       %{"id" => site.post.id}, [site.post.id]},
      {"postBySlug", ~s|query($s: String!) { postBySlug(slug: $s, locale: "en") { id title } }|,
       %{"s" => slugs.post}, [site.post.id]},
      {"pageBySlug", ~s|query($s: String!) { pageBySlug(slug: $s, locale: "en") { id title } }|,
       %{"s" => slugs.page}, [site.page.id]},
      {"entryBySlug",
       ~s|query($s: String!, $t: ID!) { entryBySlug(slug: $s, locale: "en", typeDefinitionId: $t) { id title } }|,
       %{"s" => slugs.entry, "t" => site.definition.id}, [site.entry.id]},
      {"postTranslations", "query($s: String!) { postTranslations(slug: $s) { id title } }",
       %{"s" => slugs.post}, [site.post.id]},
      {"pageTranslations", "query($s: String!) { pageTranslations(slug: $s) { id title } }",
       %{"s" => slugs.page}, [site.page.id]},
      {"entryTranslations",
       "query($s: String!, $t: ID!) { entryTranslations(slug: $s, typeDefinitionId: $t) { id title } }",
       %{"s" => slugs.entry, "t" => site.definition.id}, [site.entry.id]},
      {"searchPosts", "query($q: String!) { searchPosts(query: $q) { id title } }",
       %{"q" => term}, [site.post.id]},
      {"searchPages", "query($q: String!) { searchPages(query: $q) { id title } }",
       %{"q" => term}, [site.page.id]},
      {"searchEntries", "query($q: String!) { searchEntries(query: $q) { id title } }",
       %{"q" => term}, [site.entry.id]},
      {"searchPublishedPosts",
       "query($q: String!) { searchPublishedPosts(query: $q) { id title } }", %{"q" => term},
       [site.post.id]},
      {"searchPublishedPages",
       "query($q: String!) { searchPublishedPages(query: $q) { id title } }", %{"q" => term},
       [site.page.id]},
      {"searchPublishedEntries",
       "query($q: String!) { searchPublishedEntries(query: $q) { id title } }", %{"q" => term},
       [site.entry.id]},
      {"autocompletePosts", "query($p: String!) { autocompletePosts(prefix: $p) { id title } }",
       %{"p" => term}, [site.post.id]},
      {"autocompletePages", "query($p: String!) { autocompletePages(prefix: $p) { id title } }",
       %{"p" => term}, [site.page.id]},
      {"autocompleteEntries",
       "query($p: String!) { autocompleteEntries(prefix: $p) { id title } }", %{"p" => term},
       [site.entry.id]},
      {"autocompletePublishedPosts",
       "query($p: String!) { autocompletePublishedPosts(prefix: $p) { id title } }",
       %{"p" => term}, [site.post.id]},
      {"autocompletePublishedPages",
       "query($p: String!) { autocompletePublishedPages(prefix: $p) { id title } }",
       %{"p" => term}, [site.page.id]},
      {"autocompletePublishedEntries",
       "query($p: String!) { autocompletePublishedEntries(prefix: $p) { id title } }",
       %{"p" => term}, [site.entry.id]},
      {"categories", "{ categories { id name } }", %{}, [site.category.id]},
      {"categoryBySlug", "query($s: String!) { categoryBySlug(slug: $s) { id name } }",
       %{"s" => slugs.taxon}, [site.category.id]},
      {"tags", "{ tags { id name } }", %{}, [site.tag.id]},
      {"tagBySlug", "query($s: String!) { tagBySlug(slug: $s) { id name } }",
       %{"s" => slugs.taxon}, [site.tag.id]},
      {"tagGroups", "{ tagGroups { id name } }", %{}, [site.group.id]},
      {"tagGroupBySlug", "query($s: String!) { tagGroupBySlug(slug: $s) { id name } }",
       %{"s" => slugs.taxon}, [site.group.id]},
      {"menu", "query($k: String!) { menu(key: $k) { name items { label url } } }",
       %{"k" => slugs.menu}, ["#{term} item"]},
      {"contentAsOf (post)",
       ~s|query($at: DateTime!) { contentAsOf(type: "post", asOf: $at) { slug title } }|,
       %{"at" => DateTime.to_iso8601(DateTime.utc_now())}, ["#{term} post"]},
      {"contentAsOf (page)",
       ~s|query($at: DateTime!) { contentAsOf(type: "page", asOf: $at) { slug title } }|,
       %{"at" => DateTime.to_iso8601(DateTime.utc_now())}, ["#{term} page"]}
    ]
  end

  defp leaks(body, site), do: Enum.filter([site.marker | site.ids], &String.contains?(body, &1))

  describe "an anonymous /gql query on org B's host" do
    test "finds each org's own content on its own host (the positive control)",
         %{a: a, b: b, slugs: slugs} do
      # Collected rather than asserted one by one, so a failure names every
      # field that broke, not just the first.
      misses =
        for site <- [a, b],
            {name, query, vars, expected} <- cases(site, slugs),
            conn = gql(host(site.org), query, vars),
            conn.status != 200 or conn.resp_body =~ ~s("errors") or
              not Enum.all?(expected, &String.contains?(conn.resp_body, &1)),
            do: "#{name} on #{site.marker}'s host: #{conn.status} #{conn.resp_body}"

      assert misses == []
    end

    test "returns none of org A's published content, from any root field",
         %{a: a, b: b, slugs: slugs} do
      # A's queries (A's ids, A's type definition, A's search term) sent to B.
      failures =
        for {name, query, vars, _} <- cases(a, slugs),
            conn = gql(host(b.org), query, vars),
            conn.status != 200 or conn.resp_body =~ ~s("errors") or
              leaks(conn.resp_body, a) != [],
            do: "#{name}: #{conn.status} #{conn.resp_body}"

      assert failures == [],
             "org A's content on B's host (or no answer):\n" <> Enum.join(failures, "\n")
    end

    test "a single lookup by a slug both orgs use answers with B's record, not A's",
         %{a: a, b: b, slugs: slugs} do
      for {field, slug, record} <- [
            {"postBySlug", slugs.post, :post},
            {"pageBySlug", slugs.page, :page}
          ] do
        query = ~s|query($s: String!) { #{field}(slug: $s, locale: "en") { id title } }|
        body = gql(host(b.org), query, %{"s" => slug}) |> json_response(200)

        assert %{"data" => %{^field => %{"id" => id}}} = body
        assert id == Map.fetch!(b, record).id
        refute id == Map.fetch!(a, record).id
      end
    end

    test "cannot reach an A-only record by naming its id or slug", %{a: a, b: b} do
      only_a =
        %{title: "#{a.marker} solo", slug: "solo-#{System.unique_integer([:positive])}"}
        |> CMS.create_post!(actor: admin(), tenant: a.org)
        |> CMS.publish_post!(%{}, actor: admin(), tenant: a.org)

      by_slug = ~s|query($s: String!) { postBySlug(slug: $s, locale: "en") { id } }|

      assert %{"data" => %{"postBySlug" => nil}} =
               gql(host(b.org), by_slug, %{"s" => only_a.slug}) |> json_response(200)

      by_id =
        "query($id: ID!) { publishedPosts(filter: {id: {eq: $id}}) { results { id } } }"

      assert %{"data" => %{"publishedPosts" => %{"results" => []}}} =
               gql(host(b.org), by_id, %{"id" => only_a.id}) |> json_response(200)
    end
  end

  describe "the anonymous GET cache (#1571)" do
    # A CDN keys its copy on the Host as well as the URL, so the one way a copy
    # of A's answer could reach B's host is through revalidation: a client (or
    # an edge) holding A's ETag asking B's host with it. That must get B's full
    # body, not a 304 that tells it to keep serving A's.
    test "A's validator on B's host gets B's body, B's surrogate keys, never a 304",
         %{conn: conn, a: a, b: b} do
      path = "/gql?" <> URI.encode_query(%{query: "{ publishedPosts { results { id title } } }"})

      on_a = conn |> Map.put(:host, host(a.org)) |> get(path)
      assert on_a.status == 200
      assert on_a.resp_body =~ a.marker
      assert [etag_a] = get_resp_header(on_a, "etag")
      assert [cc] = get_resp_header(on_a, "cache-control")
      assert cc =~ "public"
      assert [keys_a] = get_resp_header(on_a, "surrogate-key")
      assert keys_a =~ KilnCMS.CDN.site_key(a.org.id)

      # Sanity: the validator does work on the host that issued it.
      assert build_conn()
             |> Map.put(:host, host(a.org))
             |> put_req_header("if-none-match", etag_a)
             |> get(path)
             |> Map.fetch!(:status) == 304

      on_b =
        build_conn()
        |> Map.put(:host, host(b.org))
        |> put_req_header("if-none-match", etag_a)
        |> get(path)

      assert on_b.status == 200
      assert leaks(on_b.resp_body, a) == []
      assert on_b.resp_body =~ b.marker
      refute get_resp_header(on_b, "etag") == [etag_a]

      assert [keys_b] = get_resp_header(on_b, "surrogate-key")
      assert keys_b =~ KilnCMS.CDN.site_key(b.org.id)
      refute keys_b =~ KilnCMS.CDN.site_key(a.org.id)
    end
  end

  describe "an anonymous /gql query on a host that names no org" do
    setup do
      strict = Application.get_env(:kiln_cms, :tenant_strict_host)
      verdict = OrgCount.verdict()

      on_exit(fn ->
        Application.put_env(:kiln_cms, :tenant_strict_host, strict)
        OrgCount.put(verdict)
      end)

      %{unknown: "no-such-org-#{System.unique_integer([:positive])}.#{Tenant.base_host()}"}
    end

    @list "{ publishedPosts { results { id title } } }"

    test "is refused once a second org exists and TENANT_STRICT_HOST is unset (#1606)",
         %{a: a, unknown: unknown} do
      Application.put_env(:kiln_cms, :tenant_strict_host, :auto)
      OrgCount.put(:multi)

      conn = gql(unknown, @list, %{})

      assert conn.status == 404
      assert leaks(conn.resp_body, a) == []
    end

    test "with strict matching forced off, is the default org's site — still none of A's",
         %{a: a, b: b, unknown: unknown} do
      Application.put_env(:kiln_cms, :tenant_strict_host, false)

      body = gql(unknown, @list, %{}) |> json_response(200)
      encoded = Jason.encode!(body)

      assert %{"data" => %{"publishedPosts" => %{"results" => _}}} = body
      assert leaks(encoded, a) == []
      assert leaks(encoded, b) == []
    end
  end
end
