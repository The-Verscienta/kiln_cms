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
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # Long enough (>= 16 characters) for the masked row to show its last four.
  @long_secret "whsec-test-0123456789-abcdWXYZ"

  # An incoming-webhook style URL with a token in its path (#2245): the page
  # shows it as `@masked_url` and never sends `@secret_segment` unasked.
  @hook_url "https://hooks.test/existing/T0SECRET-token-Zq9x"
  @masked_url "https://hooks.test/…/Zq9x"
  @secret_segment "T0SECRET-token"

  defp seed_endpoint(secret \\ "s3cret", org_id \\ nil) do
    Ash.Seed.seed!(
      WebhookEndpoint,
      Map.merge(
        %{
          url: @hook_url,
          events: ["page.published"],
          active: true,
          secret_encrypted: KilnCMS.Keys.Vault.encrypt(secret)
        },
        if(org_id, do: %{org_id: org_id}, else: %{})
      )
    )
  end

  defp new_id(existing) do
    [created] =
      for e <- CMS.list_webhook_endpoints!(authorize?: false), e.id != existing.id, do: e

    created.id
  end

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/webhooks")
    end

    test "editors are redirected away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
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
            url: "https://hooks.test/incoming/T0SECRET-token-Zq9x",
            events: ["page.published", "page.updated"]
          }
        )
        |> render_submit()

      # Listed masked straight away (#2245).
      assert html =~ "https://hooks.test/…/Zq9x"
      refute html =~ @secret_segment

      assert [endpoint] = CMS.list_webhook_endpoints!(authorize?: false)
      assert endpoint.url == "https://hooks.test/incoming/T0SECRET-token-Zq9x"
      assert endpoint.format == :kiln
      assert Enum.sort(endpoint.events) == ["page.published", "page.updated"]
      # A signing secret is generated and surfaced to the admin.
      assert is_binary(WebhookEndpoint.secret(endpoint))
      assert html =~ WebhookEndpoint.secret(endpoint)
    end

    # #2140: the new endpoint's secret starts revealed, so it can be copied
    # into the receiver; an endpoint already listed stays masked.
    test "reveals only the new endpoint's secret", %{conn: conn} do
      existing = seed_endpoint(@long_secret)
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      html =
        lv
        |> form("#new-webhook-form", webhook: %{url: "https://hooks.test/fresh"})
        |> render_submit()

      created = CMS.get_webhook_endpoint!(new_id(existing), authorize?: false)
      secret = WebhookEndpoint.secret(created)

      assert html =~ "Webhook added. Copy its signing secret into your receiver."
      assert lv |> element("#webhook-#{created.id}-secret") |> render() =~ secret
      assert has_element?(lv, ~s(#copy-secret-#{created.id}[data-clipboard-text="#{secret}"]))

      refute html =~ @long_secret
      assert has_element?(lv, "#webhook-#{existing.id}-secret-masked")
    end
  end

  # #2140: the list used to print every endpoint's signing secret in plain text.
  describe "signing secret (#2140)" do
    defp admin_live(conn) do
      {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")
      {lv, html}
    end

    test "is masked in the first and the connected render", %{conn: conn} do
      endpoint = seed_endpoint(@long_secret)
      conn = log_in(conn, authed_user(:admin))

      dead = conn |> get(~p"/editor/webhooks") |> html_response(200)
      {:ok, lv, live_html} = live(conn, ~p"/editor/webhooks")

      for html <- [dead, live_html] do
        refute html =~ @long_secret
        assert html =~ "•••• " <> String.slice(@long_secret, -4, 4)
      end

      refute has_element?(lv, "#webhook-#{endpoint.id}-secret")
      refute has_element?(lv, "#copy-secret-#{endpoint.id}")

      assert has_element?(
               lv,
               ~s(#reveal-secret-#{endpoint.id}[aria-label="Reveal signing secret for #{@masked_url}"]),
               "Reveal"
             )
    end

    test "a short secret shows no tail", %{conn: conn} do
      endpoint = seed_endpoint()
      {lv, html} = admin_live(conn)

      refute html =~ "s3cret"
      assert lv |> element("#webhook-#{endpoint.id}-secret-masked") |> render() =~ "••••"
      refute html =~ "•••• cret"
    end

    test "Reveal shows the secret with a Copy button, Hide masks it again", %{conn: conn} do
      endpoint = seed_endpoint(@long_secret)
      {lv, _html} = admin_live(conn)

      html = lv |> element("#reveal-secret-#{endpoint.id}") |> render_click()

      assert lv |> element("#webhook-#{endpoint.id}-secret") |> render() =~ @long_secret

      assert has_element?(
               lv,
               ~s(#copy-secret-#{endpoint.id}[phx-hook="Clipboard"][data-clipboard-text="#{@long_secret}"]),
               "Copy"
             )

      assert has_element?(lv, "#reveal-secret-#{endpoint.id}", "Hide")
      refute has_element?(lv, "#webhook-#{endpoint.id}-secret-masked")
      refute html =~ "Couldn&#39;t reveal"

      html = lv |> element("#reveal-secret-#{endpoint.id}") |> render_click()

      refute html =~ @long_secret
      refute has_element?(lv, "#copy-secret-#{endpoint.id}")
      assert has_element?(lv, "#webhook-#{endpoint.id}-secret-masked")
    end

    test "the Clipboard hook's copied event confirms the copy", %{conn: conn} do
      endpoint = seed_endpoint(@long_secret)
      {lv, _html} = admin_live(conn)
      lv |> element("#reveal-secret-#{endpoint.id}") |> render_click()

      assert lv |> element("#copy-secret-#{endpoint.id}") |> render_hook("copied", %{}) =~
               "Signing secret copied."
    end

    test "a revealed secret stays revealed across a list refresh", %{conn: conn} do
      endpoint = seed_endpoint(@long_secret)
      {lv, _html} = admin_live(conn)
      lv |> element("#reveal-secret-#{endpoint.id}") |> render_click()

      lv
      |> element(~s(button[phx-click="toggle_active"][phx-value-id="#{endpoint.id}"]))
      |> render_click()

      assert has_element?(lv, "#webhook-#{endpoint.id}-secret")
    end

    test "a forged reveal for another site's endpoint reveals nothing", %{conn: conn} do
      other = KilnCMS.OrgFixtures.org("wh-secret-other")
      theirs = seed_endpoint(@long_secret, other.id)
      {lv, _html} = admin_live(conn)

      html = render_hook(lv, "reveal_secret", %{"id" => theirs.id})

      refute html =~ @long_secret
      assert html =~ "Couldn&#39;t reveal that signing secret."
      refute has_element?(lv, "#webhook-#{theirs.id}-secret")
    end

    test "a reveal for an unknown id is refused without crashing", %{conn: conn} do
      {lv, _html} = admin_live(conn)

      assert render_hook(lv, "reveal_secret", %{"id" => Ash.UUID.generate()}) =~
               "Couldn&#39;t reveal that signing secret."

      assert render(lv) =~ "Webhooks"
    end

    test "an unreadable secret says so and offers no Reveal or Copy", %{conn: conn} do
      endpoint = seed_endpoint()
      # Ciphertext from a SECRET_KEY_BASE this server no longer has.
      Ash.Seed.update!(endpoint, %{secret_encrypted: :crypto.strong_rand_bytes(60)})
      {lv, html} = admin_live(conn)

      assert html =~ "unreadable"
      refute has_element?(lv, "#reveal-secret-#{endpoint.id}")
      refute has_element?(lv, "#copy-secret-#{endpoint.id}")
      refute has_element?(lv, "#webhook-#{endpoint.id}-secret-masked")

      assert render_hook(lv, "reveal_secret", %{"id" => endpoint.id}) =~
               "Couldn&#39;t reveal that signing secret."
    end
  end

  # #2347: replace an endpoint's signing secret without deleting it.
  describe "rotate secret (#2347)" do
    defp secret_of(id), do: id |> fetch_endpoint() |> WebhookEndpoint.secret()
    defp fetch_endpoint(id), do: CMS.get_webhook_endpoint!(id, authorize?: false, tenant: nil)

    test "shows the new secret and not the old one", %{conn: conn} do
      endpoint = seed_endpoint(@long_secret)
      {lv, _html} = admin_live(conn)

      html = lv |> element("#rotate-secret-#{endpoint.id}") |> render_click()

      new_secret = secret_of(endpoint.id)
      assert new_secret != @long_secret
      refute html =~ @long_secret
      assert lv |> element("#webhook-#{endpoint.id}-secret") |> render() =~ new_secret
      assert html =~ "Signing secret replaced."
      assert has_element?(lv, "#copy-secret-#{endpoint.id}")
    end

    test "says under the new secret that deliveries already use it (#2384)", %{conn: conn} do
      endpoint = seed_endpoint(@long_secret)
      {lv, _html} = admin_live(conn)
      hint = "#webhook-#{endpoint.id}-rotated-hint"

      lv |> element("#reveal-secret-#{endpoint.id}") |> render_click()
      refute has_element?(lv, hint)

      lv |> element("#rotate-secret-#{endpoint.id}") |> render_click()

      assert lv |> element(hint) |> render() =~
               "Update your receiver now: deliveries already use this secret."

      lv |> element("#reveal-secret-#{endpoint.id}") |> render_click()
      refute has_element?(lv, hint)
    end

    test "the button confirms and disables itself", %{conn: conn} do
      endpoint = seed_endpoint()
      {lv, _html} = admin_live(conn)

      assert has_element?(
               lv,
               ~s(#rotate-secret-#{endpoint.id}[data-confirm*="update the receiver"][phx-disable-with])
             )
    end

    test "an endpoint with an unreadable secret can be rotated", %{conn: conn} do
      endpoint = seed_endpoint()
      Ash.Seed.update!(endpoint, %{secret_encrypted: :crypto.strong_rand_bytes(60)})
      {lv, html} = admin_live(conn)

      assert html =~ "unreadable"
      assert has_element?(lv, "#rotate-secret-#{endpoint.id}")

      lv |> element("#rotate-secret-#{endpoint.id}") |> render_click()

      assert is_binary(secret_of(endpoint.id))
      refute render(lv) =~ "unreadable"
      assert has_element?(lv, "#webhook-#{endpoint.id}-secret")
    end

    test "an editor never reaches the page, so cannot rotate", %{conn: conn} do
      endpoint = seed_endpoint(@long_secret)
      conn = log_in(conn, authed_user(:editor))

      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               live(conn, ~p"/editor/webhooks")

      assert secret_of(endpoint.id) == @long_secret
    end

    test "a forged id from another site rotates nothing", %{conn: conn} do
      other = KilnCMS.OrgFixtures.org("wh-rotate-other")
      theirs = seed_endpoint(@long_secret, other.id)
      {lv, _html} = admin_live(conn)

      html = render_hook(lv, "rotate_secret", %{"id" => theirs.id})

      assert html =~ "Couldn&#39;t rotate that signing secret."
      assert secret_of(theirs.id) == @long_secret
    end

    test "an unknown id is refused without crashing", %{conn: conn} do
      {lv, _html} = admin_live(conn)

      assert render_hook(lv, "rotate_secret", %{"id" => Ash.UUID.generate()}) =~
               "Couldn&#39;t rotate that signing secret."
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
      # Select all leaves the security alert events out (#2642).
      all = Enum.reject(WebhookEndpoint.events(), &String.starts_with?(&1, "security."))

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

    test "Select all ticks no security event (#2642)", %{conn: conn} do
      {lv, _html} = open(conn)
      security = WebhookEndpoint.security_events()
      assert security != []

      html = bulk(lv, "new", "all")
      selected = checked(html, "new-webhook-form")

      for event <- security, do: refute(event in selected)
      assert "page.published" in selected
      assert "page.in_review" in selected

      assert has_element?(
               lv,
               ~s(button[phx-value-op="all"][title="Select all events except security alerts"])
             )
    end

    test "the security group toggle still ticks them all, and Clear clears them", %{conn: conn} do
      {lv, _html} = open(conn)
      security = WebhookEndpoint.security_events()

      html = bulk(lv, "new", "group", "security")
      selected = checked(html, "new-webhook-form")
      for event <- security, do: assert(event in selected)

      # Select all after that keeps them.
      html = bulk(lv, "new", "all")
      for event <- security, do: assert(event in checked(html, "new-webhook-form"))

      html = bulk(lv, "new", "none")
      assert checked(html, "new-webhook-form") == []
    end

    test "Select all on an edit keeps a security event already ticked", %{conn: conn} do
      endpoint = Ash.Seed.update!(seed_endpoint(), %{events: ["security.lockout"]})
      {lv, _html} = open(conn)

      lv
      |> element(~s(button[phx-click="edit"][phx-value-id="#{endpoint.id}"]))
      |> render_click()

      html = bulk(lv, "edit", "all")
      selected = checked(html, "edit-webhook-#{endpoint.id}")

      assert "security.lockout" in selected
      refute "security.new_admin" in selected
      assert "page.published" in selected
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
      assert saved.url == @hook_url
    end
  end

  describe "manage" do
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

    # #2136: Delete used to be an unlabelled trash icon, easy to miss beside
    # three text buttons. It is a labelled button whatever the endpoint's state.
    test "the row offers a labelled Delete on an active endpoint", %{conn: conn} do
      endpoint = seed_endpoint()
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      assert lv
             |> element(
               ~s(#webhook-#{endpoint.id} button[phx-click="delete"][phx-value-id="#{endpoint.id}"]),
               "Delete"
             )
             |> has_element?()
    end

    test "the row offers a labelled Delete on a disabled endpoint", %{conn: conn} do
      endpoint = seed_endpoint()
      Ash.Seed.update!(endpoint, %{active: false})
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      assert lv
             |> element(
               ~s(#webhook-#{endpoint.id} button[phx-click="delete"][phx-value-id="#{endpoint.id}"]),
               "Delete"
             )
             |> has_element?()
    end

    test "the edit form offers Delete, which deletes and closes the form", %{conn: conn} do
      endpoint = seed_endpoint()
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/webhooks")

      lv
      |> element(~s(button[phx-click="edit"][phx-value-id="#{endpoint.id}"]))
      |> render_click()

      delete_in_form =
        ~s(#edit-webhook-#{endpoint.id} button[type="button"][phx-click="delete"][phx-value-id="#{endpoint.id}"])

      assert has_element?(lv, delete_in_form, "Delete webhook")

      lv |> element(delete_in_form) |> render_click()

      assert {:error, _} = CMS.get_webhook_endpoint(endpoint.id, authorize?: false)
      refute has_element?(lv, "#edit-webhook-#{endpoint.id}")
      refute has_element?(lv, "#webhook-#{endpoint.id}")
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

    # #2330: deleting an endpoint nilifies its deliveries' endpoint_id; the
    # rows stay as history but have nowhere to be redelivered to.
    test "a delivery whose endpoint was deleted shows it and offers no redelivery",
         %{conn: conn} do
      admin = authed_user(:admin)
      endpoint = seed_endpoint()

      orphaned =
        seed_delivery(endpoint, %{
          endpoint_url: endpoint.url,
          status: :failed,
          attempts: 5,
          last_error: "endpoint returned HTTP 503"
        })

      :ok = CMS.destroy_webhook_endpoint(endpoint, actor: admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/webhooks")

      row = "#delivery-#{orphaned.id}"
      assert has_element?(lv, row, @masked_url)
      refute render(lv) =~ @secret_segment
      assert has_element?(lv, ~s(#{row} [data-role="deleted-endpoint"]), "(deleted endpoint)")
      refute has_element?(lv, ~s(button[phx-click="redeliver"][phx-value-id="#{orphaned.id}"]))
    end

    test "with no URL copy, the row still says its endpoint was deleted", %{conn: conn} do
      admin = authed_user(:admin)
      endpoint = seed_endpoint()
      orphaned = seed_delivery(endpoint, %{status: :failed, attempts: 5})
      :ok = CMS.destroy_webhook_endpoint(endpoint, actor: admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/webhooks")

      row = "#delivery-#{orphaned.id}"
      assert has_element?(lv, ~s(#{row} [data-role="deleted-endpoint"]), "(deleted endpoint)")
      refute has_element?(lv, "#{row} code", "https://hooks.test")
    end

    # Another admin deletes the endpoint after this page rendered.
    test "redelivering on a stale page says the endpoint was deleted", %{conn: conn} do
      admin = authed_user(:admin)
      endpoint = seed_endpoint()

      failed =
        seed_delivery(endpoint, %{endpoint_url: endpoint.url, status: :failed, attempts: 5})

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/webhooks")
      button = ~s(button[phx-click="redeliver"][phx-value-id="#{failed.id}"])
      assert has_element?(lv, button)

      :ok = CMS.destroy_webhook_endpoint(endpoint, actor: admin)

      html = lv |> element(button) |> render_click()

      assert html =~ "That delivery&#39;s endpoint was deleted, so it can&#39;t be redelivered."
      refute has_element?(lv, button)
      assert has_element?(lv, ~s(#delivery-#{failed.id} [data-role="deleted-endpoint"]))
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

  # #2245: an incoming webhook's URL is its credential.
  describe "URLs are masked everywhere on the page (#2245)" do
    defp edit(lv, endpoint) do
      lv
      |> element(~s(button[phx-click="edit"][phx-value-id="#{endpoint.id}"]))
      |> render_click()
    end

    test "the list, the secret's labels and the deliveries never carry the secret segment",
         %{conn: conn} do
      admin = authed_user(:admin)
      endpoint = seed_endpoint(@long_secret)

      Ash.Seed.seed!(KilnCMS.CMS.WebhookDelivery, %{
        endpoint_id: endpoint.id,
        endpoint_url: endpoint.url,
        event: "page.published",
        payload: %{}
      })

      gone = seed_endpoint()

      Ash.Seed.seed!(KilnCMS.CMS.WebhookDelivery, %{
        endpoint_id: gone.id,
        endpoint_url: gone.url,
        event: "page.published",
        payload: %{}
      })

      :ok = CMS.destroy_webhook_endpoint(gone, actor: admin)

      conn = log_in(conn, admin)
      dead = conn |> get(~p"/editor/webhooks") |> html_response(200)
      {:ok, lv, live_html} = live(conn, ~p"/editor/webhooks")

      for html <- [dead, live_html] do
        refute html =~ @secret_segment
        refute html =~ @hook_url
      end

      assert has_element?(lv, "#webhook-#{endpoint.id}-url", @masked_url)
      assert has_element?(lv, ~s([aria-label="Reveal signing secret for #{@masked_url}"]))
      assert lv |> element("table") |> render() =~ @masked_url

      # Revealing the secret labels its Copy and Hide with the masked URL too.
      html = lv |> element("#reveal-secret-#{endpoint.id}") |> render_click()
      refute html =~ @secret_segment

      assert has_element?(
               lv,
               ~s(#copy-secret-#{endpoint.id}[aria-label="Copy signing secret for #{@masked_url}"])
             )
    end

    test "Reveal URL shows the full URL, and Hide URL masks it again", %{conn: conn} do
      endpoint = seed_endpoint()
      {lv, _html} = open(conn)

      lv |> element("#reveal-url-#{endpoint.id}") |> render_click()
      assert has_element?(lv, "#webhook-#{endpoint.id}-url", @hook_url)
      assert has_element?(lv, "#reveal-url-#{endpoint.id}", "Hide URL")

      html = lv |> element("#reveal-url-#{endpoint.id}") |> render_click()
      refute html =~ @secret_segment
      assert has_element?(lv, "#webhook-#{endpoint.id}-url", @masked_url)
    end

    test "Reveal URL for another site's endpoint reveals nothing", %{conn: conn} do
      other =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Other",
          slug: "wh-url-#{System.unique_integer([:positive])}",
          status: :active
        })

      theirs = seed_endpoint("s3cret", other.id)
      {lv, _html} = open(conn)

      html = render_click(lv, "reveal_url", %{"id" => theirs.id})

      assert html =~ "Couldn&#39;t reveal that URL."
      refute html =~ @secret_segment
    end

    test "Reveal URL is refused to an admin demoted after the page mounted", %{conn: conn} do
      endpoint = seed_endpoint()
      user = authed_user(:editor)

      membership =
        Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
          user_id: user.id,
          organization_id: KilnCMS.Accounts.default_org_id(),
          role: :admin
        })

      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/webhooks")
      Ash.Seed.update!(membership, %{role: :editor})

      html = lv |> element("#reveal-url-#{endpoint.id}") |> render_click()

      assert html =~ "Couldn&#39;t reveal that URL."
      refute html =~ @secret_segment
    end

    test "the edit form is not pre-filled: not at first, after a change, or after a toggle",
         %{conn: conn} do
      endpoint = seed_endpoint()
      {lv, _html} = open(conn)

      html = edit(lv, endpoint)
      refute html =~ @secret_segment
      assert has_element?(lv, "#edit-webhook-#{endpoint.id}", "Current URL:")

      assert has_element?(
               lv,
               "#edit-webhook-#{endpoint.id} #webhook-#{endpoint.id}-url",
               @masked_url
             )

      assert has_element?(
               lv,
               "#edit-webhook-#{endpoint.id}",
               "Leave blank to keep the current URL."
             )

      assert has_element?(
               lv,
               ~s(#edit-webhook-#{endpoint.id} input[name="webhook[url]"][value=""])
             )

      html =
        lv
        |> form("#edit-webhook-#{endpoint.id}", webhook: %{active: "false"})
        |> render_change()

      refute html =~ @secret_segment

      html = bulk(lv, "edit", "group", "page")
      refute html =~ @secret_segment

      # What the admin types is theirs to see.
      html =
        lv
        |> form("#edit-webhook-#{endpoint.id}", webhook: %{url: "https://hooks.test/typed"})
        |> render_change()

      assert html =~ ~s(value="https://hooks.test/typed")
    end

    test "a blank URL keeps the URL and raises no notice; a new URL does", %{conn: conn} do
      endpoint = Ash.Seed.update!(seed_endpoint(), %{events: ["security.lockout"]})
      {lv, _html} = open(conn)

      edit(lv, endpoint)

      html =
        lv
        |> form("#edit-webhook-#{endpoint.id}", webhook: %{url: ""})
        |> render_submit()

      assert html =~ "Saved."
      assert CMS.get_webhook_endpoint!(endpoint.id, authorize?: false).url == @hook_url
      assert KilnCMS.Test.SecurityAlerts.dispatches() == []

      edit(lv, endpoint)

      lv
      |> form("#edit-webhook-#{endpoint.id}", webhook: %{url: "https://hooks.test/moved"})
      |> render_submit()

      assert CMS.get_webhook_endpoint!(endpoint.id, authorize?: false).url ==
               "https://hooks.test/moved"

      assert [%{"notice" => %{"change" => "webhook_changed"}}] =
               KilnCMS.Test.SecurityAlerts.dispatches()
    end
  end

  describe "the Slack format (#2245)" do
    defp choose_slack(lv) do
      lv
      |> form("#new-webhook-form", webhook: %{format: "slack"})
      |> render_change()
    end

    defp slack_endpoint! do
      CMS.create_webhook_endpoint!(
        %{url: "https://hooks.slack.test/services/T0/B0/T0SECRET-token-Zq9x", format: :slack},
        authorize?: false
      )
    end

    test "choosing Slack limits the picker to security events and ticks them all", %{conn: conn} do
      {lv, _html} = open(conn)
      security = WebhookEndpoint.security_events()

      html = choose_slack(lv)

      assert Enum.sort(checked(html, "new-webhook-form")) == Enum.sort(security)
      refute has_element?(lv, ~s(#new-webhook-form input[value="page.published"]))
      assert has_element?(lv, "#slack-url-credential", "the URL is the credential")
      assert html =~ "Slack endpoints receive security alerts only."

      # Back to Kiln: the defaults again.
      html =
        lv
        |> form("#new-webhook-form", webhook: %{format: "kiln"})
        |> render_change()

      assert Enum.sort(checked(html, "new-webhook-form")) ==
               Enum.sort(WebhookEndpoint.default_events())
    end

    test "Select all on a Slack form ticks every security event", %{conn: conn} do
      {lv, _html} = open(conn)
      choose_slack(lv)

      assert checked(bulk(lv, "new", "none"), "new-webhook-form") == []

      html = bulk(lv, "new", "all")

      assert Enum.sort(checked(html, "new-webhook-form")) ==
               Enum.sort(WebhookEndpoint.security_events())

      refute has_element?(lv, ~s(#new-webhook-form button[phx-value-op="all"][title]))
    end

    test "adding one: a Slack row with a badge, and no secret or Rotate", %{conn: conn} do
      {lv, _html} = open(conn)
      choose_slack(lv)

      html =
        lv
        |> form("#new-webhook-form",
          webhook: %{url: "https://hooks.slack.test/services/T0/B0/T0SECRET-token-Zq9x"}
        )
        |> render_submit()

      assert html =~ "Slack webhook added."
      assert [endpoint] = CMS.list_webhook_endpoints!(authorize?: false)
      assert endpoint.format == :slack
      assert Enum.sort(endpoint.events) == Enum.sort(WebhookEndpoint.security_events())

      refute html =~ @secret_segment
      refute html =~ WebhookEndpoint.secret(endpoint)
      assert has_element?(lv, "#webhook-#{endpoint.id}-slack", "Slack")
      refute has_element?(lv, "#webhook-#{endpoint.id}-secret-masked")
      refute has_element?(lv, "#reveal-secret-#{endpoint.id}")
      refute has_element?(lv, "#rotate-secret-#{endpoint.id}")
    end

    test "a forged Slack create with a content event is refused", %{conn: conn} do
      {lv, _html} = open(conn)
      choose_slack(lv)

      html =
        render_submit(lv, "create", %{
          "webhook" => %{
            "url" => "https://hooks.slack.test/services/T0/B0/abc",
            "format" => "slack",
            "events" => ["security.lockout", "page.published"]
          }
        })

      assert html =~ "Slack endpoints can only receive security events"
      assert CMS.list_webhook_endpoints!(authorize?: false) == []
    end

    test "editing one shows the format read-only and offers security events only",
         %{conn: conn} do
      endpoint = slack_endpoint!()
      {lv, _html} = open(conn)

      edit(lv, endpoint)

      assert has_element?(lv, "#webhook-#{endpoint.id}-format", "Slack (incoming webhook)")
      refute has_element?(lv, ~s(#edit-webhook-#{endpoint.id} select[name="webhook[format]"]))
      refute has_element?(lv, ~s(#edit-webhook-#{endpoint.id} input[value="page.published"]))

      html = bulk(lv, "edit", "none")
      assert checked(html, "edit-webhook-#{endpoint.id}") == []
      html = bulk(lv, "edit", "all")

      assert Enum.sort(checked(html, "edit-webhook-#{endpoint.id}")) ==
               Enum.sort(WebhookEndpoint.security_events())
    end

    test "an admin demoted after the page mounted cannot add one", %{conn: conn} do
      user = authed_user(:editor)

      membership =
        Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
          user_id: user.id,
          organization_id: KilnCMS.Accounts.default_org_id(),
          role: :admin
        })

      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/webhooks")
      choose_slack(lv)
      Ash.Seed.update!(membership, %{role: :editor})

      lv
      |> form("#new-webhook-form", webhook: %{url: "https://hooks.slack.test/services/T0/B0/abc"})
      |> render_submit()

      assert CMS.list_webhook_endpoints!(authorize?: false) == []
    end
  end
end
