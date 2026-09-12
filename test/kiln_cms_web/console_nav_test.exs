defmodule KilnCMSWeb.ConsoleNavTest do
  @moduledoc """
  The console's information architecture (#1319): one list behind both the
  sidebar and the ⌘K palette, sections that collapse, and an operator band that
  is only ever operator screens.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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

  describe "grouping" do
    test "an admin's configure nav is sections, not one flat list" do
      groups = ConsoleNav.nav(authed_user(:admin), nil).configure_groups

      assert Enum.map(groups, & &1.key) == [
               :content_model,
               :capture,
               :delivery,
               :integrations,
               :organization,
               :operations
             ]

      # The point of the exercise: no section is long enough to need scanning.
      for g <- groups, do: assert(length(g.items) <= 6, "#{g.key} has #{length(g.items)} items")
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

    test "an editor sees only their own settings, under one head" do
      groups = ConsoleNav.nav(authed_user(:editor), nil).configure_groups

      assert [%{key: :configure, items: [%{key: :settings}]}] = groups
    end
  end

  describe "the operator band" do
    test "holds only platform-gated screens" do
      ops = group(authed_user(:admin), :operations)

      assert ops.operator? == true
      assert Enum.all?(ops.items, & &1[:platform]), "a day-to-day screen leaked into Operations"

      assert Enum.map(ops.items, & &1.key) == [
               :team,
               :billing,
               :mail,
               :api_keys,
               :backups,
               :system
             ]
    end

    test "no other section is marked operator-only" do
      for g <- ConsoleNav.nav(authed_user(:admin), nil).configure_groups, g.key != :operations do
        refute g[:operator?]
      end
    end

    test "disappears entirely for a per-org admin" do
      # `role: :editor` globally, so `platform_admin_user?/1` is false; the whole
      # band empties and is dropped rather than rendering an empty head.
      groups = ConsoleNav.nav(authed_user(:editor), nil).configure_groups

      refute Enum.any?(groups, &(&1.key == :operations))
    end
  end

  describe "search/4" do
    test "finds a settings screen by name" do
      admin = authed_user(:admin)

      assert [%{key: :backups, path: "/editor/backups", section: "Operations"}] =
               ConsoleNav.search("backup", admin, nil)
    end

    test "matches the section name too, so a whole band is reachable" do
      keys = ConsoleNav.search("operations", authed_user(:admin), nil) |> Enum.map(& &1.key)

      assert :backups in keys
      assert :system in keys
    end

    test "a name that starts with the query leads" do
      assert [%{key: :feeds} | _] = ConsoleNav.search("fee", authed_user(:admin), nil)
    end

    test "never offers a screen the actor cannot open" do
      keys = ConsoleNav.search("backup", authed_user(:editor), nil) |> Enum.map(& &1.key)

      assert keys == []
    end

    test "an empty query matches nothing rather than everything" do
      assert ConsoleNav.search("   ", authed_user(:admin), nil) == []
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

  describe "the sidebar" do
    test "draws each section as a collapsible head", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      for key <- [:content_model, :capture, :delivery, :integrations, :organization, :operations] do
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
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      assert has_element?(lv, ~s(aside .side-group-op[data-nav-group="operations"]))
      refute has_element?(lv, ~s(aside .side-group-op[data-nav-group="delivery"]))
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
  end
end
