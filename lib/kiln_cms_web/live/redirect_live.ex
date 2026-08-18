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

  The **404s** tab (#472) is the other half: `CMS.MissedPath` counters for the
  paths delivery couldn't resolve, most-requested first, each with a one-click
  "create redirect" that drops the path into the form above. That pairing is
  what makes the page useful right after a migration — you see what actually
  broke instead of guessing. Creating a redirect for a listed path clears its
  counter, so the list is a work queue rather than an archive.
  """
  use KilnCMSWeb, :live_view

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.MissedPath
  alias KilnCMS.CMS.Redirect
  alias KilnCMS.CMS.Slugs
  alias KilnCMS.I18n

  # Bounded list; the search box narrows large tables (count shown when capped).
  @limit 500

  # The 404 table is capped by `MissedPath.max_paths/0`, but a page showing
  # every row of it would still be unreadable — the top slice is the work queue.
  @missed_limit 100

  @tabs ~w(redirects 404s)

  @impl true
  def mount(_params, _session, socket) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
      {:ok,
       socket
       |> assign(:actor, socket.assigns.current_user)
       |> assign(:page_title, gettext("Redirects"))
       |> assign(:search, "")
       |> assign(:tab, "redirects")
       |> assign(:missed_retention_days, MissedPath.retention_days())
       |> assign(:new, to_form(empty_new(), as: :redirect))
       |> load_redirects()
       |> load_missed()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  # The active tab lives in the URL so a "here's what's 404ing" link is
  # shareable and survives a refresh.
  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "redirects"
    {:noreply, assign(socket, :tab, tab)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) when is_binary(q) do
    {:noreply, socket |> assign(:search, q) |> load_redirects()}
  end

  # Prefill the form above with a 404'd path and send the admin to it. The
  # target still has to be chosen — Kiln redirects point at a *record*, so
  # there is nothing to guess.
  def handle_event("redirect_missed", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.missed, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That path is no longer listed."))}

      missed ->
        prefill = %{"path" => missed.path, "locale" => missed.locale, "slug" => ""}

        {:noreply,
         socket
         |> assign(:new, to_form(prefill, as: :redirect))
         |> push_patch(to: ~p"/editor/redirects")}
    end
  end

  def handle_event("dismiss_missed", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, delete_missed(socket, id, gettext("Removed from the 404 list."))}
  end

  def handle_event("create", %{"redirect" => params}, socket) when is_map(params) do
    case create_redirect(params, socket) do
      {:ok, path} ->
        {:noreply,
         socket
         |> assign(:new, to_form(empty_new(), as: :redirect))
         |> load_redirects()
         # The path now resolves, so its 404 counter is answered work — clear
         # it rather than leaving a fixed row in the queue.
         |> clear_missed(path, params["locale"] || I18n.default_locale())
         |> put_flash(:info, gettext("Redirect from %{path} created.", path: path))}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:new, to_form(params, as: :redirect))
         |> put_flash(:error, message)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) when is_binary(id) do
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
    |> assign(:targets, load_targets(redirects, socket))
  end

  defp filter_search(query, ""), do: query
  defp filter_search(query, q), do: Ash.Query.filter(query, contains(path, ^q))

  # Most-requested misses first (the `:top` read's sort) — the work queue.
  #
  # The total is counted separately rather than taken from `length(missed)`: the
  # list is a capped slice, so using it would report "100" for a table holding
  # 5000 — hiding exactly the backlog the tab exists to surface. One indexed
  # count against a table `MissedPath.max_paths/0` bounds is cheap.
  defp load_missed(socket) do
    opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]
    missed = CMS.list_missed_paths!(Keyword.put(opts, :query, limit: @missed_limit))

    socket
    |> assign(:missed, missed)
    |> assign(:missed_total, Ash.count!(MissedPath, opts))
  end

  defp delete_missed(socket, id, flash) do
    case destroy_missed(socket, id) do
      {:ok, socket} -> put_flash(socket, :info, flash)
      :error -> put_flash(socket, :error, gettext("Couldn't update the 404 list."))
    end
  end

  # Clear the counter a freshly-created redirect answers, if one was listed.
  # Best-effort and silent: the redirect is the point, its own flash says so,
  # and a surviving 404 row is harmless (it stops growing the moment the path
  # resolves).
  defp clear_missed(socket, path, locale) do
    case Enum.find(socket.assigns.missed, &(&1.path == path and &1.locale == locale)) do
      nil ->
        socket

      row ->
        case destroy_missed(socket, row.id) do
          {:ok, socket} -> socket
          :error -> socket
        end
    end
  end

  defp destroy_missed(socket, id) do
    actor = socket.assigns.actor
    org = socket.assigns.current_org

    with {:ok, row} <- CMS.get_missed_path(id, actor: actor, tenant: org),
         :ok <- CMS.destroy_missed_path(row, actor: actor, tenant: org) do
      {:ok, load_missed(socket)}
    else
      _ -> :error
    end
  end

  # Resolve every row's target in one read per content type: current path plus
  # whether it still resolves in delivery (published) — dead targets are the
  # prune candidates.
  #
  # Read as the acting user, not `authorize?: false` (#1309): the page is
  # admin-gated at mount, and `Checks.OrgAdmin` is that same tier, so the actor
  # read returns exactly what the bypass did — while a role revoked after mount
  # narrows to the policies instead of outliving the socket.
  defp load_targets(redirects, socket) do
    opts = [actor: socket.assigns.actor, tenant: socket.assigns.current_org]

    redirects
    |> Enum.group_by(& &1.target_type)
    |> Enum.flat_map(fn {type, rows} -> targets_for_type(type, rows, opts) end)
    |> Map.new()
  end

  defp targets_for_type(type, rows, opts) do
    case ContentTypes.get(type, opts[:tenant]) do
      nil ->
        Enum.map(rows, &{&1.id, nil})

      ct ->
        found = fetch_targets(ct, rows, opts)
        Enum.map(rows, &{&1.id, target_info(found[&1.target_id], ct)})
    end
  end

  defp fetch_targets(ct, rows, opts) do
    ids = rows |> Enum.map(& &1.target_id) |> Enum.uniq()

    Slugs.storage_resource(ct)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :slug, :state])
    |> Ash.read!(opts)
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
         {:ok, ct, record} <- find_target(params["type"], params["slug"], locale, socket),
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

  defp find_target(type, slug, locale, socket) do
    with ct when not is_nil(ct) <- ContentTypes.get(type, socket.assigns.current_org),
         slug when slug not in [nil, ""] <- slug && String.trim(slug),
         record when not is_nil(record) <- fetch_target(ct, slug, locale, socket) do
      {:ok, ct, record}
    else
      _ ->
        {:error,
         gettext("No %{type} with that slug and locale exists — check the target.", type: type)}
    end
  end

  # Any workflow state: a redirect at a draft target simply starts resolving
  # once the draft publishes.
  #
  # Actor read, not `authorize?: false` — same reasoning as `load_targets/2`
  # (and `MenuLive.fetch_target/3`): the admin bypass reads identically, and
  # nobody below admin reaches this handler.
  defp fetch_target(ct, slug, locale, socket) do
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

    Ash.read_one!(query, actor: socket.assigns.actor, tenant: socket.assigns.current_org)
  end

  defp not_self(path, ct, record) do
    if Slugs.public_path(ct, record.slug) == path,
      do: {:error, gettext("That path is already the target's own URL.")},
      else: :ok
  end

  defp empty_new, do: %{"path" => "", "locale" => I18n.default_locale(), "slug" => ""}

  # Module attributes aren't reachable from `~H` (`@limit` there means
  # `assigns.limit`), so the template reads this instead.
  defp limit, do: @limit

  defp tab_path("redirects"), do: ~p"/editor/redirects"
  defp tab_path(tab), do: ~p"/editor/redirects?#{[tab: tab]}"

  defp type_options(org), do: ContentTypes.options(org)

  defp locale_options, do: I18n.locales()

  defp stamp(nil), do: "—"
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

      <div class="mt-6 flex gap-2 border-b border-base-content/10" role="tablist">
        <.link
          :for={
            {tab, label} <- [
              {"redirects", gettext("Redirects")},
              {"404s", gettext("404s (%{count})", count: @missed_total)}
            ]
          }
          patch={tab_path(tab)}
          role="tab"
          aria-selected={to_string(@tab == tab)}
          class={[
            "-mb-px border-b-2 px-3 py-2 text-sm font-medium",
            (@tab == tab && "border-primary text-primary") ||
              "border-transparent text-base-content/60 hover:text-base-content"
          ]}
        >
          {label}
        </.link>
      </div>

      <div :if={@tab == "404s"}>
        <p class="mt-4 text-sm text-base-content/70">
          {gettext(
            "Paths visitors asked for that nothing on the site could serve, most-requested first. Counters only — no IPs, no user agents. Rows are dropped %{days} days after they were last hit, and common vulnerability probing — dotfiles, scanner roots, script and asset extensions — is filtered out before it is recorded.",
            days: @missed_retention_days
          )}
        </p>

        <.empty_state
          :if={@missed == []}
          icon="hero-magnifying-glass"
          title={gettext("No 404s recorded")}
        >
          {gettext("Nothing has asked for a URL this site can't serve.")}
        </.empty_state>

        <p :if={@missed_total > length(@missed)} class="mt-2 text-xs text-base-content/60">
          {gettext("Showing the %{count} most-requested of %{total}.",
            count: length(@missed),
            total: @missed_total
          )}
        </p>

        <div :if={@missed != []} class="mt-4 overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>{gettext("Path")}</th>
                <th>{gettext("Locale")}</th>
                <th>{gettext("Hits")}</th>
                <th>{gettext("First seen")}</th>
                <th>{gettext("Last seen")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={missed <- @missed}>
                <td class="font-mono text-xs">{missed.path}</td>
                <td>{missed.locale}</td>
                <td class="tabular-nums">{missed.count}</td>
                <td class="text-xs text-base-content/60">{stamp(missed.inserted_at)}</td>
                <td class="text-xs text-base-content/60">{stamp(missed.last_seen_at)}</td>
                <td class="text-right whitespace-nowrap">
                  <button
                    type="button"
                    phx-click="redirect_missed"
                    phx-value-id={missed.id}
                    class="btn btn-sm btn-default"
                  >
                    {gettext("Create redirect")} &rarr;
                  </button>
                  <button
                    type="button"
                    phx-click="dismiss_missed"
                    phx-value-id={missed.id}
                    data-confirm={
                      gettext("Remove this path from the list? It returns if it's hit again.")
                    }
                    aria-label={gettext("Remove from the 404 list")}
                    class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div :if={@tab == "redirects"} class="card card-pad mt-6">
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

      <div :if={@tab == "redirects"} class="mt-6 flex items-center justify-between gap-4">
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
          {gettext("Showing the %{count} most recent — narrow with the filter.", count: limit())}
        </p>
      </div>

      <.empty_state
        :if={@tab == "redirects" and @redirects == []}
        icon="hero-arrow-uturn-right"
        title={gettext("No redirects")}
      >
        {gettext("Renaming a published slug records one automatically.")}
      </.empty_state>

      <div :if={@tab == "redirects" and @redirects != []} class="mt-4 overflow-x-auto">
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
