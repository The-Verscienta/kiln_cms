defmodule KilnCMSWeb.BrandingLive do
  @moduledoc """
  White-label branding settings for the current site (#48): site name, logo,
  favicon, default social image, brand colour, and the footer attribution
  toggle.

  Scoped to the request's org — you brand the site you're currently on, the same
  way `/editor/team` manages the current site's members (multi-site admins switch
  org by host). Writes are policy-gated to org admins by
  `KilnCMS.CMS.SiteBranding`; this LiveView lives in the `:admin_routes` live
  session, whose `:live_admin_required` hook already gates on the *org* tier, so
  the router guard and the resource policy agree.

  Every field is optional. Clearing one falls back to the instance-wide
  `config :kiln_cms, :branding` and then to the stock KilnCMS defaults — see
  `KilnCMS.Branding` — so "reset to default" is just an empty input.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Branding
  alias KilnCMS.Branding.AppIcon
  alias KilnCMS.CMS

  @fields ~w(site_name logo_url favicon_url social_image_url app_icon_url brand_color show_attribution)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Branding"))
     |> load_branding()}
  end

  @impl true
  def handle_event("validate", %{"branding" => params}, socket) when is_map(params) do
    {:noreply, socket |> assign(:form, to_form(params, as: :branding)) |> assign_preview(params)}
  end

  def handle_event("save", %{"branding" => params}, socket) when is_map(params) do
    attrs = Map.new(@fields, fn field -> {field, blank_to_nil(params[field])} end)
    {icon_size, icon_problem} = measure_app_icon(attrs, socket.assigns.row)

    case CMS.save_site_branding(Map.put(attrs, "app_icon_size", icon_size),
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Branding saved."))
         |> flash_icon_problem(icon_problem)
         |> load_branding()}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :branding))
         |> put_flash(:error, error_message(error))}
    end
  end

  def handle_event("reset", _params, socket) do
    # Dropping the row restores the operator/stock defaults wholesale, which is
    # clearer than blanking six fields one at a time.
    case current_row(socket) do
      nil ->
        {:noreply, socket}

      row ->
        CMS.reset_site_branding!(row,
          actor: socket.assigns.current_user,
          tenant: socket.assigns.current_org
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Branding reset to the site defaults."))
         |> load_branding()}
    end
  end

  # `app_icon_size` is not an attribute — it is an argument the resource only
  # honours alongside the URL it measured (`KilnCMS.CMS.Changes.PairAppIcon`).
  # So this returns the measurement to pass along, and the resource is what
  # makes it impossible for a stale one to outlive its icon.
  #
  # Verification is a server-side fetch, so this blocks the LiveView for the
  # length of one bounded HTTP request (`AppIcon` caps it at 3s connect + 5s
  # receive for this reason). That is deliberate on an explicit Save: an admin
  # who pasted a 300px logo learns so in the same interaction, rather than
  # saving what looks like success and discovering weeks later that nobody can
  # install the app. The unchanged-URL short-circuit keeps it off every *other*
  # save.
  defp measure_app_icon(attrs, row) do
    url = attrs["app_icon_url"]

    cond do
      is_nil(url) ->
        {nil, nil}

      # Same URL, already measured — the bytes behind it could have changed, but
      # re-fetching on every unrelated branding save would make editing the site
      # name depend on a third-party CDN being up.
      row && row.app_icon_url == url && is_integer(row.app_icon_size) ->
        {row.app_icon_size, nil}

      true ->
        case AppIcon.verify(url) do
          {:ok, edge} -> {edge, nil}
          {:error, reason} -> {nil, reason}
        end
    end
  end

  # The URL is saved either way, so a transient CDN outage does not throw away
  # what the admin typed; only the *size* is withheld, which is what keeps the
  # unusable icon out of the manifest. The flash says which of the reasons it
  # was, because "invalid image" sends someone to re-export a fine file.
  defp flash_icon_problem(socket, nil), do: socket

  defp flash_icon_problem(socket, reason) do
    put_flash(
      socket,
      :error,
      gettext("The app icon was saved but isn't installable yet: %{reason}",
        reason: AppIcon.explain(reason)
      )
    )
  end

  defp load_branding(socket) do
    row = current_row(socket)

    params =
      Map.new(@fields, fn field ->
        {field, (row && Map.get(row, String.to_existing_atom(field))) || default_for(field, row)}
      end)

    socket
    |> assign(:row, row)
    |> assign(:form, to_form(params, as: :branding))
    |> assign_preview(params)
  end

  # `show_attribution` is a boolean with a real default; the string fields
  # legitimately render blank so the placeholder can show the inherited value.
  defp default_for("show_attribution", nil), do: true
  defp default_for("show_attribution", row), do: row.show_attribution
  defp default_for(_field, _row), do: nil

  defp current_row(socket) do
    case CMS.list_site_branding(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _ -> nil
    end
  end

  # A live preview of the derived tokens, so an admin sees the dark-mode variant
  # and the button ink BEFORE saving — the whole point of deriving them.
  defp assign_preview(socket, params) do
    case KilnCMS.Branding.Color.derive(
           KilnCMS.CMS.Validations.BrandTokens.normalize_color(params["brand_color"]) || ""
         ) do
      {:ok, color} -> assign(socket, :preview, color)
      :error -> assign(socket, :preview, nil)
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp error_message(error) do
    case error do
      %Ash.Error.Forbidden{} ->
        gettext("You don't have permission to change this site's branding.")

      _ ->
        error
        |> Ash.Error.to_error_class()
        |> Map.get(:errors, [])
        |> Enum.map_join(" ", &describe_error/1)
        |> case do
          "" -> gettext("Branding could not be saved.")
          message -> message
        end
    end
  end

  defp describe_error(%{field: field, message: message}) when not is_nil(field),
    do: "#{field}: #{message}"

  defp describe_error(%{message: message}) when is_binary(message), do: message
  defp describe_error(error), do: Exception.message(error)

  # The values in force right now, used as input placeholders so an admin can
  # see what a blank field will inherit.
  defp inherited(socket_org), do: Branding.for_org(socket_org)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :inherited, inherited(assigns.current_org))

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:branding}
    >
      <.header>
        {gettext("Branding")}
        <:subtitle>
          {gettext(
            "White-label this site: its name, logo and brand colour appear on the public pages, the editor, and the sign-in screen. Leave a field blank to inherit the server default."
          )}
        </:subtitle>
      </.header>

      <.form
        for={@form}
        id="branding-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-6 grid gap-6 lg:grid-cols-3"
      >
        <div class="card card-pad lg:col-span-2 space-y-4">
          <h2 class="text-sm font-medium">{gettext("Identity")}</h2>

          <.input
            field={@form[:site_name]}
            label={gettext("Site name")}
            placeholder={@inherited.site_name}
            hint={gettext("Shown in the header, the page title, and sign-in emails.")}
          />

          <.input
            field={@form[:logo_url]}
            label={gettext("Logo URL")}
            placeholder={@inherited.logo_url}
            hint={
              gettext(
                "A path from the media library (/uploads/…), or an https:// URL on an allowed host."
              )
            }
          />

          <.input
            field={@form[:favicon_url]}
            label={gettext("Favicon URL")}
            placeholder={@inherited.favicon_url}
          />

          <.input
            field={@form[:social_image_url]}
            label={gettext("Default social image URL")}
            hint={gettext("Used for link previews when a page has no image of its own.")}
          />

          <.input
            field={@form[:app_icon_url]}
            label={gettext("App icon URL")}
            hint={
              gettext(
                "The icon for the installed editor app on a phone home screen. Must be a square PNG or JPEG of at least %{min}×%{min} pixels — it is checked on save, and the stock mark is used until it passes.",
                min: AppIcon.min_edge()
              )
            }
          />

          <.input
            field={@form[:show_attribution]}
            type="checkbox"
            label={gettext("Show the \"Powered by\" line in the public footer")}
          />
        </div>

        <div class="card card-pad space-y-4">
          <h2 class="text-sm font-medium">{gettext("Brand colour")}</h2>

          <%!-- Text, not type="color": an empty native colour input reports
                #000000, so a site that never picked a colour would silently save
                black. A blank text field stays blank, i.e. "inherit". --%>
          <.input
            field={@form[:brand_color]}
            label={gettext("Primary colour")}
            placeholder="#1d4ed8"
            hint={
              gettext(
                "The light and dark variants, and the text colour on buttons, are derived from this so they always meet WCAG AA."
              )
            }
          />

          <div :if={@preview} class="space-y-2">
            <p class="text-xs text-base-content/70">{gettext("Derived tokens")}</p>

            <div class="flex items-center gap-2">
              <span
                class="inline-flex items-center rounded-md px-3 py-1.5 text-xs font-semibold"
                style={"background-color:#{@preview.light_primary};color:#{@preview.light_content}"}
              >
                {gettext("Light")}
              </span>
              <span
                class="inline-flex items-center rounded-md px-3 py-1.5 text-xs font-semibold"
                style={"background-color:#{@preview.dark_primary};color:#{@preview.dark_content}"}
              >
                {gettext("Dark")}
              </span>
            </div>
          </div>

          <p :if={@form[:brand_color].value not in [nil, ""] and !@preview} class="text-xs text-error">
            {gettext("That colour has no readable button text — pick a different one.")}
          </p>
        </div>

        <div class="lg:col-span-3 flex items-center gap-3">
          <.button type="submit" variant="primary">{gettext("Save branding")}</.button>
          <.button
            :if={@row}
            type="button"
            phx-click="reset"
            data-confirm={gettext("Reset this site to the default branding?")}
          >
            {gettext("Reset to defaults")}
          </.button>
        </div>
      </.form>
    </Layouts.console>
    """
  end
end
