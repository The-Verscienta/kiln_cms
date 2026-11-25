defmodule KilnCMSWeb.SiteMembershipDeliveryTest do
  @moduledoc """
  Gated documents over the public HTML site follow the reader's membership on
  the site serving the request (#337 Phase 2): the audiences of an `:active`
  `OrgMembership` there, resolved by `KilnCMS.Accounts.Scoping.audiences/2` as
  the read policies resolve them. A membership on another site, one that is
  pending or rejected, an erased account and the account-wide
  `User.audiences` column (where billing keeps the union across sites) all
  read like a signed-out visitor: the teaser, never the body.

  `async: false`: the delivery payload cache is a global Cachex table while
  sandboxes are per-test, and the cache tests below depend on real cache state.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())
  @password "password123456"
  @teaser "The public teaser sentence."

  setup do
    KilnCMS.Cache.bust_published()
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    Ash.Seed.seed!(User, %{
      email: "smd-admin-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # A signed-in reader whose account-wide `User.audiences` column holds
  # `global`, with no membership anywhere until the test seeds one.
  defp reader(global) do
    email = "smd-reader-#{uniq()}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :viewer,
      audiences: global
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp membership(user, org_id, status, audiences) do
    Ash.Seed.seed!(OrgMembership, %{
      organization_id: org_id,
      user_id: user.id,
      role: :viewer,
      status: status,
      audiences: audiences
    })
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp blocks(body), do: [%{"_type" => "heading", "text" => body, "level" => 2}]

  # A published, `@gated` document of `kind` on the default org (the bare test
  # host), with `body` in its block tree and `@teaser` as its summary. Returns
  # the path it is served at.
  defp gated_document(kind, body, attrs \\ %{})

  defp gated_document(:page, body, attrs) do
    actor = admin()

    {:ok, page} =
      %{
        title: "A gated page",
        slug: "smd-page-#{uniq()}",
        audience: @gated,
        seo_description: @teaser,
        blocks: blocks(body)
      }
      |> Map.merge(attrs)
      |> CMS.create_page(actor: actor)

    {:ok, page} = CMS.publish_page(page, %{}, actor: actor)
    page.path_alias || "/" <> page.slug
  end

  defp gated_document(:alias, body, attrs),
    do: gated_document(:page, body, Map.put(attrs, :path_alias, "/smd/aliased/#{uniq()}"))

  defp gated_document(:post, body, attrs) do
    actor = admin()

    {:ok, post} =
      %{
        title: "A gated post",
        slug: "smd-post-#{uniq()}",
        audience: @gated,
        excerpt: @teaser,
        blocks: blocks(body)
      }
      |> Map.merge(attrs)
      |> CMS.create_post(actor: actor)

    {:ok, post} = CMS.publish_post(post, %{}, actor: actor)
    "/blog/" <> post.slug
  end

  defp gated_document(:entry, body, attrs) do
    actor = admin()
    name = "smdtype#{uniq()}"

    td =
      CMS.create_type_definition!(
        %{name: name, label: "Guides", plural_label: name, path_segment: name},
        actor: actor
      )

    entry =
      %{
        title: "A gated entry",
        slug: "smd-entry-#{uniq()}",
        type_definition_id: td.id,
        audience: @gated,
        seo_description: @teaser,
        blocks: blocks(body)
      }
      |> Map.merge(attrs)
      |> CMS.create_entry!(actor: actor)
      |> CMS.publish_entry!(actor: actor)

    "/#{td.path_segment}/#{entry.slug}"
  end

  defp body, do: "MEMBERS-ONLY-BODY-#{uniq()}"

  defp default_org_id, do: Accounts.default_org_id()

  # The page a reader with no gated audience here is served: the teaser.
  defp assert_teaser(conn, body) do
    html = html_response(conn, 200)
    refute html =~ body
    assert html =~ @teaser
  end

  for kind <- [:page, :post, :entry, :alias] do
    describe "a gated #{kind} follows the reader's membership on this site" do
      @kind kind

      test "an account-wide audience with no membership here reads the teaser", %{conn: conn} do
        body = body()
        path = gated_document(@kind, body)

        conn |> log_in(reader([@gated])) |> get(path) |> assert_teaser(body)
      end

      test "a membership on another site does not open it here", %{conn: conn} do
        body = body()
        path = gated_document(@kind, body)
        other = org("smd-other")
        user = reader([@gated])
        membership(user, other.id, :active, [@gated])

        conn |> log_in(user) |> get(path) |> assert_teaser(body)
      end

      test "a pending membership here reads the teaser", %{conn: conn} do
        body = body()
        path = gated_document(@kind, body)
        user = reader([@gated])
        membership(user, default_org_id(), :pending, [@gated])

        conn |> log_in(user) |> get(path) |> assert_teaser(body)
      end

      test "a rejected membership here reads the teaser", %{conn: conn} do
        body = body()
        path = gated_document(@kind, body)
        user = reader([@gated])
        membership(user, default_org_id(), :rejected, [@gated])

        conn |> log_in(user) |> get(path) |> assert_teaser(body)
      end

      test "an active membership here holding the audience reads the body", %{conn: conn} do
        body = body()
        path = gated_document(@kind, body)
        user = reader([])
        membership(user, default_org_id(), :active, [@gated])

        html = conn |> log_in(user) |> get(path) |> html_response(200)

        assert html =~ body
      end

      test "an active membership here without the audience reads the teaser", %{conn: conn} do
        body = body()
        path = gated_document(@kind, body)
        user = reader([@gated])
        membership(user, default_org_id(), :active, [])

        conn |> log_in(user) |> get(path) |> assert_teaser(body)
      end

      test "a signed-out visitor reads the teaser", %{conn: conn} do
        body = body()
        path = gated_document(@kind, body)

        conn |> get(path) |> assert_teaser(body)
      end
    end
  end

  describe "an erased account" do
    test "reads the teaser whatever its rows still hold", %{conn: conn} do
      body = body()
      path = gated_document(:post, body)
      user = reader([@gated])
      membership(user, default_org_id(), :active, [@gated])
      Ash.Seed.update!(user, %{anonymized_at: DateTime.utc_now()})

      conn = conn |> log_in(user) |> get(path)

      refute response(conn, conn.status) =~ body
    end
  end

  describe "the delivery cache" do
    test "a member's render on one site is not served for the same slug on another",
         %{conn: conn} do
      slug = "smd-shared-#{uniq()}"
      domain = "smd-a-#{uniq()}.example.com"
      site_a = org("smd-a", custom_domain: domain)
      body_a = body()
      body_b = body()

      Ash.Seed.seed!(
        KilnCMS.CMS.Page,
        %{
          title: "Site A",
          slug: slug,
          state: :published,
          audience: @gated,
          seo_description: @teaser,
          blocks: KilnCMS.TypedFixtures.typed_blocks([%{type: :heading, content: body_a}])
        },
        tenant: site_a
      )

      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Site B",
        slug: slug,
        state: :published,
        audience: @gated,
        seo_description: @teaser,
        blocks: KilnCMS.TypedFixtures.typed_blocks([%{type: :heading, content: body_b}])
      })

      user = reader([@gated])
      membership(user, site_a.id, :active, [@gated])

      html_a = %{conn | host: domain} |> log_in(user) |> get("/" <> slug) |> html_response(200)
      assert html_a =~ body_a

      html_b = build_conn() |> log_in(user) |> get("/" <> slug) |> html_response(200)
      refute html_b =~ body_a
      refute html_b =~ body_b
      assert html_b =~ @teaser

      anon_b = build_conn() |> get("/" <> slug) |> html_response(200)
      refute anon_b =~ body_a
      refute anon_b =~ body_b
    end

    test "a change to the reader's membership here takes effect on the next request",
         %{conn: conn} do
      body = body()
      path = gated_document(:page, body)
      user = reader([])
      membership = membership(user, default_org_id(), :pending, [@gated])

      conn |> log_in(user) |> get(path) |> assert_teaser(body)

      membership = Ash.Seed.update!(membership, %{status: :active})
      html = build_conn() |> log_in(user) |> get(path) |> html_response(200)
      assert html =~ body

      Ash.Seed.update!(membership, %{audiences: []})
      build_conn() |> log_in(user) |> get(path) |> assert_teaser(body)
    end
  end
end
