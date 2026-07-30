defmodule KilnCMSWeb.BillingController do
  @moduledoc """
  Member-facing payment handoffs: start a checkout, or open the billing portal.

  ## Why a controller and not LiveView events

  Both actions end in a redirect to a **provider-hosted page on another origin**.
  A LiveView cannot `push_navigate` cross-origin, and routing the round trip
  through the socket would make it depend on a live connection. A plain
  CSRF-protected form post works with JavaScript disabled, survives a dropped
  socket, and is trivially testable — the right posture for the page that takes
  money.

  Card details never reach Kiln: every response here is a redirect to a URL the
  provider minted.

  ## Both metadata maps, always

  Checkout-session metadata does **not** propagate to the subscription the
  provider creates, and the subscription is what carries every later event —
  including the cancellation that drives revocation. So `checkout/2` stamps the
  organization, user, tier and membership onto the session **and** onto
  `subscription_data`. `KilnCMS.Billing.Webhooks` relies on that to resolve the
  owning organization from the event rather than from the request host.
  """
  use KilnCMSWeb, :controller

  require Logger

  alias KilnCMS.Billing

  # Start a subscription checkout for the signed-in member.
  def checkout(conn, %{"tier" => slug}) do
    with :ok <- ensure_configured(conn),
         {:ok, user} <- ensure_signed_in(conn, slug),
         {:ok, tier} <- fetch_tier(conn, slug),
         {:ok, membership} <- start_membership(user, tier, conn),
         {:ok, session} <- create_session(user, tier, membership, conn) do
      redirect(conn, external: session.url)
    else
      {:halted, conn} -> conn
    end
  end

  def checkout(conn, _params), do: redirect(conn, to: ~p"/membership")

  # Hand the member to the provider's hosted billing portal, which owns
  # cancellation, card updates, invoices and dunning (all explicit non-goals here).
  def portal(conn, _params) do
    with :ok <- ensure_configured(conn),
         {:ok, user} <- ensure_signed_in(conn, nil),
         {:ok, customer_id} <- fetch_customer(conn, user),
         {:ok, config} <- credentials(conn),
         {:ok, session} <-
           call_provider(
             conn,
             fn ->
               Billing.provider().create_portal_session(
                 %{customer: customer_id, return_url: absolute_url(conn, ~p"/account")},
                 config
               )
             end
           ) do
      redirect(conn, external: session.url)
    else
      {:halted, conn} -> conn
    end
  end

  ## steps

  # An unconfigured instance shouldn't confirm that a payment route exists —
  # the same posture as the webhook receiver.
  defp ensure_configured(conn) do
    if Billing.configured?() do
      :ok
    else
      {:halted, conn |> put_status(:not_found) |> text("")}
    end
  end

  # Registration is the identity step and must not be entangled with payment, so
  # the intent is stashed and replayed after the account exists.
  defp ensure_signed_in(conn, slug) do
    case conn.assigns[:current_user] do
      nil ->
        {:halted,
         conn
         |> put_session(:join_tier, slug)
         |> put_flash(:info, gettext("Create an account to continue."))
         |> redirect(to: ~p"/register")}

      user ->
        {:ok, user}
    end
  end

  defp fetch_tier(conn, slug) do
    case Billing.get_tier_by_slug(slug,
           actor: conn.assigns[:current_user],
           tenant: org_id(conn),
           not_found_error?: false
         ) do
      {:ok, %{active: true} = tier} ->
        {:ok, tier}

      _other ->
        {:halted,
         conn
         |> put_flash(:error, gettext("That plan isn't available."))
         |> redirect(to: ~p"/membership")}
    end
  end

  # Created BEFORE the redirect for three reasons: the session metadata needs a
  # stable membership id, an abandoned checkout becomes visible to an operator,
  # and the webhook has a resolution target even if metadata is somehow lost.
  # The action upserts, so re-clicking "join" reuses the row.
  defp start_membership(user, tier, conn) do
    case Billing.start_membership(%{user_id: user.id, tier_id: tier.id},
           actor: user,
           tenant: org_id(conn)
         ) do
      {:ok, membership} ->
        {:ok, membership}

      {:error, reason} ->
        Logger.error("billing checkout: could not start membership: #{inspect(reason)}")
        {:halted, fail(conn)}
    end
  end

  defp create_session(user, tier, membership, conn) do
    with {:ok, config} <- credentials(conn) do
      params = checkout_params(user, tier, membership, conn)

      call_provider(conn, fn -> Billing.provider().create_checkout_session(params, config) end)
    end
  end

  defp checkout_params(user, tier, membership, conn) do
    metadata = %{
      org_id: membership.org_id,
      user_id: user.id,
      tier_id: tier.id,
      membership_id: membership.id
    }

    %{
      mode: "subscription",
      line_items: [%{price: tier.provider_price_id, quantity: 1}],
      # Reuse the provider customer we already hold, so a returning member isn't
      # duplicated on the provider's side.
      customer: membership.provider_customer_id,
      customer_email: is_nil(membership.provider_customer_id) && to_string(user.email),
      client_reference_id: membership.id,
      metadata: metadata,
      # Session metadata does NOT reach the subscription — stamp both.
      subscription_data: %{metadata: metadata},
      success_url: success_url(conn),
      cancel_url: absolute_url(conn, ~p"/membership?checkout=canceled"),
      # A retried create must not mint a second session.
      idempotency_key: "checkout:" <> membership.id
    }
  end

  # `{CHECKOUT_SESSION_ID}` is the provider's own template token and must reach
  # them unencoded, so it is appended rather than interpolated through `~p`.
  defp success_url(conn) do
    absolute_url(conn, ~p"/account?checkout=success") <> "&session_id={CHECKOUT_SESSION_ID}"
  end

  defp fetch_customer(conn, user) do
    memberships =
      Billing.memberships_for_user!(user.id, actor: user, tenant: org_id(conn))

    case Enum.find(memberships, &(&1.provider_customer_id not in [nil, ""])) do
      nil ->
        {:halted,
         conn
         |> put_flash(:info, gettext("You don't have a membership to manage yet."))
         |> redirect(to: ~p"/account")}

      membership ->
        {:ok, membership.provider_customer_id}
    end
  end

  defp credentials(conn) do
    case Billing.credentials() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> {:halted, fail(conn)}
    end
  end

  defp call_provider(conn, fun) do
    case fun.() do
      {:ok, session} ->
        {:ok, session}

      {:error, reason} ->
        # Logged, never rendered: a provider error string can carry account
        # details, and the member can do nothing with it.
        Logger.error("billing: provider call failed: #{inspect(reason)}")
        {:halted, fail(conn)}
    end
  end

  defp fail(conn) do
    conn
    |> put_flash(:error, gettext("Couldn't reach the payment provider. Please try again."))
    |> redirect(to: ~p"/membership")
  end

  # Built from the REQUEST's host, not the configured canonical URL: a member on
  # a custom-domain org must return to that domain, or their session cookie
  # won't be there.
  defp absolute_url(conn, path), do: origin(conn) <> path

  defp origin(conn) do
    scheme = to_string(conn.scheme)

    case {scheme, conn.port} do
      {"https", 443} -> "https://" <> conn.host
      {"http", 80} -> "http://" <> conn.host
      {_scheme, port} -> "#{scheme}://#{conn.host}:#{port}"
    end
  end

  defp org_id(conn), do: KilnCMSWeb.Tenant.current_org_id(conn)
end
