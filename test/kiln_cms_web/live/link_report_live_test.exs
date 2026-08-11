defmodule KilnCMSWeb.LinkReportLiveTest do
  @moduledoc """
  The site-wide broken-link report at `/editor/links` (#474).

  Two things matter here beyond "does it render": that an editor cannot switch
  on outbound traffic, and that "off" does not look like "clean".
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Links.Settings

  @password "password123456"
  @url "https://gone.test/article"

  defp authed_user(role) do
    email = "links-#{role}-#{System.unique_integer([:positive])}@example.com"

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

  defp org, do: KilnCMS.Accounts.default_org_id()

  defp broken_link(admin) do
    n = System.unique_integer([:positive])

    page =
      CMS.create_page!(%{title: "Cites something #{n}", slug: "cites-#{n}"}, actor: admin)

    {:ok, row} =
      Ash.create(
        KilnCMS.CMS.ExternalLink,
        %{
          url: @url,
          document_type: "page",
          document_id: page.id,
          document_title: page.title,
          block_index: 2
        },
        action: :observe,
        authorize?: false,
        tenant: org()
      )

    {:ok, _updated} =
      Ash.update(row, %{outcome: :broken, status_code: 404, reason: "HTTP 404", failure_count: 1},
        action: :record_check,
        authorize?: false,
        tenant: org()
      )

    page
  end

  describe "when the site has not opted in" do
    test "an empty report says nothing has been checked, not that all is well", %{conn: conn} do
      {:ok, _settings} = Settings.save(org(), false, actor: authed_user(:admin))

      {:ok, _live, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/links")

      assert html =~ "Outbound checking is off"
      refute html =~ "No broken outbound links"
    end

    test "an editor is told an administrator has to switch it on", %{conn: conn} do
      {:ok, _settings} = Settings.save(org(), false, actor: authed_user(:admin))

      {:ok, live, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/links")

      assert render(live) =~ "An administrator can switch it on"

      # And the event itself is refused, not merely unrendered: the button is
      # hidden by `@admin?`, the resource policy is what enforces it.
      html = live |> render_click("toggle", %{"external_enabled" => "true"})
      assert html =~ "You need admin access"
      refute Settings.enabled?(org())
    end

    test "an admin can switch it on from the page", %{conn: conn} do
      {:ok, _settings} = Settings.save(org(), false, actor: authed_user(:admin))

      {:ok, live, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/links")

      live |> render_click("toggle", %{"external_enabled" => "true"})

      assert Settings.enabled?(org())
    end
  end

  describe "the report" do
    setup do
      admin = authed_user(:admin)
      {:ok, _settings} = Settings.save(org(), true, actor: admin)
      %{admin: admin}
    end

    test "lists a broken URL with the document that cites it", %{conn: conn, admin: admin} do
      page = broken_link(admin)

      {:ok, _live, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/links")

      assert html =~ @url
      assert html =~ page.title
      assert html =~ "HTTP 404"
      # The block index is 1-based for a human counting blocks in the editor.
      assert html =~ "block 3"
      assert html =~ ~s(/editor/content/page/#{page.id})
    end

    test "an admin's Check now queues a sweep for this site only", %{conn: conn} do
      {:ok, live, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/links")

      html = live |> render_click("check_now", %{})

      assert html =~ "Check queued"

      assert [%Oban.Job{args: %{"org_id" => org_id}}] =
               Oban.Testing.all_enqueued(repo: KilnCMS.Repo, worker: KilnCMS.Links.SweepWorker)

      assert org_id == org()
    end

    test "an editor cannot queue one", %{conn: conn} do
      {:ok, live, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/links")

      assert live |> render_click("check_now", %{}) =~ "You need admin access"

      assert Oban.Testing.all_enqueued(repo: KilnCMS.Repo, worker: KilnCMS.Links.SweepWorker) ==
               []
    end

    test "with nothing broken it says so, and says what it does not report", %{conn: conn} do
      {:ok, _live, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/links")

      assert html =~ "No broken outbound links"
      assert html =~ "bot wall"
    end
  end
end
