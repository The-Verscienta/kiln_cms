defmodule KilnCMSWeb.ApiKeyLive do
  @moduledoc """
  API keys (`/editor/api-keys`) — mint and revoke keys for headless / third-party
  access to the delivery API and the `/mcp` authoring endpoint. Admin-only,
  mirroring the `ApiKey` policy.

  A key authenticates as its owning user, inheriting that user's read scope. Its
  `access` scope bounds what it may do with that identity: `:read` keys (the
  default) can never mutate content; `:read_write` keys may author content
  within the owner's role (built for LLM/automation clients on `/mcp`). The
  plaintext key is shown **once**, right after minting — it's only stored
  hashed, so it can't be retrieved again.

  A drafts-only key may be given a **rotation window** at mint: until that date
  the service can exchange the key for a fresh one itself (`POST
  /api/keys/rotate`). The list shows each key's window and where it came from,
  and a key retired by rotation reads "Rotated", not "Revoked".
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts

  import KilnCMSWeb.RoleDisplay, only: [role_label: 1]

  # Offered key lifetimes (days). Keys always expire — no immortal credentials.
  @durations [{"30 days", 30}, {"90 days", 90}, {"1 year", 365}]

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if KilnCMSWeb.LiveUserAuth.platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("API keys"))
       |> assign(:durations, @durations)
       |> assign(:rotation_windows, rotation_windows())
       |> assign_users(actor)
       |> assign(:new_key, nil)
       |> load_keys()}
    else
      # Not redundant: the `:live_admin_required` hook admits any ADMIN of this
      # site, and this page needs a PLATFORM admin (#419), so it refuses the rest
      # itself, to the same access-denied page (#2143).
      {:ok,
       socket
       |> push_navigate(to: KilnCMSWeb.AccessDenied.path(:platform))}
    end
  end

  @impl true
  def handle_event(
        "mint",
        %{"user_id" => user_id, "name" => name, "days" => days} = params,
        socket
      )
      when is_binary(user_id) and user_id != "" and is_binary(name) and is_binary(days) do
    actor = socket.assigns.actor
    access = access_scope(params["access"])
    expires_at = DateTime.add(DateTime.utc_now(), duration_days(days, access), :day)

    attrs = %{access: access, rotatable_until: rotatable_until(params["rotate_days"], access)}

    case Accounts.mint_api_key(user_id, String.trim(name), expires_at, attrs,
           actor: actor,
           context: socket.assigns.security_context
         ) do
      {:ok, key} ->
        {:noreply,
         socket
         |> assign(:new_key, Ash.Resource.get_metadata(key, :plaintext_api_key))
         |> load_keys()
         |> put_flash(:info, gettext("API key created — copy it now, it won't be shown again."))}

      {:error, _error} when access == :draft_write ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Couldn't create that key. A drafts-only key needs a name and an owner who is not an editor or admin."
           )
         )}

      {:error, _error} ->
        {:noreply,
         put_flash(socket, :error, gettext("Couldn't create that key. Give it a name."))}
    end
  end

  def handle_event("mint", _params, socket),
    do:
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Choose which user the key acts as, and give it a name.")
       )}

  def handle_event("dismiss_new_key", _params, socket),
    do: {:noreply, assign(socket, :new_key, nil)}

  def handle_event("revoke", %{"id" => id}, socket) when is_binary(id) do
    actor = socket.assigns.actor

    socket =
      with {:ok, key} <- Accounts.get_api_key(id, actor: actor),
           {:ok, _} <-
             Accounts.revoke_api_key(key, actor: actor, context: socket.assigns.security_context) do
        socket |> load_keys() |> put_flash(:info, gettext("Key revoked."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't revoke that key."))
      end

    {:noreply, socket}
  end

  defp assign_users(socket, actor) do
    users = Accounts.list_users!(actor: actor)

    socket
    |> assign(:users, users)
    |> assign(:actor_listed?, Enum.any?(users, &(&1.id == actor.id)))
  end

  defp owner_label(%{id: id} = user, %{id: id}),
    do: gettext("%{email} (%{role}) — you", email: user.email, role: role_label(user.role))

  defp owner_label(user, _actor), do: "#{user.email} (#{role_label(user.role)})"

  defp load_keys(socket) do
    keys =
      Accounts.list_all_api_keys!(
        actor: socket.assigns.actor,
        load: [:user, :valid, :rotated_to],
        query: [sort: [created_at: :desc]]
      )

    assign(socket, :keys, keys)
  end

  defp duration_days(days, access) do
    n =
      case Integer.parse(to_string(days)) do
        {n, _} when n in [30, 90, 365] -> n
        _ -> 30
      end

    # A draft-write key has a lifetime ceiling (#2273); clamp rather than let a
    # 365-day pick fail the mint with an error that blames the name.
    if access == :draft_write,
      do: min(n, KilnCMS.Accounts.Validations.DraftWriteKey.max_ttl_days()),
      else: n
  end

  # Self-rotation windows offered for a drafts-only key, capped at the
  # configured ceiling. 0 = no self-rotation (the default).
  defp rotation_windows do
    max = KilnCMS.Accounts.Validations.DraftWriteKey.max_rotation_days()

    [{gettext("Off"), 0}] ++
      for {label, days} <- [
            {gettext("90 days"), 90},
            {gettext("180 days"), 180},
            {gettext("1 year"), 365}
          ],
          days <= max,
          do: {label, days}
  end

  # Only a drafts-only key can rotate; any other scope gets no window rather
  # than a refused mint, since the field sits on the shared form.
  defp rotatable_until(days, :draft_write) do
    allowed = for {_label, n} <- rotation_windows(), n > 0, do: n

    case Integer.parse(to_string(days)) do
      {n, ""} -> if n in allowed, do: DateTime.add(DateTime.utc_now(), n, :day)
      _ -> nil
    end
  end

  defp rotatable_until(_days, _access), do: nil

  # Anything but an explicit opt-in falls back to read-only.
  defp access_scope("read_write"), do: :read_write
  defp access_scope("draft_write"), do: :draft_write
  defp access_scope(_), do: :read

  defp access_label(:read_write), do: gettext("Read + write")
  defp access_label(:draft_write), do: gettext("Drafts only")
  defp access_label(_), do: gettext("Read-only")

  defp status(%{revoked_at: at, rotated_to: %KilnCMS.Accounts.ApiKey{}}) when not is_nil(at),
    do: {:rotated, gettext("Rotated")}

  defp status(%{revoked_at: at}) when not is_nil(at), do: {:revoked, gettext("Revoked")}
  defp status(%{valid: true}), do: {:active, gettext("Active")}
  defp status(_), do: {:expired, gettext("Expired")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:api_keys}
    >
      <div class="space-y-8">
        <div>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("API keys")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Grant headless / third-party access to the delivery API and the MCP authoring endpoint. A key acts as its owning user; read-only keys can never modify content, while read + write keys can author content within the owner's role. For public-only access, mint a read-only key on a viewer account; for an LLM author, mint a read + write key on an editor account."
            )}
          </p>
        </div>

        <div
          :if={@new_key}
          id="new-key-banner"
          class="rounded-lg border border-success/30 bg-success/10 p-4 space-y-2"
        >
          <p class="text-sm font-medium">
            {gettext("Copy this key now — it won't be shown again.")}
          </p>
          <div class="flex items-center gap-2">
            <code class="grow break-all rounded bg-base-100 px-2 py-1 text-sm">{@new_key}</code>
            <button
              type="button"
              phx-click="dismiss_new_key"
              class="rounded px-2 py-1 text-xs hover:bg-base-200"
            >
              {gettext("Dismiss")}
            </button>
          </div>
        </div>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Create a key")}</h2>
          <form
            id="new-api-key-form"
            phx-submit="mint"
            class="grid gap-4 rounded-lg border border-base-content/15 p-4 sm:grid-cols-2"
          >
            <label class="text-sm">
              <span class="mb-1 block font-medium">{gettext("Name")}</span>
              <input
                type="text"
                name="name"
                required
                placeholder={gettext("e.g. marketing-site")}
                class="w-full rounded border border-base-content/30 px-2 py-1.5 text-sm"
              />
            </label>
            <label class="text-sm">
              <span class="mb-1 block font-medium">{gettext("Acts as")}</span>
              <%!-- The owner defaults to the signed-in admin, never to whoever sorts
                    first in the user list (#1771): a key authenticates as its
                    owner, so minting for someone else must be a visible,
                    deliberate choice. --%>
              <select
                id="new-api-key-owner"
                name="user_id"
                required
                aria-describedby="new-api-key-owner-hint"
                class="w-full rounded border border-base-content/30 px-2 py-1.5 text-sm"
              >
                <option value="" disabled selected={!@actor_listed?}>
                  {gettext("Choose a user…")}
                </option>
                <option :for={user <- @users} value={user.id} selected={user.id == @actor.id}>
                  {owner_label(user, @actor)}
                </option>
              </select>
              <span id="new-api-key-owner-hint" class="mt-1 block text-xs text-base-content/60">
                {gettext(
                  "The key authenticates as this account and gets its role. It defaults to you; pick another user only to mint a key on their behalf."
                )}
              </span>
            </label>
            <label class="text-sm">
              <span class="mb-1 block font-medium">{gettext("Expires in")}</span>
              <select
                name="days"
                class="w-full rounded border border-base-content/30 px-2 py-1.5 text-sm"
              >
                <option :for={{label, days} <- @durations} value={days}>{label}</option>
              </select>
            </label>
            <label class="text-sm">
              <span class="mb-1 block font-medium">{gettext("Access")}</span>
              <select
                name="access"
                class="w-full rounded border border-base-content/30 px-2 py-1.5 text-sm"
              >
                <option value="read">{gettext("Read-only (delivery)")}</option>
                <option value="read_write">{gettext("Read + write (MCP authoring)")}</option>
                <option value="draft_write">{gettext("Drafts only (headless service)")}</option>
              </select>
            </label>
            <label class="text-sm">
              <span class="mb-1 block font-medium">{gettext("Self-rotation")}</span>
              <select
                id="new-api-key-rotation"
                name="rotate_days"
                aria-describedby="new-api-key-rotation-hint"
                class="w-full rounded border border-base-content/30 px-2 py-1.5 text-sm"
              >
                <option :for={{label, days} <- @rotation_windows} value={days}>{label}</option>
              </select>
              <span id="new-api-key-rotation-hint" class="mt-1 block text-xs text-base-content/60">
                {gettext(
                  "Drafts-only keys only. Until this date the service can swap the key for a fresh one itself; after it, mint a new key. Other scopes ignore it."
                )}
              </span>
            </label>
            <div class="flex items-end">
              <.button type="submit" variant="primary">{gettext("Create key")}</.button>
            </div>
          </form>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Keys")} ({length(@keys)})</h2>

          <.empty_state :if={@keys == []} icon="hero-key" title={gettext("No API keys yet")}>
            {gettext("Mint a key above to grant headless or MCP access.")}
          </.empty_state>

          <div :if={@keys != []} class="overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead>
                <tr class="border-b border-base-content/15 text-xs uppercase tracking-wide text-base-content/60">
                  <th class="py-2 pr-3">{gettext("Name")}</th>
                  <th class="py-2 pr-3">{gettext("User")}</th>
                  <th class="py-2 pr-3">{gettext("Access")}</th>
                  <th class="py-2 pr-3">{gettext("Status")}</th>
                  <th class="py-2 pr-3">{gettext("Expires")}</th>
                  <th class="py-2"></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-content/5">
                <tr :for={key <- @keys} id={"api-key-#{key.id}"}>
                  <td class="py-2 pr-3">
                    <span class="font-medium">{key.name}</span>
                    <span
                      :if={key.rotatable_until}
                      class="block text-xs text-base-content/60"
                    >
                      {gettext("Rotates itself until %{date}",
                        date: Calendar.strftime(key.rotatable_until, "%Y-%m-%d")
                      )}
                    </span>
                    <span
                      :if={key.rotated_from_id}
                      class="block text-xs text-base-content/60"
                      title={key.rotated_from_id}
                    >
                      {gettext("Rotated from %{id}", id: String.slice(key.rotated_from_id, 0, 8))}
                    </span>
                  </td>
                  <td class="py-2 pr-3 text-base-content/70">{key.user && key.user.email}</td>
                  <td class="py-2 pr-3">
                    <span class={[
                      "rounded px-1.5 py-0.5 text-xs font-medium",
                      key.access == :read_write && "bg-warning/15 text-warning-ink",
                      key.access != :read_write && "bg-base-200 text-base-content/70"
                    ]}>
                      {access_label(key.access)}
                    </span>
                  </td>
                  <td class="py-2 pr-3">
                    <% {kind, label} = status(key) %>
                    <span class={[
                      "rounded px-1.5 py-0.5 text-xs font-medium",
                      kind == :active && "bg-success/15 text-success-ink",
                      kind == :revoked && "bg-error/15 text-error-ink",
                      kind == :rotated && "bg-base-200 text-base-content/70",
                      kind == :expired && "bg-base-200 text-base-content/70"
                    ]}>
                      {label}
                    </span>
                  </td>
                  <td class="whitespace-nowrap py-2 pr-3 text-base-content/70">
                    {Calendar.strftime(key.expires_at, "%Y-%m-%d")}
                  </td>
                  <td class="py-2 text-right">
                    <button
                      :if={is_nil(key.revoked_at)}
                      type="button"
                      phx-click="revoke"
                      phx-value-id={key.id}
                      data-confirm={gettext("Revoke this key? Clients using it will stop working.")}
                      class="rounded px-2 py-1 text-xs text-base-content/60 hover:bg-base-200 hover:text-error"
                    >
                      {gettext("Revoke")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
