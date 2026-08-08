defmodule KilnCMSWeb.SocialImageTest do
  @moduledoc """
  The branding `og:image` fallback (#560).

  The three properties the issue asks for, each of which is the reason this was
  deferred out of #556 rather than shipped approximately: the page-level chain
  must not move, the URL must be absolute **on the request's own host**, and an
  org with no image must still emit no tag at all.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMSWeb.Layouts

  setup do
    org_id = KilnCMS.Accounts.default_org_id()
    org = KilnCMS.Accounts.get_organization!(org_id, authorize?: false)
    on_exit(fn -> KilnCMS.Cache.bust_branding(org_id) end)

    %{org: org, org_id: org_id, actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "social-img-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp brand!(ctx, attrs) do
    CMS.save_site_branding!(attrs, authorize?: false, tenant: ctx.org_id)
    KilnCMS.Cache.bust_branding(ctx.org_id)
  end

  describe "the page-level chain does not move" do
    test "a page's own image wins", ctx do
      brand!(ctx, %{social_image_url: "/uploads/brand.png"})

      assigns = %{current_org: ctx.org, og_image: "https://cdn.test/page.png"}

      assert Layouts.social_image(assigns) == "https://cdn.test/page.png"
    end

    test "no image anywhere means no tag", ctx do
      assert Layouts.social_image(%{current_org: ctx.org}) == nil
    end
  end

  describe "the fallback" do
    test "is absolute, on the request's own host", ctx do
      brand!(ctx, %{social_image_url: "/uploads/brand.png"})

      image = Layouts.social_image(%{current_org: ctx.org})

      # The whole reason #560 waited for #557: a deployment-global base would
      # advertise this org's image on another org's host, and a wrong absolute
      # URL in a link preview is worse than no tag at all.
      assert image == KilnCMSWeb.Tenant.base_url(ctx.org) <> "/uploads/brand.png"
      assert String.starts_with?(image, "http")
    end

    test "leaves an already-absolute URL alone", ctx do
      # `Validations.BrandTokens` only stores an absolute URL whose host the
      # image CSP already permits, so this uses one — an arbitrary host is
      # refused at write time, which is a better boundary than anything the
      # layout could do at render time.
      original = Application.get_env(:kiln_cms, :csp_img_src, [])
      Application.put_env(:kiln_cms, :csp_img_src, ["https://cdn.example.com"])
      on_exit(fn -> Application.put_env(:kiln_cms, :csp_img_src, original) end)

      brand!(ctx, %{social_image_url: "https://cdn.example.com/brand.png"})

      assert Layouts.social_image(%{current_org: ctx.org}) ==
               "https://cdn.example.com/brand.png"
    end

    test "an arbitrary absolute host cannot be stored in the first place", ctx do
      assert {:error, _} =
               CMS.save_site_branding(%{social_image_url: "https://evil.example/x.png"},
                 authorize?: false,
                 tenant: ctx.org_id
               )
    end
  end

  describe "failing closed" do
    test "a missing current_org key emits nothing", ctx do
      brand!(ctx, %{social_image_url: "/uploads/brand.png"})

      # A missing key means no hook ran — the state a url-less LiveView join
      # leaves a view in. Answering with the default org's branding would put
      # another tenant's image on this page, which is the #701 failure mode.
      assert Layouts.social_image(%{}) == nil
    end

    test "an explicit nil org emits nothing", ctx do
      brand!(ctx, %{social_image_url: "/uploads/brand.png"})

      assert Layouts.social_image(%{current_org: nil}) == nil
    end
  end

  describe "rendered" do
    test "a published page with no seo_image carries the brand image", ctx do
      brand!(ctx, %{social_image_url: "/uploads/brand.png"})

      page =
        CMS.create_page!(
          %{title: "Plain", slug: "social-#{System.unique_integer([:positive])}"},
          actor: ctx.actor
        )

      CMS.publish_page!(page, actor: ctx.actor)

      html = build_conn() |> get("/#{page.slug}") |> html_response(200)

      assert html =~ ~s(property="og:image")
      assert html =~ "/uploads/brand.png"
      assert html =~ ~s(name="twitter:image")
      # The card type follows the image, so it has to see the fallback too.
      assert html =~ "summary_large_image"
    end

    test "a page with its own seo_image is unchanged", ctx do
      brand!(ctx, %{social_image_url: "/uploads/brand.png"})

      page =
        CMS.create_page!(
          %{
            title: "Has one",
            slug: "social-#{System.unique_integer([:positive])}",
            seo_image: "https://cdn.test/page.png"
          },
          actor: ctx.actor
        )

      CMS.publish_page!(page, actor: ctx.actor)

      html = build_conn() |> get("/#{page.slug}") |> html_response(200)

      assert html =~ "https://cdn.test/page.png"
      refute html =~ "/uploads/brand.png"
    end

    test "an org with no branding image emits no tag at all", ctx do
      brand!(ctx, %{social_image_url: nil})

      page =
        CMS.create_page!(
          %{title: "Bare", slug: "social-#{System.unique_integer([:positive])}"},
          actor: ctx.actor
        )

      CMS.publish_page!(page, actor: ctx.actor)

      html = build_conn() |> get("/#{page.slug}") |> html_response(200)

      refute html =~ ~s(property="og:image")
      refute html =~ ~s(name="twitter:image")
      assert html =~ ~s(content="summary")
    end
  end
end
