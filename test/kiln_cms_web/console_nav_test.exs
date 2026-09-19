defmodule KilnCMSWeb.ConsoleNavTest do
  @moduledoc """
  The console's information architecture (#1319): one list behind the sidebar,
  the Configure hub and the ⌘K palette; sections that collapse; an operator band
  that is only ever operator screens; and a search that finds a screen by what
  it is for, not only by its name.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.ConsoleNav

  @password "password123456"

  defp authed_user(role) do
    email = "nav-#{System.unique_integer([:positive])}@example.com"

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

  defp group(user, key) do
    user
    |> ConsoleNav.nav(nil)
    |> Map.fetch!(:configure_groups)
    |> Enum.find(&(&1.key == key))
  end

  defp found(query, user), do: query |> ConsoleNav.search(user, nil) |> Enum.map(& &1.key)

  describe "grouping" do
    test "an admin's configure nav is sections, not one flat list" do
      groups = ConsoleNav.nav(authed_user(:admin), nil).configure_groups

      assert Enum.map(groups, & &1.key) == [
               :content_model,
               :capture,
               :delivery,
               :integrations,
               :organization,
               :account,
               :operations
             ]

      # The point of the exercise: no section is long enough to need scanning.
      for g <- groups, do: assert(length(g.items) <= 7, "#{g.key} has #{length(g.items)} items")
    end

    test "every screen appears in exactly one section" do
      keys =
        authed_user(:admin)
        |> ConsoleNav.nav(nil)
        |> Map.fetch!(:configure_groups)
        |> Enum.flat_map(& &1.items)
        |> Enum.map(& &1.key)

      assert keys == Enum.uniq(keys)
    end

    test "an editor sees only their own settings, labelled as theirs" do
      groups = ConsoleNav.nav(authed_user(:editor), nil).configure_groups

      assert [%{key: :account, items: [%{key: :settings, label: "Your settings"}]}] = groups
    end

    test "every configuration screen says what it is for" do
      for g <- ConsoleNav.nav(authed_user(:admin), nil).configure_groups, item <- g.items do
        assert is_binary(item.description) and item.description != "",
               "#{item.key} has no description for the hub"

        assert is_list(item.keywords), "#{item.key} has no keyword list"
      end
    end

    test "every path is a route the router actually serves" do
      routes = MapSet.new(KilnCMSWeb.Router.__routes__(), & &1.path)

      for %{path: path, label: label} <- ConsoleNav.destinations(authed_user(:admin), nil) do
        assert MapSet.member?(routes, path), "#{label} links to #{path}, which is not a route"
      end
    end
  end

  describe "the hub" do
    test "is offered to an admin and to nobody else" do
      assert %{key: :configure, path: "/editor/configure"} =
               ConsoleNav.nav(authed_user(:admin), nil).hub

      assert ConsoleNav.nav(authed_user(:editor), nil).hub == nil
    end

    test "is itself a palette destination" do
      assert :configure in found("configure", authed_user(:admin))
      refute :configure in found("configure", authed_user(:editor))
    end
  end

  describe "the operator band" do
    test "holds only platform-gated screens" do
      ops = group(authed_user(:admin), :operations)

      assert ops.operator? == true
      assert Enum.all?(ops.items, & &1[:platform]), "a day-to-day screen leaked into Operations"

      assert Enum.map(ops.items, & &1.key) == [
               :team,
               :accounts,
               :billing,
               :mail,
               :api_keys,
               :backups,
               :system
             ]
    end

    test "is the last section, so nothing day-to-day sits below its rule" do
      assert %{key: :operations} =
               List.last(ConsoleNav.nav(authed_user(:admin), nil).configure_groups)
    end

    test "no other section is marked operator-only" do
      for g <- ConsoleNav.nav(authed_user(:admin), nil).configure_groups, g.key != :operations do
        refute g[:operator?]
      end
    end

    test "disappears entirely for a non-platform admin" do
      # `role: :editor` globally, so `platform_admin_user?/1` is false; the whole
      # band empties and is dropped rather than rendering an empty head.
      groups = ConsoleNav.nav(authed_user(:editor), nil).configure_groups

      refute Enum.any?(groups, &(&1.key == :operations))
    end

    test "is dropped for an org admin, who still gets the site sections and the hub" do
      # A global editor made admin of this site by membership: effective tier
      # :admin, so `configure_groups(:admin, false)` — the case the editor
      # fixture above never reaches.
      user = authed_user(:editor)

      {:ok, _membership} =
        Accounts.create_org_membership(
          %{user_id: user.id, organization_id: Accounts.default_org_id(), role: :admin},
          authorize?: false
        )

      nav = ConsoleNav.nav(user, nil)

      assert Enum.map(nav.configure_groups, & &1.key) == [
               :content_model,
               :capture,
               :delivery,
               :integrations,
               :organization,
               :account
             ]

      assert %{key: :configure} = nav.hub
      refute Enum.any?(Enum.flat_map(nav.configure_groups, & &1.items), & &1[:platform])
      assert ConsoleNav.search("backup", user, nil) == []
      assert :governance in Enum.map(ConsoleNav.search("audit", user, nil), & &1.key)
    end
  end

  describe "search/4" do
    test "finds a settings screen by name" do
      assert [%{key: :backups, path: "/editor/backups", section: "Operations"}] =
               ConsoleNav.search("backup", authed_user(:admin), nil)
    end

    test "matches the section name too, so a whole band is reachable" do
      keys = found("operations", authed_user(:admin))

      assert :backups in keys
      assert :system in keys
    end

    test "a name that starts with the query leads" do
      assert [:feeds | _] = found("fee", authed_user(:admin))
    end

    test "a name match beats a keyword match" do
      # "mail" is the whole of one screen's name, a word in another's ("Outgoing
      # mail", #1322), and a keyword ("email") on Newsletter. The screen called
      # Mail leads, and both name matches beat the keyword match.
      assert found("mail", authed_user(:admin)) == [:mail, :site_mail, :newsletter]
    end

    test "the words someone would actually type find the screen that owns them" do
      admin = authed_user(:admin)

      # None of these is in a screen's name, so before descriptions and keywords
      # joined the match none of them led anywhere.
      assert :feeds in found("rss", admin)
      assert :billing in found("stripe", admin)
      assert :settings in found("passkey", admin)
      assert :team in found("permissions", admin)
      assert :code_injection in found("css", admin)
      assert :redirects in found("301", admin)
      assert :mail in found("dkim", admin)
    end

    test "matching ignores case, surrounding space and accents" do
      admin = authed_user(:admin)

      assert found("  RSS  ", admin) == found("rss", admin)
      assert found("bäckup", admin) == found("backup", admin)
    end

    test "never offers a screen the actor cannot open" do
      editor = authed_user(:editor)

      assert found("backup", editor) == []
      assert found("rss", editor) == []
      # Their own settings still answer.
      assert found("passkey", editor) == [:settings]
    end

    test "an empty query matches nothing rather than everything" do
      assert ConsoleNav.search("   ", authed_user(:admin), nil) == []
    end

    test "results are capped" do
      admin = authed_user(:admin)

      assert length(ConsoleNav.search("e", admin, nil)) == 6
      assert length(ConsoleNav.search("e", admin, nil, limit: 2)) == 2
    end

    # Usability pass, M5: "settings" is a name match for the per-user screen, so
    # it leads — but someone after SITE configuration types "site settings", and
    # that used to match nothing at all.
    test "“settings” leads with Your settings, and the hub follows" do
      assert [:settings, :configure | _] = found("settings", authed_user(:admin))
    end

    test "“site settings” finds the Configure hub first" do
      admin = authed_user(:admin)

      assert [:configure | _] = found("site settings", admin)
      assert [:configure | _] = found("Site Settings", admin)
      # An editor has no hub, and nothing else claims the phrase.
      assert found("site settings", authed_user(:editor)) == []
    end
  end

  # Sidebar presets: Essentials is the daily author screens plus the hub and Your
  # settings; Everything is the full map. Only the sidebar filters.
  describe "sidebar presets" do
    defp with_preset(user, preset) do
      {:ok, updated} = Accounts.set_nav_preset(user, preset, actor: user)
      %{user | nav_preset: updated.nav_preset}
    end

    defp sidebar_keys(user, active \\ nil) do
      nav = ConsoleNav.sidebar(user, nil, active)

      %{
        author: Enum.map(nav.author, & &1.key),
        hub: nav.hub && nav.hub.key,
        pinned: Enum.map(nav.pinned, & &1.key),
        groups: Enum.map(nav.configure_groups, & &1.key),
        plugin: nav.plugin
      }
    end

    test "a new account starts on Essentials" do
      assert authed_user(:editor).nav_preset == :essentials
      assert authed_user(:admin).nav_preset == :essentials
    end

    test "Essentials, for an admin: the daily screens, the hub and Your settings" do
      admin = authed_user(:admin)

      assert %{
               author: [:overview, :content, :media, :calendar, :tasks, :inbox],
               hub: :configure,
               pinned: [:settings],
               groups: [],
               plugin: []
             } = sidebar_keys(admin)
    end

    test "Essentials, for an editor: the daily screens and Your settings, no hub" do
      assert %{
               author: [:overview, :content, :media, :calendar, :tasks, :inbox],
               hub: nil,
               pinned: [:settings],
               groups: []
             } = sidebar_keys(authed_user(:editor))
    end

    test "Everything is exactly nav/2" do
      for role <- [:admin, :editor] do
        user = with_preset(authed_user(role), :everything)
        nav = ConsoleNav.nav(user, nil)

        assert ConsoleNav.sidebar(user, nil) == Map.put(nav, :pinned, [])
      end
    end

    test "a page the preset would hide is drawn anyway while you are on it" do
      admin = authed_user(:admin)

      # An author screen keeps its place in the author list…
      assert %{author: [:overview, :content, :media, :menus, :calendar, :tasks, :inbox]} =
               sidebar_keys(admin, :menus)

      # …a grouped screen is pinned above Your settings…
      assert %{pinned: [:redirects, :settings], groups: []} = sidebar_keys(admin, :redirects)

      # …and one the actor may not open is still not conjured up.
      assert %{pinned: [:settings]} = sidebar_keys(authed_user(:editor), :redirects)
      assert %{pinned: [:settings]} = sidebar_keys(admin, :settings)
    end

    test "the hub and ⌘K read the whole map whatever the preset" do
      essentials = authed_user(:admin)
      everything = with_preset(authed_user(:admin), :everything)

      strip = fn user -> user |> ConsoleNav.destinations(nil) |> Enum.map(& &1.key) end

      assert strip.(essentials) == strip.(everything)
      assert :menus in strip.(essentials)
      assert :backups in strip.(essentials)

      assert ConsoleNav.nav(essentials, nil).configure_groups ==
               ConsoleNav.nav(everything, nil).configure_groups

      assert [:taxonomy | _] = found("taxonomy", essentials)
    end

    test "anything but an explicit :essentials draws everything" do
      assert ConsoleNav.preset(nil) == :everything
      assert ConsoleNav.preset(%{}) == :everything
      assert ConsoleNav.preset(%{nav_preset: %Ash.ForbiddenField{}}) == :everything
    end
  end

  describe "the palette" do
    test "lists matching screens above content", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/search")

      html = render_change(lv, "search", %{"q" => "redirect"})

      assert html =~ "Go to"
      assert html =~ ~s(href="/editor/redirects")
    end

    test "offers an editor no admin screen", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/search")

      html = render_change(lv, "search", %{"q" => "billing"})

      refute html =~ ~s(href="/editor/billing")
    end
  end

  # An admin on the Everything preset — what the section, band and hub tests
  # below are about. A new account is on Essentials, which draws no sections.
  defp everything_admin do
    user = authed_user(:admin)
    {:ok, _} = Accounts.set_nav_preset(user, :everything, actor: user)
    user
  end

  describe "the sidebar" do
    test "draws each section as a collapsible head", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(everything_admin()) |> live(~p"/editor")

      for key <- [
            :content_model,
            :capture,
            :delivery,
            :integrations,
            :organization,
            :account,
            :operations
          ] do
        assert has_element?(
                 lv,
                 ~s(aside .side-group[data-nav-group="#{key}"] button[data-nav-group-toggle="#{key}"][aria-expanded="true"])
               )

        assert has_element?(
                 lv,
                 ~s(aside .side-group[data-nav-group="#{key}"] ##{"side-group-#{key}"})
               )
      end
    end

    test "sets the operator band apart", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(everything_admin()) |> live(~p"/editor")

      assert has_element?(lv, ~s(aside .side-group-op[data-nav-group="operations"]))
      refute has_element?(lv, ~s(aside .side-group-op[data-nav-group="delivery"]))
    end

    test "links the hub for an admin, and not for an editor", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")
      assert has_element?(lv, ~s(aside a.side-link[href="/editor/configure"]), "Configure")

      {:ok, lv, _html} = build_conn() |> log_in(authed_user(:editor)) |> live(~p"/editor")
      refute has_element?(lv, ~s(aside a.side-link[href="/editor/configure"]))
    end

    # The collapse is CSS-only (the state lives on <html data-nav-collapsed>,
    # which LiveView never patches), and app.css spells out one rule per group
    # key. A key added without its rule renders a head that does nothing when
    # clicked — silently, and only in the browser. Catch it here instead.
    test "every group key has a collapse rule in the kit" do
      css = File.read!(Path.join(File.cwd!(), "assets/css/app.css"))

      keys =
        for user <- [authed_user(:admin), authed_user(:editor)],
            g <- ConsoleNav.nav(user, nil).configure_groups,
            uniq: true,
            do: g.key

      for key <- keys do
        assert css =~ ~s([data-nav-collapsed~="#{key}"] .side-group[data-nav-group="#{key}"]),
               "assets/css/app.css has no collapse rule for the #{key} nav section"
      end
    end

    test "Essentials draws the daily screens, the hub and Your settings — no sections",
         %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      for path <- ~w(/editor/overview /editor /media /editor/calendar /editor/tasks /editor/inbox
                     /editor/configure /editor/settings) do
        assert has_element?(lv, ~s(aside a.side-link[href="#{path}"])), "#{path} missing"
      end

      for path <- ~w(/editor/taxonomy /editor/menus /editor/releases /editor/analytics
                     /editor/links /editor/redirects /editor/backups) do
        refute has_element?(lv, ~s(aside a.side-link[href="#{path}"])), "#{path} drawn"
      end

      refute has_element?(lv, "aside .side-group")
      assert has_element?(lv, "aside #nav-preset-switch", "Show all tools")
    end

    test "Essentials still draws the current page, marked current", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/redirects")

      assert has_element?(
               lv,
               ~s(aside a.side-link[href="/editor/redirects"][aria-current="page"])
             )

      refute has_element?(lv, ~s(aside a.side-link[href="/editor/slugs"]))
    end

    test "the switch changes the sidebar in place and is saved on the user", %{conn: conn} do
      user = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor")

      refute has_element?(lv, ~s(aside a.side-link[href="/editor/menus"]))

      lv |> element("#nav-preset-switch") |> render_click()

      assert has_element?(lv, ~s(aside a.side-link[href="/editor/menus"]))
      assert has_element?(lv, ~s(aside .side-group[data-nav-group="operations"]))
      assert has_element?(lv, "aside #nav-preset-switch", "Show essentials")
      assert {:ok, %{nav_preset: :everything}} = Accounts.get_user(user.id, actor: user)

      lv |> element("#nav-preset-switch") |> render_click()

      refute has_element?(lv, ~s(aside a.side-link[href="/editor/menus"]))
      assert {:ok, %{nav_preset: :essentials}} = Accounts.get_user(user.id, actor: user)
    end

    test "the switch works from an admin-session page too", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/configure")

      lv |> element("#nav-preset-switch") |> render_click()

      assert has_element?(lv, ~s(aside .side-group[data-nav-group="delivery"]))
    end

    test "a forged preset value changes nothing", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor")

      render_click(lv, "set_nav_preset", %{"preset" => "admin"})

      assert {:ok, %{nav_preset: :essentials}} = Accounts.get_user(user.id, actor: user)
      assert has_element?(lv, "aside #nav-preset-switch", "Show all tools")
    end
  end

  describe "the preset's update policy" do
    test "a user may set their own preset" do
      user = authed_user(:editor)

      assert {:ok, %{nav_preset: :everything}} =
               Accounts.set_nav_preset(user, :everything, actor: user)
    end

    test "nobody else but a platform admin may set it" do
      target = authed_user(:editor)
      other = authed_user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.set_nav_preset(target, :everything, actor: other)

      assert {:ok, %{nav_preset: :essentials}} =
               Accounts.get_user(target.id, actor: target)
    end

    test "it accepts only the preset, and only the two values" do
      user = authed_user(:editor)

      assert {:error, %Ash.Error.Invalid{}} = Accounts.set_nav_preset(user, :admin, actor: user)

      assert {:error, %Ash.Error.Invalid{}} =
               user
               |> Ash.Changeset.for_update(
                 :set_nav_preset,
                 %{nav_preset: :everything, role: :admin},
                 actor: user
               )
               |> Ash.update()
    end
  end
end
