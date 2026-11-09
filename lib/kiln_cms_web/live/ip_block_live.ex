defmodule KilnCMSWeb.IpBlockLive do
  @moduledoc """
  The site's IP block list (#2242): add an address or CIDR range, with an
  optional note and expiry, and remove it again.

  Org-scoped like `/editor/code-injection`, and gated the same two ways: the
  `:admin_routes` live session's `:live_admin_required` hook, and the
  `KilnCMS.CMS.IpBlockRule` org-admin policy. Every client-bound event re-checks
  the policy as well, because the socket outlives the mount-time check.

  ## Locking yourself out

  The create action refuses a rule that contains the caller's own address, or
  one whose address is unknown, unless it is confirmed. This screen resolves the
  address from the handshake (`KilnCMSWeb.Plugs.ClientIp.resolve/2`, as the join
  budgets do), hands it to the action as `context: %{client_ip: ...}`, and when
  the action refuses for that reason shows a confirmation step; only the
  confirm button resubmits with `confirm_self_block: true`.

  When the app sits behind a proxy it does not trust (`TRUSTED_PROXIES` unset),
  the "client address" is the proxy's, so the check is blind to a real lock-out
  and the page says so.

  ## Removal is by id, under this site's tenant

  The row is fetched again with `get_ip_block_rule(id, tenant: org)` before it
  is destroyed. A struct (or id) from another site's list is not refused by Ash
  once it is in hand, so the lookup is the tenant boundary here.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMSWeb.Plugs.ClientIp

  @impl true
  def mount(_params, _session, socket) do
    # Only a connected ROOT mount has a handshake to read (see
    # `KilnCMSWeb.SignInLive`); anywhere else the address is unknown, which the
    # action treats as "needs confirming".
    {client_ip, untrusted?} = ClientIp.from_socket(socket)

    {:ok,
     socket
     |> assign(:page_title, gettext("Blocked addresses"))
     |> assign(:client_ip, client_ip)
     |> assign(:untrusted_forwarding?, untrusted?)
     |> assign(:pending, nil)
     |> assign(:form, blank_form())
     |> load_rules()}
  end

  @impl true
  def handle_event("validate", %{"rule" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, :form, to_form(params, as: :rule))}
  end

  def handle_event("add", %{"rule" => params}, socket) when is_map(params) do
    if can_add?(socket) do
      case parse_attrs(params) do
        {:ok, attrs} ->
          socket |> assign(:form, to_form(params, as: :rule)) |> create(attrs, false)

        :error ->
          {:noreply,
           put_flash(socket, :error, gettext("The expiry is not a valid date and time."))}
      end
    else
      {:noreply, put_flash(socket, :error, forbidden_message())}
    end
  end

  def handle_event("confirm_self_block", _params, %{assigns: %{pending: attrs}} = socket)
      when is_map(attrs) do
    if can_add?(socket) do
      create(socket, attrs, true)
    else
      {:noreply, socket |> assign(:pending, nil) |> put_flash(:error, forbidden_message())}
    end
  end

  def handle_event("confirm_self_block", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_self_block", _params, socket),
    do: {:noreply, assign(socket, :pending, nil)}

  def handle_event("remove", %{"id" => id}, socket) when is_binary(id) do
    opts = [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

    # Re-fetched under this site's tenant: a rule id from another site finds
    # nothing here, and an unauthorised actor is refused by the read itself.
    with {:ok, %{} = rule} <- CMS.get_ip_block_rule(id, opts ++ [not_found_error?: false]),
         true <-
           CMS.can_destroy_ip_block_rule?(socket.assigns.current_user, rule,
             tenant: socket.assigns.current_org
           ),
         :ok <-
           CMS.destroy_ip_block_rule(
             rule,
             opts ++ [context: socket.assigns.security_context]
           ) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Block removed."))
       |> load_rules()}
    else
      {:ok, nil} ->
        {:noreply,
         socket |> put_flash(:error, gettext("That block no longer exists.")) |> load_rules()}

      false ->
        {:noreply, put_flash(socket, :error, forbidden_message())}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  defp create(socket, attrs, confirmed?) do
    params = Map.put(attrs, :confirm_self_block, confirmed?)

    case CMS.create_ip_block_rule(params,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org,
           context: Map.put(socket.assigns.security_context, :client_ip, socket.assigns.client_ip)
         ) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> assign(:pending, nil)
         |> assign(:form, blank_form())
         |> put_flash(:info, gettext("Address blocked."))
         |> load_rules()}

      {:error, error} ->
        if not confirmed? and self_block_refusal?(error) do
          {:noreply, assign(socket, :pending, attrs)}
        else
          {:noreply,
           socket
           |> assign(:pending, nil)
           |> put_flash(:error, error_message(error))}
        end
    end
  end

  # The create action's refusal for "this rule includes you" is an error on the
  # `confirm_self_block` argument; any other invalid field is an ordinary error.
  defp self_block_refusal?(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.any?(&(Map.get(&1, :field) == :confirm_self_block))
  end

  defp can_add?(socket) do
    CMS.can_create_ip_block_rule?(
      socket.assigns.current_user,
      %{cidr: "192.0.2.0/24"},
      tenant: socket.assigns.current_org
    )
  end

  defp parse_attrs(params) do
    with {:ok, expires_at} <- parse_expiry(params["expires_at"]) do
      {:ok,
       %{
         cidr: params["cidr"],
         note: blank_to_nil(params["note"]),
         expires_at: expires_at
       }}
    end
  end

  # `datetime-local` posts "2026-11-08T10:00" (no zone, maybe no seconds). The
  # field is labelled UTC, so that is how it is read.
  defp parse_expiry(value) when value in [nil, ""], do: {:ok, nil}

  defp parse_expiry(value) when is_binary(value) do
    value = String.trim(value)
    value = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
      _invalid -> :error
    end
  end

  defp parse_expiry(_other), do: :error

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_other), do: nil

  # The scanner guard's rules (#2253) carry its fixed note; an admin could type the
  # same words, which only earns their rule an explanation that happens to fit.
  defp automatic?(rule), do: rule.note == KilnCMS.Security.ScannerGuard.note()

  defp blank_form, do: to_form(%{"cidr" => "", "note" => "", "expires_at" => ""}, as: :rule)

  defp load_rules(socket) do
    rules =
      case CMS.list_ip_block_rules(
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org
           ) do
        {:ok, rules} -> rules
        _refused -> []
      end

    assign(socket, :rules, rules)
  end

  defp forbidden_message,
    do: gettext("You don't have permission to change this site's blocked addresses.")

  # Ash's validation messages are English strings fixed in the resource, so they
  # are mapped here, keyed on field + message, to gettext sentences. A message
  # that is not one of ours (a new validation, a framework error) falls back to
  # Ash's own text.
  defp error_message(%Ash.Error.Forbidden{} = error),
    do: ash_error_message(error, forbidden: forbidden_message())

  defp error_message(error) do
    errors = error |> Ash.Error.to_error_class() |> Map.get(:errors, [])

    case Enum.map(errors, &localised_error/1) do
      [] -> ash_error_message(error, fallback: gettext("The block could not be saved."))
      messages -> Enum.join(messages, " ")
    end
  end

  defp localised_error(error) do
    case {Map.get(error, :field), Map.get(error, :message)} do
      {:cidr, "must be an IP address or a range like 203.0.113.0/24"} ->
        gettext("Enter an IP address or a range like 203.0.113.0/24.")

      {:cidr, "is too broad: use at least /8 for IPv4 or /16 for IPv6"} ->
        gettext("That range is too broad: use at least /8 for IPv4 or /16 for IPv6.")

      {:cidr, "must not include loopback (127.0.0.0/8 or ::1)"} ->
        gettext("A range must not include loopback (127.0.0.0/8 or ::1).")

      {:cidr, "is already blocked"} ->
        gettext("That range is already blocked.")

      {:expires_at, "must be in the future"} ->
        gettext("The expiry must be in the future.")

      _other ->
        Exception.message(error)
    end
  end

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp expired?(%{expires_at: nil}), do: false
  defp expired?(%{expires_at: at}), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp ip_text(ip), do: ip |> :inet.ntoa() |> to_string()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:ip_blocks}
    >
      <.header>
        {gettext("Blocked addresses")}
        <:subtitle>
          {gettext("Refuse requests from an IP address or range. Applies to this site only.")}
        </:subtitle>
      </.header>

      <p id="ip-block-recovery-hint" class="text-sm text-base-content/70">
        {gettext(
          "Locked yourself out? An operator can lift blocks from the server: see docs/ip-blocking.md, \"Recovering from a lock-out\"."
        )}
      </p>

      <div
        :if={@untrusted_forwarding?}
        id="ip-block-proxy-warning"
        class="mt-6 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm text-warning-ink"
      >
        <p class="font-medium">{gettext("Visitor addresses may be your proxy's.")}</p>
        <p class="mt-1">
          {gettext(
            "This request arrived with a forwarding header, but no trusted proxies are configured (TRUSTED_PROXIES), so Kiln sees your proxy's address, not the visitor's. Blocks would then match the proxy, and the check that stops you blocking yourself cannot be relied on. Set TRUSTED_PROXIES before adding blocks."
          )}
        </p>
      </div>

      <div class="mt-6 rounded-lg bg-base-200 p-4 text-sm text-base-content/70">
        <p>
          {gettext(
            "Blocked visitors get an empty 403 on pages, the API, and live connections. Static files and uploaded media are served before this check and are not covered; use your CDN or proxy for those. Your own loopback address, health checks, and very wide ranges (wider than /8 for IPv4, /16 for IPv6) cannot be blocked."
          )}
        </p>
      </div>

      <div
        :if={@pending}
        id="ip-block-self-confirm"
        class="mt-6 rounded-lg border border-error/40 bg-error/10 p-4 text-sm"
        role="alertdialog"
        aria-labelledby="ip-block-self-confirm-title"
      >
        <p id="ip-block-self-confirm-title" class="font-medium">
          {gettext("This block may lock you out.")}
        </p>
        <p :if={@client_ip} class="mt-1">
          {gettext("The range %{cidr} includes your own address, %{ip}. Confirm to add it anyway.",
            cidr: @pending.cidr,
            ip: ip_text(@client_ip)
          )}
        </p>
        <p :if={is_nil(@client_ip)} class="mt-1">
          {gettext(
            "Your own address could not be determined, so %{cidr} cannot be checked against it. Confirm to add it anyway.",
            cidr: @pending.cidr
          )}
        </p>
        <div class="mt-3 flex items-center gap-3">
          <.button
            id="ip-block-confirm"
            type="button"
            variant="danger"
            phx-click="confirm_self_block"
            phx-disable-with={gettext("Saving…")}
          >
            {gettext("Block it anyway")}
          </.button>
          <.button id="ip-block-cancel" type="button" variant="ghost" phx-click="cancel_self_block">
            {gettext("Cancel")}
          </.button>
        </div>
      </div>

      <.form
        for={@form}
        id="ip-block-form"
        phx-change="validate"
        phx-submit="add"
        class="mt-8 grid gap-4 sm:grid-cols-3"
      >
        <.input
          field={@form[:cidr]}
          type="text"
          label={gettext("Address or range")}
          placeholder="203.0.113.7 or 198.51.100.0/24"
          hint={gettext("IPv4 or IPv6, with an optional /prefix.")}
          required
        />
        <.input
          field={@form[:note]}
          type="text"
          label={gettext("Note")}
          placeholder={gettext("Why this was blocked")}
        />
        <.input
          field={@form[:expires_at]}
          type="datetime-local"
          label={gettext("Expires (UTC)")}
          hint={gettext("Leave empty to block until removed.")}
        />
        <div class="sm:col-span-3">
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Block")}</.button>
        </div>
      </.form>

      <div class="mt-10">
        <h2 class="text-sm font-semibold">{gettext("Current blocks")}</h2>

        <p :if={@rules == []} id="ip-block-empty" class="mt-2 text-sm text-base-content/70">
          {gettext("Nothing is blocked.")}
        </p>

        <ul :if={@rules != []} id="ip-block-rules" class="mt-3 divide-y divide-base-300">
          <li
            :for={rule <- @rules}
            id={"ip-block-#{rule.id}"}
            class="flex items-center justify-between gap-4 py-3"
          >
            <div class="min-w-0">
              <p class="flex items-center gap-2">
                <span class="font-mono text-sm">{rule.cidr}</span>
                <.badge :if={expired?(rule)} variant="outline">{gettext("Expired")}</.badge>
              </p>
              <p :if={rule.note} class="mt-0.5 truncate text-sm text-base-content/70">
                {rule.note}
              </p>
              <p :if={rule.expires_at} class="mt-0.5 text-xs text-base-content/70">
                {gettext("Expires %{at}", at: format_time(rule.expires_at))}
              </p>
              <p :if={automatic?(rule)} class="mt-0.5 text-xs text-base-content/70">
                {gettext(
                  "Added automatically after repeated 404s or probes of paths like /wp-login.php. It expires by itself; Remove it to lift it sooner."
                )}
              </p>
            </div>
            <.button
              type="button"
              variant="ghost"
              size="sm"
              phx-click="remove"
              phx-value-id={rule.id}
              data-confirm={gettext("Stop blocking %{cidr}?", cidr: rule.cidr)}
            >
              <.icon name="hero-trash" class="size-4" /> {gettext("Remove")}
            </.button>
          </li>
        </ul>
      </div>
    </Layouts.console>
    """
  end
end
