defmodule KilnCMSWeb.LocaleSettingsLive do
  @moduledoc """
  Per-site locale fallback chains: which translation a reader gets when the
  one they asked for is not published — `fr-CA → fr → en`.

  Scoped to the request's org like `/editor/feeds`. Writes are policy-gated to
  org admins by `KilnCMS.CMS.SiteLocaleSettings`, and this LiveView sits in the
  `:admin_routes` live session whose tier gate agrees.

  ## One row per locale, three answers each

  The stored shape is one map, but the question an admin is answering is per
  locale, and it has three answers that must stay distinct
  (`KilnCMS.I18n.Fallback`):

    * **the default locale** — no entry; what the site has always done;
    * **these locales, in order** — an explicit chain;
    * **never** — an empty chain: a missing translation is a 404, not English.

  So each locale gets a select for which of the three, and a text box for the
  chain when it is the second. Locale tags are the deployment's own
  (`KilnCMS.I18n.locales/0`) and the form only ever reads the rows it rendered,
  so no client-chosen string becomes a key in the saved map.

  Save writes the whole map; **Use the operator defaults** drops the row and
  goes back to inheriting `config :kiln_cms, :i18n, fallbacks: …`.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.I18n
  alias KilnCMS.I18n.Fallback

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Locales"))
     |> assign(:locales, I18n.locales())
     |> assign(:default_locale, I18n.default_locale())
     |> load_settings()}
  end

  @impl true
  def handle_event("save", params, socket) do
    fallbacks =
      socket.assigns.locales
      |> Enum.flat_map(&entry(&1, row_params(params, &1)))
      |> Map.new()

    case CMS.save_site_locale_settings(%{fallbacks: fallbacks},
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Locale fallbacks saved."))
         |> load_settings()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("reset", _params, socket) do
    # Re-read rather than destroying the struct assigned at mount, for the
    # reason `FeedSettingsLive` gives: a second tab may already have dropped it.
    case current_row(socket) do
      nil ->
        {:noreply, load_settings(socket)}

      row ->
        case CMS.reset_site_locale_settings(row,
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_org
             ) do
          {:error, error} ->
            {:noreply, socket |> put_flash(:error, error_message(error)) |> load_settings()}

          _destroyed ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Locale fallbacks reset to the operator defaults."))
             |> load_settings()}
        end
    end
  end

  # `params["fallbacks"][locale]`, read only for locales this page rendered.
  # Client-controlled and query-decoded, so any level may be a bare binary.
  defp row_params(%{"fallbacks" => %{} = rows}, locale) do
    case Map.get(rows, locale) do
      %{} = row -> row
      _other -> %{}
    end
  end

  defp row_params(_params, _locale), do: %{}

  defp entry(locale, %{"mode" => "none"}), do: [{locale, []}]

  # An empty custom chain is kept as an explicit `[]` only if the admin chose
  # "never"; a "these locales" row left blank means they have not said anything
  # yet, which is the default behaviour, not a refusal to fall back.
  defp entry(locale, %{"mode" => "chain", "chain" => chain}) when is_binary(chain) do
    case chain |> String.split([",", " "], trim: true) |> Enum.map(&String.trim/1) do
      [] -> []
      tags -> [{locale, tags}]
    end
  end

  defp entry(_locale, _row), do: []

  defp load_settings(socket) do
    row = current_row(socket)

    socket
    |> assign(:row, row)
    # The resolved chains, so each row shows what the site does today whether
    # that comes from this row or from the operator config beneath it — from
    # the row in hand, not through `Fallback.chains/1` (which would read it
    # again and always miss its cache on the save path).
    |> assign(:chains, Fallback.for_row(row))
    |> assign(:defaults, Fallback.defaults())
    |> assign(:form, to_form(%{}, as: :fallbacks))
  end

  defp current_row(socket) do
    case CMS.list_site_locale_settings(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _other -> nil
    end
  end

  defp mode(%Fallback.Chains{explicit: explicit}, locale) do
    case Map.fetch(explicit, locale) do
      :error -> "default"
      {:ok, []} -> "none"
      {:ok, _chain} -> "chain"
    end
  end

  defp chain_text(%Fallback.Chains{explicit: explicit}, locale),
    do: explicit |> Map.get(locale, []) |> Enum.join(", ")

  # The whole walk a request for `locale` makes, for the "Tries" column.
  defp walk(chains, locale), do: chains |> Fallback.chain(locale) |> Enum.join(" → ")

  defp error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's locale settings."),
      fallback: gettext("Locale fallbacks could not be saved.")
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:locales}
    >
      <.header>
        {gettext("Locales")}
        <:subtitle>
          {gettext(
            "What a reader gets when the translation they asked for has not been published — on this site's pages, its API and its menus."
          )}
        </:subtitle>
      </.header>

      <div
        :if={length(@locales) < 2}
        class="mt-6 rounded-lg border border-base-300 bg-base-200 p-4 text-sm"
      >
        <p class="font-medium">{gettext("This deployment runs one locale.")}</p>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "Fallbacks only matter once there is a second language to fall back from. The operator adds locales in configuration."
          )}
        </p>
      </div>

      <div
        :if={is_nil(@row) and length(@locales) > 1}
        class="mt-6 rounded-lg border border-base-300 bg-base-200 p-4 text-sm"
      >
        <p class="font-medium">{gettext("This site is using the deployment defaults.")}</p>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "Nothing has been set for this site yet, so it follows whatever the operator configured for the whole deployment. Saving below gives this site its own chains."
          )}
        </p>
      </div>

      <.form
        :if={length(@locales) > 1}
        for={@form}
        id="locale-settings-form"
        phx-submit="save"
        class="mt-8 space-y-8"
      >
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th scope="col">{gettext("Locale")}</th>
                <th scope="col">{gettext("When a translation is missing")}</th>
                <th scope="col">{gettext("Fall back to")}</th>
                <th scope="col">{gettext("Tries")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={locale <- @locales} id={"locale-#{locale}"}>
                <td>
                  <span class="font-mono font-medium">{locale}</span>
                  <span class="ml-2 text-xs text-base-content/60">
                    {I18n.language_name(locale)}
                  </span>
                </td>
                <td>
                  <select
                    name={"fallbacks[#{locale}][mode]"}
                    class="field-select w-auto py-1"
                    aria-label={gettext("Fallback for %{locale}", locale: locale)}
                  >
                    <option value="default" selected={mode(@chains, locale) == "default"}>
                      {gettext("Use the default locale (%{locale})", locale: @default_locale)}
                    </option>
                    <option value="chain" selected={mode(@chains, locale) == "chain"}>
                      {gettext("Try these locales, in order")}
                    </option>
                    <option value="none" selected={mode(@chains, locale) == "none"}>
                      {gettext("Never — show nothing")}
                    </option>
                  </select>
                </td>
                <td>
                  <input
                    type="text"
                    name={"fallbacks[#{locale}][chain]"}
                    value={chain_text(@chains, locale)}
                    placeholder={gettext("e.g. fr, en")}
                    class="field-input py-1 font-mono"
                    aria-label={gettext("Locales %{locale} falls back to", locale: locale)}
                  />
                </td>
                <td class="font-mono text-xs text-base-content/70">{walk(@chains, locale)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="rounded-lg border border-base-300 p-4 text-sm">
          <p class="font-medium">{gettext("A chain is taken as written.")}</p>
          <p class="mt-1 text-base-content/70">
            {gettext(
              "\"fr, en\" tries French, then English, then stops. Navigation menus follow a chain you write here, but never fall back to the default locale on their own. A headless request can narrow the chain with ?fallback=false or ?fallback_locale=, and every response says which locale it served."
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
              gettext("Remove this site's locale fallbacks and follow the deployment defaults again?")
            }
            class="btn btn-ghost btn-sm"
          >
            {gettext("Use the operator defaults")}
          </button>
        </div>
      </.form>

      <section :if={length(@locales) > 1} class="mt-10 rounded-lg bg-base-200 p-4 text-sm">
        <h2 class="font-medium">{gettext("Deployment defaults")}</h2>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "Set by the operator in configuration, and used by any site that has not saved its own chains above."
          )}
        </p>
        <dl class="mt-3 grid gap-2 sm:grid-cols-3">
          <div :for={locale <- @locales}>
            <dt class="font-mono text-xs text-base-content/60">{locale}</dt>
            <dd class="font-mono text-xs">{walk(@defaults, locale)}</dd>
          </div>
        </dl>
      </section>
    </Layouts.console>
    """
  end
end
