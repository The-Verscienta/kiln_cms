defmodule KilnCMSWeb.MembershipLive do
  @moduledoc """
  The public join page (`/membership`): the tiers a site sells, and the way in.

  Anonymous-tolerant on purpose — it is the destination of the paywall CTA, so a
  reader who has not signed up yet must be able to see what is on offer before
  creating an account.

  Renders inside `Layouts.public` (the delivery chrome), not the authoring
  console. That layout takes no `flash` attr — it is shared by four delivery
  templates and both preview LiveViews, so adding a required one would break them
  all — hence `<Layouts.flash_group>` is rendered here, at this page's own level,
  exactly as `Layouts.app` and `Layouts.console` do.

  The "join" control is a real form post to `KilnCMSWeb.BillingController`, not a
  LiveView event: checkout ends on a provider-hosted page on another origin, which
  a LiveView cannot navigate to.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Billing

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Membership"))
     |> assign(:configured?, Billing.configured?())
     |> load_tiers()
     |> load_memberships()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # The provider bounces a cancelled checkout back here; say so rather than
    # silently re-rendering the same page.
    socket =
      if params["checkout"] == "canceled" do
        put_flash(socket, :info, gettext("Checkout cancelled — you haven't been charged."))
      else
        socket
      end

    {:noreply, socket}
  end

  defp load_tiers(socket) do
    tiers =
      if socket.assigns.configured? do
        Billing.list_active_tiers!(
          actor: socket.assigns[:current_user],
          tenant: org_id(socket)
        )
      else
        []
      end

    assign(socket, :tiers, tiers)
  end

  # Which tiers this reader already holds, so the page can badge their current
  # plan instead of offering to sell it again.
  defp load_memberships(socket) do
    memberships =
      case socket.assigns[:current_user] do
        nil ->
          %{}

        user ->
          user.id
          |> Billing.memberships_for_user!(actor: user, tenant: org_id(socket))
          |> Map.new(&{&1.tier_id, &1.status})
      end

    assign(socket, :memberships, memberships)
  end

  defp org_id(socket), do: socket.assigns.current_org && socket.assigns.current_org.id

  defp entitling?(status), do: status in KilnCMS.Billing.Membership.entitling_statuses()

  defp price_line(%{price_config: config}) when is_map(config) do
    case {config["amount"], config["interval"]} do
      {nil, _interval} -> nil
      {amount, nil} -> to_string(amount)
      {amount, interval} -> "#{amount} / #{interval}"
    end
  end

  defp price_line(_tier), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public current_org={@current_org} locale={@locale}>
      <Layouts.flash_group flash={@flash} />

      <div class="space-y-8">
        <header class="space-y-2">
          <h1 class="text-3xl font-semibold">{gettext("Membership")}</h1>
          <p class="text-base-content/70">
            {gettext("Support this site and unlock members-only writing.")}
          </p>
        </header>

        <%= cond do %>
          <% not @configured? or @tiers == [] -> %>
            <.empty_state icon="hero-credit-card" title={gettext("No plans available yet")}>
              {gettext("Memberships aren't set up on this site. Please check back later.")}
            </.empty_state>
          <% true -> %>
            <div class="grid gap-4 sm:grid-cols-2">
              <section :for={tier <- @tiers} class="card card-pad flex flex-col gap-3">
                <div class="flex items-start justify-between gap-3">
                  <h2 class="text-lg font-medium">{tier.name}</h2>
                  <.badge :if={entitling?(@memberships[tier.id])} variant="success">
                    {gettext("Your plan")}
                  </.badge>
                </div>

                <p :if={price_line(tier)} class="text-2xl font-semibold">{price_line(tier)}</p>
                <p :if={tier.description} class="text-sm text-base-content/70">
                  {tier.description}
                </p>

                <div class="mt-auto pt-2">
                  <%= cond do %>
                    <% entitling?(@memberships[tier.id]) -> %>
                      <.link href={~p"/account"} class="btn btn-default btn-block">
                        {gettext("Manage membership")}
                      </.link>
                    <% is_nil(@current_user) -> %>
                      <.link navigate={~p"/register"} class="btn btn-primary btn-block">
                        {gettext("Create an account to join")}
                      </.link>
                    <% true -> %>
                      <form method="post" action={~p"/billing/checkout"}>
                        <input
                          type="hidden"
                          name="_csrf_token"
                          value={Phoenix.Controller.get_csrf_token()}
                        />
                        <input type="hidden" name="tier" value={tier.slug} />
                        <button type="submit" class="btn btn-primary btn-block">
                          {gettext("Join")}
                        </button>
                      </form>
                  <% end %>
                </div>
              </section>
            </div>
        <% end %>
      </div>
    </Layouts.public>
    """
  end
end
