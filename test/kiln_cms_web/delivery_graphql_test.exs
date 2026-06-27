defmodule KilnCMSWeb.DeliveryGraphqlTest do
  @moduledoc """
  Issue #34 — the curated, read-only public GraphQL delivery surface (D7).

  Anonymous queries go through the read policies, so only published content (and
  world-readable taxonomy) is ever returned, and no authoring/workflow mutations
  are exposed at all.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  @schema KilnCMSWeb.GraphqlSchema

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gql-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "gql-#{System.unique_integer([:positive])}"

  defp run(query, variables \\ %{}), do: Absinthe.run(query, @schema, variables: variables)

  describe "published content reads" do
    test "postBySlug returns a published post and hides drafts" do
      admin = admin()
      live_slug = slug()
      draft_slug = slug()

      post =
        CMS.create_post!(%{title: "Live", slug: live_slug, excerpt: "hi"}, actor: admin)
        |> then(&CMS.publish_post!(&1, %{}, actor: admin))

      _draft = CMS.create_post!(%{title: "Draft", slug: draft_slug}, actor: admin)

      query = """
      query ($slug: String!, $locale: String!) {
        postBySlug(slug: $slug, locale: $locale) { id title excerpt published }
      }
      """

      assert {:ok, %{data: %{"postBySlug" => found}}} =
               run(query, %{"slug" => live_slug, "locale" => "en"})

      assert found["id"] == post.id
      assert found["published"] == true

      # A draft slug is invisible to anonymous callers.
      assert {:ok, %{data: %{"postBySlug" => nil}}} =
               run(query, %{"slug" => draft_slug, "locale" => "en"})
    end

    test "pageBySlug returns a published page" do
      admin = admin()
      page_slug = slug()

      page =
        CMS.create_page!(%{title: "Live page", slug: page_slug}, actor: admin)
        |> then(&CMS.publish_page!(&1, %{}, actor: admin))

      query = """
      query ($slug: String!, $locale: String!) {
        pageBySlug(slug: $slug, locale: $locale) { id title }
      }
      """

      assert {:ok, %{data: %{"pageBySlug" => %{"id" => id}}}} =
               run(query, %{"slug" => page_slug, "locale" => "en"})

      assert id == page.id
    end

    test "publishedPosts lists only published posts" do
      admin = admin()
      marker = "pubmarker#{System.unique_integer([:positive])}"

      post =
        CMS.create_post!(%{title: "#{marker} live", slug: slug()}, actor: admin)
        |> then(&CMS.publish_post!(&1, %{}, actor: admin))

      _draft = CMS.create_post!(%{title: "#{marker} draft", slug: slug()}, actor: admin)

      # #195: publishedPosts is offset-paginated (a PageOfPost with results+count),
      # matching the JSON:API /published feed.
      query = "{ publishedPosts(limit: 100) { results { id title } count } }"

      assert {:ok, %{data: %{"publishedPosts" => %{"results" => posts, "count" => count}}}} =
               run(query)

      titles = Enum.map(posts, & &1["title"])
      assert "#{marker} live" in titles
      refute "#{marker} draft" in titles
      assert post.id in Enum.map(posts, & &1["id"])
      assert is_integer(count)
    end

    test "postTranslations lists every published locale variant of a slug" do
      admin = admin()
      shared = slug()

      en =
        CMS.create_post!(%{title: "EN", slug: shared, locale: "en"}, actor: admin)
        |> then(&CMS.publish_post!(&1, %{}, actor: admin))

      fr =
        CMS.create_post!(%{title: "FR", slug: shared, locale: "fr"}, actor: admin)
        |> then(&CMS.publish_post!(&1, %{}, actor: admin))

      query = """
      query ($slug: String!) {
        postTranslations(slug: $slug) { id locale }
      }
      """

      assert {:ok, %{data: %{"postTranslations" => rows}}} = run(query, %{"slug" => shared})

      ids = Enum.map(rows, & &1["id"])
      assert en.id in ids
      assert fr.id in ids
    end
  end

  describe "taxonomy reads" do
    test "categories and categoryBySlug are world-readable" do
      admin = admin()
      cat_slug = slug()
      category = CMS.create_category!(%{name: "News", slug: cat_slug}, actor: admin)

      list_q = "{ categories { id slug } }"
      assert {:ok, %{data: %{"categories" => cats}}} = run(list_q)
      assert category.id in Enum.map(cats, & &1["id"])

      get_q = """
      query ($slug: String!) { categoryBySlug(slug: $slug) { id name } }
      """

      assert {:ok, %{data: %{"categoryBySlug" => %{"id" => id}}}} =
               run(get_q, %{"slug" => cat_slug})

      assert id == category.id
    end

    test "tags and tagBySlug are world-readable" do
      admin = admin()
      tag_slug = slug()
      tag = CMS.create_tag!(%{name: "Elixir", slug: tag_slug}, actor: admin)

      assert {:ok, %{data: %{"tags" => tags}}} = run("{ tags { id slug } }")
      assert tag.id in Enum.map(tags, & &1["id"])

      get_q = "query ($slug: String!) { tagBySlug(slug: $slug) { id name } }"

      assert {:ok, %{data: %{"tagBySlug" => %{"id" => id}}}} =
               run(get_q, %{"slug" => tag_slug})

      assert id == tag.id
    end
  end

  describe "deliberate non-exposure (D7)" do
    test "no authoring/workflow mutations are exposed" do
      mutation_fields =
        @schema
        |> Absinthe.Schema.lookup_type("RootMutationType")
        |> case do
          nil -> %{}
          type -> type.fields
        end

      names = Map.keys(mutation_fields)

      # The public surface is read-only — none of the content write actions leak.
      for forbidden <- [
            :create_page,
            :update_page,
            :publish_page,
            :destroy_page,
            :create_post,
            :publish_post,
            :create_category,
            :create_tag
          ] do
        refute forbidden in names,
               "expected no #{forbidden} mutation on the public GraphQL surface"
      end
    end

    test "media library has no top-level query (resolved only as nested featuredImage)" do
      query_fields = Absinthe.Schema.lookup_type(@schema, "RootQueryType").fields
      names = Map.keys(query_fields)

      refute :media_items in names
      refute :list_media_items in names
    end
  end

  # Regression for #183: the public GraphQL surface must never expose author PII.
  # User has no GraphQL type, so the content types expose only the opaque
  # `authorId` foreign key — there is no nested `author` object through which
  # email / role could be selected.
  describe "author PII redaction (#183)" do
    for type <- ["Post", "Page"] do
      test "the #{type} GraphQL type exposes authorId but no author object/PII" do
        fields = Map.keys(Absinthe.Schema.lookup_type(@schema, unquote(type)).fields)

        assert :author_id in fields
        refute :author in fields
        refute :email in fields
        refute :role in fields
      end
    end

    test "selecting a nested author object is a schema error, not a leak" do
      admin = admin()
      s = slug()

      CMS.create_post!(%{title: "Byline", slug: s}, actor: admin)
      |> then(&CMS.publish_post!(&1, %{}, actor: admin))

      assert {:ok, %{errors: [%{message: msg} | _]}} =
               run(
                 "query($s:String!,$l:String!){ postBySlug(slug:$s,locale:$l){ author { email } } }",
                 %{"s" => s, "l" => "en"}
               )

      assert msg =~ ~r/Cannot query field "author"/
    end
  end

  # Regression for #184: a bearer token widens the `:read`/`:search` policies for
  # editors, but the `*BySlug` queries run `:public_by_slug`, which hard-filters
  # `state == :published` in the action — so they never return drafts, authed or
  # not. The docs previously claimed otherwise.
  describe "bearer does not widen *BySlug (#184)" do
    defp editor do
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "gqled-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })
    end

    defp run_as(actor, query, variables),
      do: Absinthe.run(query, @schema, variables: variables, context: %{actor: actor})

    test "postBySlug returns null for a draft slug even with an editor actor" do
      admin = admin()
      s = slug()
      # Created, deliberately left in :draft.
      _draft = CMS.create_post!(%{title: "Hidden draft", slug: s}, actor: admin)

      q = "query($s:String!,$l:String!){ postBySlug(slug:$s,locale:$l){ id state } }"

      # Anonymous: null (published-only).
      assert {:ok, %{data: %{"postBySlug" => nil}}} = run(q, %{"s" => s, "l" => "en"})

      # Editor bearer: STILL null — the action filter ignores the actor.
      assert {:ok, %{data: %{"postBySlug" => nil}}} =
               run_as(editor(), q, %{"s" => s, "l" => "en"})
    end

    test "searchPosts DOES widen for an editor actor (contrast with *BySlug)" do
      admin = admin()
      term = "draftsearch#{System.unique_integer([:positive])}"
      draft = CMS.create_post!(%{title: "#{term} draft", slug: slug()}, actor: admin)

      q = "query($q:String!){ searchPosts(query:$q){ id title } }"

      # Anonymous: the draft is hidden.
      assert {:ok, %{data: %{"searchPosts" => anon}}} = run(q, %{"q" => term})
      refute draft.id in Enum.map(anon, & &1["id"])

      # Editor bearer: the draft surfaces through search.
      assert {:ok, %{data: %{"searchPosts" => found}}} = run_as(editor(), q, %{"q" => term})
      assert draft.id in Enum.map(found, & &1["id"])
    end
  end
end
