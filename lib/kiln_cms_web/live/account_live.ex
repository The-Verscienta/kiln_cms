defmodule KilnCMSWeb.AccountLive do
  @moduledoc """
  The member's own page (`/account`).

  **The first signed-in-but-not-editor LiveView in the codebase.** Every
  `/editor/*` screen gates on an editorial tier, so before this a `:viewer` — the
  role every self-registered reader lands on — could reach nothing at all.

  It introduces no new authorization surface: `update_profile` and
  `change_password` are already self-scoped by policy on
  `KilnCMS.Accounts.User`, so this is a member-appropriate front end for actions a
  viewer may already run. `/editor/settings` stays editor-gated; opening it would
  mean auditing its 2FA, recovery-code and passkey cards for a reader account,
  which is a separate decision.

  ## Closing the return-from-checkout race

  A member landing back here may arrive before the provider's webhook does. When
  the membership is still `:incomplete`, the checkout session is retrieved
  **server-side** and applied through the same path the webhook uses — but only
  after verifying the session's metadata names *this* user. `session_id` comes
  from the query string and is therefore attacker-suppliable; the ownership check
  is what makes acting on it safe. Nothing is ever granted from the query
  parameters themselves.

  ## The newsletter card (issue #586)

  `KilnCMS.Newsletter.TierSync` links an activating member's subscriber row as
  **`:pending`** — a purchase is not consent to marketing email. Nothing in the
  shipped app then moved that row to `:confirmed`, so a paying member sat in
  their tier's segment receiving nothing, permanently. This card is the missing
  control.

  Wiring it up needed a policy fix, not just markup. `:resubscribe`,
  `:unsubscribe` and `:for_user` were already scoped to `user_id ==
  ^actor(:id)`, but as ordinary policies those self-grants were AND-narrowed to
  nothing by the resource's blanket admin policy — a member is not an admin — so
  the reads filtered to `[]` and the writes came back forbidden. They are a
  `bypass` on `KilnCMS.Newsletter.Subscriber` now. The grant itself is unchanged
  and still self-only; every call here passes the member as actor rather than
  `authorize?: false`, so the policy — not this module — is what confines them
  to their own row.

  The card appears only when a subscriber row already exists for this site.
  Opt-in from scratch is the public `POST /newsletter/subscribe` endpoint's job;
  offering it here would mean granting a non-admin the `:subscribe` action,
  which is a separate decision.
  """
  use KilnCMSWeb, :live_view

  require Logger

  alias KilnCMS.Billing
  alias KilnCMS.Newsletter

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Your account"))
     |> assign(:reconciling?, false)
     |> load_memberships()
     |> load_subscriber()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, maybe_reconcile(socket, params)}
  end

  # Only worth a provider round trip when we're actually waiting on the webhook.
  defp maybe_reconcile(socket, %{"checkout" => "success", "session_id" => session_id})
       when is_binary(session_id) do
    if socket.assigns.reconciling? or not pending?(socket) do
      socket
    else
      socket
      |> assign(:reconciling?, true)
      |> start_async(:reconcile, fn -> retrieve_session(session_id) end)
    end
  end

  defp maybe_reconcile(socket, %{"checkout" => "success"}) do
    put_flash(socket, :info, gettext("Thanks for joining!"))
  end

  defp maybe_reconcile(socket, _params), do: socket

  # Checked against the FULL set, not the displayed one: `:incomplete` rows are
  # hidden from the list (an abandoned checkout isn't a membership), so asking
  # the display list whether anything is pending would always answer "no" and the
  # reconcile would never fire.
  defp pending?(socket),
    do: Enum.any?(socket.assigns.all_memberships, &(&1.status == :incomplete))

  defp retrieve_session(session_id) do
    with {:ok, config} <- Billing.credentials() do
      Billing.provider().retrieve_checkout_session(session_id, config)
    end
  end

  @impl true
  def handle_async(:reconcile, {:ok, {:ok, session}}, socket) do
    {:noreply,
     socket
     |> assign(:reconciling?, false)
     |> apply_session(session)
     |> load_memberships()}
  end

  def handle_async(:reconcile, {:ok, {:error, reason}}, socket) do
    # The webhook is the durable path; a failed reconcile just means the page
    # shows "activating" a moment longer.
    Logger.warning("account: checkout reconcile failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:reconciling?, false)
     |> put_flash(:info, gettext("Thanks for joining! Your membership is being activated."))}
  end

  def handle_async(:reconcile, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :reconciling?, false)}
  end

  # The ownership gate: act on the session only if its metadata names this user.
  defp apply_session(socket, session) do
    user = socket.assigns.current_user
    metadata = session["metadata"] || %{}

    if metadata["user_id"] == user.id do
      # Wrapped in an event envelope so it travels the SAME path a webhook
      # would, rather than a second, divergent activation route.
      KilnCMS.Billing.Subscriptions.apply(%{
        "id" => "checkout_return:" <> to_string(session["id"]),
        "type" => "checkout.session.completed",
        "data" => %{"object" => session}
      })

      put_flash(socket, :info, gettext("Thanks for joining!"))
    else
      Logger.warning("account: checkout session metadata does not name the signed-in user")
      socket
    end
  end

  defp load_memberships(socket) do
    user = socket.assigns.current_user
    all = Billing.memberships_for_user!(user.id, actor: user, tenant: org_id(socket))

    socket
    |> assign(:all_memberships, all)
    # An abandoned checkout leaves an `:incomplete` row; it is not a membership
    # and must not be displayed as one.
    |> assign(:memberships, Enum.reject(all, &(&1.status == :incomplete)))
  end

  # --- newsletter (issue #586) -----------------------------------------------

  @impl true
  def handle_event("newsletter_subscribe", _params, socket) do
    {:noreply,
     set_consent(
       socket,
       &Newsletter.resubscribe_subscriber/2,
       gettext("You're subscribed to the newsletter.")
     )}
  end

  def handle_event("newsletter_unsubscribe", _params, socket) do
    {:noreply,
     set_consent(
       socket,
       &Newsletter.unsubscribe_subscriber/2,
       gettext("You've been unsubscribed.")
     )}
  end

  # Guards the events against a client that fires them with no row loaded; the
  # buttons only render when there is one.
  defp set_consent(%{assigns: %{subscriber: nil}} = socket, _action, _flash), do: socket

  defp set_consent(socket, action, flash) do
    subscriber = socket.assigns.subscriber

    # The row's OWN org, not the socket's: `:for_user` reads across sites
    # (`multitenancy :bypass`), so re-scoping the write to the request's tenant
    # would be a guess. Actor, not `authorize?: false` — the self-scoping policy
    # is the check.
    case action.(subscriber, actor: socket.assigns.current_user, tenant: subscriber.org_id) do
      {:ok, _updated} ->
        socket |> load_subscriber() |> put_flash(:info, flash)

      {:error, reason} ->
        Logger.warning("account: newsletter consent update failed: #{inspect(reason)}")
        put_flash(socket, :error, gettext("Couldn't update your newsletter preference."))
    end
  end

  # The member's subscriber row for THIS site, if they have one. `:for_user`
  # spans organizations by design (one account, one row per site it belongs to),
  # so the current org is filtered for here rather than passed as a tenant.
  defp load_subscriber(socket) do
    user = socket.assigns.current_user
    org_id = org_id(socket) || KilnCMS.Accounts.default_org_id()

    subscriber =
      user.id
      |> Newsletter.subscribers_for_user!(actor: user)
      |> Enum.find(&(&1.org_id == org_id))

    assign(socket, :subscriber, subscriber)
  end

  defp newsletter_line(%{status: :confirmed}),
    do: gettext("You're receiving the newsletter at this address.")

  defp newsletter_line(%{status: :pending}),
    do:
      gettext(
        "You're on the list but haven't confirmed yet, so nothing is being sent. Subscribe to start receiving it."
      )

  defp newsletter_line(_subscriber),
    do: gettext("You're not receiving the newsletter.")

  defp org_id(socket), do: socket.assigns.current_org && socket.assigns.current_org.id

  defp status_variant(:active), do: "success"
  defp status_variant(:comped), do: "info"
  defp status_variant(:past_due), do: "warning"
  defp status_variant(_status), do: "neutral"

  defp status_label(:active), do: gettext("Active")
  defp status_label(:comped), do: gettext("Complimentary")
  defp status_label(:past_due), do: gettext("Payment overdue")
  defp status_label(:canceled), do: gettext("Cancelled")
  defp status_label(_status), do: gettext("Pending")

  defp period_line(%{status: :canceled}), do: nil

  defp period_line(%{cancel_at_period_end: true, current_period_end: at}) when not is_nil(at),
    do: gettext("Access ends on %{date}", date: on_date(at))

  defp period_line(%{current_period_end: at}) when not is_nil(at),
    do: gettext("Renews on %{date}", date: on_date(at))

  defp period_line(_membership), do: nil

  defp on_date(at), do: Calendar.strftime(at, "%-d %B %Y")

  defp manageable?(memberships),
    do: Enum.any?(memberships, &(&1.provider_customer_id not in [nil, ""]))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public current_org={@current_org} locale={@locale}>
      <Layouts.flash_group flash={@flash} />

      <div class="space-y-8">
        <header class="space-y-1">
          <h1 class="text-3xl font-semibold">{gettext("Your account")}</h1>
          <p class="text-base-content/70">{@current_user.email}</p>
        </header>

        <section class="card card-pad space-y-4">
          <h2 class="text-lg font-medium">{gettext("Membership")}</h2>

          <%= cond do %>
            <% @reconciling? -> %>
              <p class="text-sm text-base-content/70">{gettext("Activating your membership…")}</p>
            <% @memberships == [] -> %>
              <.empty_state icon="hero-credit-card" title={gettext("No membership yet")}>
                {gettext("Join to read members-only writing.")}
              </.empty_state>
              <.link navigate={~p"/membership"} class="btn btn-primary">
                {gettext("See plans")}
              </.link>
            <% true -> %>
              <ul class="divide-y divide-base-300">
                <li
                  :for={membership <- @memberships}
                  class="flex flex-wrap items-center justify-between gap-3 py-3"
                >
                  <div>
                    <p class="font-medium">
                      {(membership.tier && membership.tier.name) || gettext("Membership")}
                    </p>
                    <p :if={period_line(membership)} class="text-sm text-base-content/60">
                      {period_line(membership)}
                    </p>
                  </div>
                  <.badge variant={status_variant(membership.status)}>
                    {status_label(membership.status)}
                  </.badge>
                </li>
              </ul>

              <div class="flex flex-wrap gap-2">
                <form :if={manageable?(@memberships)} method="post" action={~p"/billing/portal"}>
                  <input
                    type="hidden"
                    name="_csrf_token"
                    value={Phoenix.Controller.get_csrf_token()}
                  />
                  <button type="submit" class="btn btn-default">
                    {gettext("Manage billing")}
                  </button>
                </form>
                <.link navigate={~p"/membership"} class="btn btn-ghost">
                  {gettext("See all plans")}
                </.link>
              </div>
          <% end %>
        </section>

        <section :if={@subscriber} class="card card-pad space-y-3">
          <h2 class="text-lg font-medium">{gettext("Newsletter")}</h2>
          <p class="text-sm text-base-content/70">{newsletter_line(@subscriber)}</p>

          <div>
            <button
              :if={@subscriber.status != :confirmed}
              type="button"
              phx-click="newsletter_subscribe"
              class="btn btn-primary btn-sm"
            >
              {gettext("Subscribe")}
            </button>
            <button
              :if={@subscriber.status == :confirmed}
              type="button"
              phx-click="newsletter_unsubscribe"
              class="btn btn-default btn-sm"
            >
              {gettext("Unsubscribe")}
            </button>
          </div>
        </section>

        <section class="card card-pad space-y-2">
          <h2 class="text-lg font-medium">{gettext("Your data")}</h2>
          <p class="text-sm text-base-content/70">
            {gettext("Download everything this site stores about your account.")}
          </p>
          <div>
            <.link href={~p"/editor/account/export.json"} class="btn btn-default btn-sm">
              {gettext("Export my data")}
            </.link>
          </div>
        </section>
      </div>
    </Layouts.public>
    """
  end
end
