defmodule KilnCMSWeb.BillingControllerTest do
  @moduledoc """
  Checkout and billing-portal handoffs.

  The metadata assertions matter most: checkout-session metadata does **not**
  propagate to the subscription the provider creates, and the subscription is what
  carries every later event — so if `subscription_data[metadata]` ever stopped
  being stamped, cancellations would arrive unattributable and revocation would
  silently stop working.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.CMS.Audiences

  @password "password123456"
  @gated hd(Audiences.gated())

  setup do
    Application.put_env(:kiln_cms, KilnCMS.Billing, provider: KilnCMS.StubBillingProvider)

    on_exit(fn ->
      Application.delete_env(:kiln_cms, KilnCMS.Billing)
      Application.delete_env(:kiln_cms, :stub_billing_provider)
    end)

    :ok
  end

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
    email = "checkout-#{System.unique_integer([:positive])}@example.com"

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

  defp tier(attrs \\ %{}) do
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
      tenant: default_org_id()
    )
  end

  describe "checkout" do
    test "redirects a signed-in member to the provider's hosted page", %{conn: conn} do
      configure_billing!()
      t = tier()
      conn = log_in(conn, authed_user())

      conn = post(conn, ~p"/billing/checkout", %{"tier" => t.slug})

      assert redirected_to(conn) =~ "checkout.example.test"
    end

    test "creates an :incomplete membership before redirecting", %{conn: conn} do
      # It must exist before the redirect: the session metadata needs a stable id,
      # and the webhook needs a resolution target even if metadata is lost.
      configure_billing!()
      t = tier()
      user = authed_user()
      conn = log_in(conn, user)

      post(conn, ~p"/billing/checkout", %{"tier" => t.slug})

      assert [membership] =
               Billing.memberships_for_user!(user.id, authorize?: false, tenant: default_org_id())

      assert membership.status == :incomplete
      assert membership.tier_id == t.id
    end

    test "clicking join twice reuses the same membership row", %{conn: conn} do
      configure_billing!()
      t = tier()
      user = authed_user()

      post(log_in(conn, user), ~p"/billing/checkout", %{"tier" => t.slug})
      post(log_in(build_conn(), user), ~p"/billing/checkout", %{"tier" => t.slug})

      assert length(
               Billing.memberships_for_user!(user.id,
                 authorize?: false,
                 tenant: default_org_id()
               )
             ) == 1
    end

    test "stamps metadata on BOTH the session and subscription_data", %{conn: conn} do
      # Session metadata does NOT propagate to the subscription the provider
      # creates, and the subscription carries every later event — including the
      # cancellation that drives revocation. Dropping either map would make
      # cancellations unattributable and silently break revocation.
      configure_billing!()
      t = tier()
      user = authed_user()
      KilnCMS.StubBillingProvider.spy_on(:checkout_session, self())

      post(log_in(conn, user), ~p"/billing/checkout", %{"tier" => t.slug})

      assert_received {:stub_billing, :checkout_session, params}

      assert params.mode == "subscription"
      assert [%{price: price_id, quantity: 1}] = params.line_items
      assert price_id == t.provider_price_id

      [membership] =
        Billing.memberships_for_user!(user.id, authorize?: false, tenant: default_org_id())

      for metadata <- [params.metadata, params.subscription_data.metadata] do
        assert metadata.org_id == default_org_id()
        assert metadata.user_id == user.id
        assert metadata.tier_id == t.id
        assert metadata.membership_id == membership.id
      end

      # A retried create must not mint a second session.
      assert params.idempotency_key == "checkout:" <> membership.id
    end

    test "the success URL keeps the provider's template token unencoded", %{conn: conn} do
      # `{CHECKOUT_SESSION_ID}` is substituted by the provider; percent-encoding
      # it would hand the member a literal brace-laden URL.
      configure_billing!()
      t = tier()
      KilnCMS.StubBillingProvider.spy_on(:checkout_session, self())

      post(log_in(conn, authed_user()), ~p"/billing/checkout", %{"tier" => t.slug})

      assert_received {:stub_billing, :checkout_session, params}
      assert params.success_url =~ "session_id={CHECKOUT_SESSION_ID}"
      assert params.success_url =~ "/account?checkout=success"
    end

    test "return URLs are built from the REQUEST host, not the canonical URL", %{conn: conn} do
      # A member on a custom-domain org must come back to that domain, or their
      # session cookie won't be there.
      configure_billing!()
      t = tier()
      KilnCMS.StubBillingProvider.spy_on(:checkout_session, self())

      conn = %{log_in(conn, authed_user()) | host: "custom.example.org"}
      post(conn, ~p"/billing/checkout", %{"tier" => t.slug})

      assert_received {:stub_billing, :checkout_session, params}
      assert params.success_url =~ "custom.example.org"
      assert params.cancel_url =~ "custom.example.org"
    end

    test "an anonymous visitor is sent to register with the intent stashed", %{conn: conn} do
      # Registration is the identity step; entangling it with payment would lose
      # the intent, so it is replayed after the account exists.
      configure_billing!()
      t = tier()

      conn = post(conn, ~p"/billing/checkout", %{"tier" => t.slug})

      assert redirected_to(conn) == ~p"/register"
      assert get_session(conn, :join_tier) == t.slug
    end

    test "an unknown tier redirects with a flash rather than 500ing", %{conn: conn} do
      configure_billing!()
      conn = log_in(conn, authed_user())

      conn = post(conn, ~p"/billing/checkout", %{"tier" => "no-such-plan"})

      assert redirected_to(conn) == ~p"/membership"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't available"
    end

    test "a retired tier cannot be bought", %{conn: conn} do
      configure_billing!()
      t = tier(%{active: false})
      conn = log_in(conn, authed_user())

      conn = post(conn, ~p"/billing/checkout", %{"tier" => t.slug})

      assert redirected_to(conn) == ~p"/membership"
    end

    test "an unconfigured instance 404s rather than confirming the route", %{conn: conn} do
      t = tier()
      conn = log_in(conn, authed_user())

      conn = post(conn, ~p"/billing/checkout", %{"tier" => t.slug})

      assert conn.status == 404
    end

    test "a provider failure never leaks its message to the member", %{conn: conn} do
      configure_billing!()
      t = tier()
      conn = log_in(conn, authed_user())

      KilnCMS.StubBillingProvider.put(
        :checkout_session,
        {:error, {:http_status, 402, %{"error" => %{"message" => "SECRET-ACCOUNT-DETAIL"}}}}
      )

      conn = post(conn, ~p"/billing/checkout", %{"tier" => t.slug})

      assert redirected_to(conn) == ~p"/membership"
      refute Phoenix.Flash.get(conn.assigns.flash, :error) =~ "SECRET-ACCOUNT-DETAIL"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "payment provider"
    end
  end

  describe "portal" do
    test "redirects a member with a provider customer", %{conn: conn} do
      configure_billing!()
      user = authed_user()
      t = tier()

      Ash.Seed.seed!(Billing.Membership, %{
        org_id: default_org_id(),
        user_id: user.id,
        tier_id: t.id,
        status: :active,
        provider_customer_id: "cus_1"
      })

      conn = post(log_in(conn, user), ~p"/billing/portal", %{})

      assert redirected_to(conn) =~ "billing.example.test"
    end

    test "a member with no provider customer is sent back to their account", %{conn: conn} do
      configure_billing!()
      conn = post(log_in(conn, authed_user()), ~p"/billing/portal", %{})

      assert redirected_to(conn) == ~p"/account"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "don't have a membership"
    end

    test "an anonymous visitor is sent to register", %{conn: conn} do
      configure_billing!()

      conn = post(conn, ~p"/billing/portal", %{})

      assert redirected_to(conn) == ~p"/register"
    end

    test "an unconfigured instance 404s", %{conn: conn} do
      conn = post(log_in(conn, authed_user()), ~p"/billing/portal", %{})

      assert conn.status == 404
    end
  end
end
