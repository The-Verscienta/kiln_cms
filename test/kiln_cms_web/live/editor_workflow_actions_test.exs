defmodule KilnCMSWeb.EditorWorkflowActionsTest do
  @moduledoc """
  The content list's workflow verbs and the console nav's admin links.

  Bulk verbs open their confirm bar only for a tier that is offered them; a
  failed transition is described by the error it returned, not by the verb; and
  the instance-wide consoles are linked only for the platform admins their pages
  admit.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp authed_user(role) do
    email = "wf-#{System.unique_integer([:positive])}@example.com"

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

  defp draft_page(attrs \\ %{}) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{title: "A page", slug: "wf-#{System.unique_integer([:positive])}", state: :draft},
        attrs
      )
    )
  end

  describe "bulk verbs" do
    test "an editor's crafted publish or delete opens no confirm bar", %{conn: conn} do
      page = draft_page()
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()

      assert render_hook(lv, "bulk", %{"action" => "publish"}) =~
               "Only an admin can publish. Submit the draft for review instead."

      assert render_hook(lv, "bulk", %{"action" => "delete"}) =~
               "You don&#39;t have permission to do that."

      refute has_element?(lv, "button[phx-click='confirm_bulk']")
    end

    test "an editor bulk-submits drafts for review", %{conn: conn} do
      page = draft_page()
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()

      confirm = lv |> element("button[phx-value-action='submit']") |> render_click()
      assert confirm =~ "An admin must publish them."

      lv |> element("button[phx-click='confirm_bulk']") |> render_click()

      assert CMS.get_page!(page.id, authorize?: false).state == :in_review
    end
  end

  describe "a failed transition" do
    # The Approve button is admin-only, so the old verb-keyed "publishing
    # requires an admin approval" was false for everyone who could press it.
    test "an admin who lost the race is told so, not that they need an admin", %{conn: conn} do
      page = draft_page(%{state: :in_review})
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      # A colleague approves it first.
      Ash.Seed.update!(page, %{state: :published})

      html = render_hook(lv, "publish", %{"kind" => "page", "id" => page.id})

      assert html =~ "Someone else changed this item"
      refute html =~ "admin approval"
    end
  end

  describe "console nav" do
    test "a per-org admin is not shown links to the platform-admin consoles", %{conn: conn} do
      person = authed_user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: person.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      {:ok, lv, _html} = conn |> log_in(person) |> live(~p"/editor/overview")

      # The org-admin groups render...
      assert has_element?(lv, ~s(a[href="/editor/types"]))
      # ...but not the consoles that would only bounce them.
      for path <-
            ~w(/editor/team /editor/billing /editor/system /editor/mail /editor/backups /editor/api-keys) do
        refute has_element?(lv, ~s(a[href="#{path}"])), "#{path} linked for a per-org admin"
      end
    end

    test "a platform admin is shown them, API keys included", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

      for path <-
            ~w(/editor/team /editor/billing /editor/system /editor/mail /editor/backups /editor/api-keys) do
        assert has_element?(lv, ~s(a[href="#{path}"])), "#{path} missing for a platform admin"
      end
    end
  end
end
