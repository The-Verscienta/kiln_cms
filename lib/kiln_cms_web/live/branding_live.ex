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

  ## Images (#1811)

  Each image field keeps its URL box (for an image hosted elsewhere) and adds
  two shortcuts: **Choose from library**, which opens the content editor's
  image drawer (`KilnCMSWeb.ContentEditor.MediaPickerComponents.image_picker/1`)
  over this site's images, and **Upload**, which sends the file through the
  media library's own pipeline (`KilnCMS.Media.Ingest.store_file/3`) under the
  admin's actor and site — so the upload is a normal library item, stripped
  and stored like any other. Both only fill the box; Save is still what writes
  the branding, and `KilnCMS.CMS.Validations.BrandTokens` still judges the URL.

  Each field narrows the formats it offers: a favicon is a PNG, an app icon a
  PNG or JPEG (what `KilnCMS.Branding.AppIcon` accepts). The narrowing is
  checked again on the stored item's *sniffed* type, since a file's extension
  is only a claim.

  ## Saving reloads the page (#1810)

  The brand colour, logo, favicon and site name are rendered by the root
  layout (`KilnCMSWeb.Layouts.brand_tokens/1` in `root.html.heex`), which a
  LiveView never re-renders. A successful save or reset therefore ends in a
  full `redirect/2` back to this page, so the console the admin is looking at
  picks up the new colour at once instead of after a manual refresh.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Branding
  alias KilnCMS.Branding.AppIcon
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Validations.BrandTokens
  alias KilnCMS.Media.Ingest

  import Ash.Expr, only: [expr: 1]
  import KilnCMSWeb.ContentEditor.MediaPickerComponents, only: [image_picker: 1]

  @fields ~w(site_name logo_url favicon_url social_image_url app_icon_url brand_color show_attribution theme header_menu_key footer_menu_key)

  # The image fields: form field, upload name, the extensions the file chooser
  # offers, and the sniffed content types a library item must have to fill it.
  @web_images ~w(image/png image/jpeg image/webp image/gif)
  @image_fields [
    {"logo_url", :logo_upload, ~w(.png .jpg .jpeg .webp .gif), @web_images},
    {"favicon_url", :favicon_upload, ~w(.png), ~w(image/png)},
    {"social_image_url", :social_image_upload, ~w(.png .jpg .jpeg .webp .gif), @web_images},
    {"app_icon_url", :app_icon_upload, ~w(.png .jpg .jpeg), ~w(image/png image/jpeg)}
  ]
  @image_field_names Enum.map(@image_fields, &elem(&1, 0))
  @upload_names Enum.map(@image_fields, &Atom.to_string(elem(&1, 1)))
  # The library drawer lists at most this many of the newest images; its
  # search reaches the rest.
  @max_media 200

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Branding"))
      |> assign(:menu_options, menu_options(socket))
      # The library drawer: `picking` is the field it fills (nil = closed).
      |> assign(:picking, nil)
      |> assign(:picker_media, [])
      |> assign(:picker_results, nil)
      |> assign(:media_query, "")
      |> load_branding()

    socket =
      Enum.reduce(@image_fields, socket, fn {_field, upload, accept, _types}, acc ->
        allow_upload(acc, upload,
          accept: accept,
          max_entries: 1,
          max_file_size: Ingest.max_image_size(),
          auto_upload: true,
          progress: &handle_upload_progress/3
        )
      end)

    {:ok, socket}
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
      # A full reload, not a re-render: the colour, logo and favicon live in
      # the root layout, which only a fresh page load re-renders (#1810).
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Branding saved."))
         |> flash_icon_problem(icon_problem)
         |> redirect(to: ~p"/editor/branding")}

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
         |> redirect(to: ~p"/editor/branding")}
    end
  end

  # --- images: library drawer and upload (#1811) ------------------------------

  def handle_event("open_picker", %{"field" => field}, socket)
      when field in @image_field_names do
    {:noreply,
     socket
     |> assign(:picking, field)
     |> assign(:media_query, "")
     |> assign(:picker_results, nil)
     |> assign(:picker_media, list_images(socket, field, nil))}
  end

  def handle_event("close_picker", _params, socket), do: {:noreply, close_picker(socket)}

  def handle_event("search_media", %{"q" => q}, socket) when is_binary(q) do
    case socket.assigns.picking do
      nil ->
        {:noreply, socket}

      field ->
        results = if q == "", do: nil, else: list_images(socket, field, q)
        {:noreply, socket |> assign(:media_query, q) |> assign(:picker_results, results)}
    end
  end

  # Resolved by id under the admin's actor, never from the `url` the button
  # also carries: that value is the client's to change, while the stored
  # item's own url and sniffed type are what the field may hold.
  def handle_event("pick_image", %{"id" => id}, socket) when is_binary(id) do
    case socket.assigns.picking do
      nil ->
        {:noreply, socket}

      field ->
        case CMS.get_media_item(id,
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_org
             ) do
          {:ok, item} ->
            {:noreply, socket |> close_picker() |> fill_image(field, item)}

          _ ->
            {:noreply,
             socket
             |> close_picker()
             |> put_flash(:error, gettext("That image is no longer in the media library."))}
        end
    end
  end

  def handle_event("clear_image", %{"field" => field}, socket)
      when field in @image_field_names do
    {:noreply, put_param(socket, field, nil)}
  end

  def handle_event("cancel_upload", %{"upload" => upload, "ref" => ref}, socket)
      when upload in @upload_names and is_binary(ref) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(upload), ref)}
  end

  # `auto_upload: true` fires this on every progress tick; the work happens
  # once the bytes are all here. The file goes through the media library's own
  # pipeline under this admin and site, so it lands in the library as a normal
  # item — and the media policies decide whether it may.
  defp handle_upload_progress(_name, %{done?: false}, socket), do: {:noreply, socket}

  defp handle_upload_progress(name, entry, socket) do
    {field, _upload, _accept, _types} = List.keyfind(@image_fields, name, 1)

    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok,
         Ingest.store_file(path, entry.client_name,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         )}
      end)

    case result do
      {:ok, item} ->
        {:noreply, fill_image(socket, field, item)}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Couldn't upload %{name}: %{reason}",
             name: entry.client_name,
             reason: ingest_failure_reason(reason)
           )
         )}
    end
  end

  # Fill `field` from a library item if the item's sniffed type suits it — a
  # JPEG renamed `.png` is still a JPEG, and a favicon must really be a PNG.
  defp fill_image(socket, field, item) do
    if item.content_type in image_types(field) do
      put_param(socket, field, item.url)
    else
      put_flash(socket, :error, wrong_type_message(field))
    end
  end

  defp put_param(socket, field, value) do
    params = Map.put(socket.assigns.form.params, field, value)
    socket |> assign(:form, to_form(params, as: :branding)) |> assign_preview(params)
  end

  defp close_picker(socket) do
    socket
    |> assign(:picking, nil)
    |> assign(:picker_media, [])
    |> assign(:picker_results, nil)
    |> assign(:media_query, "")
  end

  # This site's images in the formats `field` takes, newest first, read as the
  # admin (so the media policies apply), optionally narrowed by a search.
  defp list_images(socket, field, query) do
    types = image_types(field)

    filter =
      case query do
        nil ->
          expr(content_type in ^types)

        q ->
          pattern = "%" <> String.replace(q, ~r/([\\%_])/, "\\\\\\1") <> "%"

          expr(
            content_type in ^types and
              (ilike(filename, ^pattern) or ilike(alt, ^pattern) or ilike(caption, ^pattern))
          )
      end

    case CMS.list_media_items(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org,
           query: [
             filter: filter,
             select: [:id, :url, :alt, :caption, :filename, :content_type],
             sort: [inserted_at: :desc],
             limit: @max_media
           ]
         ) do
      {:ok, items} -> items
      _ -> []
    end
  end

  defp image_types(field) do
    {_field, _upload, _accept, types} = List.keyfind(@image_fields, field, 0)
    types
  end

  defp picker_title("logo_url"), do: gettext("Choose a logo")
  defp picker_title("favicon_url"), do: gettext("Choose a favicon")
  defp picker_title("social_image_url"), do: gettext("Choose a social image")
  defp picker_title("app_icon_url"), do: gettext("Choose an app icon")

  defp wrong_type_message("favicon_url"), do: gettext("The favicon must be a PNG image.")

  defp wrong_type_message("app_icon_url"),
    do: gettext("The app icon must be a PNG or JPEG image.")

  defp wrong_type_message(_field),
    do: gettext("That file can't be used here. Choose a PNG, JPEG, WebP or GIF image.")

  # The same vocabulary the media library and the content editor use.
  defp ingest_failure_reason(:too_many_pixels), do: gettext("image dimensions are too large")
  defp ingest_failure_reason(:unsupported_format), do: gettext("unsupported file format")
  defp ingest_failure_reason(:too_large), do: gettext("file is too large for its type")
  defp ingest_failure_reason(:storage_failed), do: gettext("couldn't be stored")
  defp ingest_failure_reason(:create_failed), do: gettext("couldn't be saved")

  defp ingest_failure_reason({:site_storage, _reason}),
    do:
      gettext(
        "wasn't stored — this site's own object storage can't be used right now. An admin can check it under Integrations → Object storage."
      )

  defp ingest_failure_reason(_other), do: gettext("upload failed")

  defp upload_error_text(:too_large),
    do: gettext("too large (max %{mb} MB)", mb: div(Ingest.max_image_size(), 1_000_000))

  defp upload_error_text(:not_accepted), do: gettext("this file type can't be used here")
  defp upload_error_text(_other), do: gettext("upload failed")

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

  # Shared with the other settings pages (#1080) — this copy used to render
  # `"field: message"` without interpolating the error's `vars`, so a refused
  # brand token arrived as a literal `%{value}` template.
  defp error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's branding."),
      fallback: gettext("Branding could not be saved.")
    )
  end

  # The values in force right now, used as input placeholders so an admin can
  # see what a blank field will inherit.
  defp inherited(socket_org), do: Branding.for_org(socket_org)

  # One entry per menu KEY (menus are one key with a row per locale — the
  # layout picks the request-locale variant), labelled by the first row's name.
  # The empty option is the unconfigured slot: stock links in the header,
  # nothing in the footer.
  defp menu_options(socket) do
    case CMS.list_menus(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, menus} ->
        menus
        |> Enum.uniq_by(& &1.key)
        |> Enum.map(fn menu -> {"#{menu.name} (#{menu.key})", menu.key} end)

      _ ->
        []
    end
  end

  # Select options for the theme presets, first (:standard) as the fallback the
  # resolver applies to a blank column.
  defp theme_options do
    labels = %{
      standard: gettext("Standard — the stock look"),
      editorial: gettext("Editorial — serif, narrower reading column"),
      studio: gettext("Studio — wide, bold display headings"),
      monograph: gettext("Monograph — condensed display type, full-bleed images")
    }

    Enum.map(Branding.themes(), fn theme ->
      {Map.get(labels, theme, Phoenix.Naming.humanize(theme)), Atom.to_string(theme)}
    end)
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, default: nil
  attr :hint, :string, default: nil

  # One image field: a thumbnail of what it holds, the URL box, and the two
  # shortcuts that fill the box — the library drawer and an upload (#1811).
  defp image_field(assigns) do
    value = assigns.field.value
    # Only a URL the save would accept is previewed, so the thumbnail never
    # makes the admin's browser fetch from a host the image policy refuses.
    shown = if is_binary(value) and BrandTokens.allowed_image_url?(value), do: value

    assigns =
      assigns
      |> assign(:shown, shown)
      |> assign(:name, assigns.field.field |> to_string())
      |> assign(:errors, upload_errors(assigns.upload))

    ~H"""
    <div id={"image-field-#{@name}"} class="flex gap-4">
      <div class="flex size-16 shrink-0 items-center justify-center overflow-hidden rounded-lg border border-base-content/10 bg-base-200">
        <img
          :if={@shown}
          src={@shown}
          alt=""
          id={"image-field-#{@name}-preview"}
          class="max-h-full max-w-full object-contain"
        />
        <.icon :if={!@shown} name="hero-photo" class="size-6 text-base-content/30" />
      </div>

      <div class="min-w-0 flex-1 space-y-2">
        <.input field={@field} label={@label} placeholder={@placeholder} hint={@hint} />

        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            phx-click="open_picker"
            phx-value-field={@name}
            class="btn btn-sm btn-default"
          >
            <.icon name="hero-photo" class="size-4" />
            {gettext("Choose from library")}
          </button>

          <label class="btn btn-sm btn-default cursor-pointer focus-within:ring-2 focus-within:ring-primary">
            <.icon name="hero-arrow-up-tray" class="size-4" />
            {gettext("Upload")}
            <.live_file_input upload={@upload} class="sr-only" />
          </label>

          <button
            :if={@field.value not in [nil, ""]}
            type="button"
            phx-click="clear_image"
            phx-value-field={@name}
            class="btn btn-sm btn-ghost"
          >
            {gettext("Remove")}
          </button>
        </div>

        <div
          :for={entry <- @upload.entries}
          id={"upload-#{entry.ref}"}
          class="flex items-center gap-2 text-xs text-base-content/70"
        >
          <span class="min-w-0 truncate">{entry.client_name}</span>
          <span :if={upload_errors(@upload, entry) == []} role="status">
            {gettext("Uploading… %{percent}%", percent: entry.progress)}
          </span>
          <span :for={err <- upload_errors(@upload, entry)} class="text-error">
            {upload_error_text(err)}
          </span>
          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-upload={@upload.name}
            phx-value-ref={entry.ref}
            class="underline"
          >
            {gettext("Dismiss")}
          </button>
        </div>

        <p :for={err <- @errors} class="text-xs text-error">{upload_error_text(err)}</p>
      </div>
    </div>
    """
  end

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

          <.image_field
            field={@form[:logo_url]}
            upload={@uploads.logo_upload}
            label={gettext("Logo")}
            placeholder={@inherited.logo_url}
            hint={
              gettext(
                "Choose an image from the media library or upload one. To use an image stored elsewhere, paste its https:// address."
              )
            }
          />

          <.image_field
            field={@form[:favicon_url]}
            upload={@uploads.favicon_upload}
            label={gettext("Favicon")}
            placeholder={@inherited.favicon_url}
            hint={
              gettext(
                "The small icon in the browser tab. Use a square PNG. For an .ico or .svg file, paste its address."
              )
            }
          />

          <.image_field
            field={@form[:social_image_url]}
            upload={@uploads.social_image_upload}
            label={gettext("Default social image")}
            hint={gettext("Used for link previews when a page has no image of its own.")}
          />

          <.image_field
            field={@form[:app_icon_url]}
            upload={@uploads.app_icon_upload}
            label={gettext("App icon")}
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
                "Used for buttons, links and highlights, on the public site and here in the editor. Kiln adjusts it slightly if needed so text on it stays readable. In dark mode a lighter shade is used."
              )
            }
          />

          <%!-- The preview is what the colour will DO, on the two surfaces it
                lands on: a button and a link on a light page and on a dark
                one (#1810). Rendered from the derived tokens, so it is exactly
                what Save will emit. --%>
          <div :if={@preview} id="brand-colour-preview" class="space-y-2">
            <p class="text-xs text-base-content/70">{gettext("Preview")}</p>

            <div
              :for={
                {mode, label, surface, fill, ink, link} <- [
                  {"light", gettext("Light mode"), "#ffffff", @preview.light_primary,
                   @preview.light_content, @preview.light_ink},
                  {"dark", gettext("Dark mode"), "#1b1e23", @preview.dark_primary,
                   @preview.dark_content, @preview.dark_ink}
                ]
              }
              id={"brand-preview-#{mode}"}
              class="flex flex-wrap items-center gap-3 rounded-lg border border-base-content/10 p-3"
              style={"background-color:#{surface}"}
            >
              <span
                class="inline-flex items-center rounded-md px-3 py-1.5 text-xs font-semibold shadow-sm"
                style={"background-color:#{fill};color:#{ink}"}
              >
                {gettext("Button")}
              </span>
              <span class="text-xs font-medium underline" style={"color:#{link}"}>
                {gettext("A link")}
              </span>
              <span
                class="ml-auto text-[11px]"
                style={"color:#{if mode == "dark", do: "#c9ced6", else: "#5b6270"}"}
              >
                {label}
              </span>
            </div>
          </div>

          <p :if={@form[:brand_color].value not in [nil, ""] and !@preview} class="text-xs text-error">
            {gettext("That colour has no readable button text — pick a different one.")}
          </p>
        </div>

        <div class="card card-pad lg:col-span-3 space-y-4">
          <h2 class="text-sm font-medium">{gettext("Public site")}</h2>

          <div class="grid gap-4 sm:grid-cols-3">
            <.input
              field={@form[:theme]}
              type="select"
              label={gettext("Theme")}
              options={theme_options()}
              hint={gettext("Typography and page width for the public pages.")}
            />

            <.input
              field={@form[:header_menu_key]}
              type="select"
              label={gettext("Header menu")}
              prompt={gettext("Stock links (Blog, Search)")}
              options={@menu_options}
              hint={gettext("Top-level items replace the stock header links.")}
            />

            <.input
              field={@form[:footer_menu_key]}
              type="select"
              label={gettext("Footer menu")}
              prompt={gettext("None")}
              options={@menu_options}
              hint={gettext("Rendered as link sections above the attribution line.")}
            />
          </div>

          <p class="text-xs text-base-content/70">
            {gettext("Need more than a preset? Custom CSS for the public site lives in")}
            <.link navigate={~p"/editor/code-injection"} class="underline">
              {gettext("Code injection")}
            </.link>.
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

      <%!-- Outside the branding form: the drawer has its own search form, and
            forms do not nest. --%>
      <.image_picker
        :if={@picking}
        index={@picking}
        title={picker_title(@picking)}
        media={@picker_media}
        results={@picker_results}
        query={@media_query}
        unsplash_enabled?={false}
        picker_tab={:library}
        unsplash_query=""
        unsplash_photos={[]}
        unsplash_more?={false}
        unsplash_searching?={false}
        unsplash_importing={MapSet.new()}
      />
    </Layouts.console>
    """
  end
end
