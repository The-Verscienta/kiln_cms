defmodule KilnCMSWeb.SiteAiLiveTest do
  @moduledoc """
  The console screen behind `/editor/site-ai` (#1557): a site's own AI
  provider, key and models.

  `KilnCMS.LLM.SiteProviderTest` covers the row and the resolver. This covers
  what only the screen does:

    * **the auth matrix** — a site admin is admitted on their own site, an
      editor is turned away, and a site sees only its own row;
    * **the write-only key** — never rendered, a blank save keeps it;
    * **the honest status** — whose provider each feature uses on this site,
      and the banner when the stored key can't be read.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Keys.Vault

  @moduletag :capture_log

  @password "password1234!"

  @valid %{
    "enabled" => "true",
    "provider" => "anthropic",
    "api_key" => "sk-very-secret-site-key",
    "seo_model" => "claude-sonnet-5",
    "assist_model" => "claude-sonnet-5",
    "ask_model" => ""
  }

  setup do
    %{org: KilnCMS.OrgFixtures.org("site-ai")}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/site-ai")
    end

    test "turns away an editor of this very site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :editor)

      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-ai")
    end

    test "admits a site admin on their own site, and their save lands there",
         %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-ai")
      save(lv, @valid)

      assert %{provider: :anthropic, seo_model: "claude-sonnet-5"} = row!(org)
    end

    test "a site sees only its own provider", %{conn: conn, org: org} do
      other = KilnCMS.OrgFixtures.org("site-ai-other")

      CMS.save_site_ai_provider!(
        %{provider: :openai, api_key: "k", seo_model: "other-site-model"},
        tenant: other,
        authorize?: false
      )

      html = conn |> mount_as_admin(org) |> render()

      refute html =~ "other-site-model"
      refute html =~ "This site&#39;s provider"
    end
  end

  describe "saving" do
    test "stores the key encrypted and never renders it", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      html = save(lv, @valid)

      assert html =~ "AI provider saved."
      refute html =~ "sk-very-secret-site-key"
      assert html =~ "Saved. Leave blank to keep it."
      assert {:ok, "sk-very-secret-site-key"} = Vault.decrypt(row!(org).api_key_encrypted)
    end

    test "the status says which provider each feature uses, and a blank model is off",
         %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)

      status = lv |> element("#site-ai-status") |> render()
      assert status =~ "This site&#39;s provider (Anthropic)"
      # `ask_model` was left blank: off for this site, not the deployment's.
      assert status =~ "Off"
    end

    test "a later save with a blank key keeps the stored one", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)
      save(lv, %{@valid | "api_key" => "", "seo_model" => "claude-opus-5"})

      row = row!(org)
      assert row.seo_model == "claude-opus-5"
      assert {:ok, "sk-very-secret-site-key"} = Vault.decrypt(row.api_key_encrypted)
    end

    test "the endpoint field appears only for an OpenAI-compatible provider",
         %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      refute has_element?(lv, "#site-ai-form input[name='ai[base_url]']")

      lv
      |> form("#site-ai-form", ai: %{@valid | "provider" => "openai_compatible"})
      |> render_change()

      assert has_element?(lv, "#site-ai-form input[name='ai[base_url]']")
    end

    test "a private endpoint is refused, with the reason", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)

      lv
      |> form("#site-ai-form", ai: %{@valid | "provider" => "openai_compatible"})
      |> render_change()

      html =
        save(
          lv,
          @valid
          |> Map.put("provider", "openai_compatible")
          |> Map.put("base_url", "https://10.0.0.5/v1")
        )

      assert html =~ "private or link-local"
      assert {:ok, []} = CMS.list_site_ai_provider(tenant: org, authorize?: false)
    end

    test "Remove puts the site back on the deployment's configuration",
         %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)

      lv |> element("button", "Remove") |> render_click()

      assert {:ok, []} = CMS.list_site_ai_provider(tenant: org, authorize?: false)
    end
  end

  describe "an unreadable key" do
    test "is called out, because the site's AI requests are refused", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)

      # What a SECRET_KEY_BASE rotation leaves behind.
      {1, _} =
        KilnCMS.Repo.update_all(
          from(r in "site_ai_providers", where: r.org_id == type(^org.id, :binary_id)),
          set: [api_key_encrypted: :crypto.strong_rand_bytes(48)]
        )

      html = conn |> mount_as_admin(org) |> render()
      assert html =~ "The saved API key can&#39;t be read. Re-enter it."
      assert html =~ "Refused: this site&#39;s provider is set but can&#39;t be used"
    end
  end

  defp mount_as_admin(conn, org) do
    {:ok, lv, _html} =
      conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/site-ai")

    lv
  end

  defp save(lv, params) do
    lv |> form("#site-ai-form", ai: params) |> render_submit()
  end

  defp row!(org) do
    {:ok, [row]} = CMS.list_site_ai_provider(tenant: org, authorize?: false)
    row
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "siteai-#{role}-#{System.unique_integer([:positive])}@example.com"

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
