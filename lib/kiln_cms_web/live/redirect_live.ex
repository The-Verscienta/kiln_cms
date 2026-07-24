defmodule KilnCMSWeb.RedirectLive do
  @moduledoc """
  Admin management for pathauto redirects (issue #457): list every
  `CMS.Redirect` row with its live-resolved destination, prune stale ones, and
  create manual redirects (e.g. legacy URLs from a previous site) by pointing
  an arbitrary path at a content record — the destination stays current when
  that record's slug changes again.

  Rows whose target is unpublished or gone are badged as prune candidates:
  they no longer resolve in delivery. Admin-only (writes are policy-gated to
  org admins; automatic rows are written system-side on published renames).
  """
  use KilnCMSWeb, :live_view

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Redirect
  alias KilnCMS.CMS.Slugs
  alias KilnCMS.I18n

  # Bounded list; the search box narrows large tables (count shown when capped).
  @limit 500

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      {:ok,
       socket
       |> assign(:actor, socket.assigns.current_user)
       |> assign(:page_title, gettext("Redirects"))
       |> assign(:search, "")
       |> assign(:new, to_form(empty_new(), as: :redirect))
       |> load_redirects()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> load_redirects()}
  end

  def handle_event("create", %{"redirect" => params}, socket) do
    case create_redirect(params, socket) do
      {:ok, path} ->
        {:noreply,
         socket
         |> assign(:new, to_form(empty_new(), as: :redirect))
         |> load_redirects()
         |> put_flash(:info, gettext("Redirect from %{path} created.", path: path))}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:new, to_form(params, as: :redirect))
         |> put_flash(:error, message)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    socket =
      with {:ok, redirect} <- CMS.get_redirect(id, actor: actor, tenant: org),
           :ok <- CMS.destroy_redirect(redirect, actor: actor, tenant: org) do
        socket |> load_redirects() |> put_flash(:info, gettext("Redirect deleted."))
      else
        _ -> put_flash(socket, :error, gettext("Couldn't delete that redirect."))
      end

    {:noreply, socket}
  end

  # --- data ---

  defp load_redirects(socket) do
    query =
      Redirect
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@limit)
      |> filter_search(socket.assigns.search)

    redirects =
      Ash.read!(query, actor: socket.assigns.actor, tenant: socket.assigns.current_org)

    socket
    |> assign(:redirects, redirects)
    |> assign(:capped?, length(redirects) == @limit)
    |> assign(:targets, load_targets(redirects, socket.assigns.current_org))
  end

  defp filter_search(query, ""), do: query
  defp filter_search(query, q), do: Ash.Query.filter(query, contains(path, ^q))

  # Resolve every row's target in one read per content type: current path plus
  # whether it still resolves in delivery (published) — dead targets are the
  # prune candidates.
  defp load_targets(redirects, org) do
    redirects
    |> Enum.group_by(& &1.target_type)
    |> Enum.flat_map(fn {type, rows} -> targets_for_type(type, rows, org) end)
    |> Map.new()
  end

  defp targets_for_type(type, rows, org) do
    case ContentTypes.get(type, org_id(org)) do
      nil ->
        Enum.map(rows, &{&1.id, nil})

      ct ->
        found = fetch_targets(ct, rows, org)
        Enum.map(rows, &{&1.id, target_info(found[&1.target_id], ct)})
    end
  end

  defp fetch_targets(ct, rows, org) do
    ids = rows |> Enum.map(& &1.target_id) |> Enum.uniq()

    Slugs.storage_resource(ct)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :slug, :state])
    |> Ash.read!(authorize?: false, tenant: org)
    |> Map.new(&{&1.id, &1})
  end

  defp target_info(nil, _ct), do: nil

  defp target_info(record, ct),
    do: %{path: Slugs.public_path(ct, record.slug), live?: record.state == :published}

  # --- manual creation ---

  defp create_redirect(params, socket) do
    org = socket.assigns.current_org
    locale = params["locale"] || I18n.default_locale()

    with {:ok, path} <- normalize_path(params["path"]),
         {:ok, ct, record} <- find_target(params["type"], params["slug"], locale, org),
         :ok <- not_self(path, ct, record) do
      CMS.create_redirect!(
        %{path: path, locale: locale, target_type: to_string(ct.type), target_id: record.id},
        actor: socket.assigns.actor,
        tenant: org
      )

      {:ok, path}
    end
  end

  defp normalize_path(nil), do: {:error, gettext("Enter a path starting with /.")}

  defp normalize_path(path) do
    case String.trim(path) do
      "/" <> _ = trimmed -> {:ok, String.trim_trailing(trimmed, "/")}
      _ -> {:error, gettext("The path must start with /.")}
    end
  end

  defp find_target(type, slug, locale, org) do
    with ct when not is_nil(ct) <- ContentTypes.get(type, org_id(org)),
         slug when slug not in [nil, ""] <- slug && String.trim(slug),
         record when not is_nil(record) <- fetch_target(ct, slug, locale, org) do
      {:ok, ct, record}
    else
      _ ->
        {:error,
         gettext("No %{type} with that slug and locale exists — check the target.", type: type)}
    end
  end

  # Any workflow state: a redirect at a draft target simply starts resolving
  # once the draft publishes.
  defp fetch_target(ct, slug, locale, org) do
    query =
      Slugs.storage_resource(ct)
      |> Ash.Query.filter(slug == ^slug and locale == ^locale)
      |> Ash.Query.select([:id, :slug, :state])

    query =
      case ct do
        %{source: :dynamic, definition: definition} ->
          Ash.Query.filter(query, type_definition_id == ^definition.id)

        _compiled ->
          query
      end

    Ash.read_one!(query, authorize?: false, tenant: org)
  end

  defp not_self(path, ct, record) do
    if Slugs.public_path(ct, record.slug) == path,
      do: {:error, gettext("That path is already the target's own URL.")},
      else: :ok
  end

  defp empty_new, do: %{"path" => "", "locale" => I18n.default_locale(), "slug" => ""}

  defp org_id(nil), do: KilnCMS.Accounts.default_org_id()
  defp org_id(org), do: org.id

  defp type_options(org) do
    Enum.map(ContentTypes.all() ++ ContentTypes.dynamic_all(org_id(org)), fn ct ->
      {ct.label, to_string(ct.type)}
    end)
  end

  defp locale_options, do: I18n.locales()

  defp stamp(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:redirects}
    >
      <.header>
        {gettext("Redirects")}
        <:subtitle>
          {gettext(
            "301s from retired URLs. Rows appear automatically when a published slug is renamed; add manual ones for legacy paths. Destinations follow the target record's current URL."
          )}
        </:subtitle>
      </.header>

      <div class="card card-pad mt-6">
        <h2 class="text-sm font-medium">{gettext("Add a manual redirect")}</h2>
        <.form
          for={@new}
          id="new-redirect-form"
          phx-submit="create"
          class="mt-3 grid gap-3 sm:grid-cols-5"
        >
          <div class="sm:col-span-2">
            <.input
              field={@new[:path]}
              label={gettext("From path")}
              placeholder="/2019/05/old-post"
            />
          </div>
          <.input
            field={@new[:locale]}
            type="select"
            label={gettext("Locale")}
            options={locale_options()}
          />
          <.input
            field={@new[:type]}
            type="select"
            label={gettext("Target type")}
            options={type_options(@current_org)}
          />
          <.input field={@new[:slug]} label={gettext("Target slug")} placeholder="my-page" />
          <div class="sm:col-span-5">
            <.button variant="primary" size="sm">{gettext("Add redirect")}</.button>
            <span class="ml-2 text-xs text-base-content/60">
              {gettext("A draft target starts redirecting once it's published.")}
            </span>
          </div>
        </.form>
      </div>

      <div class="mt-6 flex items-center justify-between gap-4">
        <form id="redirect-search" phx-change="search" class="flex-1" onsubmit="return false;">
          <.input
            type="text"
            name="q"
            value={@search}
            placeholder={gettext("Filter by path…")}
            phx-debounce="300"
          />
        </form>
        <p :if={@capped?} class="text-xs text-base-content/60">
          {gettext("Showing the %{count} most recent — narrow with the filter.", count: @limit)}
        </p>
      </div>

      <.empty_state
        :if={@redirects == []}
        icon="hero-arrow-uturn-right"
        title={gettext("No redirects")}
      >
        {gettext("Renaming a published slug records one automatically.")}
      </.empty_state>

      <div :if={@redirects != []} class="mt-4 overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("From")}</th>
              <th>{gettext("Locale")}</th>
              <th>{gettext("To (current)")}</th>
              <th>{gettext("Updated")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={redirect <- @redirects}>
              <td class="font-mono text-xs">{redirect.path}</td>
              <td>{redirect.locale}</td>
              <td>
                <%= case @targets[redirect.id] do %>
                  <% %{path: path, live?: true} -> %>
                    <a href={path} target="_blank" rel="noopener" class="link font-mono text-xs">
                      {path}
                    </a>
                    <span class="ml-1 text-xs text-base-content/50">({redirect.target_type})</span>
                  <% %{path: path, live?: false} -> %>
                    <span class="font-mono text-xs">{path}</span>
                    <.badge variant="warning">{gettext("unpublished")}</.badge>
                  <% _ -> %>
                    <.badge variant="error">{gettext("target missing")}</.badge>
                <% end %>
              </td>
              <td class="text-xs text-base-content/60">{stamp(redirect.updated_at)}</td>
              <td class="text-right">
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={redirect.id}
                  data-confirm={gettext("Delete this redirect? The old URL will 404.")}
                  aria-label={gettext("Delete redirect")}
                  class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.console>
    """
  end
end
