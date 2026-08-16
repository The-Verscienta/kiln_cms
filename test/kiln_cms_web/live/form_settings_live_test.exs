defmodule KilnCMSWeb.FormSettingsLiveTest do
  @moduledoc """
  Per-site form settings (`/editor/forms/settings`, #1232): the admin auth
  matrix, a real save of each section, the embed tri-state, and the served
  header moving with the org default — the thing #1131 built and this page
  finally makes reachable in production.

  Shaped after `KilnCMSWeb.FeedSettingsLiveTest`.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMSWeb.FormSettingsLive

  @password "password1234!"
  @path "/editor/forms/settings"

  setup do
    %{org: org("formsettings")}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, @path)
    end

    test "turns away a non-admin", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               conn |> log_in(authed_user(:editor)) |> live(@path)

      assert flash["error"] =~ "admin access"
    end

    test "loads for an org admin on their own site, before either row exists", %{
      conn: conn,
      org: org
    } do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      {:ok, lv, html} = conn |> org_conn(org) |> log_in(user) |> live(@path)

      assert html =~ "Form settings"
      assert html =~ "Who may embed this site&#39;s forms"
      assert html =~ "Spam keywords"
      # Inherit is the state with no row — and the deployment's own list is
      # never printed (#1130).
      assert has_element?(lv, ~s(input[value="inherit"][checked]))
      refute html =~ "embedder.test"
    end

    test "the literal /editor/forms/settings segment wins over /editor/forms/:id", %{
      conn: conn,
      org: org
    } do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      # A form-builder mount on the id "settings" would be a 404 / raise, not
      # this page.
      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(user) |> live(@path)
      assert has_element?(lv, "#embed-default-form")
      assert has_element?(lv, "#spam-keywords-form")
    end

    test "the Forms page links here", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/forms")
      assert has_element?(lv, ~s(a[href="#{@path}"]), "Form settings")
    end
  end

  describe "the embed default" do
    setup %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)
      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(user) |> live(@path)
      %{lv: lv, user: user}
    end

    test "saves a list for the current site only, and the served header follows", %{
      lv: lv,
      org: org,
      user: user,
      conn: conn
    } do
      html =
        lv
        |> form("#embed-default-form",
          embed: %{mode: "list", origins: "https://a.test, https://b.test"}
        )
        |> render_submit()

      assert html =~ "Embed default saved."

      assert {:ok, [%{embed_origins: ["https://a.test", "https://b.test"]}]} =
               CMS.list_site_embed_settings(actor: user, tenant: org)

      # Another org is untouched.
      other = org("formsettings-other")
      assert {:ok, []} = CMS.list_site_embed_settings(authorize?: false, tenant: other.id)

      # And a form on this site with no list of its own now serves it (#1131).
      form = form!(org, user)

      policy =
        conn
        |> unique_ip()
        |> org_conn(org)
        |> get("/forms/#{form.slug}/embed")
        |> get_resp_header("content-security-policy")
        |> List.first()

      assert policy =~ "frame-ancestors 'self' https://a.test https://b.test"
    end

    test "'this site only' saves [] and 'inherit' writes nil back — three states, not two", %{
      lv: lv,
      org: org,
      user: user
    } do
      assert lv
             |> form("#embed-default-form", embed: %{mode: "closed", origins: ""})
             |> render_submit() =~ "Embed default saved."

      assert {:ok, [%{embed_origins: []}]} =
               CMS.list_site_embed_settings(actor: user, tenant: org)

      assert has_element?(lv, ~s(input[value="closed"][checked]))

      assert lv
             |> form("#embed-default-form", embed: %{mode: "inherit", origins: ""})
             |> render_submit() =~ "Embed default saved."

      assert {:ok, [%{embed_origins: nil}]} =
               CMS.list_site_embed_settings(actor: user, tenant: org)

      assert has_element?(lv, ~s(input[value="inherit"][checked]))
    end

    test "a radio that contradicts the box is refused, not guessed", %{
      lv: lv,
      org: org,
      user: user
    } do
      assert lv
             |> form("#embed-default-form", embed: %{mode: "inherit", origins: "https://a.test"})
             |> render_submit() =~ "Choose “Only these sites”"

      assert lv
             |> form("#embed-default-form", embed: %{mode: "list", origins: ""})
             |> render_submit() =~ "Add at least one site"

      assert {:ok, []} = CMS.list_site_embed_settings(actor: user, tenant: org)
    end

    test "a malformed origin is refused by the resource and named in the flash", %{
      lv: lv,
      org: org,
      user: user
    } do
      html =
        lv
        |> form("#embed-default-form", embed: %{mode: "list", origins: "https://ok.test, nope"})
        |> render_submit()

      # `Exception.message/1` interpolates the offending entry — not a bare
      # `%{value}` template.
      assert html =~ "nope"
      refute html =~ "%{value}"
      assert {:ok, []} = CMS.list_site_embed_settings(actor: user, tenant: org)
      # The typed value is kept so the admin can fix it rather than retype it.
      assert has_element?(lv, ~s(#embed-default-origins[value="https://ok.test, nope"]))
    end

    test "a payload that is not a map does not crash the LiveView", %{lv: lv} do
      assert render_submit(lv, "save_embed", %{"embed" => "not-a-map"}) =~ "Something went wrong."
    end
  end

  describe "spam keywords" do
    setup %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)
      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(user) |> live(@path)
      %{lv: lv, user: user}
    end

    test "saves one per line, trimmed, de-duplicated case-insensitively", %{
      lv: lv,
      org: org,
      user: user
    } do
      html =
        lv
        |> form("#spam-keywords-form", spam: %{keywords: " casino \n\nCASINO\ncheap pills\r\n"})
        |> render_submit()

      assert html =~ "Spam keywords saved."
      assert html =~ "2 keywords saved."

      assert {:ok, [%{keywords: ["casino", "cheap pills"]}]} =
               CMS.list_form_spam_settings(actor: user, tenant: org)

      # Rendered back one per line.
      assert render(lv) =~ "casino\ncheap pills</textarea>"
    end

    test "an empty box saves [] — no keywords, which the check reads as nothing to do", %{
      lv: lv,
      org: org,
      user: user
    } do
      lv
      |> form("#spam-keywords-form", spam: %{keywords: "casino"})
      |> render_submit()

      assert lv
             |> form("#spam-keywords-form", spam: %{keywords: ""})
             |> render_submit() =~ "0 keywords saved."

      assert {:ok, [%{keywords: []}]} = CMS.list_form_spam_settings(actor: user, tenant: org)
    end

    test "a payload that is not a map saves nothing and does not crash", %{lv: lv} do
      assert render_submit(lv, "save_keywords", %{"spam" => "not-a-map"}) =~
               "Spam keywords saved."
    end

    test "parse_keywords/1 on its own" do
      assert FormSettingsLive.parse_keywords("") == []
      assert FormSettingsLive.parse_keywords("a\nb\r\nc") == ["a", "b", "c"]
      assert FormSettingsLive.parse_keywords("  A  \n a\n") == ["A"]
    end
  end

  describe "cross-org write boundary" do
    test "an admin of one site cannot write another site's form settings", %{org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)
      other = org("formsettings-cross")

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_embed_settings(%{embed_origins: []}, actor: user, tenant: other)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_form_spam_settings(%{keywords: ["x"]}, actor: user, tenant: other)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp form!(org, user) do
    form =
      CMS.create_form!(
        %{
          name: "Contact",
          slug: "fs-#{System.unique_integer([:positive])}",
          success_message: "Merci!"
        },
        actor: user,
        tenant: org
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, required: true},
      actor: user,
      tenant: org
    )

    form
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "formsettings-#{role}-#{System.unique_integer([:positive])}@example.com"

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
