defmodule KilnCMSWeb.ApiKeyLive do
  @moduledoc """
  API keys (`/editor/api-keys`) — mint and revoke keys for headless / third-party
  **read** access to the delivery API. Admin-only, mirroring the `ApiKey` policy.

  A key authenticates as its owning user, inheriting that user's read scope; keys
  can never mutate content. The plaintext key is shown **once**, right after
  minting — it's only stored hashed, so it can't be retrieved again.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts

  # Offered key lifetimes (days). Keys always expire — no immortal credentials.
  @durations [{"30 days", 30}, {"90 days", 90}, {"1 year", 365}]

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if actor.role == :admin do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:page_title, gettext("API keys"))
       |> assign(:durations, @durations)
       |> assign(:users, Accounts.list_users!(actor: actor))
       |> assign(:new_key, nil)
       |> load_keys()}
    else
      # Defense-in-depth: the `:live_admin_required` on_mount guard already
      # bounces non-admins before mount; mirror its flash for consistency.
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("mint", %{"user_id" => user_id, "name" => name, "days" => days}, socket) do
    actor = socket.assigns.actor
    expires_at = DateTime.add(DateTime.utc_now(), duration_days(days), :day)

    case Accounts.mint_api_key(user_id, String.trim(name), expires_at, actor: actor) do
      {:ok, key} ->
        {:noreply,
         socket
         |> assign(:new_key, Ash.Resource.get_metadata(key, :plaintext_api_key))
         |> load_keys()
         |> put_flash(:info, gettext("API key created — copy it now, it won't be shown again."))}

      {:error, _error} ->
        {:noreply,
         put_flash(socket, :error, gettext("Couldn't create that key. Give it a name."))}
    end
  end

  def handle_event("dismiss_new_key", _params, socket),
    do: {:noreply, assign(socket, :new_key, nil)}

  def handle_event("revoke", %{"id" => id}, socket) do
    actor = socket.assigns.actor

    socket =
      with {:ok, key} <- Accounts.get_api_key(id, actor: actor),
           {:ok, _} <- Accounts.revoke_api_key(key, actor: actor) do
        socket |> load_keys() |> put_flash(:info, gettext("Key revoked."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't revoke that key."))
      end

    {:noreply, socket}
  end

  defp load_keys(socket) do
    keys =
      Accounts.list_all_api_keys!(
        actor: socket.assigns.actor,
        load: [:user, :valid],
        query: [sort: [created_at: :desc]]
      )

    assign(socket, :keys, keys)
  end

  defp duration_days(days) do
    case Integer.parse(to_string(days)) do
      {n, _} when n in [30, 90, 365] -> n
      _ -> 30
    end
  end

  defp status(%{revoked_at: at}) when not is_nil(at), do: {:revoked, gettext("Revoked")}
  defp status(%{valid: true}), do: {:active, gettext("Active")}
  defp status(_), do: {:expired, gettext("Expired")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_user={@current_user}>
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("API keys")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Grant headless / third-party read access to the delivery API. A key acts as its owning user and can never modify content. For public-only access, mint a key on a viewer account."
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
              <span class="mb-1 block font-medium">{gettext("User")}</span>
              <select
                name="user_id"
                required
                class="w-full rounded border border-base-content/30 px-2 py-1.5 text-sm"
              >
                <option :for={user <- @users} value={user.id}>
                  {user.email} ({user.role})
                </option>
              </select>
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
            <div class="flex items-end">
              <.button type="submit" variant="primary">{gettext("Create key")}</.button>
            </div>
          </form>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-medium">{gettext("Keys")} ({length(@keys)})</h2>

          <p :if={@keys == []} class="text-sm text-base-content/60">
            {gettext("No API keys yet.")}
          </p>

          <div :if={@keys != []} class="overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead>
                <tr class="border-b border-base-content/15 text-xs uppercase tracking-wide text-base-content/60">
                  <th class="py-2 pr-3">{gettext("Name")}</th>
                  <th class="py-2 pr-3">{gettext("User")}</th>
                  <th class="py-2 pr-3">{gettext("Status")}</th>
                  <th class="py-2 pr-3">{gettext("Expires")}</th>
                  <th class="py-2"></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-content/5">
                <tr :for={key <- @keys} id={"api-key-#{key.id}"}>
                  <td class="py-2 pr-3 font-medium">{key.name}</td>
                  <td class="py-2 pr-3 text-base-content/70">{key.user && key.user.email}</td>
                  <td class="py-2 pr-3">
                    <% {kind, label} = status(key) %>
                    <span class={[
                      "rounded px-1.5 py-0.5 text-xs font-medium",
                      kind == :active && "bg-success/15 text-success",
                      kind == :revoked && "bg-error/15 text-error",
                      kind == :expired && "bg-base-200 text-base-content/60"
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
    </Layouts.app>
    """
  end
end
