defmodule KilnCMSWeb.SitePushLive do
  @moduledoc """
  A site's own Web Push key (#1560), at `/editor/site-push`.

  Before this, push was signed with one VAPID key pair from `KILN_VAPID_*`: off
  until the operator generated keys and redeployed, and one identity with the
  push services for every site. Now a site admin presses *Generate* and the
  site has its own pair, as the DKIM key is generated on `/editor/mail`. There
  is no key to paste, and the private half is never shown.

  Scoped to the request's org. Writes are policy-gated to org admins by
  `KilnCMS.CMS.SiteVapidKey`, and the `:admin_routes` live session gates on
  the same tier.

  ## What the page has to say

    * **Which key new subscriptions use** — this site's, the deployment's, or
      none (push is off here).
    * **That existing subscriptions keep their key.** Devices subscribed with
      the deployment's key keep receiving notifications after *Generate*; only
      new subscriptions use the site's key (`KilnCMS.Push.Keys`).
    * **What rotating costs, before it happens.** A rotation deletes every
      subscription made against the old key, so each of those devices has to
      turn notifications on again. The button's confirmation names the count.
    * **When the private key can't be read.** After a `SECRET_KEY_BASE`
      rotation the row still looks fine, but the site's pushes are held.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Push.Keys
  alias KilnCMS.Push.Vapid

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Push notifications"))
     |> load()}
  end

  @impl true
  def handle_event("generate", _params, socket) do
    case CMS.generate_site_vapid_key(%{}, opts(socket)) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Key generated. New devices on this site use it."))
         |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("save_subject", %{"push" => %{"subject" => subject}}, socket)
      when is_binary(subject) do
    case socket.assigns.row do
      nil ->
        {:noreply, socket}

      row ->
        case CMS.update_site_vapid_key(row, %{subject: subject}, opts(socket)) do
          {:ok, _row} ->
            {:noreply, socket |> put_flash(:info, gettext("Contact saved.")) |> load()}

          {:error, error} ->
            {:noreply,
             socket
             |> assign(:form, to_form(%{"subject" => subject}, as: :push))
             |> put_flash(:error, error_message(error))}
        end
    end
  end

  def handle_event("rotate", _params, socket) do
    case socket.assigns.row do
      %{public_key: key} = row when is_binary(key) ->
        case CMS.rotate_site_vapid_key(row, opts(socket)) do
          {:ok, _row} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext(
                 "Key rotated. Devices that used the old key have to turn notifications on again."
               )
             )
             |> load()}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, error_message(error))}
        end

      _no_key ->
        {:noreply, socket}
    end
  end

  defp opts(socket), do: [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

  defp load(socket) do
    row = current_row(socket)
    has_key? = match?(%{public_key: key} when is_binary(key), row)

    socket
    |> assign(:row, row)
    |> assign(:has_key?, has_key?)
    |> assign(:key_readable?, not has_key? or Keys.private_key_readable?(row))
    |> assign(:deployment_key?, Vapid.configured?())
    |> assign(:bound_count, bound_count(socket, row))
    |> assign(:form, to_form(%{"subject" => row && row.subject}, as: :push))
  end

  defp current_row(socket) do
    case CMS.list_site_vapid_key(opts(socket)) do
      {:ok, [row | _rest]} -> row
      _ -> nil
    end
  end

  # How many devices a rotation would cut off. A system read: the rows belong
  # to the reviewers, not to the admin looking at this page, and only the count
  # leaves this function.
  defp bound_count(socket, %{public_key: key}) when is_binary(key) do
    socket.assigns.current_org
    |> Accounts.org_id()
    |> Accounts.push_subscriptions_bound_to_key!(key, authorize?: false)
    |> length()
  end

  defp bound_count(_socket, _row), do: 0

  defp error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's push key."),
      fallback: gettext("The push key could not be saved.")
    )
  end

  defp rotate_confirmation(0),
    do:
      gettext(
        "Rotate this site's push key? No devices use the current one, so nothing stops working."
      )

  defp rotate_confirmation(count),
    do:
      ngettext(
        "Rotate this site's push key? 1 device stops receiving notifications until it turns them on again in Your settings.",
        "Rotate this site's push key? %{count} devices stop receiving notifications until each turns them on again in Your settings.",
        count
      )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      active={:site_push}
    >
      <.header>
        {gettext("Push notifications")}
        <:subtitle>
          {gettext("The key this site's review notifications are signed with.")}
        </:subtitle>
      </.header>

      <div id="site-push-status" class="mt-6 card card-pad text-sm">
        <p class="font-medium">
          <%= cond do %>
            <% @has_key? -> %>
              {gettext("New devices on this site subscribe with this site's own key.")}
            <% @deployment_key? -> %>
              {gettext("This site uses the deployment's push key.")}
            <% true -> %>
              {gettext("Push notifications are off on this site: it has no key yet.")}
          <% end %>
        </p>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "Reviewers turn notifications on for each device in Your settings. A device stays on the key it subscribed with, so devices that subscribed with the deployment's key keep receiving notifications after this site generates its own."
          )}
        </p>
      </div>

      <div
        :if={not @key_readable?}
        id="site-push-key-unreadable"
        role="alert"
        class="mt-4 rounded-lg border border-error/40 bg-error/10 p-4 text-sm text-error-ink"
      >
        <p class="font-medium">{gettext("The saved private key can't be read. Rotate it.")}</p>
        <p class="mt-1">
          {gettext(
            "The deployment's secret key has changed since it was generated. Until you rotate it, this site's notifications are held, not sent."
          )}
        </p>
      </div>

      <section :if={not @has_key?} class="mt-8 card card-pad max-w-xl">
        <h2 class="text-lg font-medium">{gettext("Generate a key")}</h2>
        <p class="mt-1 text-sm text-base-content/70">
          {gettext(
            "A key pair for this site alone. The private half is stored encrypted and never shown. Nothing to copy or paste."
          )}
        </p>
        <.button
          type="button"
          id="site-push-generate"
          phx-click="generate"
          variant="primary"
          class="mt-4"
        >
          {gettext("Generate key")}
        </.button>
      </section>

      <section :if={@has_key?} class="mt-8 card card-pad max-w-xl space-y-6">
        <div>
          <h2 class="text-lg font-medium">{gettext("This site's key")}</h2>
          <p class="mt-1 text-sm text-base-content/70">
            {ngettext(
              "1 device is subscribed with it.",
              "%{count} devices are subscribed with it.",
              @bound_count
            )}
          </p>
          <code
            id="site-push-public-key"
            class="mt-3 block break-all rounded bg-base-200 px-3 py-2 font-mono text-xs"
          >
            {@row.public_key}
          </code>
        </div>

        <.form for={@form} id="site-push-subject-form" phx-submit="save_subject" class="space-y-3">
          <.input
            field={@form[:subject]}
            type="text"
            label={gettext("Contact for push services")}
            placeholder="mailto:admin@example.com"
            hint={
              gettext(
                "A mailto: address or https:// URL the push services can reach you at. Leave blank to use your own address."
              )
            }
          />
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
        </.form>

        <div class="border-t border-base-content/10 pt-4">
          <h3 class="text-sm font-medium">{gettext("Rotate the key")}</h3>
          <p class="mt-1 text-sm text-base-content/70">
            {gettext(
              "Replaces the key pair. Every device subscribed with the current key is removed, and has to turn notifications on again."
            )}
          </p>
          <.button
            type="button"
            id="site-push-rotate"
            phx-click="rotate"
            variant="danger"
            class="mt-3"
            data-confirm={rotate_confirmation(@bound_count)}
          >
            {gettext("Rotate key")}
          </.button>
        </div>
      </section>
    </Layouts.console>
    """
  end
end
