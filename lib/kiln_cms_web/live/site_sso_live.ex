defmodule KilnCMSWeb.SiteSsoLive do
  @moduledoc """
  A site's own single sign-on (#1561), at `/editor/site-sso`: the OpenID
  Connect provider this site's sign-in page offers, and the email domains that
  provider may vouch for.

  Before this, SSO was `OIDC_*` environment variables — one provider for the
  whole deployment, set by the operator. That provider is untouched and still
  offered everywhere it was; this adds a site's own, beside it.

  Scoped to the request's org. Every write is policy-gated to org admins by
  `KilnCMS.CMS.SiteSsoProvider` / `KilnCMS.CMS.SiteSsoDomain`, and the
  `:admin_routes` live session gates the page on the same tier.

  ## What the page has to say

    * **The callback URL** to register at the provider — derived from the
      site's address, not typed.
    * **Which addresses it covers.** Only those in a domain verified here, and
      never an account with access to another site or to the whole deployment
      (`KilnCMS.Accounts.SiteSso.Admission`). An admin who expects it to sign
      in the operator will otherwise think it is broken.
    * **That the DNS record must stay.** It is re-checked on every sign-in.
    * **When the stored secret can't be read.** After a `SECRET_KEY_BASE`
      rotation the row still looks fine, but the sign-in page says single
      sign-on is unavailable.

  The client secret field is write-only. It is never filled in, so a blank
  field keeps the stored secret (`Changes.StoreSsoClientSecret`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts.SiteSso
  alias KilnCMS.Accounts.SiteSso.DomainCheck
  alias KilnCMS.CMS

  @fields ~w(issuer client_id label)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Single sign-on"))
     |> assign(
       :callback_url,
       KilnCMSWeb.SiteSsoController.callback_url(socket.assigns.current_org)
     )
     |> assign(:domain_form, to_form(%{"domain" => ""}, as: :domain))
     |> load()}
  end

  @impl true
  def handle_event("validate", %{"provider" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, :form, to_form(params, as: :provider))}
  end

  def handle_event("save", %{"provider" => params}, socket) when is_map(params) do
    # An existing row is updated, never re-upserted: the upsert leaves the
    # secret out of what it overwrites (see `SiteSsoProvider`'s moduledoc).
    result =
      case socket.assigns.row do
        nil -> CMS.save_site_sso_provider(attrs(params), opts(socket))
        row -> CMS.update_site_sso_provider(row, attrs(params), opts(socket))
      end

    case result do
      {:ok, _row} ->
        {:noreply, socket |> put_flash(:info, gettext("Single sign-on saved.")) |> load()}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Map.delete(params, "client_secret"), as: :provider))
         |> put_flash(:error, error_message(error))}
    end
  end

  def handle_event("reset", _params, socket) do
    case socket.assigns.row do
      nil ->
        {:noreply, socket}

      row ->
        case CMS.reset_site_sso_provider(row, opts(socket)) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext("Removed. This site's sign-in page no longer offers it.")
             )
             |> load()}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, error_message(error))}
        end
    end
  end

  def handle_event("add_domain", %{"domain" => %{"domain" => domain}}, socket)
      when is_binary(domain) do
    case CMS.add_site_sso_domain(domain, opts(socket)) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> assign(:domain_form, to_form(%{"domain" => ""}, as: :domain))
         |> put_flash(:info, gettext("Domain added. Publish its DNS record, then verify it."))
         |> load()}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:domain_form, to_form(%{"domain" => domain}, as: :domain))
         |> put_flash(:error, domain_error_message(error))}
    end
  end

  def handle_event("verify_domain", %{"id" => id}, socket) when is_binary(id) do
    with_domain(socket, id, fn row ->
      case CMS.verify_site_sso_domain(row, opts(socket)) do
        {:ok, verified} ->
          put_flash(socket, :info, gettext("%{domain} is verified.", domain: verified.domain))

        {:error, error} ->
          put_flash(socket, :error, domain_error_message(error))
      end
    end)
  end

  def handle_event("remove_domain", %{"id" => id}, socket) when is_binary(id) do
    with_domain(socket, id, fn row ->
      case CMS.remove_site_sso_domain(row, opts(socket)) do
        :ok ->
          put_flash(socket, :info, gettext("%{domain} removed.", domain: row.domain))

        {:error, error} ->
          put_flash(socket, :error, domain_error_message(error))
      end
    end)
  end

  # Only a row this page listed — so only one of this site's, read with this
  # admin's own authorization. An id from another site is simply not found.
  defp with_domain(socket, id, fun) do
    case Enum.find(socket.assigns.domains, &(&1.id == id)) do
      nil -> {:noreply, socket}
      row -> {:noreply, row |> fun.() |> load()}
    end
  end

  defp opts(socket), do: [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

  defp attrs(params) do
    params
    |> Map.take(@fields)
    |> Map.put("enabled", params["enabled"] in [true, "true", "on"])
    |> Map.put("client_secret", params["client_secret"])
  end

  defp load(socket) do
    row = current_row(socket)

    params =
      if row do
        %{
          "enabled" => row.enabled,
          "issuer" => row.issuer,
          "client_id" => row.client_id,
          "label" => row.label
        }
      else
        %{"enabled" => true}
      end

    domains = list_domains(socket)

    socket
    |> assign(:row, row)
    |> assign(:secret_stored?, row && not is_nil(row.client_secret_encrypted))
    |> assign(:secret_readable?, is_nil(row) or SiteSso.secret_readable?(row))
    |> assign(:domains, domains)
    |> assign(:verified_count, Enum.count(domains, &(not is_nil(&1.verified_at))))
    |> assign(:form, to_form(params, as: :provider))
  end

  defp current_row(socket) do
    case CMS.list_site_sso_provider(opts(socket)) do
      {:ok, [row | _rest]} -> row
      _ -> nil
    end
  end

  defp list_domains(socket) do
    case CMS.list_site_sso_domains(Keyword.put(opts(socket), :query, sort: [domain: :asc])) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's single sign-on."),
      fallback: gettext("Single sign-on could not be saved.")
    )
  end

  defp domain_error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's domains."),
      fallback: gettext("The domain could not be saved.")
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      active={:site_sso}
    >
      <.header>
        {gettext("Single sign-on")}
        <:subtitle>
          {gettext("Let people sign in to this site through your own identity provider.")}
        </:subtitle>
      </.header>

      <div id="site-sso-status" class="mt-6 card card-pad text-sm">
        <p class="font-medium">
          <%= cond do %>
            <% is_nil(@row) or not @row.enabled -> %>
              {gettext("This site's sign-in page doesn't offer its own single sign-on.")}
            <% @verified_count == 0 -> %>
              {gettext("Saved, but not offered yet: verify at least one email domain below first.")}
            <% true -> %>
              {gettext("This site's sign-in page offers single sign-on through %{issuer}.",
                issuer: @row.issuer
              )}
          <% end %>
        </p>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "Accounts belong to the whole deployment, so your provider can only sign in addresses in the domains you verify here. It can't sign in anyone who has access to another site, or who administers the deployment: they sign in with a password or an email link instead. A second factor, if the account has one, is still asked for."
          )}
        </p>
      </div>

      <div
        :if={not @secret_readable?}
        id="site-sso-secret-unreadable"
        role="alert"
        class="mt-4 rounded-lg border border-error/40 bg-error/10 p-4 text-sm text-error-ink"
      >
        <p class="font-medium">{gettext("The saved client secret can't be read. Re-enter it.")}</p>
        <p class="mt-1">
          {gettext(
            "The deployment's secret key has changed since it was saved. Until you enter it again, the sign-in page says single sign-on is unavailable."
          )}
        </p>
      </div>

      <section class="mt-8">
        <h2 class="text-base font-semibold">{gettext("Provider")}</h2>
        <p class="mt-1 text-sm text-base-content/70">
          {gettext("Register this callback URL with your provider:")}
        </p>
        <code
          id="site-sso-callback-url"
          class="mt-2 block break-all rounded bg-base-200 px-3 py-2 text-sm"
        >
          {@callback_url}
        </code>

        <.form
          for={@form}
          id="site-sso-form"
          phx-change="validate"
          phx-submit="save"
          class="mt-6 space-y-6"
        >
          <.input
            field={@form[:enabled]}
            type="checkbox"
            label={gettext("Offer this provider on the sign-in page")}
            value={@form[:enabled].value}
          />

          <.input
            field={@form[:issuer]}
            type="url"
            label={gettext("Issuer URL")}
            placeholder="https://login.example.com"
            autocomplete="off"
            hint={
              gettext(
                "The provider's OpenID Connect issuer, exactly as its discovery document states it. Must be https://."
              )
            }
          />

          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@form[:client_id]}
              type="text"
              label={gettext("Client ID")}
              autocomplete="off"
            />
            <.input
              field={@form[:client_secret]}
              type="password"
              label={gettext("Client secret")}
              value=""
              autocomplete="new-password"
              placeholder={if @secret_stored?, do: gettext("Saved. Leave blank to keep it.")}
              hint={gettext("Stored encrypted and never shown again.")}
            />
          </div>

          <.input
            field={@form[:label]}
            type="text"
            label={gettext("Button label")}
            placeholder={gettext("e.g. Acme staff")}
            hint={gettext("Shown as \"Sign in with …\". Leave blank for \"single sign-on\".")}
          />

          <div class="flex flex-wrap items-center gap-3">
            <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
            <.button
              :if={@row}
              type="button"
              variant="ghost"
              phx-click="reset"
              data-confirm={
                gettext("Remove this site's provider? Its sign-in button goes away at once.")
              }
            >
              {gettext("Remove")}
            </.button>
          </div>
        </.form>
      </section>

      <section class="mt-10" id="site-sso-domains">
        <h2 class="text-base font-semibold">{gettext("Email domains")}</h2>
        <p class="mt-1 text-sm text-base-content/70">
          {gettext(
            "Your provider may only sign in addresses in these domains, once each is verified. Publish the TXT record shown, then press Verify. Keep the record in place: it is checked again at every sign-in. Each domain is exact — example.com does not cover mail.example.com."
          )}
        </p>

        <ul :if={@domains != []} class="mt-4 space-y-3">
          <li
            :for={domain <- @domains}
            id={"site-sso-domain-#{domain.id}"}
            class="card card-pad text-sm"
          >
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="flex items-center gap-2">
                <span class="font-medium">{domain.domain}</span>
                <span :if={domain.verified_at} class="badge badge-success">
                  {gettext("Verified")}
                </span>
                <span :if={is_nil(domain.verified_at)} class="badge">
                  {gettext("Not verified")}
                </span>
              </div>
              <div class="flex gap-2">
                <.button
                  type="button"
                  size="sm"
                  phx-click="verify_domain"
                  phx-value-id={domain.id}
                  phx-disable-with={gettext("Checking…")}
                >
                  {if domain.verified_at, do: gettext("Check again"), else: gettext("Verify")}
                </.button>
                <.button
                  type="button"
                  size="sm"
                  variant="ghost"
                  phx-click="remove_domain"
                  phx-value-id={domain.id}
                  data-confirm={gettext("Remove %{domain}?", domain: domain.domain)}
                >
                  {gettext("Remove")}
                </.button>
              </div>
            </div>
            <dl class="mt-3 grid gap-1 text-xs text-base-content/70 sm:grid-cols-[auto_1fr] sm:gap-x-3">
              <dt>{gettext("TXT name")}</dt>
              <dd><code class="break-all">{DomainCheck.record_name(domain.domain)}</code></dd>
              <dt>{gettext("TXT value")}</dt>
              <dd>
                <code class="break-all">{DomainCheck.record_value(domain.verification_token)}</code>
              </dd>
            </dl>
          </li>
        </ul>

        <.form
          for={@domain_form}
          id="site-sso-domain-form"
          phx-submit="add_domain"
          class="mt-4 flex flex-wrap items-end gap-3"
        >
          <div class="min-w-64 flex-1">
            <.input
              field={@domain_form[:domain]}
              type="text"
              label={gettext("Add a domain")}
              placeholder="example.com"
              autocomplete="off"
            />
          </div>
          <.button>{gettext("Add")}</.button>
        </.form>
      </section>
    </Layouts.console>
    """
  end
end
