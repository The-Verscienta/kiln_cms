defmodule KilnCMSWeb.MembershipLiveTest do
  @moduledoc """
  The public join page. Anonymous-tolerant by design — it is where the paywall
  CTA sends a reader who has not signed up yet.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.Organization
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.CMS.Audiences

  @password "password123456"
  @gated hd(Audiences.gated())

  defp default_org_id, do: KilnCMS.Accounts.default_org_id()

  defp configure_billing! do
    settings = Billing.ensure_settings!()

    {:ok, settings} =
      Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", authorize?: false)

    {:ok, _settings} =
      Billing.store_billing_secret(settings, :webhook_secret, "whsec_abc", authorize?: false)

    :ok
  end

  defp authed_user do
    email = "join-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
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

  defp tier(attrs \\ %{}, org_id \\ nil) do
    Billing.create_tier!(
      Map.merge(
        %{
          name: "Supporter",
          slug: "supporter-#{System.unique_integer([:positive])}",
          audience: @gated,
          provider_price_id: "price_#{System.unique_integer([:positive])}"
        },
        attrs
      ),
      authorize?: false,
      tenant: org_id || default_org_id()
    )
  end

  describe "anonymous visitors" do
    test "may view the page", %{conn: conn} do
      configure_billing!()
      tier(%{name: "Patron"})

      assert {:ok, _view, html} = live(conn, ~p"/membership")
      assert html =~ "Patron"
    end

    test "are asked to create an account rather than shown a dead join button", %{conn: conn} do
      configure_billing!()
      tier()

      {:ok, _view, html} = live(conn, ~p"/membership")

      assert html =~ "Create an account to join"
      refute html =~ ~s(action="/billing/checkout")
    end
  end

  describe "tier listing" do
    test "only active tiers are offered", %{conn: conn} do
      configure_billing!()
      tier(%{name: "Current"})
      tier(%{name: "Retired", active: false})

      {:ok, _view, html} = live(conn, ~p"/membership")

      assert html =~ "Current"
      refute html =~ "Retired"
    end

    test "another org's tiers are not listed", %{conn: conn} do
      configure_billing!()

      other =
        Ash.Seed.seed!(Organization, %{
          name: "Other",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      tier(%{name: "ForeignPlan"}, other.id)

      {:ok, _view, html} = live(conn, ~p"/membership")

      refute html =~ "ForeignPlan"
    end

    test "the display price is rendered when configured", %{conn: conn} do
      configure_billing!()
      tier(%{price_config: %{"amount" => "$5", "interval" => "month"}})

      {:ok, _view, html} = live(conn, ~p"/membership")

      assert html =~ "$5 / month"
    end
  end

  describe "unconfigured instance" do
    test "renders a neutral notice instead of crashing a public URL", %{conn: conn} do
      tier()

      assert {:ok, _view, html} = live(conn, ~p"/membership")

      assert html =~ "No plans available yet"
      refute html =~ ~s(action="/billing/checkout")
    end
  end

  describe "signed-in readers" do
    test "see a join form for a tier they don't hold", %{conn: conn} do
      configure_billing!()
      tier()
      conn = log_in(conn, authed_user())

      {:ok, _view, html} = live(conn, ~p"/membership")

      assert html =~ ~s(action="/billing/checkout")
      assert html =~ "_csrf_token"
    end

    test "see their current plan badged rather than offered again", %{conn: conn} do
      configure_billing!()
      user = authed_user()
      t = tier(%{name: "Mine"})

      Ash.Seed.seed!(Billing.Membership, %{
        org_id: default_org_id(),
        user_id: user.id,
        tier_id: t.id,
        status: :active
      })

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/membership")

      assert html =~ "Your plan"
      assert html =~ "Manage membership"
      refute html =~ ~s(action="/billing/checkout")
    end

    test "a past-due member still counts as holding the plan", %{conn: conn} do
      # Access survives dunning, so the page must not try to re-sell it.
      configure_billing!()
      user = authed_user()
      t = tier()

      Ash.Seed.seed!(Billing.Membership, %{
        org_id: default_org_id(),
        user_id: user.id,
        tier_id: t.id,
        status: :past_due
      })

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/membership")

      assert html =~ "Your plan"
    end

    test "a cancelled membership is offered again", %{conn: conn} do
      configure_billing!()
      user = authed_user()
      t = tier()

      Ash.Seed.seed!(Billing.Membership, %{
        org_id: default_org_id(),
        user_id: user.id,
        tier_id: t.id,
        status: :canceled
      })

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/membership")

      refute html =~ "Your plan"
      assert html =~ ~s(action="/billing/checkout")
    end
  end

  describe "cancelled checkout" do
    test "says nothing was charged", %{conn: conn} do
      configure_billing!()
      tier()

      {:ok, _view, html} = live(conn, ~p"/membership?checkout=canceled")

      assert html =~ "haven&#39;t been charged"
    end
  end
end
