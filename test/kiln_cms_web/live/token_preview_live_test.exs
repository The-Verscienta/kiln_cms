defmodule KilnCMSWeb.TokenPreviewLiveTest do
  @moduledoc "Presence on the token preview (#379) — guests join the editors' shared session."
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.PreviewToken

  @password "password123456"

  defp editor_conn(name) do
    email = "tp-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      name: name,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp draft_page do
    Ash.Seed.seed!(KilnCMS.CMS.Page, %{
      title: "Guest Draft",
      slug: "tp-#{System.unique_integer([:positive])}",
      state: :draft,
      blocks:
        KilnCMS.TypedFixtures.typed_blocks([
          %{type: :heading, content: "Hello guests", data: %{"level" => 1}, order: 0}
        ])
    })
  end

  test "a valid token renders the draft with the shared ribbon", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    {:ok, _lv, html} = live(conn, "/preview/#{token}/live")

    assert html =~ "Guest Draft"
    assert html =~ "Shared draft preview"
  end

  test "the shared preview wears the delivery templates' public-* hooks (#1682)", %{conn: conn} do
    token = PreviewToken.sign(draft_page())

    {:ok, lv, _html} = live(conn, "/preview/#{token}/live")

    assert has_element?(lv, "article.public-article h1.public-title", "Guest Draft")
    assert has_element?(lv, "article.public-article > #preview-blocks.public-body")
  end

  test "the preview chrome carries the requesting site's brand, not the default org's",
       %{conn: conn} do
    o = KilnCMS.OrgFixtures.org("tpbrand")
    Ash.Seed.seed!(KilnCMS.CMS.SiteBranding, %{org_id: o.id, site_name: "Acme Tenant"})
    KilnCMS.Cache.bust_branding(o.id)

    page =
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Their Draft",
        slug: "tp-#{System.unique_integer([:positive])}",
        state: :draft,
        org_id: o.id,
        blocks:
          KilnCMS.TypedFixtures.typed_blocks([
            %{type: :heading, content: "Theirs", data: %{"level" => 1}, order: 0}
          ])
      })

    # `Layouts.public` used to be rendered bare here, and `Branding.for_org(nil)`
    # resolves the DEFAULT org — so a shared preview of Acme's draft wore some
    # other site's name and logo (#680).
    {:ok, _lv, html} =
      live(
        %{conn | host: "#{o.slug}.#{KilnCMSWeb.Tenant.base_host()}"},
        "/preview/#{PreviewToken.sign(page)}/live"
      )

    assert html =~ "Powered by Acme Tenant."
    refute html =~ "Powered by KilnCMS."
  end

  test "a token minted on another site is a dead link here, never content (#1309)",
       %{conn: conn} do
    o = KilnCMS.OrgFixtures.org("tpforeign")

    page =
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Their Draft",
        slug: "tp-#{System.unique_integer([:positive])}",
        state: :draft,
        org_id: o.id,
        blocks:
          KilnCMS.TypedFixtures.typed_blocks([
            %{type: :heading, content: "Theirs", data: %{"level" => 1}, order: 0}
          ])
      })

    # Served on the default site's host: the token's org is not the serving org.
    {:ok, _lv, html} = live(conn, "/preview/#{PreviewToken.sign(page)}/live")

    assert html =~ "expired"
    refute html =~ "Their Draft"
    refute html =~ "Theirs"
  end

  test "a live document shows its unpublished working copy, not the published row",
       %{conn: conn} do
    # What the editor sharing the link is looking at (docs/working-copy.md). The
    # published text is what readers already have; showing it here would make
    # the link useless for reviewing the edit it was shared for.
    page =
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Published title",
        slug: "tp-#{System.unique_integer([:positive])}",
        state: :published,
        blocks:
          KilnCMS.TypedFixtures.typed_blocks([
            %{type: :heading, content: "Published body", data: %{"level" => 1}, order: 0}
          ]),
        working_title: "Edited title",
        working_blocks:
          KilnCMS.TypedFixtures.typed_blocks([
            %{type: :heading, content: "Edited body", data: %{"level" => 1}, order: 0}
          ]),
        working_copy_at: DateTime.utc_now()
      })

    {:ok, _lv, html} = live(conn, "/preview/#{PreviewToken.sign(page)}/live")

    assert html =~ "Edited title"
    assert html =~ "Edited body"
    refute html =~ "Published body"
  end

  describe "media and fragments (#2767)" do
    defp shared_page(audience, text) do
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Shared #{text}",
        slug: "tp-shared-#{System.unique_integer([:positive])}",
        state: :published,
        audience: audience,
        blocks: [%{"_type" => "heading", "text" => text}]
      })
    end

    defp guest_draft(audience, blocks) do
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Guest Draft",
        slug: "tp-#{System.unique_integer([:positive])}",
        state: :draft,
        audience: audience,
        blocks: blocks
      })
    end

    defp fragment(target),
      do: %{"_type" => "fragment", "ref" => %{"type" => "page", "id" => target.id}}

    test "the guest sees the video player and the inlined fragment", %{conn: conn} do
      clip = Ash.UUID.generate()
      shared = shared_page(:public, "Shared call to action")

      draft =
        guest_draft(:public, [%{"_type" => "video", "media_id" => clip}, fragment(shared)])

      {:ok, _lv, html} = live(conn, "/preview/#{PreviewToken.sign(draft)}/live")

      assert html =~ ~s(<figure class="kiln-video">)
      assert html =~ ~s(src="/media/#{clip}/stream")
      assert html =~ "Shared call to action"
    end

    # The fired artifact of a `:public` page carries no gated fragment, so its
    # preview shows none either, whoever holds the link.
    test "a public draft shows its guest no member fragment", %{conn: conn} do
      gated = shared_page(:member, "Members only text")
      draft = guest_draft(:public, [fragment(gated)])

      {:ok, _lv, html} = live(conn, "/preview/#{PreviewToken.sign(draft)}/live")

      refute html =~ "Members only text"
    end

    # A deliberate choice: the preview shows what this document will publish.
    # A `:member` page's artifact inlines its `:member` fragments, so the guest
    # previewing that page sees them, as the members it is for will.
    test "a member draft shows its guest the member fragment it will publish", %{conn: conn} do
      gated = shared_page(:member, "Members only text")
      draft = guest_draft(:member, [fragment(gated)])

      {:ok, _lv, html} = live(conn, "/preview/#{PreviewToken.sign(draft)}/live")

      assert html =~ "Members only text"
    end
  end

  # #2769: the guest preview rendered every heading block as an h2.
  test "the guest preview renders a heading at its own level", %{conn: conn} do
    draft =
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Guest Draft",
        slug: "tp-#{System.unique_integer([:positive])}",
        state: :draft,
        blocks: [%{"_type" => "heading", "text" => "Subsection", "level" => 3}]
      })

    {:ok, _lv, html} = live(conn, "/preview/#{PreviewToken.sign(draft)}/live")

    assert html =~ "<h3>Subsection</h3>"
  end

  test "an invalid token shows a dead-link notice, never content", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/preview/garbage-token/live")

    assert html =~ "expired"
    refute html =~ "Guest Draft"
  end

  test "a guest and an editor pop-out viewer see each other", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    {:ok, guest, _} = live(conn, "/preview/#{token}/live")
    {:ok, editor, _} = live(editor_conn("Edna"), ~p"/editor/preview/page/#{page.id}")

    # The editor sees the anonymous guest; the guest sees the editor by name.
    assert eventually(editor, "Guest") =~ "2 viewing"
    assert eventually(guest, "Edna") =~ "2 viewing"

    # An editor cursor move lands on the guest's screen.
    render_hook(editor, "cursor", %{"x" => 0.5, "y" => 0.5})
    assert render(guest) =~ "remote-cursor"
  end

  test "a guest can pick a display name that co-viewers see", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    {:ok, guest, _} = live(conn, "/preview/#{token}/live")
    {:ok, editor, _} = live(editor_conn("Edna"), ~p"/editor/preview/page/#{page.id}")
    eventually(editor, "Guest")

    guest |> form("#guest-name-form", %{"name" => "Priya (agency)"}) |> render_submit()

    assert eventually(editor, "Priya (agency)")
  end

  test "the guest view live-updates when the editor broadcasts a preview update", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    {:ok, guest, _} = live(conn, "/preview/#{token}/live")

    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      KilnCMSWeb.PreviewLive.topic("page", page.id),
      {:preview_update, %{title: "Retitled live", blocks: []}}
    )

    assert eventually(guest, "Retitled live")
  end

  test "a guest ignores the editors' locale-switch broadcast (#378)", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    {:ok, guest, _} = live(conn, "/preview/#{token}/live")

    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      KilnCMSWeb.PreviewLive.topic("page", page.id),
      {:preview_switch, Ash.UUID.generate()}
    )

    # Still alive and still on the same page (a navigate would tear it down).
    assert render(guest) =~ "Guest Draft"
  end

  test "a browser opening the JSON link is redirected to the live view", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    conn = conn |> put_req_header("accept", "text/html") |> get("/preview/#{token}")
    assert redirected_to(conn) == "/preview/#{token}/live"
  end

  test "the JSON surface is unchanged for headless consumers", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    conn = conn |> put_req_header("accept", "application/json") |> get("/preview/#{token}")
    assert %{"data" => %{"title" => "Guest Draft"}} = json_response(conn, 200)
  end
end
