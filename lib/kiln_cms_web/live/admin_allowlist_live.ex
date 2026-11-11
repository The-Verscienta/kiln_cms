defmodule KilnCMSWeb.AdminAllowlistLive do
  @moduledoc """
  The site's admin allowlist (#2248): the IP addresses and ranges this site's
  console and sign-in may be reached from. Empty means off.

  Org-scoped like `/editor/ip-blocks`, and gated the same two ways: the
  `:admin_routes` live session's `:live_admin_required` hook, and the
  `KilnCMS.CMS.SiteAdminAllowlist` org-admin policy. Every client-bound event
  re-checks the policy too, because the socket outlives the mount-time check.

  ## Your address

  The page shows the address the HTTP gate admitted this page from (stamped
  into its LiveView session, `KilnCMSWeb.AdminAllowlist`) and, when it differs,
  the address the page's socket arrived from — a dual-stack network can show
  IPv4 to one and IPv6 to the other, and both gates check their own. Both go to
  the save as context, and the save refuses a list that does not admit both
  (`KilnCMS.CMS.Changes.RefuseAdminLockout`). "Add my address" adds each: the
  address itself for IPv4, its `/64` for IPv6.

  ## Also restrict sign-in

  A checkbox in the same form (#2493), on by default: whether the list gates
  the sign-in pages and the headless `POST /api/auth/sign_in` too. Turned off,
  members sign in from anywhere and the console stays behind the list. The
  form always sends it, and every save (Turn off included) writes it: `:save`
  is an upsert that resets an omitted `restrict_sign_in` to its default.

  An address in private or carrier-grade NAT space is usually a proxy's, so the
  page warns that listing it admits everyone behind it; and when a forwarding
  header arrived that nothing trusts, it says so and refuses to save a list.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Changes.RefuseAdminLockout
  alias KilnCMS.Security.AdminAllowlist
  alias KilnCMS.Security.Cidr
  alias KilnCMSWeb.AdminAllowlist, as: Gate
  alias KilnCMSWeb.Plugs.ClientIp

  @impl true
  def mount(_params, session, socket) do
    org_id = socket.assigns.current_org.id
    stamped = Gate.stamped_ip(session, org_id)
    socket_ip = ClientIp.socket_client_from(socket)
    {_resolved, untrusted?} = ClientIp.from_socket(socket)

    {:ok,
     socket
     |> assign(:page_title, gettext("Admin allowlist"))
     |> assign(:client_ip, stamped)
     |> assign(:socket_ip, if(socket_ip != stamped, do: socket_ip))
     |> assign(:untrusted_forwarding?, untrusted?)
     |> assign(:disabled?, AdminAllowlist.disabled?())
     |> load_list()}
  end

  @impl true
  def handle_event("validate", %{"allowlist" => %{"cidrs" => text} = params}, socket)
      when is_binary(text) do
    {:noreply, assign(socket, :form, list_form(text, restrict_param(params)))}
  end

  def handle_event("save", %{"allowlist" => %{"cidrs" => text} = params}, socket)
      when is_binary(text) do
    restrict? = restrict_param(params)
    socket = assign(socket, :form, list_form(text, restrict?))
    save(socket, entries(text), restrict?, gettext("Admin allowlist saved."))
  end

  def handle_event("add_mine", _params, socket) do
    if can_save?(socket) do
      text = socket.assigns.form[:cidrs].value || ""

      missing =
        socket.assigns
        |> own_addresses()
        |> Enum.map(&Cidr.client_range/1)
        |> Enum.reject(&(is_nil(&1) or &1 in entries(text)))

      {:noreply,
       assign(
         socket,
         :form,
         list_form(Enum.join(entries(text) ++ missing, "\n"), form_restrict(socket))
       )}
    else
      {:noreply, put_flash(socket, :error, forbidden_message())}
    end
  end

  # Keeps "Also restrict sign-in" as the form shows it: the next list turned
  # on starts from the site's last choice.
  def handle_event("turn_off", _params, socket) do
    save(socket, [], form_restrict(socket), gettext("Admin allowlist turned off."))
  end

  defp save(socket, entries, restrict?, success) do
    if can_save?(socket) do
      context =
        Map.merge(socket.assigns.security_context, %{
          client_ip: socket.assigns.client_ip,
          socket_ip: socket.assigns.socket_ip,
          untrusted_forwarding?: socket.assigns.untrusted_forwarding?
        })

      # Both columns, always: see "Also restrict sign-in".
      case CMS.save_site_admin_allowlist(%{cidrs: entries, restrict_sign_in: restrict?},
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org,
             context: context
           ) do
        {:ok, _row} ->
          {:noreply, socket |> put_flash(:info, success) |> load_list()}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, error_message(error))}
      end
    else
      {:noreply, put_flash(socket, :error, forbidden_message())}
    end
  end

  defp can_save?(socket) do
    CMS.can_save_site_admin_allowlist?(socket.assigns.current_user, %{cidrs: []},
      tenant: socket.assigns.current_org
    )
  end

  defp load_list(socket) do
    {cidrs, restrict?} =
      case CMS.list_site_admin_allowlist(
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org
           ) do
        {:ok, [row | _]} -> {row.cidrs, row.restrict_sign_in != false}
        _none_or_refused -> {[], true}
      end

    socket
    |> assign(:cidrs, cidrs)
    |> assign(:restrict_sign_in?, restrict?)
    |> assign(:form, list_form(Enum.join(cidrs, "\n"), restrict?))
  end

  defp list_form(text, restrict?),
    do: to_form(%{"cidrs" => text, "restrict_sign_in" => restrict?}, as: :allowlist)

  # Only an explicit "false" opens sign-in; a missing or unexpected value keeps
  # the stricter default.
  defp restrict_param(params), do: Map.get(params, "restrict_sign_in") not in ["false", false]

  defp form_restrict(socket),
    do: socket.assigns.form[:restrict_sign_in].value not in ["false", false]

  defp entries(text) do
    text
    |> String.split(["\n", "\r", ",", " ", "\t"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp own_addresses(%{client_ip: client_ip, socket_ip: socket_ip}),
    do: Enum.reject([client_ip, socket_ip], &is_nil/1)

  defp forbidden_message,
    do: gettext("You don't have permission to change this site's admin allowlist.")

  # The resource's messages are English strings fixed in its changes, so they
  # are mapped here, keyed on field + message, to gettext sentences. A message
  # that is not one of ours (a framework constraint) falls back to Ash's text.
  defp error_message(%Ash.Error.Forbidden{} = error),
    do: ash_error_message(error, forbidden: forbidden_message())

  defp error_message(error) do
    errors = error |> Ash.Error.to_error_class() |> Map.get(:errors, [])

    case Enum.map(errors, &localised_error/1) do
      [] -> ash_error_message(error, fallback: gettext("The admin allowlist could not be saved."))
      messages -> messages |> Enum.uniq() |> Enum.join(" ")
    end
  end

  defp localised_error(error) do
    vars = Map.new(Map.get(error, :vars) || [])

    case {Map.get(error, :field), Map.get(error, :message)} do
      {:cidrs, "%{entry} is not an IP address or range"} ->
        gettext("%{entry} is not an IP address or range.", entry: vars[:entry])

      {:cidrs, "%{entry} is too broad"} ->
        gettext("%{entry} is too broad: use at least /8 for IPv4 or /16 for IPv6.",
          entry: vars[:entry]
        )

      {:cidrs, "%{entry} includes loopback"} ->
        gettext("%{entry} includes loopback (127.0.0.0/8 or ::1), which can't be listed.",
          entry: vars[:entry]
        )

      {:cidrs, "at most %{max} entries"} ->
        gettext("The list can hold at most %{max} entries.", max: vars[:max])

      {:cidrs, message} ->
        lockout_error(message, vars) || Exception.message(error)

      _other ->
        Exception.message(error)
    end
  end

  # `RefuseAdminLockout`'s refusals, or nil for a message that is not one.
  defp lockout_error(message, vars) do
    [untrusted, unknown, excluded, excluded_both] = RefuseAdminLockout.messages()

    case message do
      ^untrusted ->
        untrusted_message()

      ^unknown ->
        gettext(
          "Your address could not be determined, so this list can't be checked against it. Reload the page and try again."
        )

      ^excluded ->
        gettext(
          "This list doesn't include your current address, %{ip}. Add it, or a range that contains it, so you aren't locked out.",
          ip: vars[:ip]
        )

      ^excluded_both ->
        gettext(
          "This list must include both of your current addresses, %{ip} and %{socket_ip}. Add them, or ranges that contain them, so you aren't locked out.",
          ip: vars[:ip],
          socket_ip: vars[:socket_ip]
        )

      _other ->
        nil
    end
  end

  defp untrusted_message,
    do:
      gettext(
        "Kiln is seeing a proxy's address, not yours: a forwarding header arrived that nothing is configured to trust. Either Kiln runs behind a proxy that TRUSTED_PROXIES (or CLIENT_IP_HEADER) does not name, or a proxy on your side added the header. Fix that before turning on the admin allowlist."
      )

  defp ip_text(ip), do: ip |> :inet.ntoa() |> to_string()

  defp family_note({_, _, _, _}),
    do:
      gettext(
        "You're connected over IPv4. If your network also uses IPv6, add its range too, or you may be refused when your browser switches."
      )

  defp family_note({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: family_note({0, 0, 0, 0})

  defp family_note(_ipv6),
    do:
      gettext(
        "You're connected over IPv6. If your network also uses IPv4, add its address too, or you may be refused when your browser switches."
      )

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:addresses, own_addresses(assigns))
      |> assign(:shared?, Enum.any?(own_addresses(assigns), &Cidr.shared_space?/1))

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:admin_allowlist}
    >
      <.header>
        {gettext("Admin allowlist")}
        <:subtitle>
          {gettext(
            "The networks this site's console and sign-in can be reached from, such as your office or VPN. Applies to this site only."
          )}
        </:subtitle>
      </.header>

      <p id="admin-allowlist-status" class="mt-6 text-sm font-medium">
        <%= cond do %>
          <% @cidrs == [] -> %>
            {gettext("Off: people can sign in from any network.")}
          <% @restrict_sign_in? -> %>
            {ngettext(
              "On: %{count} network can open the console and sign in.",
              "On: %{count} networks can open the console and sign in.",
              length(@cidrs)
            )}
          <% true -> %>
            {ngettext(
              "On: %{count} network can open the console. Anyone can sign in from any network.",
              "On: %{count} networks can open the console. Anyone can sign in from any network.",
              length(@cidrs)
            )}
        <% end %>
      </p>

      <div
        :if={@disabled?}
        id="admin-allowlist-disabled"
        class="mt-6 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm text-warning-ink"
      >
        {gettext(
          "This server isn't enforcing the admin allowlist (KILN_ADMIN_ALLOWLIST_DISABLED is set). The list is saved but not applied."
        )}
      </div>

      <div
        :if={@untrusted_forwarding?}
        id="admin-allowlist-proxy-warning"
        class="mt-6 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm text-warning-ink"
      >
        <p class="font-medium">{gettext("Kiln can't see your real address.")}</p>
        <p class="mt-1">{untrusted_message()}</p>
      </div>

      <section id="admin-allowlist-you" class="mt-6 rounded-lg bg-base-200 p-4 text-sm">
        <p :if={@addresses == []} id="admin-allowlist-unknown">
          {gettext("Your address could not be determined yet.")}
        </p>
        <p :for={ip <- @addresses} class="admin-allowlist-address">
          <%= if @cidrs == [] or AdminAllowlist.would_admit?(@cidrs, ip) do %>
            {gettext("Your address: %{ip} (included)", ip: ip_text(ip))}
          <% else %>
            {gettext("Your address: %{ip} (not included)", ip: ip_text(ip))}
          <% end %>
        </p>
        <p :if={@addresses != []} class="mt-1 text-base-content/70">
          {family_note(hd(@addresses))}
        </p>
        <p :if={@shared?} id="admin-allowlist-shared-warning" class="mt-2 text-warning-ink">
          {gettext(
            "This looks like a private or shared address, which may be your proxy's or your provider's: adding it admits everyone behind it."
          )}
        </p>
      </section>

      <.form
        for={@form}
        id="admin-allowlist-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-8 max-w-2xl space-y-4"
      >
        <.input
          field={@form[:cidrs]}
          type="textarea"
          rows="8"
          label={gettext("Allowed addresses and ranges")}
          placeholder="203.0.113.7&#10;198.51.100.0/24&#10;2001:db8:1:2::/64"
          hint={
            gettext(
              "One per line: an IPv4 or IPv6 address, or a range like 198.51.100.0/24. Leave empty to turn the allowlist off."
            )
          }
        />
        <.input
          field={@form[:restrict_sign_in]}
          type="checkbox"
          id="admin-allowlist-restrict-sign-in"
          label={gettext("Also restrict sign-in")}
        />
        <p id="admin-allowlist-restrict-sign-in-hint" class="-mt-2 text-sm text-base-content/70">
          {gettext(
            "On: signing in, on this site's sign-in pages and through the API, works only from the networks above. Off: members can sign in from anywhere, and the console still opens only from the networks above."
          )}
        </p>
        <div class="flex flex-wrap items-center gap-3">
          <.button
            id="admin-allowlist-save"
            phx-disable-with={gettext("Saving…")}
            disabled={@untrusted_forwarding?}
          >
            {gettext("Save")}
          </.button>
          <.button
            :if={@addresses != []}
            id="admin-allowlist-add-mine"
            type="button"
            variant="ghost"
            phx-click="add_mine"
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("Add my address")}
          </.button>
          <.button
            :if={@cidrs != []}
            id="admin-allowlist-turn-off"
            type="button"
            variant="ghost"
            phx-click="turn_off"
            data-confirm={
              gettext(
                "Turn the admin allowlist off? Anyone will be able to sign in from any network."
              )
            }
          >
            {gettext("Turn off")}
          </.button>
        </div>
      </.form>

      <div class="mt-10 max-w-2xl space-y-3 rounded-lg bg-base-200 p-4 text-sm text-base-content/70">
        <p :if={not @restrict_sign_in?} id="admin-allowlist-scope">
          {gettext(
            "From any other network, the console answers \"Not available from this network\", and open console pages are sent away as soon as you save. The public site, sign-in, API keys, existing app tokens, previews and media are not affected, except that the security posture endpoint for monitoring (GET /api/security/posture) also answers only to listed networks."
          )}
        </p>
        <p :if={@restrict_sign_in?} id="admin-allowlist-scope">
          {gettext(
            "From any other network, the console and every sign-in page answer \"Not available from this network\", and open console pages are sent away as soon as you save. The public site, API keys, existing app tokens, previews and media are not affected, except that the security posture endpoint for monitoring (GET /api/security/posture) also answers only to listed networks."
          )}
        </p>
        <p :if={@restrict_sign_in?} id="admin-allowlist-members">
          {gettext(
            "This also applies to members and readers who sign in to this site, and to sign-in through the API: a website's own sign-in form or a mobile app that signs people in only works from listed networks too. Turn off \"Also restrict sign-in\" to let them sign in from anywhere."
          )}
        </p>
        <p :if={not @restrict_sign_in?} id="admin-allowlist-members-open">
          {gettext(
            "Sign-in is not restricted: members, readers, and apps that sign people in through the API can sign in from any network. Signing in from elsewhere still doesn't open the console. Anyone with an admin's password can get an API token from anywhere, so use two-factor sign-in."
          )}
        </p>
        <p id="admin-allowlist-recovery-hint">
          {gettext(
            "Locked out? An operator can widen or clear the list from the server: see docs/admin-allowlist.md, \"Recovering from a lock-out\"."
          )}
        </p>
      </div>
    </Layouts.console>
    """
  end
end
