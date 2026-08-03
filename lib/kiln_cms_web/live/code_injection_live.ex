defmodule KilnCMSWeb.CodeInjectionLive do
  @moduledoc """
  Per-site code injection settings (#490): custom `<head>` / footer HTML for the
  **delivery site**, plus the CSP origins that let it run.

  Scoped to the request's org, like `/editor/branding` — you configure the site
  you are on. Writes are policy-gated to org admins by
  `KilnCMS.CMS.SiteCodeInjection`, and this LiveView lives in the
  `:admin_routes` live session whose `:live_admin_required` hook gates on the
  same org tier, so the router guard and the resource policy agree.

  ## The page has to be honest about what it is

  This form writes script that runs on every public page of the site. The UI
  says so plainly rather than presenting it as another settings panel: an admin
  pasting a vendor snippet should know the trust boundary they are extending,
  and an admin who did not expect the page to exist should be able to tell from
  looking at it what it does.

  It also shows the derived script hashes after a save. That is not decoration —
  it is how an admin confirms the CSP will actually permit the inline script
  they just pasted, without opening a browser console.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS

  @text_fields ~w(head_html footer_html)
  @origin_fields ~w(script_src connect_src img_src)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Code injection"))
     |> load_injection()}
  end

  @impl true
  def handle_event("validate", %{"injection" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :injection))}
  end

  def handle_event("save", %{"injection" => params}, socket) do
    case CMS.save_site_code_injection(attrs(params),
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Code injection saved."))
         |> load_injection()}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :injection))
         |> put_flash(:error, error_message(error))}
    end
  end

  def handle_event("reset", _params, socket) do
    case current_row(socket) do
      nil ->
        {:noreply, socket}

      row ->
        CMS.reset_site_code_injection!(row,
          actor: socket.assigns.current_user,
          tenant: socket.assigns.current_org
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Code injection removed."))
         |> load_injection()}
    end
  end

  defp attrs(params) do
    text = Map.new(@text_fields, fn field -> {field, blank_to_nil(params[field])} end)
    origins = Map.new(@origin_fields, fn field -> {field, parse_origins(params[field])} end)

    text
    |> Map.merge(origins)
    |> Map.put("enabled", params["enabled"] in [true, "true", "on"])
  end

  # One origin per line, which is what someone pastes. Blank lines and stray
  # whitespace are dropped rather than validated into an error — a trailing
  # newline is not a mistake worth a red form.
  defp parse_origins(nil), do: []

  defp parse_origins(value) do
    value
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp load_injection(socket) do
    row = current_row(socket)

    params = %{
      "head_html" => row && row.head_html,
      "footer_html" => row && row.footer_html,
      "script_src" => origins_text(row, :script_src),
      "connect_src" => origins_text(row, :connect_src),
      "img_src" => origins_text(row, :img_src),
      "enabled" => if(row, do: row.enabled, else: true)
    }

    socket
    |> assign(:row, row)
    |> assign(:form, to_form(params, as: :injection))
  end

  defp origins_text(nil, _field), do: ""
  defp origins_text(row, field), do: row |> Map.get(field, []) |> Enum.join("\n")

  defp current_row(socket) do
    case CMS.list_site_code_injection(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _ -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp blank_to_nil(value), do: value

  defp error_message(error) do
    case error do
      %Ash.Error.Forbidden{} ->
        gettext("You don't have permission to change this site's code injection.")

      _ ->
        error
        |> Ash.Error.to_error_class()
        |> Map.get(:errors, [])
        |> Enum.map_join(" ", &describe_error/1)
        |> case do
          "" -> gettext("Code injection could not be saved.")
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
      active={:code_injection}
    >
      <.header>
        {gettext("Code injection")}
        <:subtitle>
          {gettext("Custom HTML added to every page of this site's public pages. Not the editor.")}
        </:subtitle>
      </.header>

      <div class="mt-6 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm text-warning-ink">
        <p class="font-medium">{gettext("This runs code on your public site.")}</p>
        <p class="mt-1">
          {gettext(
            "Anything you paste here is served to every visitor, exactly as written, with no filtering. Only add snippets from a source you trust — an analytics tag, a verification meta tag, a support widget. Every change is recorded with your name against it."
          )}
        </p>
      </div>

      <.form
        for={@form}
        id="code-injection-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-8 space-y-8"
      >
        <.input
          field={@form[:enabled]}
          type="checkbox"
          label={gettext("Serve these snippets")}
          value={@form[:enabled].value}
        />

        <.input
          field={@form[:head_html]}
          type="textarea"
          rows="8"
          label={gettext("Head HTML")}
          placeholder={"<!-- " <> gettext("added just before </head>") <> " -->"}
        />

        <.input
          field={@form[:footer_html]}
          type="textarea"
          rows="8"
          label={gettext("Footer HTML")}
          placeholder={"<!-- " <> gettext("added just before </body>") <> " -->"}
        />

        <div class="rounded-lg border border-base-300 p-4">
          <h3 class="text-sm font-semibold">{gettext("Allowed origins")}</h3>
          <p class="mt-1 text-sm text-base-content/70">
            {gettext(
              "This site's Content-Security-Policy blocks scripts, connections and images from hosts it doesn't know. List the origins your snippet needs — one per line, e.g. https://plausible.io — or the browser will silently refuse them. Inline <script> blocks are allowed automatically once you save."
            )}
          </p>

          <div class="mt-4 grid gap-4 sm:grid-cols-3">
            <.input
              field={@form[:script_src]}
              type="textarea"
              rows="3"
              label={gettext("Scripts")}
            />
            <.input
              field={@form[:connect_src]}
              type="textarea"
              rows="3"
              label={gettext("Connections")}
            />
            <.input field={@form[:img_src]} type="textarea" rows="3" label={gettext("Images")} />
          </div>
        </div>

        <div :if={@row && @row.script_hashes != []} class="rounded-lg bg-base-200 p-4 text-sm">
          <p class="font-medium">
            {gettext("Inline scripts allowed by this site's policy")}
          </p>
          <p class="mt-1 text-base-content/70">
            {gettext(
              "Derived from the snippets above when you saved. If a script you pasted isn't listed, the browser will block it."
            )}
          </p>
          <ul class="mt-2 space-y-1 font-mono text-xs">
            <li :for={hash <- @row.script_hashes} class="truncate">sha256-{hash}</li>
          </ul>
        </div>

        <div class="flex items-center gap-3">
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
          <.button
            :if={@row}
            type="button"
            variant="ghost"
            phx-click="reset"
            data-confirm={gettext("Remove this site's custom code entirely?")}
          >
            {gettext("Remove")}
          </.button>
        </div>
      </.form>
    </Layouts.console>
    """
  end
end
