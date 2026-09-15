defmodule KilnCMSWeb.OverviewLiveTest do
  @moduledoc """
  The console home (`/editor/overview`): the fixed 3×3 overview grid — content
  counts in the centre tile, one headline number per surrounding domain tile,
  and admin-only numbers rendered as “—” for editors.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.Organization
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.EditorialSettings
  alias KilnCMS.CMS.Page
  alias KilnCMSWeb.Tenant

  @password "password123456"

  defp authed_user(role) do
    email = "ov-live-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp seed_page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(%{title: "A page", slug: "ov-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  describe "the summary line under the heading" do
    test "counts published, drafts and media, pluralised, and names review only when non-empty",
         %{conn: conn} do
      seed_page(%{state: :published})
      seed_page(%{state: :published})
      seed_page(%{state: :draft})

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

      summary = lv |> element("#overview-summary") |> render()

      assert summary =~ "2 published · 1 draft · 0 media items"
      refute summary =~ "in review"
      refute summary =~ "eight domains"
    end

    test "an in-review item is counted", %{conn: conn} do
      seed_page(%{state: :in_review})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert lv |> element("#overview-summary") |> render() =~
               "0 published · 1 in review · 0 drafts · 0 media items"
    end

    test "an empty site says so in words", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      summary = lv |> element("#overview-summary") |> render()

      assert summary =~ "Nothing written or uploaded yet."
      refute summary =~ "0 published"
    end
  end

  # H3: a seeded deploy never sees `/setup`, so nobody was ever asked who
  # publishes. The card asks an admin once, and the row it writes retires it.
  describe "the publishing-mode card" do
    test "an admin on a site that never chose is asked", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert has_element?(lv, "#overview-publishing-choice", "How do you publish?")
      assert has_element?(lv, "#overview-publishing-solo", "Just me — publish directly")

      assert has_element?(
               lv,
               "#overview-publishing-team",
               "I have a team — review before publishing"
             )

      assert has_element?(lv, "#overview-publishing-team-link[href='/editor/team']")
    end

    for value <- [true, false] do
      test "a site that already chose (editors_can_publish: #{value}) is not asked", %{conn: conn} do
        admin = authed_user(:admin)
        org = KilnCMS.Accounts.default_org_id()

        {:ok, _} =
          EditorialSettings.save(%{editors_can_publish: unquote(value)},
            actor: admin,
            tenant: org
          )

        {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/overview")

        refute has_element?(lv, "#overview-publishing-choice")
      end
    end

    test "an editor is never asked", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

      refute has_element?(lv, "#overview-publishing-choice")
    end

    test "“Just me” lets editors publish, writes the row and retires the card", %{conn: conn} do
      org = KilnCMS.Accounts.default_org_id()
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      refute EditorialSettings.chosen?(org)

      lv |> element("#overview-publishing-solo") |> render_click()

      refute has_element?(lv, "#overview-publishing-choice")
      assert EditorialSettings.chosen?(org)
      assert EditorialSettings.editors_can_publish?(org)
    end

    test "“I have a team” keeps review, writes the row and retires the card", %{conn: conn} do
      org = KilnCMS.Accounts.default_org_id()
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      lv |> element("#overview-publishing-team") |> render_click()

      refute has_element?(lv, "#overview-publishing-choice")
      assert EditorialSettings.chosen?(org)
      refute EditorialSettings.editors_can_publish?(org)

      # And it stays gone on the next visit.
      {:ok, lv2, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")
      refute has_element?(lv2, "#overview-publishing-choice")
    end

    test "an org admin (not a platform admin) is asked, without a link to Team", %{conn: conn} do
      user = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: user.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/overview")

      assert has_element?(lv, "#overview-publishing-choice")
      refute has_element?(lv, "#overview-publishing-team-link")
    end

    # The save runs under the same OrgAdmin write policy as Team's switch. Take
    # the admin tier away between mount and click and the policy refuses: the
    # page must say so and keep asking, not pretend the choice was recorded.
    test "a refused save shows an error and keeps the card", %{conn: conn} do
      org = KilnCMS.Accounts.default_org_id()
      user = authed_user(:editor)

      membership =
        Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
          user_id: user.id,
          organization_id: org,
          role: :admin
        })

      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/overview")
      assert has_element?(lv, "#overview-publishing-choice")

      Ash.Seed.update!(membership, %{role: :editor})

      html = lv |> element("#overview-publishing-solo") |> render_click()

      assert has_element?(lv, "#overview-publishing-choice")
      refute html =~ "Done — you publish directly"
      assert has_element?(lv, "#flash-error")
      refute EditorialSettings.chosen?(org)
    end
  end

  # First-run checklist (usability review, B4): the path from `/setup` to a
  # published Home page, shown to admins until anything is published.
  describe "the getting-started checklist" do
    test "an admin on a site with nothing published is walked to the home page", %{conn: conn} do
      home = seed_page(%{slug: "home", state: :draft})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      assert has_element?(lv, "#overview-getting-started", "Get your site live")

      assert has_element?(
               lv,
               ~s(#overview-open-home[href="/editor/content/page/#{home.id}"]),
               "Write your home page"
             )

      refute has_element?(lv, "#overview-create-home")
    end

    test "a site with no home page is offered one, created as a draft", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/overview")

      assert {:error, {:live_redirect, %{to: "/editor/content/page/" <> id}}} =
               lv |> element("#overview-create-home") |> render_click()

      page = CMS.get_page!(id, actor: admin)
      assert page.slug == "home"
      assert page.state == :draft
    end

    test "it leaves once anything is published", %{conn: conn} do
      seed_page(%{state: :published})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      refute has_element?(lv, "#overview-getting-started")
    end

    test "editors don't get it — publishing is an admin step", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

      refute has_element?(lv, "#overview-getting-started")
    end
  end

  test "the console top bar links to the public site", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    assert has_element?(lv, ~s(#console-view-site[href="/"][target="_blank"]), "View site")
  end

  test "viewers are redirected away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in(authed_user(:viewer)) |> live(~p"/editor/overview")
  end

  test "the centre tile counts content by state and surfaces attention items", %{conn: conn} do
    seed_page(%{state: :draft})
    seed_page(%{state: :published})
    seed_page(%{state: :in_review})

    {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    # The heading itself — the sidebar's "Home" link would satisfy a bare
    # substring match on the whole page.
    assert has_element?(lv, "h1", "Home")
    assert lv |> element("#overview-total") |> render() =~ ">3<"
    assert html =~ "1 published · 1 in review · 1 drafts"
    assert html =~ "1 waiting for review"
  end

  # Admins are the ones who approve, so the same count is work waiting on them.
  test "an admin sees in-review items as waiting on their approval", %{conn: conn} do
    seed_page(%{state: :in_review})

    {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

    assert html =~ "1 item needs your approval"
    refute html =~ "waiting for review"
  end

  test "a quiet site says so", %{conn: conn} do
    {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    assert html =~ "All quiet."
  end

  test "the centre tile surfaces tasks assigned to the viewer (#501)", %{conn: conn} do
    editor = authed_user(:editor)
    page = seed_page(%{})

    CMS.assign_task!(
      %{content_type: "page", content_id: page.id, assignee_id: editor.id},
      actor: editor
    )

    {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor/overview")

    assert html =~ "1 task assigned to you"
    refute html =~ "All quiet."
  end

  test "the calendar tile counts scheduled transitions in the next week", %{conn: conn} do
    seed_page(%{state: :draft, scheduled_at: DateTime.add(DateTime.utc_now(), 2, :day)})
    seed_page(%{state: :published, unpublish_at: DateTime.add(DateTime.utc_now(), 3, :day)})
    # Outside the window — must not count.
    seed_page(%{state: :draft, scheduled_at: DateTime.add(DateTime.utc_now(), 30, :day)})

    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    assert lv |> element("#overview-calendar") |> render() =~ ">2<"
  end

  test "the translations tile reports translation coverage across locale variants", %{
    conn: conn
  } do
    covered = "ov-covered-#{System.unique_integer([:positive])}"
    for locale <- ["en", "fr", "es"], do: seed_page(%{slug: covered, locale: locale})
    seed_page(%{slug: "ov-gap-#{System.unique_integer([:positive])}", locale: "en"})

    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    rendered = lv |> element("#overview-translations") |> render()
    assert rendered =~ "50%"
    assert rendered =~ "1 of 2 fully translated"
  end

  test "admin-only tiles render as — for editors", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    assert lv |> element("#overview-webhooks") |> render() =~ "—"
    assert lv |> element("#overview-forms") |> render() =~ "—"
    assert lv |> element("#overview-settings") |> render() =~ "—"
  end

  test "admins get webhook, form and key numbers", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

    assert lv |> element("#overview-webhooks") |> render() =~ ">0<"
    assert lv |> element("#overview-forms") |> render() =~ "0 submissions this week"
    refute lv |> element("#overview-settings") |> render() =~ "—"
  end

  test "every tile renders", %{conn: conn} do
    {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    for key <-
          ~w(translations analytics media webhooks forms structure calendar settings) do
      assert html =~ ~s(id="overview-#{key}")
    end

    assert html =~ ~s(id="overview-center")
  end

  describe "tenant scoping (#336)" do
    test "the structure tile counts THIS site's dynamic content types", %{conn: conn} do
      admin = authed_user(:admin)

      org =
        Ash.Seed.seed!(Organization, %{
          name: "Org Overview",
          slug: "ov-org-#{System.unique_integer([:positive])}",
          status: :active
        })

      # One admin-defined type on this site…
      CMS.create_type_definition!(
        %{name: "gadget#{System.unique_integer([:positive])}", label: "Gadget"},
        actor: admin,
        tenant: org
      )

      # …and two on the DEFAULT site, which this site must not count: before
      # the fix the registry resolved for the default org, so the tile counted
      # the wrong site's custom types.
      for _ <- 1..2 do
        CMS.create_type_definition!(
          %{name: "widget#{System.unique_integer([:positive])}", label: "Widget"},
          actor: admin
        )
      end

      org_conn = %{conn | host: "#{org.slug}.#{Tenant.base_host()}"}
      {:ok, lv, _html} = org_conn |> log_in(admin) |> live(~p"/editor/overview")

      # Compiled types are install-wide; only the one dynamic type is ours.
      assert lv |> element("#overview-structure") |> render() =~
               ">#{length(ContentTypes.all()) + 1}<"
    end
  end
end
