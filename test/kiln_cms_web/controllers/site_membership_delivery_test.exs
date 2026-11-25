defmodule KilnCMSWeb.SiteMembershipDeliveryTest do
  @moduledoc """
  Gated documents over the public HTML site (#337 Phase 2): the audiences come
  from the reader's active membership on this site, as the read policies
  resolve them (`KilnCMS.Accounts.Scoping.audiences/2`). A reader with no such
  membership here (one on another site, a pending or rejected one, an erased
  account, or audiences held only in the account-wide `User.audiences` column)
  reads like a signed-out visitor: the teaser, never the body.

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

  for kind <- [:page, :post] do
    describe "an erased account reading a gated #{kind}" do
      @kind kind

      test "reads the teaser whatever its rows still hold", %{conn: conn} do
        body = body()
        path = gated_document(@kind, body)
        user = reader([@gated])
        membership(user, default_org_id(), :active, [@gated])
        Ash.Seed.update!(user, %{anonymized_at: DateTime.utc_now()})

        conn = conn |> log_in(user) |> get(path)

        refute response(conn, conn.status) =~ body
      end
    end
  end

  describe "a gated fragment embedded in a public page" do
    # The public page that embeds it, and the text only the fragment carries.
    defp embedding_page do
      text = "GATED-FRAGMENT-#{uniq()}"

      target =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Fragment",
          slug: "smd-fragment-#{uniq()}",
          state: :published,
          audience: @gated,
          blocks: KilnCMS.TypedFixtures.typed_blocks([%{type: :heading, content: text}])
        })

      host =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Host",
          slug: "smd-host-#{uniq()}",
          state: :published,
          blocks:
            KilnCMS.CMS.TypedBlocks.to_typed([
              %{"_type" => "heading", "text" => "PUBLIC-HOST-BODY"},
              %{"_type" => "fragment", "ref" => %{"type" => "page", "id" => target.id}}
            ])
        })

      {"/" <> host.slug, text}
    end

    test "an account-wide audience with no membership here does not show it", %{conn: conn} do
      {path, text} = embedding_page()

      html = conn |> log_in(reader([@gated])) |> get(path) |> html_response(200)

      assert html =~ "PUBLIC-HOST-BODY"
      refute html =~ text
    end

    test "a membership on another site does not show it here", %{conn: conn} do
      {path, text} = embedding_page()
      user = reader([@gated])
      membership(user, org("smd-frag-other").id, :active, [@gated])

      html = conn |> log_in(user) |> get(path) |> html_response(200)

      assert html =~ "PUBLIC-HOST-BODY"
      refute html =~ text
    end

    test "an active membership here holding the audience shows it", %{conn: conn} do
      {path, text} = embedding_page()
      user = reader([])
      membership(user, default_org_id(), :active, [@gated])

      html = conn |> log_in(user) |> get(path) |> html_response(200)

      assert html =~ text
    end
  end

  describe "a gated document behind a passphrase" do
    # The lock page (its passphrase field) is offered only to a reader the
    # document's audience admits: `get_locked_by_slug` at the slug,
    # `find_locked_by_alias` at an alias.
    defp locked_gated(:slug), do: locked_gated(%{})
    defp locked_gated(:alias), do: locked_gated(%{path_alias: "/smd/locked/#{uniq()}"})

    defp locked_gated(%{} = attrs) do
      body = body()
      attrs = Map.put(attrs, :access_password, "a shared passphrase")
      {gated_document(:page, body, attrs), body}
    end

    for at <- [:slug, :alias] do
      @at at

      test "at the #{at}, an account-wide audience with no membership here gets no lock page",
           %{conn: conn} do
        {path, body} = locked_gated(@at)

        conn = conn |> log_in(reader([@gated])) |> get(path)
        html = response(conn, conn.status)

        refute html =~ ~s(id="kiln-passphrase")
        refute html =~ body
      end

      test "at the #{at}, a membership on another site gets no lock page here", %{conn: conn} do
        {path, body} = locked_gated(@at)
        user = reader([@gated])
        membership(user, org("smd-lock-other").id, :active, [@gated])

        conn = conn |> log_in(user) |> get(path)
        html = response(conn, conn.status)

        refute html =~ ~s(id="kiln-passphrase")
        refute html =~ body
      end

      test "at the #{at}, an active membership here gets the lock page", %{conn: conn} do
        {path, body} = locked_gated(@at)
        user = reader([])
        membership(user, default_org_id(), :active, [@gated])

        conn = conn |> log_in(user) |> get(path)
        html = response(conn, conn.status)

        assert html =~ ~s(id="kiln-passphrase")
        refute html =~ body
      end
    end
  end

  describe "the delivery cache" do
    test "a foreign-org member's render is not served for the same slug on this site",
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
