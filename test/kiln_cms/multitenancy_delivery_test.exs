defmodule KilnCMS.MultitenancyDeliveryTest do
  @moduledoc """
  Tenant-aware delivery + routing (epic #336, PR 2).

  Proves the delivery hot path is isolated per organization: the request's org is
  resolved from the host, and every read/fire is scoped to it — so two sites can
  share a slug (`/about`) and each is served its own content, never the other's.

  Not async: the delivery caches (Cachex) are process-global and reads span the
  table, so a shared sandbox is required. Orgs are seeded via `Ash.Seed` to
  bypass the `multitenancy_enabled` create guard — this suite is about the tenant
  axis, not org provisioning.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Organization
  alias KilnCMS.CMS
  alias KilnCMS.Firing.{Delivery, Engine}
  alias KilnCMSWeb.Tenant

  defp org(slug, opts \\ []) do
    Ash.Seed.seed!(
      Organization,
      Map.merge(
        %{
          name: "Org #{slug}",
          slug: "#{slug}-#{System.unique_integer([:positive])}",
          status: :active
        },
        Map.new(opts)
      )
    )
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "mtd-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # Create + publish a page in `org` and fire its artifacts synchronously.
  defp publish_page(org, slug, title) do
    page =
      CMS.create_page!(
        %{
          title: title,
          slug: slug,
          blocks: [%{type: :rich_text, content: "<p>#{title}</p>", order: 0}]
        },
        tenant: org,
        authorize?: false
      )

    published = CMS.publish_page!(page, actor: admin(), tenant: org, authorize?: false)
    # Firing is async on publish; run the enqueued FireWorker so artifacts exist.
    KilnCMS.DataCase.drain_oban()
    published
  end

  describe "KilnCMSWeb.Tenant.resolve_org/1" do
    test "a subdomain of the base host resolves to the org by slug" do
      o = org("acme")
      assert Tenant.resolve_org("#{o.slug}.#{Tenant.base_host()}").id == o.id
    end

    test "an exact custom domain resolves to that org" do
      domain = "vanity-#{System.unique_integer([:positive])}.example.com"
      o = org("vanity", custom_domain: domain)
      assert Tenant.resolve_org(domain).id == o.id
    end

    test "the bare base host resolves to the default org" do
      assert Tenant.resolve_org(Tenant.base_host()).id == Accounts.default_org_id()
    end

    test "an unknown subdomain resolves to the default org" do
      assert Tenant.resolve_org(
               "no-such-org-#{System.unique_integer([:positive])}.#{Tenant.base_host()}"
             ).id ==
               Accounts.default_org_id()
    end

    test "a nil/blank host resolves to the default org" do
      assert Tenant.resolve_org(nil).id == Accounts.default_org_id()
    end
  end

  describe "delivery isolation for a shared slug" do
    setup do
      a = org("a")
      b = org("b")
      pa = publish_page(a, "about", "A about")
      pb = publish_page(b, "about", "B about")
      %{a: a, b: b, pa: pa, pb: pb}
    end

    test "each org's fired artifact is read back under its own tenant", ctx do
      assert {:ok, %{"title" => "A about"}} = Engine.read(ctx.a.id, :page, ctx.pa.id, :json)
      assert {:ok, %{"title" => "B about"}} = Engine.read(ctx.b.id, :page, ctx.pb.id, :json)
    end

    test "an artifact is invisible under another org's tenant", ctx do
      # B's artifact id, read under A's tenant → miss (no cross-tenant read).
      assert :error = Engine.read(ctx.a.id, :page, ctx.pb.id, :json)
      assert :error = Engine.read(ctx.b.id, :page, ctx.pa.id, :json)
    end

    test "Delivery.published resolves the shared slug per org", ctx do
      assert {:ok, %{id: id_a}} = Delivery.published(ctx.a.id, :page, "about", "en")
      assert id_a == ctx.pa.id

      assert {:ok, %{id: id_b}} = Delivery.published(ctx.b.id, :page, "about", "en")
      assert id_b == ctx.pb.id
    end

    test "Delivery.read_artifact is tenant-scoped", ctx do
      assert {:ok, %{"title" => "A about"}} =
               Delivery.read_artifact(ctx.a.id, :page, ctx.pa.id, :json)

      # A's tenant can't read B's artifact body — it's a miss (would backfill), not B's content.
      assert :miss = Delivery.read_artifact(ctx.a.id, :page, ctx.pb.id, :json)
    end
  end

  describe "ArtifactController resolves the tenant from the host" do
    setup %{conn: conn} do
      a = org("host-a")
      b = org("host-b")
      publish_page(a, "about", "A about")
      publish_page(b, "about", "B about")
      %{conn: conn, a: a, b: b}
    end

    test "a request to org A's subdomain serves A's content, never B's", %{conn: conn, a: a} do
      conn = %{conn | host: "#{a.slug}.#{Tenant.base_host()}"}
      body = conn |> get(~p"/api/content/page/about?surface=json") |> json_response(200)
      assert body["title"] == "A about"
    end

    test "a request to org B's subdomain serves B's content", %{conn: conn, b: b} do
      conn = %{conn | host: "#{b.slug}.#{Tenant.base_host()}"}
      body = conn |> get(~p"/api/content/page/about?surface=json") |> json_response(200)
      assert body["title"] == "B about"
    end
  end
end
