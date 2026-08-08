defmodule KilnCMSWeb.FeedSettingsLive do
  @moduledoc """
  Per-org syndication settings (#719): which of this site's content types appear
  in its feeds, and which of them carry the rendered body rather than a summary.

  Scoped to the request's org, like `/editor/branding` — you configure the site
  you are on. Writes are policy-gated to org admins by
  `KilnCMS.CMS.FeedSettings`, and this LiveView sits in the `:admin_routes` live
  session whose `:live_admin_required` hook gates on the same tier, so the
  router guard and the resource policy agree.

  ## Why the page is a per-type grid over a single row

  The stored shape is two name lists on one `FeedSettings` row, but nobody
  thinks in lists here — they think "does *this* type syndicate, and does it go
  out in full". So the page renders one row per content type and derives the
  lists on save. It also means the exclusion list can never name a type that
  does not exist, which is the failure mode a free-text list has.

  Full content is called out rather than presented as a peer toggle: it is the
  one with a disclosure consequence, and the admin turning it on should see that
  it hands the complete article to every subscriber before they do.

  ## Two layers, and the difference between "none" and "unset"

  Until this page is saved the site inherits `config :kiln_cms, :feeds` — the
  operator default — and the page says so. **Save** writes explicit lists for
  this org; **Use the operator defaults** drops the row entirely and goes back
  to inheriting. That distinction is real: an empty saved list means the admin
  said *none*, which is not the same as never having said anything, and
  collapsing them would let clearing full content fall back to a config that
  turns it on.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Feeds

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Feeds"))
     |> load_settings()}
  end

  @impl true
  def handle_event("save", params, socket) do
    names = Enum.map(socket.assigns.types, &to_string(&1.type))
    syndicate = checked(params, "syndicate")
    full_content = checked(params, "full_content")

    attrs = %{
      # Derived by subtraction from the types the *form* offered, so a type
      # added since this page loaded is not silently excluded by a stale save.
      excluded_types:
        carried(socket, :excluded_types, names) ++ Enum.reject(names, &(&1 in syndicate)),
      full_content_types:
        carried(socket, :full_content_types, names) ++ Enum.filter(names, &(&1 in full_content))
    }

    case CMS.save_feed_settings(attrs,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Feed settings saved."))
         |> load_settings()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("reset", _params, socket) do
    # Re-read rather than destroying the struct assigned at mount: a second tab
    # (or a second click — this is a plain button) may already have dropped it,
    # and `reset_feed_settings!/2` on a deleted row raises out of the handler
    # and takes the LiveView process with it, reloading the page with no
    # message. The sibling settings pages re-read for the same reason.
    case current_row(socket) do
      nil ->
        {:noreply, load_settings(socket)}

      row ->
        # A destroy answers `:ok`, not `{:ok, record}`.
        case CMS.reset_feed_settings(row,
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_org
             ) do
          {:error, error} ->
            {:noreply, socket |> put_flash(:error, error_message(error)) |> load_settings()}

          _destroyed ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Feed settings reset to the operator defaults."))
             |> load_settings()}
        end
    end
  end

  # Names the form did NOT offer, kept from what the row already said. A type
  # archived since the row was written is absent from the registry, so a plain
  # rebuild would quietly drop its name from `excluded_types` — and restoring
  # the type would then bring it back *syndicating*, reversing an explicit "not
  # in feeds" with no write to feed settings and nothing recording it.
  defp carried(socket, field, offered) do
    case socket.assigns.row do
      nil -> []
      row -> row |> Map.get(field) |> List.wrap() |> Enum.reject(&(&1 in offered))
    end
  end

  # Unchecked boxes are simply absent from the payload — each checkbox carries
  # its type name as its *value* rather than in its name, so no user-supplied
  # string ever becomes a param key. An all-unchecked form omits the key
  # entirely, which is a legitimate answer ("nothing syndicates"), not a missing
  # one.
  #
  # `params["feeds"]` is client-controlled and decoded from a query string, so
  # it is not necessarily a map: `feeds=x` decodes to a bare binary, and reading
  # a field off that would raise and crash the LiveView into a reconnect loop.
  defp checked(params, field) do
    case params do
      %{"feeds" => %{^field => names}} when is_list(names) -> Enum.filter(names, &is_binary/1)
      _absent -> []
    end
  end

  defp load_settings(socket) do
    org = socket.assigns.current_org
    row = current_row(socket)

    socket
    |> assign(:row, row)
    |> assign(:types, ContentTypes.all_for_org(org))
    # The *resolved* policy, so the boxes show what the site actually does today
    # whether that comes from this row or from the operator config beneath it —
    # derived from the row already in hand rather than through `Feeds.policy/1`,
    # which would read the same single row again (and always miss its cache on
    # the save path, since the save just busted it).
    |> assign(:policy, Feeds.for_row(row))
    |> assign(:defaults, Feeds.defaults())
    |> assign(:entry_limit, Feeds.entry_limit())
    # An empty form only to give `<.form>` a source; every input here is named
    # by hand because the two columns are checkbox *arrays*, not one field each.
    |> assign(:form, to_form(%{}, as: :feeds))
  end

  defp current_row(socket) do
    case CMS.list_feed_settings(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _other -> nil
    end
  end

  # The **exclusion list** only, deliberately not `Feeds.syndicated?/2`. That
  # predicate also requires a public index, so a dynamic type with the index off
  # would render unchecked and then be written into `excluded_types` on save —
  # silently staying out of the feeds after the admin later turned its index on.
  # This column says what this page owns; the index is `/editor/types`', and the
  # row says so in as many words.
  #
  # Argument order matches `Feeds.syndicated?/2` and `Feeds.full_content?/2`,
  # which the template calls directly beside it.
  defp included?(descriptor, policy), do: to_string(descriptor.type) not in policy.exclude

  # A dynamic type with no public index of published entries never syndicates,
  # whatever this page says — `/editor/types` owns that switch. The row stays
  # editable rather than disabled: a disabled checkbox submits nothing, so
  # saving would quietly drop the admin's choice the moment they turn the index
  # on.
  defp indexed?(descriptor), do: Map.get(descriptor, :published_feed?, false)

  defp source_label(%{source: :dynamic}), do: gettext("Custom")
  defp source_label(_descriptor), do: gettext("Built-in")

  defp error_message(error) do
    case error do
      %Ash.Error.Forbidden{} ->
        gettext("You don't have permission to change this site's feed settings.")

      _other ->
        error
        |> Ash.Error.to_error_class()
        |> Map.get(:errors, [])
        |> Enum.map_join(" ", &describe_error/1)
        |> case do
          "" -> gettext("Feed settings could not be saved.")
          message -> message
        end
    end
  end

  defp describe_error(%{message: message} = error) when is_binary(message) do
    Enum.reduce(Map.get(error, :vars, []), message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp describe_error(error), do: Exception.message(error)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:feeds}
    >
      <.header>
        {gettext("Feeds")}
        <:subtitle>
          {gettext(
            "Which of this site's content types appear in its Atom and JSON feeds, and how much of each entry they carry."
          )}
        </:subtitle>
      </.header>

      <div
        :if={is_nil(@row)}
        class="mt-6 rounded-lg border border-base-300 bg-base-200 p-4 text-sm"
      >
        <p class="font-medium">{gettext("This site is using the deployment defaults.")}</p>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "Nothing has been set for this site yet, so it follows whatever the operator configured for the whole deployment. Saving below gives this site its own settings."
          )}
        </p>
      </div>

      <!-- `<.form>` rather than a bare `<form>`, as every other settings page
           here uses. Note it does NOT make the form work before the socket
           connects: with no `action` it renders a plain GET form, so a click
           during the dead render reloads the page and the ticks are lost. That
           is true of every LiveView form in this app, and it is why the boxes
           render from server state rather than from anything pending. -->
      <.form for={@form} id="feed-settings-form" phx-submit="save" class="mt-8 space-y-8">
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th scope="col">{gettext("Content type")}</th>
                <th scope="col"><span class="sr-only">{gettext("Defined by")}</span></th>
                <th scope="col">{gettext("In feeds")}</th>
                <th scope="col">{gettext("Full content")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={type <- @types}>
                <td>
                  <span class="font-medium">{type.label}</span>
                  <span class="ml-2 font-mono text-xs text-base-content/50">{type.type}</span>
                  <p :if={not indexed?(type)} class="mt-1 text-xs text-warning-ink">
                    {gettext(
                      "No public index of published entries, so this type never syndicates. Turn that on in Content types first."
                    )}
                  </p>
                </td>
                <td class="text-xs text-base-content/60">{source_label(type)}</td>
                <td>
                  <input
                    type="checkbox"
                    name="feeds[syndicate][]"
                    value={to_string(type.type)}
                    checked={included?(type, @policy)}
                    class="size-4 rounded border border-base-content/30 accent-primary"
                    aria-label={gettext("Include %{type} in this site's feeds", type: type.label)}
                  />
                </td>
                <td>
                  <input
                    type="checkbox"
                    name="feeds[full_content][]"
                    value={to_string(type.type)}
                    checked={Feeds.full_content?(type, @policy)}
                    class="size-4 rounded border border-base-content/30 accent-primary"
                    aria-label={gettext("Syndicate the full body of every %{type}", type: type.label)}
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm text-warning-ink">
          <p class="font-medium">{gettext("Full content hands out the whole article.")}</p>
          <p class="mt-1">
            {gettext(
              "A feed is fetched by anonymous readers, aggregators and scrapers. With full content on, each of them receives the complete rendered body of every published entry of that type, not a summary. Turn it on for a type you are happy to have republished elsewhere — a newsletter built from the feed body is the usual reason."
            )}
          </p>
        </div>

        <div class="rounded-lg border border-base-300 p-4 text-sm">
          <p class="font-medium">{gettext("\"In feeds\" also covers the fediverse.")}</p>
          <p class="mt-1 text-base-content/70">
            {gettext(
              "A type you take out of this site's feeds also stops being announced over ActivityPub, and drops out of the site's outbox. If this site has followers on Mastodon or another fediverse server, they stop receiving new entries of that type."
            )}
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
          <button
            :if={@row}
            type="button"
            phx-click="reset"
            data-confirm={
              gettext("Remove this site's feed settings and follow the deployment defaults again?")
            }
            class="btn btn-ghost btn-sm"
          >
            {gettext("Use the operator defaults")}
          </button>
        </div>
      </.form>

      <section class="mt-10 rounded-lg bg-base-200 p-4 text-sm">
        <h2 class="font-medium">{gettext("Deployment defaults")}</h2>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "Set by the operator in configuration, and used by any site that has not saved its own settings above."
          )}
        </p>
        <dl class="mt-3 grid gap-2 sm:grid-cols-3">
          <div>
            <dt class="text-xs text-base-content/60">{gettext("Not in feeds")}</dt>
            <dd class="font-mono text-xs">{name_list(@defaults.exclude)}</dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/60">{gettext("Full content")}</dt>
            <dd class="font-mono text-xs">{name_list(@defaults.full_content)}</dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/60">{gettext("Entries per feed")}</dt>
            <dd class="font-mono text-xs">{@entry_limit}</dd>
          </div>
        </dl>
        <p class="mt-3 text-xs text-base-content/60">
          {gettext(
            "The entry limit is deployment-wide and not configurable per site: it bounds the work a feed request costs the server, rather than expressing a publishing choice."
          )}
        </p>
      </section>
    </Layouts.console>
    """
  end

  defp name_list([]), do: gettext("none")
  defp name_list(names), do: Enum.join(names, ", ")
end
