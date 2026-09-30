defmodule KilnCMSWeb.WebhookLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.WebhookEndpoint

  @password "password123456"

  defp authed_user(role) do
    email = "wh-live-#{System.unique_integer([:positive])}@example.com"

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

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/webhooks")
    end

    test "editors are redirected away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error,
              {:redirect,
               %{to: "/", flash: %{"error" => "You need admin access to view that page."}}}} =
               live(conn, ~p"/editor/webhooks")
    end

    test "admins can load the page and see selectable events", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")
      assert html =~ "Webhooks"
      assert html =~ "page.updated"
      assert html =~ "post.published"
    end

    test "the selectable events are THIS site's dynamic types (#336)", %{conn: conn} do
      admin = authed_user(:admin)

      org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Org Webhooks",
          slug: "wh-org-#{System.unique_integer([:positive])}",
          status: :active
        })

      mine = "gadget#{System.unique_integer([:positive])}"
      theirs = "widget#{System.unique_integer([:positive])}"
      CMS.create_type_definition!(%{name: mine, label: "Gadget"}, actor: admin, tenant: org)
      CMS.create_type_definition!(%{name: theirs, label: "Widget"}, actor: admin)

      org_conn = %{conn | host: "#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}"}
      {:ok, _lv, html} = org_conn |> log_in(admin) |> live(~p"/editor/webhooks")

      assert html =~ "#{mine}.published"
      refute html =~ "#{theirs}.published"
    end
  end

  describe "create" do
    test "admin creates an endpoint with selected events", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      html =
        lv
        |> form("#new-webhook-form",
          webhook: %{
            url: "https://hooks.test/incoming",
            events: ["page.published", "page.updated"]
          }
        )
        |> render_submit()

      assert html =~ "https://hooks.test/incoming"

      assert [endpoint] = CMS.list_webhook_endpoints!(authorize?: false)
      assert endpoint.url == "https://hooks.test/incoming"
      assert Enum.sort(endpoint.events) == ["page.published", "page.updated"]
      # A signing secret is generated and surfaced to the admin.
      assert is_binary(WebhookEndpoint.secret(endpoint))
      assert html =~ WebhookEndpoint.secret(endpoint)
    end
  end

  # #1776: the new-endpoint form used to tick every event, so an endpoint added
  # without reviewing the list was POSTed unpublished draft bodies.
  describe "default selection and bulk controls (#1776)" do
    @draft_events ~w(page.created page.in_review page.returned_to_draft)

    defp checked(html, form_id) do
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("##{form_id} input[type=checkbox][name='webhook[events][]'][checked]")
      |> LazyHTML.attribute("value")
    end

    defp open(conn) do
      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")
      {lv, html}
    end

    defp bulk(lv, target, op, group \\ nil) do
      selector =
        ~s(button[phx-click="select_events"][phx-value-target="#{target}"][phx-value-op="#{op}"]) <>
          if(group, do: ~s([phx-value-group="#{group}"]), else: "")

      lv |> element(selector) |> render_click()
    end

    test "a new endpoint starts with exactly the resource's default events", %{conn: conn} do
      {lv, html} = open(conn)

      assert Enum.sort(checked(html, "new-webhook-form")) ==
               Enum.sort(WebhookEndpoint.default_events())

      for event <- @draft_events, do: refute(event in checked(html, "new-webhook-form"))

      lv
      |> form("#new-webhook-form", webhook: %{url: "https://hooks.test/defaults"})
      |> render_submit()

      assert [endpoint] = CMS.list_webhook_endpoints!(authorize?: false)
      assert Enum.sort(endpoint.events) == Enum.sort(WebhookEndpoint.default_events())
      for event <- @draft_events, do: refute(event in endpoint.events)
      # The console's default is the one a programmatic create gets.
      api = CMS.create_webhook_endpoint!(%{url: "https://hooks.test/api"}, authorize?: false)
      assert Enum.sort(api.events) == Enum.sort(endpoint.events)
    end

    test "draft-carrying events are marked, and only those", %{conn: conn} do
      {_lv, html} = open(conn)
      doc = LazyHTML.from_document(html)

      marked =
        for label <- LazyHTML.query(doc, "#new-webhook-form label"),
            LazyHTML.text(label) =~ "includes unpublished content",
            value <- label |> LazyHTML.query("input") |> LazyHTML.attribute("value"),
            do: value

      assert Enum.sort(marked) ==
               Enum.sort(
                 Enum.filter(WebhookEndpoint.events(), &WebhookEndpoint.carries_drafts?/1)
               )

      for event <- @draft_events, do: assert(event in marked)
      refute "page.published" in marked
    end

    test "a deliberate opt-in to draft events is kept and flagged", %{conn: conn} do
      {lv, _html} = open(conn)

      html =
        lv
        |> form("#new-webhook-form",
          webhook: %{url: "https://hooks.test/drafts", events: ["page.in_review"]}
        )
        |> render_submit()

      assert [endpoint] = CMS.list_webhook_endpoints!(authorize?: false)
      assert endpoint.events == ["page.in_review"]
      assert html =~ "Receives unpublished content"
      assert has_element?(lv, "#webhook-#{endpoint.id}-drafts")
    end

    test "an endpoint without draft events carries no flag", %{conn: conn} do
      {lv, _html} = open(conn)

      lv
      |> form("#new-webhook-form", webhook: %{url: "https://hooks.test/clean"})
      |> render_submit()

      assert [endpoint] = CMS.list_webhook_endpoints!(authorize?: false)
      refute has_element?(lv, "#webhook-#{endpoint.id}-drafts")
    end

    test "Select all, Clear and Reset to defaults", %{conn: conn} do
      {lv, _html} = open(conn)
      all = WebhookEndpoint.events()

      html = bulk(lv, "new", "all")
      assert Enum.sort(checked(html, "new-webhook-form")) == Enum.sort(all)

      html = bulk(lv, "new", "none")
      assert checked(html, "new-webhook-form") == []

      html = bulk(lv, "new", "defaults")

      assert Enum.sort(checked(html, "new-webhook-form")) ==
               Enum.sort(WebhookEndpoint.default_events())

      # Select all then submit: every event, drafts included, on purpose.
      bulk(lv, "new", "all")

      lv
      |> form("#new-webhook-form", webhook: %{url: "https://hooks.test/everything"})
      |> render_submit()

      assert [endpoint] = CMS.list_webhook_endpoints!(authorize?: false)
      assert Enum.sort(endpoint.events) == Enum.sort(all)
    end

    test "bulk controls keep the URL typed so far", %{conn: conn} do
      {lv, _html} = open(conn)

      lv
      |> form("#new-webhook-form", webhook: %{url: "https://hooks.test/typed"})
      |> render_change()

      html = bulk(lv, "new", "none")
      assert html =~ ~s(value="https://hooks.test/typed")
    end

    test "a group toggle selects the whole group, then clears it", %{conn: conn} do
      {lv, _html} = open(conn)
      page = Enum.filter(WebhookEndpoint.events(), &String.starts_with?(&1, "page."))

      html = bulk(lv, "new", "group", "page")
      selected = checked(html, "new-webhook-form")
      for event <- page, do: assert(event in selected)
      # Other groups are left as they were.
      assert "post.published" in selected
      refute "post.in_review" in selected

      html = bulk(lv, "new", "group", "page")
      selected = checked(html, "new-webhook-form")
      for event <- page, do: refute(event in selected)
      assert "post.published" in selected
    end

    test "the group toggle is a labelled button", %{conn: conn} do
      {lv, _html} = open(conn)

      assert has_element?(
               lv,
               ~s(#new-events-page button[type="button"][aria-label="Select all page events"])
             )

      bulk(lv, "new", "group", "page")

      assert has_element?(
               lv,
               ~s(#new-events-page button[type="button"][aria-label="Clear page events"])
             )
    end

    test "the edit form's bulk controls act on that endpoint", %{conn: conn} do
      endpoint = seed_endpoint()
      {lv, _html} = open(conn)

      lv
      |> element(~s(button[phx-click="edit"][phx-value-id="#{endpoint.id}"]))
      |> render_click()

      html = bulk(lv, "edit", "none")
      assert checked(html, "edit-webhook-#{endpoint.id}") == []
      # The new-endpoint form is untouched.
      assert Enum.sort(checked(html, "new-webhook-form")) ==
               Enum.sort(WebhookEndpoint.default_events())

      lv |> form("#edit-webhook-#{endpoint.id}") |> render_submit()

      saved = CMS.get_webhook_endpoint!(endpoint.id, authorize?: false)
      assert saved.events == []
      assert saved.url == "https://hooks.test/existing"
    end
  end

  describe "manage" do
    defp seed_endpoint do
      Ash.Seed.seed!(KilnCMS.CMS.WebhookEndpoint, %{
        url: "https://hooks.test/existing",
        events: ["page.published"],
        active: true,
        secret_encrypted: KilnCMS.Keys.Vault.encrypt("s3cret")
      })
    end

    test "admin toggles an endpoint active/inactive", %{conn: conn} do
      endpoint = seed_endpoint()
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      lv
      |> element(~s(button[phx-click="toggle_active"][phx-value-id="#{endpoint.id}"]))
      |> render_click()

      refute CMS.get_webhook_endpoint!(endpoint.id, authorize?: false).active
    end

    test "admin deletes an endpoint", %{conn: conn} do
      endpoint = seed_endpoint()
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      lv
      |> element(~s(button[phx-click="delete"][phx-value-id="#{endpoint.id}"]))
      |> render_click()

      assert {:error, _} = CMS.get_webhook_endpoint(endpoint.id, authorize?: false)
    end
  end

  describe "deliveries panel" do
    defp seed_delivery(endpoint, attrs) do
      Ash.Seed.seed!(
        KilnCMS.CMS.WebhookDelivery,
        Map.merge(%{endpoint_id: endpoint.id, event: "page.published", payload: %{}}, attrs)
      )
    end

    test "recent deliveries render with status, and failures offer redelivery", %{conn: conn} do
      endpoint = seed_endpoint()

      failed =
        seed_delivery(endpoint, %{
          status: :failed,
          attempts: 5,
          last_status: 503,
          last_error: "endpoint returned HTTP 503"
        })

      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      assert html =~ "Recent deliveries"
      assert html =~ "Failed"
      assert html =~ "HTTP 503"

      # Redeliver queues a fresh (pending) ledger row.
      lv
      |> element(~s(button[phx-click="redeliver"][phx-value-id="#{failed.id}"]))
      |> render_click()

      rows = CMS.recent_webhook_deliveries!(authorize?: false)
      assert length(rows) == 2
      assert Enum.any?(rows, &(&1.status == :pending))
    end

    test "ping queues a test delivery", %{conn: conn} do
      endpoint = seed_endpoint()

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      html =
        lv
        |> element(~s(button[phx-click="ping"][phx-value-id="#{endpoint.id}"]))
        |> render_click()

      assert html =~ "Test ping queued"

      assert [%{event: "ping", status: :pending}] =
               CMS.recent_webhook_deliveries!(authorize?: false)
    end

    test "an auto-disabled endpoint wears the badge", %{conn: conn} do
      endpoint = seed_endpoint()

      Ash.Seed.update!(endpoint, %{
        active: false,
        consecutive_failures: 10,
        auto_disabled_at: DateTime.utc_now()
      })

      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      assert html =~ "Auto-disabled after 10 failed deliveries"
    end
  end
end
