defmodule KilnCMSWeb.AccountLiveTest do
  @moduledoc """
  `/account` — the first signed-in-but-not-editor LiveView in the codebase.

  The assertion worth pinning is that a **`:viewer` mounts**: every other
  LiveView here gates on an editorial tier, so this is new behaviour, and a
  regression would silently lock every paying reader out of their own account.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.Newsletter

  @password "password123456"
  @gated hd(Audiences.gated())

  setup do
    Application.put_env(:kiln_cms, KilnCMS.Billing, provider: KilnCMS.StubBillingProvider)

    on_exit(fn ->
      Application.delete_env(:kiln_cms, KilnCMS.Billing)
      Application.delete_env(:kiln_cms, :stub_billing_provider)
    end)

    # Real credentials matter here: without them `Billing.credentials/0` fails and
    # the checkout-return path short-circuits before it reaches the ownership
    # check — which would make the security test below pass for the wrong reason.
    settings = Billing.ensure_settings!()

    {:ok, settings} =
      Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", authorize?: false)

    {:ok, _settings} =
      Billing.store_billing_secret(settings, :webhook_secret, "whsec_abc", authorize?: false)

    assert Billing.configured?()
    :ok
  end

  defp default_org_id, do: KilnCMS.Accounts.default_org_id()

  defp authed_user(role \\ :viewer) do
    email = "account-#{System.unique_integer([:positive])}@example.com"

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

  defp membership(user, tier, attrs) do
    Ash.Seed.seed!(
      Billing.Membership,
      Map.merge(
        %{
          org_id: default_org_id(),
          user_id: user.id,
          tier_id: tier.id,
          status: :active
        },
        attrs
      )
    )
  end

  describe "access" do
    test "an anonymous visitor is sent to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/account")
    end

    test "a VIEWER mounts — the new behaviour", %{conn: conn} do
      # Before this page, a self-registered reader could reach nothing at all.
      user = authed_user(:viewer)
      conn = log_in(conn, user)

      assert {:ok, _view, html} = live(conn, ~p"/account")
      assert html =~ "Your account"
      assert html =~ to_string(user.email)
    end

    test "an editor may also use it", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:ok, _view, _html} = live(conn, ~p"/account")
    end
  end

  describe "membership display" do
    test "a member with nothing sees the empty state and a link to plans", %{conn: conn} do
      conn = log_in(conn, authed_user())

      {:ok, _view, html} = live(conn, ~p"/account")

      assert html =~ "No membership yet"
      assert html =~ ~s(href="/membership")
      # Nothing to manage without a provider customer.
      refute html =~ ~s(action="/billing/portal")
    end

    test "an active membership shows its tier, status and renewal date", %{conn: conn} do
      user = authed_user()
      t = tier(%{name: "Patron"})

      membership(user, t, %{
        provider_customer_id: "cus_1",
        current_period_end: ~U[2027-03-05 00:00:00.000000Z]
      })

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/account")

      assert html =~ "Patron"
      assert html =~ "Active"
      assert html =~ "Renews on 5 March 2027"
      assert html =~ ~s(action="/billing/portal")
    end

    test "a cancel-at-period-end membership says when access ends", %{conn: conn} do
      user = authed_user()

      membership(user, tier(), %{
        provider_customer_id: "cus_1",
        cancel_at_period_end: true,
        current_period_end: ~U[2027-03-05 00:00:00.000000Z]
      })

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/account")

      assert html =~ "Access ends on 5 March 2027"
    end

    test "a past-due membership is shown as overdue, not hidden", %{conn: conn} do
      user = authed_user()
      membership(user, tier(), %{status: :past_due, provider_customer_id: "cus_1"})

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/account")

      assert html =~ "Payment overdue"
    end

    test "an incomplete membership is not listed", %{conn: conn} do
      # An abandoned checkout must not read as a membership.
      user = authed_user()
      membership(user, tier(%{name: "Ghost"}), %{status: :incomplete})

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/account")

      refute html =~ "Ghost"
      assert html =~ "No membership yet"
    end

    test "another member's membership is not shown", %{conn: conn} do
      other = authed_user()
      membership(other, tier(%{name: "SomeoneElse"}), %{provider_customer_id: "cus_x"})

      conn = log_in(conn, authed_user())
      {:ok, _view, html} = live(conn, ~p"/account")

      refute html =~ "SomeoneElse"
    end
  end

  describe "return from checkout" do
    test "a session naming ANOTHER user does not activate anything", %{conn: conn} do
      # `session_id` is attacker-suppliable, so the ownership check on the
      # session's metadata is what makes acting on it safe.
      victim = authed_user()
      t = tier()
      m = membership(victim, t, %{status: :incomplete})

      KilnCMS.StubBillingProvider.put(:checkout_session_retrieve, %{
        "id" => "cs_evil",
        "mode" => "subscription",
        "subscription" => "sub_evil",
        "metadata" => %{
          "membership_id" => m.id,
          "org_id" => m.org_id,
          # Someone else's id.
          "user_id" => Ash.UUID.generate()
        }
      })

      conn = log_in(conn, victim)
      {:ok, view, _html} = live(conn, ~p"/account?checkout=success&session_id=cs_evil")
      # `start_async` completes after mount returns; `render_async/1` is the API
      # that awaits it (plain `render/1` does not).
      render_async(view)

      {:ok, reloaded} = Billing.get_membership(m.id, authorize?: false, tenant: m.org_id)
      assert reloaded.status == :incomplete

      {:ok, user} = KilnCMS.Accounts.get_user(victim.id, authorize?: false)
      assert user.audiences == []
    end

    test "the member's own completed session activates the membership", %{conn: conn} do
      user = authed_user()
      t = tier()
      m = membership(user, t, %{status: :incomplete})

      KilnCMS.StubBillingProvider.put(:checkout_session_retrieve, %{
        "id" => "cs_ok",
        "mode" => "subscription",
        "customer" => "cus_ok",
        "subscription" => "sub_ok",
        "metadata" => %{
          "membership_id" => m.id,
          "org_id" => m.org_id,
          "user_id" => user.id
        }
      })

      conn = log_in(conn, user)
      {:ok, view, _html} = live(conn, ~p"/account?checkout=success&session_id=cs_ok")
      render_async(view)

      {:ok, reloaded} = Billing.get_membership(m.id, authorize?: false, tenant: m.org_id)
      assert reloaded.status == :active

      {:ok, reloaded_user} = KilnCMS.Accounts.get_user(user.id, authorize?: false)
      assert reloaded_user.audiences == [@gated]
    end

    test "no reconcile happens when nothing is pending", %{conn: conn} do
      # A refresh of `?checkout=success` on an already-active membership must not
      # keep calling the provider.
      user = authed_user()
      membership(user, tier(), %{provider_customer_id: "cus_1"})

      KilnCMS.StubBillingProvider.put(
        :checkout_session_retrieve,
        {:error, :should_not_be_called}
      )

      conn = log_in(conn, user)

      assert {:ok, _view, html} =
               live(conn, ~p"/account?checkout=success&session_id=cs_whatever")

      assert html =~ "Active"
    end
  end

  describe "newsletter card (#586)" do
    defp link_subscriber(user) do
      Newsletter.link_member_subscriber!(
        user.id,
        %{email: to_string(user.email)},
        authorize?: false,
        tenant: default_org_id()
      )
    end

    defp reload(subscriber),
      do:
        Newsletter.get_subscriber!(subscriber.id,
          authorize?: false,
          tenant: subscriber.org_id
        )

    test "no card at all for a member with no subscriber row", %{conn: conn} do
      conn = log_in(conn, authed_user())

      {:ok, _view, html} = live(conn, ~p"/account")

      refute html =~ "Newsletter"
    end

    test "a PENDING member is told nothing is being sent, and can fix it", %{conn: conn} do
      # The whole point of #586: `TierSync` links a paying member as `:pending`,
      # and before this there was no path in the shipped app to `:confirmed` —
      # so they sat in their tier's segment receiving nothing, permanently.
      user = authed_user()
      subscriber = link_subscriber(user)
      assert subscriber.status == :pending

      conn = log_in(conn, user)
      {:ok, view, html} = live(conn, ~p"/account")

      assert html =~ "Newsletter"
      assert html =~ "haven&#39;t confirmed yet"

      html = view |> element("button[phx-click=newsletter_subscribe]") |> render_click()

      assert html =~ "You&#39;re receiving the newsletter"
      assert reload(subscriber).status == :confirmed
    end

    test "a confirmed member can unsubscribe without touching their membership",
         %{conn: conn} do
      # Consent and entitlement are separate bits — opting out of email must
      # leave paid content access alone.
      user = authed_user()
      m = membership(user, tier(), %{})
      subscriber = link_subscriber(user)

      {:ok, _} =
        Newsletter.resubscribe_subscriber(subscriber, authorize?: false, tenant: m.org_id)

      conn = log_in(conn, user)
      {:ok, view, html} = live(conn, ~p"/account")
      assert html =~ "You&#39;re receiving the newsletter"

      html = view |> element("button[phx-click=newsletter_unsubscribe]") |> render_click()

      assert html =~ "not receiving the newsletter"
      assert reload(subscriber).status == :unsubscribed

      {:ok, reloaded} = Billing.get_membership(m.id, authorize?: false, tenant: m.org_id)
      assert reloaded.status == :active
    end

    test "the card shows only THIS member's row, never another account's", %{conn: conn} do
      # `:for_user` bypasses multitenancy and is policy-scoped rather than
      # tenant-scoped, so the self-only filter is the whole boundary.
      stranger = authed_user()
      stranger_subscriber = link_subscriber(stranger)

      user = authed_user()
      conn = log_in(conn, user)

      {:ok, _view, html} = live(conn, ~p"/account")

      refute html =~ "Newsletter"
      assert reload(stranger_subscriber).status == :pending
    end
  end
end
