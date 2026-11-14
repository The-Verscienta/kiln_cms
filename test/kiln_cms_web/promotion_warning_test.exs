defmodule KilnCMSWeb.PromotionWarningTest do
  @moduledoc """
  The warning an administrator gets when they give someone a tier this site's
  two-step sign-in requirement covers and that person has no second factor
  (decision 6 on #2247): `KilnCMSWeb.PromotionWarning` on its own, then on
  each surface that gives a tier — the Team page's tier picker (an inline
  note, then the save's confirmation), its temporary grant, adding a member,
  and approving a registration. Never blocking; nothing for an enrolled
  person, an uncovered tier, or a site with the requirement off.

  Each test has a site of its own: the policy is cached per site on the whole
  node, so a policy on the default org would reach every other test.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.TwoFactorRequirement.Policy
  alias KilnCMSWeb.PromotionWarning

  @day 86_400

  setup do
    %{site: org("promo")}
  end

  # The acting administrator: a platform admin with an authenticator app, so
  # the requirement never holds them.
  defp operator, do: seed_user(%{role: :admin}) |> with_app()

  defp page(conn, site, path),
    do: conn |> signed_in(operator(), site) |> live(path)

  defp policy(required_for, grace_days) do
    covered = KilnCMS.CMS.SiteSecondFactorPolicy.covered_tiers(required_for)

    %Policy{
      required_for: required_for,
      grace_days: grace_days,
      since: Map.new([:admin, :editor, :viewer], &{&1, if(&1 in covered, do: long_ago())})
    }
  end

  describe "message/4" do
    test "a long-standing member made an admin is held at once", %{site: site} do
      viewer = viewer(site)

      message = PromotionWarning.message(viewer, site.id, :admin, policy: policy(:admins, 14))

      assert message =~ "#{viewer.email} has no second factor"
      assert message =~ "requires one of administrators"
      assert message =~ "grace period ended 2026-01-15"
      assert message =~ "before anything else"
    end

    test "someone new to the site gets the grace period", %{site: site} do
      newcomer = seed_user(%{inserted_at: DateTime.utc_now()})
      deadline = DateTime.add(DateTime.utc_now(), 14 * @day, :second)

      message =
        PromotionWarning.message(newcomer, site.id, "editor", policy: policy(:editors, 14))

      assert message =~ "requires one of editors"
      assert message =~ "they have until #{Calendar.strftime(deadline, "%Y-%m-%d")}"
    end

    test "nothing to say", %{site: site} do
      viewer = viewer(site)
      on = policy(:admins, 0)

      assert PromotionWarning.message(viewer, site.id, :editor, policy: on) == nil
      assert PromotionWarning.message(viewer, site.id, :admin, policy: policy(:off, 0)) == nil
      assert PromotionWarning.message(with_app(viewer), site.id, :admin, policy: on) == nil

      assert PromotionWarning.message(seed_user(%{role: :admin}), site.id, :admin, policy: on) ==
               nil

      assert PromotionWarning.message(viewer, site.id, "owner", policy: on) == nil
      assert PromotionWarning.message(viewer, nil, :admin, policy: on) == nil
    end

    test "with_confirmation/2 appends a warning, or leaves the confirmation alone" do
      assert PromotionWarning.with_confirmation("Saved.", nil) == "Saved."
      assert PromotionWarning.with_confirmation("Saved.", "Careful.") == "Saved. Careful."
    end
  end

  describe "the Team page" do
    setup %{site: site} do
      policy_row!(site, :editors, grace_days: 14)
      :ok
    end

    defp membership(user, site),
      do: Accounts.get_org_membership!(user.id, site.id, authorize?: false)

    test "picking a covered tier says so under the picker, and the save says it again",
         %{conn: conn, site: site} do
      viewer = viewer(site)
      row = membership(viewer, site)
      {:ok, view, _html} = page(conn, site, ~p"/editor/team")

      view |> element("#member-#{row.id} button", "Edit") |> render_click()
      refute has_element?(view, "#edit-member-#{row.id}-promotion")

      view
      |> form("#edit-member-#{row.id}", %{"member" => %{"role" => "editor"}})
      |> render_change()

      assert has_element?(
               view,
               "#edit-member-#{row.id}-promotion[role=status]",
               "#{viewer.email} has no second factor"
             )

      # Back to the tier they hold: nothing to warn of.
      view
      |> form("#edit-member-#{row.id}", %{"member" => %{"role" => "viewer"}})
      |> render_change()

      refute has_element?(view, "#edit-member-#{row.id}-promotion")

      html =
        view
        |> form("#edit-member-#{row.id}", %{"member" => %{"role" => "admin"}})
        |> render_submit()

      assert html =~ "Saved."
      assert html =~ "requires one of administrators, and their grace period ended"
      # Not blocking.
      assert membership(viewer, site).role == :admin
    end

    test "nothing for someone who holds a factor, or a save that keeps the tier",
         %{conn: conn, site: site} do
      enrolled = viewer(site) |> with_app()
      editor = editor(site)
      {:ok, view, _html} = page(conn, site, ~p"/editor/team")

      enrolled_row = membership(enrolled, site)
      view |> element("#member-#{enrolled_row.id} button", "Edit") |> render_click()

      html =
        view
        |> form("#edit-member-#{enrolled_row.id}", %{"member" => %{"role" => "admin"}})
        |> render_submit()

      assert html =~ "Saved."
      refute html =~ "no second factor"

      editor_row = membership(editor, site)
      view |> element("#member-#{editor_row.id} button", "Edit") |> render_click()

      html =
        view
        |> form("#edit-member-#{editor_row.id}", %{"member" => %{"role" => "editor"}})
        |> render_submit()

      assert html =~ "Saved."
      refute html =~ "no second factor"
    end

    test "a temporary tier warns too", %{conn: conn, site: site} do
      viewer = viewer(site)
      row = membership(viewer, site)
      {:ok, view, _html} = page(conn, site, ~p"/editor/team")

      view |> element("#member-#{row.id} button", "Edit") |> render_click()

      html =
        view
        |> form("#grant-member-#{row.id}", %{"role" => "editor", "hours" => "24"})
        |> render_submit()

      assert html =~ "Editor on this site until"
      assert html =~ "#{viewer.email} has no second factor"
    end

    test "a member added at a covered tier is told their grace period", %{conn: conn, site: site} do
      colleague = seed_user()
      {:ok, view, _html} = page(conn, site, ~p"/editor/team")

      html =
        view
        |> form("#add-member-form", %{
          "member" => %{"email" => to_string(colleague.email), "role" => "editor"}
        })
        |> render_submit()

      assert html =~ "Member added to this site."
      assert html =~ "they have until"
    end
  end

  test "the Team page says nothing when the requirement is off", %{conn: conn, site: site} do
    viewer = viewer(site)
    row = Accounts.get_org_membership!(viewer.id, site.id, authorize?: false)
    {:ok, view, _html} = page(conn, site, ~p"/editor/team")

    view |> element("#member-#{row.id} button", "Edit") |> render_click()
    view |> form("#edit-member-#{row.id}", %{"member" => %{"role" => "admin"}}) |> render_change()
    refute has_element?(view, "#edit-member-#{row.id}-promotion")

    html =
      view
      |> form("#edit-member-#{row.id}", %{"member" => %{"role" => "admin"}})
      |> render_submit()

    assert html =~ "Saved."
    refute html =~ "no second factor"
  end

  test "approving a registration that waited past the grace period warns",
       %{conn: conn, site: site} do
    policy_row!(site, :everyone, grace_days: 14)
    applicant = seed_user()

    pending =
      Ash.Seed.seed!(Accounts.OrgMembership, %{
        user_id: applicant.id,
        organization_id: site.id,
        role: :viewer,
        status: :pending,
        inserted_at: long_ago()
      })

    {:ok, view, _html} = page(conn, site, ~p"/editor/registrations")
    html = view |> element("#approve-#{pending.id}") |> render_click()

    assert html =~ "Approved #{applicant.email}"
    assert html =~ "requires one of viewers, and their grace period ended"
  end
end
