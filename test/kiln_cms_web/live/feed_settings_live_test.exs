defmodule KilnCMSWeb.FeedSettingsLiveTest do
  @moduledoc """
  Per-site syndication settings (#719): the admin auth matrix, a real save, and
  the cross-org write boundary.

  Shaped after `KilnCMSWeb.BrandingLiveTest`, and for the same reason: this page
  writes a tenant-scoped settings row, so `Checks.OrgAdmin` resolving the actor's
  tier against the *request's* org is only safe while the resource stays
  tenant-scoped. These tests are the regression guard for that.

  The save assertions are the ones that carry the issue, though. The stored shape
  is two name lists and the page is a grid of checkboxes, so "the form derives
  the lists correctly" is the whole feature: an off-by-one there is a site
  syndicating its full articles when the admin said not to.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Feeds

  @password "password1234!"

  setup do
    original = Application.get_env(:kiln_cms, :feeds, [])
    Application.put_env(:kiln_cms, :feeds, [])

    org = org("feedslive")

    on_exit(fn ->
      Application.put_env(:kiln_cms, :feeds, original)
      KilnCMS.Cache.bust_feed_policy(org.id)
      KilnCMS.Cache.bust_feed_policy(Accounts.default_org_id())
    end)

    %{org: org}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/feeds")
    end

    test "turns away a non-admin", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               conn |> log_in(authed_user(:editor)) |> live(~p"/editor/feeds")

      assert flash["error"] =~ "admin access"
    end

    test "loads for an org admin on their own site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      {:ok, _lv, html} = conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/feeds")

      assert html =~ "Full content"
      # Every content type the site has, listed by name.
      assert html =~ "post"
      assert html =~ "page"
    end
  end

  describe "the page reflects what the site actually does" do
    test "says so when the site is still on the deployment defaults", %{conn: conn, org: org} do
      {:ok, _lv, html} = admin_live(conn, org)

      assert html =~ "using the deployment defaults"
    end

    test "shows the operator config as the layer beneath", %{conn: conn, org: org} do
      Application.put_env(:kiln_cms, :feeds, exclude: ["page"], full_content: ["post"])

      {:ok, _lv, html} = admin_live(conn, org)

      # Syndicate is every registered type minus the excluded one — computed
      # rather than hardcoded, because a downstream project can register more
      # content types than this repo ships (e.g. a catalog overlay), and a
      # fixed list here would fail for reasons that have nothing to do with
      # this test.
      expected_syndicate =
        org
        |> ContentTypes.all_for_org()
        |> Enum.map(&to_string(&1.type))
        |> Enum.reject(&(&1 == "page"))

      # Boxes are checked from the RESOLVED policy, so an inherited config shows
      # as the state the site is in rather than as an empty form.
      assert html =~ "Deployment defaults"

      assert Enum.sort(checked_values(html, "feeds[syndicate][]")) ==
               Enum.sort(expected_syndicate)

      assert checked_values(html, "feeds[full_content][]") == ["post"]
    end

    test "the 'in feeds' box tracks the exclusion list, not the public index", %{
      conn: conn,
      org: org
    } do
      # `Feeds.syndicated?/2` also requires a public index, which this page does
      # not own. Rendering the box from that combined predicate would leave a
      # dynamic type with its index off unchecked — and then written into
      # `excluded_types` on save, silently staying out of the feeds after the
      # admin turned the index on in `/editor/types`.
      definition =
        CMS.create_type_definition!(
          %{
            name: "recipe#{System.unique_integer([:positive])}",
            label: "Recipe",
            has_published_feed: false
          },
          authorize?: false,
          tenant: org
        )

      {:ok, _lv, html} = admin_live(conn, org)

      assert definition.name in checked_values(html, "feeds[syndicate][]")
      assert html =~ "No public index of published entries"
    end
  end

  describe "saving" do
    test "derives both lists from the checked boxes", %{conn: conn, org: org} do
      {:ok, lv, _html} = admin_live(conn, org)

      lv
      |> form("#feed-settings-form", feeds: %{syndicate: ["post"], full_content: ["post"]})
      |> render_submit()

      assert {:ok, [row]} = CMS.list_feed_settings(tenant: org, authorize?: false)
      # Exclusions are derived by SUBTRACTION from the types the form offered,
      # so an unchecked page lands in the list and a type added since the page
      # loaded does not.
      assert "page" in row.excluded_types
      refute "post" in row.excluded_types
      assert row.full_content_types == ["post"]
    end

    test "keeps a choice about a type the form no longer offers", %{conn: conn, org: org} do
      # An archived type leaves the registry, so it is not on the page. A save
      # that rebuilt the lists from the page alone would drop its name — and
      # restoring the type would then bring it back *syndicating*, reversing an
      # explicit "not in feeds" with nothing recording the change.
      CMS.save_feed_settings!(%{excluded_types: ["post", "gone"]},
        authorize?: false,
        tenant: org
      )

      {:ok, lv, _html} = admin_live(conn, org)

      lv
      |> form("#feed-settings-form", feeds: %{syndicate: ["post", "page"], full_content: []})
      |> render_submit()

      assert {:ok, [row]} = CMS.list_feed_settings(tenant: org, authorize?: false)
      assert "gone" in row.excluded_types
      # And the types the page DID offer still follow the boxes.
      refute "post" in row.excluded_types
    end

    test "a payload that is not the shape the form sends is ignored, not fatal", %{
      conn: conn,
      org: org
    } do
      # `phx-submit` params are decoded from a client-controlled string, so
      # `feeds` need not be a map at all. Reading a field off a bare binary
      # would crash the LiveView into a reconnect loop.
      {:ok, lv, _html} = admin_live(conn, org)

      assert render_submit(lv, "save", %{"feeds" => "not-a-map"}) =~ "Feed settings saved."

      assert {:ok, [row]} = CMS.list_feed_settings(tenant: org, authorize?: false)
      # Nothing was checked, so nothing syndicates — a legitimate answer.
      assert "post" in row.excluded_types
      assert row.full_content_types == []
    end

    test "resetting twice does not crash the page", %{conn: conn, org: org} do
      # `@row` is assigned at mount, so a second click (or a second tab) would
      # destroy an already-deleted record. A bang call there raises out of the
      # handler and takes the LiveView with it.
      {:ok, lv, _html} = admin_live(conn, org)

      lv
      |> form("#feed-settings-form", feeds: %{syndicate: ["post"], full_content: []})
      |> render_submit()

      render_click(lv, "reset")
      html = render_click(lv, "reset")

      assert html =~ "using the deployment defaults"
      assert {:ok, []} = CMS.list_feed_settings(tenant: org, authorize?: false)
    end

    test "writes for the current site only", %{conn: conn, org: org} do
      other = org("feedslive")
      on_exit(fn -> KilnCMS.Cache.bust_feed_policy(other.id) end)

      {:ok, lv, _html} = admin_live(conn, org)

      lv
      |> form("#feed-settings-form", feeds: %{syndicate: ["post"], full_content: ["post"]})
      |> render_submit()

      assert {:ok, []} = CMS.list_feed_settings(tenant: other, authorize?: false)
      assert Feeds.policy(other) == %KilnCMS.Feeds.Policy{exclude: [], full_content: []}
    end

    test "an empty column saves as NONE, and resetting goes back to inheriting", %{
      conn: conn,
      org: org
    } do
      # The distinction the nullable columns exist for. An empty saved column
      # must round-trip as `[]`, not `nil`: if it inherited, the site would fall
      # back to a config that turns full text ON — the inversion #719 exists to
      # remove — and the admin would have no way to say "not here". Dropping the
      # row is the only thing that restores inheritance.
      Application.put_env(:kiln_cms, :feeds, full_content: ["post"])

      {:ok, lv, _html} = admin_live(conn, org)

      lv
      |> form("#feed-settings-form", feeds: %{syndicate: ["post", "page"], full_content: []})
      |> render_submit()

      assert {:ok, [row]} = CMS.list_feed_settings(tenant: org, authorize?: false)
      assert row.full_content_types == []
      assert Feeds.policy(org).full_content == []

      render_click(lv, "reset")

      assert {:ok, []} = CMS.list_feed_settings(tenant: org, authorize?: false)
      assert Feeds.policy(org).full_content == ["post"]
    end
  end

  describe "cross-org write boundary" do
    test "an admin of one site cannot write another site's feed settings", %{org: org} do
      other = org("feedslive")
      on_exit(fn -> KilnCMS.Cache.bust_feed_policy(other.id) end)

      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_feed_settings(%{full_content_types: ["post"]}, actor: user, tenant: other)
    end

    test "a DEFAULT-org admin cannot write another site's feed settings" do
      other = org("feedslive")
      on_exit(fn -> KilnCMS.Cache.bust_feed_policy(other.id) end)

      user = authed_user(:editor)
      grant_tier(user, Accounts.default_org(), :admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_feed_settings(%{full_content_types: ["post"]}, actor: user, tenant: other)
    end

    test "an org editor is not an org admin", %{org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_feed_settings(%{excluded_types: []}, actor: user, tenant: org)
    end
  end

  # Which boxes in one column are ticked, by the type name each carries as its
  # value. Parsed rather than regexed: this is the assertion that says the page
  # shows the site its real state, and it must not pass because of attribute
  # ordering.
  defp checked_values(html, name) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(~s(input[name="#{name}"][checked]))
    |> Floki.attribute("value")
  end

  defp admin_live(conn, org) do
    conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/feeds")
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "feedslive-#{role}-#{System.unique_integer([:positive])}@example.com"

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
end
