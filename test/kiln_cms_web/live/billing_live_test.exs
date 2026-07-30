defmodule KilnCMSWeb.BillingLiveTest do
  @moduledoc """
  The `/editor/billing` console: mount guards, the degrade-when-unconfigured
  behaviour, and tier CRUD.

  The mount guards carry real weight here — this page can read and rewrite an
  instance-wide payment credential, so the non-admin cases are a security
  assertion, not a UX one.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing

  @password "password123456"

  defp authed_user(role) do
    email = "billing-live-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    # A real sign-in, so the user carries the session token
    # `store_in_session/2` needs.
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

  defp configure_billing! do
    settings = Billing.ensure_settings!()

    {:ok, settings} =
      Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", authorize?: false)

    {:ok, settings} =
      Billing.store_billing_secret(settings, :webhook_secret, "whsec_abc", authorize?: false)

    settings
  end

  defp tier!(attrs \\ %{}) do
    Billing.create_tier!(
      Map.merge(
        %{
          name: "Supporter",
          slug: "supporter-#{System.unique_integer([:positive])}",
          audience: hd(KilnCMS.CMS.Audiences.gated()),
          provider_price_id: "price_#{System.unique_integer([:positive])}"
        },
        attrs
      ),
      authorize?: false,
      tenant: KilnCMS.Accounts.default_org_id()
    )
  end

  describe "mount guards" do
    test "an anonymous visitor is sent to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/billing")
    end

    test "a viewer is bounced", %{conn: conn} do
      conn = log_in(conn, authed_user(:viewer))

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/editor/billing")
    end

    test "an editor is bounced — payment credentials are not an editorial concern", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/editor/billing")
    end

    test "a platform admin mounts", %{conn: conn} do
      conn = log_in(conn, authed_user(:admin))

      assert {:ok, _view, html} = live(conn, ~p"/editor/billing")
      assert html =~ "Billing"
    end
  end

  describe "unconfigured instance" do
    test "reports not-configured and disables the connection check", %{conn: conn} do
      conn = log_in(conn, authed_user(:admin))
      {:ok, _view, html} = live(conn, ~p"/editor/billing")

      assert html =~ "Not configured"
      assert html =~ "no tier is offered"
      # The button must be disabled rather than able to fire a provider call with
      # no credentials.
      assert html =~ "disabled"
    end

    test "creating the settings row does not make billing configured", %{conn: conn} do
      conn = log_in(conn, authed_user(:admin))
      {:ok, _view, _html} = live(conn, ~p"/editor/billing")

      # Mount calls `ensure_settings!/0`, so a row now exists — but an empty row
      # must never read as configured.
      assert Billing.get_settings()
      refute Billing.configured?()
    end
  end

  describe "credentials" do
    test "storing both secrets flips the status to configured", %{conn: conn} do
      conn = log_in(conn, authed_user(:admin))
      {:ok, view, _html} = live(conn, ~p"/editor/billing")

      view
      |> form("#secret-secret_key", %{"secret" => %{"value" => "sk_test_abc"}})
      |> render_submit()

      # One secret is not enough — every payment surface gates on BOTH resolving.
      refute Billing.configured?()

      view
      |> form("#secret-webhook_secret", %{"secret" => %{"value" => "whsec_abc"}})
      |> render_submit()

      assert Billing.configured?()
      assert render(view) =~ "Configured"
    end

    test "disconnect clears the credentials", %{conn: conn} do
      configure_billing!()
      conn = log_in(conn, authed_user(:admin))
      {:ok, view, html} = live(conn, ~p"/editor/billing")

      assert html =~ "Configured"

      render_click(view, "clear_credentials", %{})

      refute Billing.configured?()
      assert render(view) =~ "Not configured"
    end

    test "selecting the env provider swaps in the pointer form", %{conn: conn} do
      conn = log_in(conn, authed_user(:admin))
      {:ok, view, _html} = live(conn, ~p"/editor/billing")

      html =
        render_click(view, "select_provider", %{"key" => "secret_key", "provider" => "env"})

      assert html =~ "Environment variable name"
      assert html =~ ~s(phx-submit="save_key_source")
    end

    test "a bad env pointer surfaces the operator-facing error", %{conn: conn} do
      conn = log_in(conn, authed_user(:admin))
      {:ok, view, _html} = live(conn, ~p"/editor/billing")

      render_click(view, "select_provider", %{"key" => "secret_key", "provider" => "env"})

      html =
        view
        |> form("#key-source-secret_key", %{"source" => %{"pointer" => "KILN_DEFINITELY_UNSET"}})
        |> render_submit()

      assert html =~ "KILN_DEFINITELY_UNSET"
      refute Billing.configured?()
    end
  end

  describe "tiers" do
    test "lists existing tiers", %{conn: conn} do
      tier = tier!(%{name: "Patron"})
      conn = log_in(conn, authed_user(:admin))

      {:ok, _view, html} = live(conn, ~p"/editor/billing")

      assert html =~ "Patron"
      assert html =~ tier.provider_price_id
    end

    test "shows an empty state with no tiers", %{conn: conn} do
      conn = log_in(conn, authed_user(:admin))

      {:ok, _view, html} = live(conn, ~p"/editor/billing")

      assert html =~ "No tiers yet"
    end

    test "creates a tier", %{conn: conn} do
      conn = log_in(conn, authed_user(:admin))
      {:ok, view, _html} = live(conn, ~p"/editor/billing")

      html =
        view
        |> form("#tier-form", %{
          "tier" => %{
            "name" => "Supporter",
            "slug" => "supporter",
            "audience" => to_string(hd(KilnCMS.CMS.Audiences.gated())),
            "provider_price_id" => "price_new",
            "position" => "1",
            "active" => "true"
          }
        })
        |> render_submit()

      assert html =~ "Supporter"
      assert html =~ "price_new"
    end

    test "editing a tier hides the audience field and explains why", %{conn: conn} do
      tier = tier!()
      conn = log_in(conn, authed_user(:admin))
      {:ok, view, _html} = live(conn, ~p"/editor/billing")

      html = render_click(view, "edit_tier", %{"id" => tier.id})

      assert html =~ "Edit tier"
      # The audience select must be gone, replaced by the immutability note.
      refute html =~ ~s(name="tier[audience]")
      assert html =~ "can&#39;t change"
    end

    test "deletes a tier", %{conn: conn} do
      tier = tier!(%{name: "Doomed"})
      conn = log_in(conn, authed_user(:admin))
      {:ok, view, html} = live(conn, ~p"/editor/billing")

      assert html =~ "Doomed"

      html = render_click(view, "delete_tier", %{"id" => tier.id})

      refute html =~ "Doomed"
    end

    test "only this org's tiers are listed", %{conn: conn} do
      other =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Other",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      Billing.create_tier!(
        %{
          name: "ForeignTier",
          slug: "foreign",
          audience: hd(KilnCMS.CMS.Audiences.gated()),
          provider_price_id: "price_foreign"
        },
        authorize?: false,
        tenant: other.id
      )

      conn = log_in(conn, authed_user(:admin))
      {:ok, _view, html} = live(conn, ~p"/editor/billing")

      refute html =~ "ForeignTier"
    end
  end
end
