defmodule KilnCMSWeb.BillingLive do
  @moduledoc """
  Billing settings (`/editor/billing`, admin-only) — the operator console for paid
  memberships (`docs/memberships.md`): payment-provider credentials through the
  key providers (`KilnCMS.Keys`) with a live connection check, and CRUD for the
  membership tiers on sale.

  ## Why this page gates on `platform_admin?`

  It hosts two differently-scoped resources. `KilnCMS.Billing.Settings` is an
  instance-wide singleton (one provider account per instance) whose policy is the
  global `User.role`; `KilnCMS.Billing.MembershipTier` is per-site and gates on
  `KilnCMS.CMS.Checks.OrgAdmin`. Gating the *page* on `platform_admin?/1` follows
  the rule in `KilnCMSWeb.LiveUserAuth.platform_admin?/1` — consoles backed by
  instance-wide resources must not be reachable by a per-org admin — and avoids a
  page where half the controls would always be forbidden. A platform admin is
  resolved as `:admin` on every org by `KilnCMS.Accounts.Scoping.effective_tier/2`,
  so the tier actions authorize fine. If per-org admins ever need tier-only
  access, that is a separate `OrgAdmin`-gated page, not a loosened gate here.

  Slow work (the provider round-trip) runs via `start_async` so the page stays
  responsive.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Billing
  alias KilnCMS.Billing.MembershipTier
  alias KilnCMS.Billing.Settings
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.Keys

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:actor, socket.assigns.current_user)
       |> assign(:page_title, gettext("Billing"))
       |> assign(:verifying?, false)
       |> assign(:selected, %{secret_key: nil, webhook_secret: nil})
       |> assign(:editing_tier, nil)
       |> load_settings(Billing.ensure_settings!())
       |> load_tiers()
       |> assign_tier_form()}
    else
      # Defense-in-depth: the `:live_admin_required` on_mount guard already
      # redirects non-admins before mount runs; mirror it for consistency.
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  # --- credentials ------------------------------------------------------------

  @impl true
  def handle_event("select_provider", %{"key" => key, "provider" => provider}, socket)
      when key in ~w(secret_key webhook_secret) and provider in ~w(database env file) do
    key = String.to_existing_atom(key)
    selected = Map.put(socket.assigns.selected, key, String.to_existing_atom(provider))

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("store_secret", %{"secret" => %{"key" => key, "value" => value}}, socket)
      when key in ~w(secret_key webhook_secret) and is_binary(value) do
    key = String.to_existing_atom(key)

    case Billing.store_billing_secret(socket.assigns.settings, key, value,
           actor: socket.assigns.actor
         ) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> load_settings(settings)
         |> put_flash(:info, gettext("Secret saved."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event(
        "save_key_source",
        %{"source" => %{"key" => key, "provider" => provider} = params},
        socket
      )
      when key in ~w(secret_key webhook_secret) and provider in ~w(env file) do
    key = String.to_existing_atom(key)
    provider = String.to_existing_atom(provider)
    pointer = String.trim(params["pointer"] || "")

    config =
      case provider do
        :env -> %{"var" => pointer}
        :file -> %{"path" => pointer}
      end

    case Billing.configure_billing_key_source(socket.assigns.settings, key, provider, config,
           actor: socket.assigns.actor
         ) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> load_settings(settings)
         |> put_flash(:info, gettext("Key source saved and checked."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("verify", _params, socket) do
    # Ignore a re-click while a run is already in flight: the disabled button
    # attribute is client-side only, so a fast double-click (or a replayed
    # event) would otherwise start a second concurrent provider call.
    if socket.assigns.verifying? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:verifying?, true)
       |> start_async(:verify, fn -> Billing.verify_credentials() end)}
    end
  end

  def handle_event("clear_credentials", _params, socket) do
    case Billing.clear_billing_credentials(socket.assigns.settings, actor: socket.assigns.actor) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> load_settings(settings)
         |> put_flash(:info, gettext("Credentials cleared. No payment surface is offered now."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  # --- tiers ------------------------------------------------------------------

  def handle_event("validate_tier", %{"tier" => params}, socket) when is_map(params) do
    {:noreply,
     assign(socket, :tier_form, AshPhoenix.Form.validate(socket.assigns.tier_form, params))}
  end

  def handle_event("save_tier", %{"tier" => params}, socket) when is_map(params) do
    case AshPhoenix.Form.submit(socket.assigns.tier_form, params: params) do
      {:ok, _tier} ->
        {:noreply,
         socket
         |> load_tiers()
         |> assign(:editing_tier, nil)
         |> assign_tier_form()
         |> put_flash(:info, gettext("Tier saved."))}

      {:error, form} ->
        {:noreply, assign(socket, :tier_form, form)}
    end
  end

  def handle_event("edit_tier", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.tiers, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That tier no longer exists."))}

      tier ->
        {:noreply, socket |> assign(:editing_tier, tier) |> assign_tier_form(tier)}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_tier, nil) |> assign_tier_form()}
  end

  def handle_event("delete_tier", %{"id" => id}, socket) when is_binary(id) do
    socket =
      case Enum.find(socket.assigns.tiers, &(&1.id == id)) do
        nil ->
          put_flash(socket, :error, gettext("That tier no longer exists."))

        tier ->
          case Billing.destroy_tier(tier, actor: socket.assigns.actor, tenant: org_id(socket)) do
            :ok ->
              socket |> load_tiers() |> put_flash(:info, gettext("Tier deleted."))

            {:ok, _tier} ->
              socket |> load_tiers() |> put_flash(:info, gettext("Tier deleted."))

            {:error, error} ->
              put_flash(socket, :error, error_message(error))
          end
      end

    {:noreply, socket}
  end

  # --- async ------------------------------------------------------------------

  @impl true
  def handle_async(:verify, {:ok, {:ok, settings}}, socket) do
    {:noreply,
     socket
     |> assign(:verifying?, false)
     |> load_settings(settings)
     |> put_flash(:info, gettext("Connected to the payment provider."))}
  end

  def handle_async(:verify, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:verifying?, false)
     |> load_settings(Billing.ensure_settings!())
     |> put_flash(:error, Billing.describe_error(reason))}
  end

  def handle_async(:verify, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:verifying?, false)
     |> put_flash(:error, gettext("The connection check crashed. Check the server logs."))}
  end

  # --- helpers ----------------------------------------------------------------

  defp org_id(socket), do: socket.assigns.current_org.id

  defp load_settings(socket, settings) do
    selected =
      Map.new(Settings.secrets(), fn key ->
        {provider_field, _config, _encrypted} = Settings.fields(key)
        {key, socket.assigns.selected[key] || Map.fetch!(settings, provider_field)}
      end)

    socket
    |> assign(:settings, settings)
    |> assign(:selected, selected)
    |> assign(:configured?, Billing.configured?())
    |> assign(:secret_states, Map.new(Settings.secrets(), &{&1, secret_state(&1)}))
  end

  # Whether each secret currently resolves, so the console reports the truth
  # rather than "a provider is selected".
  defp secret_state(key) do
    case Keys.fetch(registry_name(key)) do
      {:ok, _secret} -> :ok
      {:error, reason} -> {:error, Keys.describe_error(reason)}
    end
  end

  defp registry_name(:secret_key), do: :billing_secret_key
  defp registry_name(:webhook_secret), do: :billing_webhook_secret

  defp load_tiers(socket) do
    assign(
      socket,
      :tiers,
      Billing.list_tiers!(
        actor: socket.assigns.actor,
        tenant: org_id(socket),
        query: [sort: [position: :asc, name: :asc]]
      )
    )
  end

  defp assign_tier_form(socket, tier \\ nil) do
    form =
      if tier do
        AshPhoenix.Form.for_update(tier, :update,
          actor: socket.assigns.actor,
          tenant: org_id(socket),
          as: "tier"
        )
      else
        AshPhoenix.Form.for_create(MembershipTier, :create,
          actor: socket.assigns.actor,
          tenant: org_id(socket),
          as: "tier"
        )
      end

    assign(socket, :tier_form, to_form(form))
  end

  defp error_message(%{errors: [%{message: message} | _rest]}) when is_binary(message),
    do: message

  defp error_message(_error), do: gettext("Something went wrong.")

  defp secret_label(:secret_key), do: gettext("API secret key")
  defp secret_label(:webhook_secret), do: gettext("Webhook signing secret")

  defp secret_hint(:secret_key),
    do: gettext("Used to open checkout and billing-portal sessions. Starts with sk_ or rk_.")

  defp secret_hint(:webhook_secret),
    do:
      gettext(
        "Verifies inbound webhooks. Copy it from the webhook endpoint you created in the provider's dashboard; it starts with whsec_."
      )

  defp provider_label(:env), do: gettext("Environment variable")
  defp provider_label(:file), do: gettext("File")
  defp provider_label(:database), do: gettext("Database (encrypted)")

  defp provider_hint(:env),
    do: gettext("Recommended for production. Reads the secret from an environment variable.")

  defp provider_hint(:file),
    do:
      gettext(
        "Recommended for production. Reads a file — the natural fit for Docker/Kubernetes mounted secrets."
      )

  defp provider_hint(:database),
    do:
      gettext(
        "Zero-ops default: paste the secret here. Encrypted with a key derived from SECRET_KEY_BASE — rotating that secret orphans it."
      )

  defp pointer_value(settings, key, provider) do
    {provider_field, config_field, _encrypted} = Settings.fields(key)
    config = Map.get(settings, config_field) || %{}

    if Map.fetch!(settings, provider_field) == provider do
      config["var"] || config["path"]
    end
  end

  defp audience_options, do: Enum.map(Audiences.gated(), &{Phoenix.Naming.humanize(&1), &1})

  # A tier whose audience is no longer in `config :kiln_cms, :audiences` cannot be
  # rendered as a valid option — surface it rather than crashing the page.
  defp orphaned_tiers(tiers), do: Enum.reject(tiers, &Audiences.valid?(&1.audience))

  # --- render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:billing}
    >
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Billing")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Paid memberships: connect a payment provider, then sell tiers that grant readers access to gated content."
            )}
          </p>
        </div>

        <section class="card card-pad">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 class="text-lg font-medium">{gettext("Status")}</h2>
              <p class="mt-1 text-sm text-base-content/70">
                <%= if @configured? do %>
                  {gettext("Billing is configured. Tiers can be sold.")}
                <% else %>
                  {gettext(
                    "Billing is not configured yet. Until both secrets resolve, no tier is offered and no payment page is reachable."
                  )}
                <% end %>
              </p>
            </div>
            <div class="flex items-center gap-2">
              <.badge variant={if @configured?, do: "success", else: "neutral"}>
                {if @configured?, do: gettext("Configured"), else: gettext("Not configured")}
              </.badge>
              <%= if @settings.livemode do %>
                <.badge variant="warning">{gettext("Live mode")}</.badge>
              <% end %>
            </div>
          </div>

          <dl class="mt-4 grid gap-x-8 gap-y-2 text-sm sm:grid-cols-2">
            <div class="flex justify-between gap-4 sm:block">
              <dt class="text-base-content/60">{gettext("Provider")}</dt>
              <dd class="font-medium">{Phoenix.Naming.humanize(@settings.provider)}</dd>
            </div>
            <div class="flex justify-between gap-4 sm:block">
              <dt class="text-base-content/60">{gettext("Account")}</dt>
              <dd class="font-medium">{@settings.provider_account_id || gettext("unknown")}</dd>
            </div>
            <div class="flex justify-between gap-4 sm:block">
              <dt class="text-base-content/60">{gettext("Last checked")}</dt>
              <dd class="font-medium">
                {(@settings.last_verified_at &&
                    Calendar.strftime(@settings.last_verified_at, "%Y-%m-%d %H:%M UTC")) ||
                  gettext("never")}
              </dd>
            </div>
            <%= if @settings.verification_error do %>
              <div class="flex justify-between gap-4 sm:block">
                <dt class="text-base-content/60">{gettext("Last error")}</dt>
                <dd class="font-medium text-error">{@settings.verification_error}</dd>
              </div>
            <% end %>
          </dl>

          <div class="mt-4 flex flex-wrap gap-2">
            <button
              type="button"
              phx-click="verify"
              class="btn btn-default btn-sm"
              disabled={@verifying? or not @configured?}
            >
              {if @verifying?, do: gettext("Checking…"), else: gettext("Test connection")}
            </button>
            <%= if @configured? do %>
              <button
                type="button"
                phx-click="clear_credentials"
                class="btn btn-danger btn-sm"
                data-confirm={
                  gettext(
                    "Disconnect the payment provider? No new memberships can be sold until you reconnect."
                  )
                }
              >
                {gettext("Disconnect")}
              </button>
            <% end %>
          </div>
        </section>

        <section :for={key <- Settings.secrets()} class="card card-pad">
          <h2 class="text-lg font-medium">{secret_label(key)}</h2>
          <p class="mt-1 text-sm text-base-content/70">{secret_hint(key)}</p>

          <p class="mt-2 text-sm">
            <%= case @secret_states[key] do %>
              <% :ok -> %>
                <span class="text-success">{gettext("Resolves correctly.")}</span>
              <% {:error, reason} -> %>
                <span class="text-error">{gettext("Not available")}: {reason}</span>
            <% end %>
          </p>

          <div class="mt-4 flex flex-wrap gap-2">
            <button
              :for={provider <- Keys.provider_names()}
              type="button"
              phx-click="select_provider"
              phx-value-key={key}
              phx-value-provider={provider}
              class={[
                "btn btn-sm",
                if(@selected[key] == provider, do: "btn-primary", else: "btn-default")
              ]}
            >
              {provider_label(provider)}
            </button>
          </div>

          <p class="mt-2 text-xs text-base-content/60">{provider_hint(@selected[key])}</p>

          <%= if Keys.writable?(@selected[key]) do %>
            <form id={"secret-#{key}"} phx-submit="store_secret" class="mt-4 space-y-3">
              <input type="hidden" name="secret[key]" value={key} />
              <.input
                type="password"
                name="secret[value]"
                value=""
                label={gettext("Paste the secret")}
                autocomplete="off"
              />
              <button type="submit" class="btn btn-primary btn-sm">{gettext("Save secret")}</button>
            </form>
          <% else %>
            <form id={"key-source-#{key}"} phx-submit="save_key_source" class="mt-4 space-y-3">
              <input type="hidden" name="source[key]" value={key} />
              <input type="hidden" name="source[provider]" value={@selected[key]} />
              <.input
                type="text"
                name="source[pointer]"
                value={pointer_value(@settings, key, @selected[key])}
                label={
                  if @selected[key] == :env,
                    do: gettext("Environment variable name"),
                    else: gettext("File path")
                }
              />
              <button type="submit" class="btn btn-primary btn-sm">
                {gettext("Save key source")}
              </button>
            </form>
          <% end %>
        </section>

        <section class="card card-pad">
          <h2 class="text-lg font-medium">{gettext("Membership tiers")}</h2>
          <p class="mt-1 text-sm text-base-content/70">
            {gettext(
              "Each tier grants one audience. Configure the price in your provider's dashboard and paste its price ID here, so there is one source of truth for money."
            )}
          </p>

          <%= if orphaned_tiers(@tiers) != [] do %>
            <p class="mt-3 text-sm text-error">
              {gettext(
                "Some tiers grant an audience that is no longer configured. Restore it in config :kiln_cms, :audiences, or retire those tiers."
              )}
            </p>
          <% end %>

          <%= if @tiers == [] do %>
            <.empty_state icon="hero-credit-card" title={gettext("No tiers yet")}>
              {gettext("Create one below to start selling memberships.")}
            </.empty_state>
          <% else %>
            <table class="table table-zebra mt-4">
              <thead>
                <tr>
                  <th>{gettext("Name")}</th>
                  <th>{gettext("Audience")}</th>
                  <th>{gettext("Price ID")}</th>
                  <th>{gettext("Status")}</th>
                  <th class="text-right">{gettext("Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={tier <- @tiers}>
                  <td class="font-medium">{tier.name}</td>
                  <td>{tier.audience}</td>
                  <td class="font-mono text-xs">{tier.provider_price_id}</td>
                  <td>
                    <.badge variant={if tier.active, do: "success", else: "neutral"}>
                      {if tier.active, do: gettext("Active"), else: gettext("Retired")}
                    </.badge>
                  </td>
                  <td class="text-right">
                    <button
                      type="button"
                      phx-click="edit_tier"
                      phx-value-id={tier.id}
                      class="btn btn-ghost btn-sm"
                    >
                      {gettext("Edit")}
                    </button>
                    <button
                      type="button"
                      phx-click="delete_tier"
                      phx-value-id={tier.id}
                      class="btn btn-ghost btn-sm text-error"
                      data-confirm={
                        gettext("Delete this tier? Retiring it is usually safer than deleting.")
                      }
                    >
                      {gettext("Delete")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          <% end %>

          <.form
            for={@tier_form}
            id="tier-form"
            phx-change="validate_tier"
            phx-submit="save_tier"
            class="mt-6 space-y-3 border-t border-base-300 pt-6"
          >
            <h3 class="font-medium">
              {if @editing_tier, do: gettext("Edit tier"), else: gettext("New tier")}
            </h3>

            <.input field={@tier_form[:name]} type="text" label={gettext("Name")} />
            <.input field={@tier_form[:slug]} type="text" label={gettext("Slug")} />
            <.input field={@tier_form[:description]} type="textarea" label={gettext("Description")} />

            <%= if @editing_tier do %>
              <p class="text-sm text-base-content/70">
                {gettext("Audience")}: <span class="font-medium">{@editing_tier.audience}</span>
                <span class="block text-xs text-base-content/60">
                  {gettext(
                    "A tier's audience can't change — existing members would keep an entitlement nothing would revoke. Retire this tier and create a new one instead."
                  )}
                </span>
              </p>
            <% else %>
              <.input
                field={@tier_form[:audience]}
                type="select"
                label={gettext("Audience granted")}
                options={audience_options()}
              />
            <% end %>

            <.input
              field={@tier_form[:provider_price_id]}
              type="text"
              label={gettext("Provider price ID")}
            />
            <.input field={@tier_form[:position]} type="number" label={gettext("Position")} />
            <.input field={@tier_form[:active]} type="checkbox" label={gettext("Active")} />

            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">{gettext("Save tier")}</button>
              <%= if @editing_tier do %>
                <button type="button" phx-click="cancel_edit" class="btn btn-default btn-sm">
                  {gettext("Cancel")}
                </button>
              <% end %>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
