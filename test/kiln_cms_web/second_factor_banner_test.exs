defmodule KilnCMSWeb.SecondFactorBannerTest do
  @moduledoc """
  The grace-period reminder (#2247, `KilnCMSWeb.Layouts.second_factor_banner/1`):
  on every console page and on `/account` while an account the site requires a
  second factor of is in its grace period, with the days left; never for an
  account that holds a factor, one the site does not cover, or a site with the
  requirement off. Demo mode's shared account, which needs `Application.put_env`,
  is in `KilnCMSWeb.SecondFactorSocketsTest`.

  Each test signs in on a site of its own: the policy is cached per site on
  the whole node.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures
  import Phoenix.LiveViewTest

  alias KilnCMSWeb.Layouts

  @moduletag :capture_log

  # Covered since `ago_seconds` ago, with `grace_days` of grace.
  defp grace_site(slug, required_for, grace_days, ago_seconds \\ 60) do
    site = org(slug)
    since = DateTime.add(DateTime.utc_now(), -ago_seconds, :second)
    policy_row!(site, required_for, grace_days: grace_days, since: since)
    site
  end

  describe "in the console" do
    test "shows the days left and links to the setup page", %{conn: conn} do
      site = grace_site("sfb-console", :editors, 30)
      user = editor(site)

      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/overview")

      assert has_element?(view, "#second-factor-banner", "30 days left to set it up.")
      assert has_element?(view, ~s(#second-factor-banner-link[href="/account/two-factor"]))
    end

    test "says one day, not zero, on the last day", %{conn: conn} do
      site = grace_site("sfb-last-day", :editors, 7, 7 * 86_400 - 60)
      user = editor(site)

      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/overview")

      assert has_element?(view, "#second-factor-banner", "1 day left to set it up.")
    end

    test "is not shown to an account holding a factor", %{conn: conn} do
      site = grace_site("sfb-enrolled", :editors, 30)
      user = site |> editor() |> with_app()

      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/overview")

      refute has_element?(view, "#second-factor-banner")
    end

    test "is not shown where the role is not covered, or the requirement is off", %{conn: conn} do
      covered_admins = grace_site("sfb-admins-only", :admins, 30)
      editor = editor(covered_admins)

      {:ok, view, _html} = conn |> signed_in(editor, covered_admins) |> live(~p"/editor/overview")
      refute has_element?(view, "#second-factor-banner")

      off = org("sfb-off")
      policy_row!(off, :off)
      other = editor(off)

      {:ok, view, _html} = build_conn() |> signed_in(other, off) |> live(~p"/editor/overview")
      refute has_element?(view, "#second-factor-banner")
    end
  end

  describe "on /account" do
    test "a reader in grace sees it; once enrolled, not", %{conn: conn} do
      site = grace_site("sfb-account", :everyone, 14)
      reader = viewer(site)

      {:ok, view, _html} = conn |> signed_in(reader, site) |> live(~p"/account")
      assert has_element?(view, "#second-factor-banner", "14 days left to set it up.")

      enrolled = with_app(reader)
      {:ok, view, _html} = build_conn() |> signed_in(enrolled, site) |> live(~p"/account")
      refute has_element?(view, "#second-factor-banner")
    end
  end

  describe "days_left/2" do
    test "whole days, rounded up, never zero" do
      now = ~U[2026-11-13 12:00:00Z]

      assert Layouts.days_left(DateTime.add(now, 1, :second), now) == 1
      assert Layouts.days_left(DateTime.add(now, 86_400, :second), now) == 1
      assert Layouts.days_left(DateTime.add(now, 86_401, :second), now) == 2
      assert Layouts.days_left(DateTime.add(now, 14 * 86_400, :second), now) == 14
      assert Layouts.days_left(now, now) == 1
    end
  end

  describe "the component" do
    test "renders only in the grace period" do
      deadline = ~U[2026-11-20 12:00:00Z]
      now = ~U[2026-11-13 12:00:00Z]

      assert render_component(&Layouts.second_factor_banner/1,
               status: {:grace, deadline},
               now: now
             ) =~ "7 days left to set it up."

      for status <- [:not_required, :enrolled, {:enforced, deadline}] do
        refute render_component(&Layouts.second_factor_banner/1, status: status, now: now) =~
                 "second-factor-banner"
      end
    end
  end
end
