defmodule KilnCMSWeb.SiteSearchLive do
  @moduledoc """
  A site's own Meilisearch instance (#1558): the URL, API key and index this
  site's published content is indexed into, at `/editor/site-search`.

  Before this, Meilisearch was `MEILI_*` environment variables — one instance
  for the whole deployment, changed by the operator with a redeploy. Now a site
  admin can index their site into their own instance with no redeploy. The
  operator's instance stays underneath, for every site that has not set one.

  Scoped to the request's org, like `/editor/site-mail`. Writes are
  policy-gated to org admins by `KilnCMS.CMS.SiteMeilisearch`, and the
  `:admin_routes` live session gates on the same tier.

  ## What the page has to say

    * **That the site's content leaves the deployment.** Saving sends every
      published document an anonymous visitor could read — full text included —
      to the URL in the form. The page says so above the form, not in a hint.
    * **Which instance is in use now.** The site's own, the deployment's, or
      none — the admin can't tell from the form.
    * **Where the reindex is.** Every save rebuilds the site into the instance
      it now uses; the page counts what is still waiting, and what is held
      waiting to retry, and refreshes while there is any.
    * **When the stored key can't be read.** After a `SECRET_KEY_BASE` rotation
      the row still looks fine, but indexing is held. This page is the one place
      that can say so.

  The API key field is write-only. It is never filled in, so a blank field
  keeps the stored key (`Changes.StoreMeilisearchKey`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.Search.Meilisearch
  alias KilnCMS.Search.Meilisearch.SiteInstance
  alias KilnCMS.Search.MeilisearchWorker

  @fields ~w(url index)
  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Search instance"))
     |> assign(:refresh_scheduled?, false)
     |> load()}
  end

  @impl true
  def handle_event("validate", %{"search" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, :form, to_form(params, as: :search))}
  end

  def handle_event("save", %{"search" => params}, socket) when is_map(params) do
    opts = [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

    # An existing row is updated, never re-upserted: the upsert leaves the key
    # out of what it overwrites (see `SiteMeilisearch`'s moduledoc).
    result =
      case socket.assigns.row do
        nil -> CMS.save_site_meilisearch(attrs(params), opts)
        row -> CMS.update_site_meilisearch(row, attrs(params), opts)
      end

    case result do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Search instance saved. Reindexing this site."))
         |> load()}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Map.delete(params, "api_key"), as: :search))
         |> put_flash(:error, error_message(error))}
    end
  end

  def handle_event("reindex", _params, socket) do
    %{row: row, current_user: user, current_org: org} = socket.assigns

    cond do
      is_nil(row) or not row.enabled ->
        {:noreply, socket}

      # Enqueueing checks nothing, so a forged event on a socket that never
      # passed the mount guard stops here (#1166).
      not CMS.can_update_site_meilisearch?(user, row, tenant: org) ->
        {:noreply, socket}

      true ->
        {:ok, _job} = MeilisearchWorker.enqueue_reindex(KilnCMS.Accounts.org_id(org))

        {:noreply,
         socket
         |> put_flash(:info, gettext("Reindexing this site."))
         |> load()}
    end
  end

  def handle_event("reset", _params, socket) do
    case socket.assigns.row do
      nil ->
        {:noreply, socket}

      row ->
        CMS.reset_site_meilisearch!(row,
          actor: socket.assigns.current_user,
          tenant: socket.assigns.current_org
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Removed. This site no longer uses its own instance."))
         |> load()}
    end
  end

  @impl true
  def handle_info(:refresh_progress, socket) do
    {:noreply, socket |> assign(:refresh_scheduled?, false) |> load()}
  end

  defp attrs(params) do
    params
    |> Map.take(@fields)
    |> Map.put("enabled", params["enabled"] in [true, "true", "on"])
    |> Map.put("api_key", params["api_key"])
  end

  defp load(socket) do
    row = current_row(socket)
    org_id = KilnCMS.Accounts.org_id(socket.assigns.current_org)

    params =
      if row do
        %{"enabled" => row.enabled, "url" => row.url, "index" => row.index}
      else
        %{"enabled" => true, "index" => "kiln_content"}
      end

    socket
    |> assign(:row, row)
    |> assign(:operator?, Meilisearch.enabled?())
    |> assign(:key_stored?, row && not is_nil(row.api_key_encrypted))
    |> assign(:key_readable?, is_nil(row) or SiteInstance.api_key_readable?(row))
    |> assign(:pending, MeilisearchWorker.pending(org_id))
    |> assign(:form, to_form(params, as: :search))
    |> schedule_refresh()
  end

  # Poll only while there is indexing work outstanding, and only one timer at a
  # time — `load/1` runs on every save and every tick.
  defp schedule_refresh(%{assigns: %{pending: %{queued: 0, held: 0}}} = socket), do: socket
  defp schedule_refresh(%{assigns: %{refresh_scheduled?: true}} = socket), do: socket

  defp schedule_refresh(socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh_progress, @refresh_ms)
      assign(socket, :refresh_scheduled?, true)
    else
      socket
    end
  end

  defp current_row(socket) do
    case CMS.list_site_meilisearch(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _ -> nil
    end
  end

  defp error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's search instance."),
      fallback: gettext("The search instance could not be saved.")
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      active={:site_search}
    >
      <.header>
        {gettext("Search instance")}
        <:subtitle>
          {gettext("The Meilisearch instance this site's published content is indexed into.")}
        </:subtitle>
      </.header>

      <div id="site-search-status" class="mt-6 card card-pad text-sm">
        <p class="font-medium">
          <%= cond do %>
            <% @row && @row.enabled -> %>
              {gettext("This site's content is indexed into %{url}, index %{index}.",
                url: @row.url,
                index: @row.index
              )}
            <% @operator? -> %>
              {gettext("This site's content is indexed into the deployment's Meilisearch instance.")}
            <% true -> %>
              {gettext(
                "This site doesn't use Meilisearch. Search uses the built-in search, which needs no setup."
              )}
          <% end %>
        </p>
        <p :if={@row && @row.enabled} id="site-search-progress" class="mt-1 text-base-content/70">
          <%= cond do %>
            <% @pending.held > 0 -> %>
              {ngettext(
                "%{count} indexing job is waiting to retry: the instance didn't answer, or refused it.",
                "%{count} indexing jobs are waiting to retry: the instance didn't answer, or refused them.",
                @pending.held
              )}
            <% @pending.queued > 0 -> %>
              {ngettext(
                "Indexing: %{count} job left.",
                "Indexing: %{count} jobs left.",
                @pending.queued
              )}
            <% true -> %>
              {gettext("Up to date.")}
          <% end %>
        </p>
      </div>

      <div
        id="site-search-disclosure"
        role="note"
        class="mt-4 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm text-warning-ink"
      >
        <p class="font-medium">
          {gettext("Saving this sends this site's content to the URL below.")}
        </p>
        <p class="mt-1">
          {gettext(
            "Every published page, post and entry that anyone can read without signing in is copied to that Meilisearch instance: its title, excerpt and full text. It is kept up to date as you publish, edit and unpublish. Members-only and passphrase-protected content is never sent. Whoever runs that instance can read everything in it."
          )}
        </p>
      </div>

      <div
        :if={not @key_readable?}
        id="site-search-key-unreadable"
        role="alert"
        class="mt-4 rounded-lg border border-error/40 bg-error/10 p-4 text-sm text-error-ink"
      >
        <p class="font-medium">{gettext("The saved API key can't be read. Re-enter it.")}</p>
        <p class="mt-1">
          {gettext(
            "The deployment's secret key has changed since it was saved. Until you enter it again, this site's indexing is held and retried, and search uses the built-in search."
          )}
        </p>
      </div>

      <.form
        for={@form}
        id="site-search-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-8 space-y-6"
      >
        <.input
          field={@form[:enabled]}
          type="checkbox"
          label={gettext("Index this site into this instance")}
          value={@form[:enabled].value}
        />

        <.input
          field={@form[:url]}
          type="url"
          label={gettext("Instance URL")}
          placeholder="https://search.example.com"
          autocomplete="off"
          hint={gettext("HTTPS only. Private and internal addresses are refused.")}
        />

        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={@form[:index]}
            type="text"
            label={gettext("Index")}
            autocomplete="off"
            hint={gettext("Letters, digits, hyphens and underscores.")}
          />
          <.input
            field={@form[:api_key]}
            type="password"
            label={gettext("API key")}
            value=""
            autocomplete="new-password"
            placeholder={if @key_stored?, do: gettext("Saved. Leave blank to keep it.")}
            hint={
              gettext(
                "A key that can write documents and settings to this index. Stored encrypted and never shown again."
              )
            }
          />
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
          <.button
            :if={@row && @row.enabled}
            type="button"
            variant="ghost"
            id="site-search-reindex"
            phx-click="reindex"
          >
            {gettext("Reindex now")}
          </.button>
          <.button
            :if={@row}
            type="button"
            variant="ghost"
            phx-click="reset"
            data-confirm={
              gettext(
                "Remove this site's instance? Nothing more is sent to it, and what is already there stays until you delete it."
              )
            }
          >
            {gettext("Remove")}
          </.button>
        </div>
      </.form>
    </Layouts.console>
    """
  end
end
